#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-runtime-security.sh [--mutation-test]

Proves the runtime-security pieces in kubernetes/platform/runtime-security
without touching any cluster (the Tetragon records and the runtime alert rules
are proven by test-observability-logs.sh, against the real Alloy pipeline and
VictoriaLogs):

  chart     downloads the Tetragon chart named by the HelmRelease and refuses
            it unless its SHA-256 is the one reviewed below, so a version bump
            needs a person to read the new chart and record its digest
  policies  starts a throwaway etcd and kube-apiserver at the cluster's
            Kubernetes version, installs the chart's CRDs and sends every
            TracingPolicy as a server-side dry run, so the CRD's OpenAPI schema
            (argument types, operators, enums, required fields) judges them
            exactly as the live API server will
  mode      every TracingPolicy names its policy-mode, monitor or enforce;
            Tetragon enforces a policy that names none

  --mutation-test  also breaks each check on purpose and requires it to fail:
                   a policy without policy-mode, and a policy with an operator
                   the CRD does not know.

Downloads kube-apiserver, kubectl and etcd at pinned versions,
checksum-verified, into a cache directory. Needs curl, jq, sha256sum, tar
and node."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly runtime_dir="${repo_root}/kubernetes/platform/runtime-security"
readonly policy_dir="${runtime_dir}/policies"
readonly helmrelease="${runtime_dir}/tetragon/helmrelease.yaml"

readonly tetragon_chart_version="1.7.1"
readonly tetragon_chart_sha256="79ec0f7d35b6fcad99ca317348deac136c00b674430c28be17aa818d2015c632"

# renovate: datasource=github-releases depName=kubernetes/kubernetes
readonly kubernetes_version="v1.37.1"
readonly kube_apiserver_sha256_linux_amd64="de9b1b43c10143f448408b3aaf15f44fd5248b97a56301417a1fe2f1fc47a691"
readonly kubectl_sha256_linux_amd64="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"

# renovate: datasource=github-releases depName=etcd-io/etcd
readonly etcd_version="v3.7.3"
readonly etcd_sha256_linux_amd64="5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775"

readonly etcd_client_port="${RUNTIME_TEST_ETCD_PORT:-23890}"
readonly etcd_peer_port="$((etcd_client_port + 1))"
readonly api_port="${RUNTIME_TEST_API_PORT:-16543}"
readonly ready_timeout_seconds=90

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only linux-amd64 binaries are pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-runtime-security-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/runtime-security-test.XXXXXX")"
readonly work_dir
readonly kubeconfig="${work_dir}/kubeconfig"
background_pids=()

stop_servers() {
  for pid in "${background_pids[@]}"; do
    kill -KILL "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "${work_dir}"
}
trap stop_servers EXIT

failures=()

record_failure() {
  failures+=("$1")
  echo "FAIL  $1" >&2
}

pass() {
  echo "ok    $1"
}

download_verified() {
  local url="$1" sha256="$2" target="$3"
  if [ -f "${target}" ] && echo "${sha256}  ${target}" | sha256sum -c --status -; then
    return
  fi
  mkdir -p "$(dirname "${target}")"
  curl -fsSL --retry 3 -o "${target}.partial" "${url}"
  echo "${sha256}  ${target}.partial" | sha256sum -c --quiet -
  mv "${target}.partial" "${target}"
}

install_binaries() {
  local k8s_dir="${cache_dir}/kubernetes-${kubernetes_version}"
  download_verified "https://dl.k8s.io/${kubernetes_version}/bin/linux/amd64/kube-apiserver" \
    "${kube_apiserver_sha256_linux_amd64}" "${k8s_dir}/kube-apiserver"
  download_verified "https://dl.k8s.io/${kubernetes_version}/bin/linux/amd64/kubectl" \
    "${kubectl_sha256_linux_amd64}" "${k8s_dir}/kubectl"
  chmod 0755 "${k8s_dir}/kube-apiserver" "${k8s_dir}/kubectl"

  local etcd_archive="${cache_dir}/etcd-${etcd_version}-linux-amd64.tar.gz"
  download_verified "https://github.com/etcd-io/etcd/releases/download/${etcd_version}/etcd-${etcd_version}-linux-amd64.tar.gz" \
    "${etcd_sha256_linux_amd64}" "${etcd_archive}"
  tar -xzf "${etcd_archive}" -C "${work_dir}" "etcd-${etcd_version}-linux-amd64/etcd"

  kube_apiserver="${k8s_dir}/kube-apiserver"
  kubectl_bin="${k8s_dir}/kubectl"
  etcd_bin="${work_dir}/etcd-${etcd_version}-linux-amd64/etcd"
}

kubectl() {
  "${kubectl_bin}" --kubeconfig "${kubeconfig}" "$@"
}

declared_chart_version() {
  sed -n 's/^ *version: *\([0-9][0-9.]*\) *$/\1/p' "$1" | head -n 1
}

check_chart() {
  local declared archive="${work_dir}/tetragon-${tetragon_chart_version}.tgz"
  declared="$(declared_chart_version "${helmrelease}")"
  if [ "${declared}" != "${tetragon_chart_version}" ]; then
    record_failure "chart: the HelmRelease asks for tetragon ${declared}, but the reviewed digest is for ${tetragon_chart_version}; read the new chart and update tetragon_chart_version and tetragon_chart_sha256 here"
    return
  fi
  curl -fsSL --retry 3 -o "${archive}" "https://helm.cilium.io/tetragon-${tetragon_chart_version}.tgz"
  if echo "${tetragon_chart_sha256}  ${archive}" | sha256sum -c --status -; then
    pass "chart: tetragon ${tetragon_chart_version} has the reviewed SHA-256"
  else
    record_failure "chart: tetragon ${tetragon_chart_version} from helm.cilium.io no longer has the reviewed SHA-256"
    return
  fi
  tar -xzf "${archive}" -C "${work_dir}" tetragon/crds-yaml
}

write_service_account_key() {
  node -e '
    const { generateKeyPairSync } = require("crypto");
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    process.stdout.write(privateKey.export({ type: "sec1", format: "pem" }));
  ' >"${work_dir}/service-account.key"
  chmod 0600 "${work_dir}/service-account.key"
}

start_servers() {
  "${etcd_bin}" \
    --data-dir "${work_dir}/etcd" \
    --listen-client-urls "http://127.0.0.1:${etcd_client_port}" \
    --advertise-client-urls "http://127.0.0.1:${etcd_client_port}" \
    --listen-peer-urls "http://127.0.0.1:${etcd_peer_port}" \
    --initial-advertise-peer-urls "http://127.0.0.1:${etcd_peer_port}" \
    --initial-cluster "default=http://127.0.0.1:${etcd_peer_port}" \
    --log-level error >"${work_dir}/etcd.log" 2>&1 &
  background_pids+=("$!")

  local token
  token="$(head -c 32 /dev/urandom | sha256sum | cut -c1-48)"
  printf '%s,runtime-test,runtime-test,system:masters\n' "${token}" >"${work_dir}/tokens.csv"
  write_service_account_key

  "${kube_apiserver}" \
    --etcd-servers "http://127.0.0.1:${etcd_client_port}" \
    --bind-address 127.0.0.1 \
    --advertise-address 127.0.0.1 \
    --endpoint-reconciler-type none \
    --secure-port "${api_port}" \
    --cert-dir "${work_dir}/certs" \
    --token-auth-file "${work_dir}/tokens.csv" \
    --authorization-mode AlwaysAllow \
    --disable-admission-plugins ServiceAccount \
    --service-account-issuer https://kubernetes.default.svc \
    --service-account-key-file "${work_dir}/service-account.key" \
    --service-account-signing-key-file "${work_dir}/service-account.key" \
    --service-cluster-ip-range 10.66.0.0/16 >"${work_dir}/kube-apiserver.log" 2>&1 &
  background_pids+=("$!")

  cat >"${kubeconfig}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: throwaway
    cluster:
      server: https://127.0.0.1:${api_port}
      insecure-skip-tls-verify: true
users:
  - name: runtime-test
    user:
      token: ${token}
contexts:
  - name: throwaway
    context:
      cluster: throwaway
      user: runtime-test
current-context: throwaway
EOF
  chmod 0600 "${kubeconfig}"

  local waited=0 api_server_pid="${background_pids[-1]}"
  until kubectl get --raw /readyz >/dev/null 2>&1; do
    waited=$((waited + 1))
    if [ "${waited}" -ge "${ready_timeout_seconds}" ] || ! kill -0 "${api_server_pid}" 2>/dev/null; then
      echo "the throwaway API server did not become ready; its log:" >&2
      tail -n 40 "${work_dir}/kube-apiserver.log" >&2
      exit 1
    fi
    sleep 1
  done
}

install_crds() {
  kubectl apply --server-side -f "${work_dir}/tetragon/crds-yaml" >/dev/null
  kubectl wait --for condition=Established --timeout 60s crd/tracingpolicies.cilium.io >/dev/null
  until kubectl api-resources --api-group cilium.io -o name 2>/dev/null | grep -qx 'tracingpolicies.cilium.io'; do sleep 1; done
}

policy_files() {
  find "$1" -maxdepth 1 -name '*.yaml' ! -name kustomization.yaml | sort
}

dry_run_policies() {
  kubectl apply --server-side --dry-run=server -o json -f "$1" 2>&1
}

policy_modes() {
  jq -r '(if .kind == "List" then .items[] else . end)
    | [.metadata.name, ([.spec.options[]? | select(.name == "policy-mode") | .value] | first // "")]
    | @tsv'
}

check_policies() {
  local dir="$1" expect="$2" label="$3" file output
  local admitted=true
  for file in $(policy_files "${dir}"); do
    if ! output="$(dry_run_policies "${file}")"; then
      admitted=false
      [ "${expect}" = admitted ] && record_failure "policies: ${label}: the API server refused ${file##*/}: ${output}"
      continue
    fi
    if [ "${expect}" = admitted ]; then
      pass "policies: ${label}: ${file##*/} passes the CRD schema"
    fi
  done
  if [ "${expect}" = refused ] && [ "${admitted}" = true ]; then
    record_failure "policies: ${label}: every policy was admitted, so the schema check proves nothing"
  elif [ "${expect}" = refused ]; then
    pass "policies: ${label}: the API server refused it"
  fi
}

check_modes() {
  local dir="$1" expect="$2" label="$3" file name mode
  local unnamed=()
  for file in $(policy_files "${dir}"); do
    while IFS=$'\t' read -r name mode; do
      case "${mode}" in
        monitor | enforce) ;;
        *) unnamed+=("${name}") ;;
      esac
    done < <(dry_run_policies "${file}" | policy_modes)
  done
  if [ "${expect}" = pass ] && [ "${#unnamed[@]}" -eq 0 ]; then
    pass "mode: ${label}: every policy names monitor or enforce"
  elif [ "${expect}" = pass ]; then
    record_failure "mode: ${label}: these policies name no policy-mode, so Tetragon would enforce them: ${unnamed[*]}"
  elif [ "${#unnamed[@]}" -gt 0 ]; then
    pass "mode: ${label}: the gate names ${unnamed[*]}"
  else
    record_failure "mode: ${label}: the gate found nothing to refuse"
  fi
}

mutate_policies() {
  local mutant="${work_dir}/mutant-policies"
  rm -rf "${mutant}"
  cp -r "${policy_dir}" "${mutant}"
  local victim
  victim="$(policy_files "${mutant}" | head -n 1)"
  sed -i '/^  options:$/,/^      value: monitor$/d' "${victim}"
  check_modes "${mutant}" fail "${victim##*/} without its options"

  rm -rf "${mutant}"
  mkdir -p "${mutant}"
  cp "$(policy_files "${policy_dir}" | head -n 1)" "${mutant}/"
  local original
  original="$(find "${mutant}" -name '*.yaml')"
  awk '!done && /operator: [A-Za-z]+/ { sub(/operator: [A-Za-z]+/, "operator: PrefixOf"); done = 1 } { print }' \
    "${original}" >"${original}.mutated"
  mv "${original}.mutated" "${original}"
  check_policies "${mutant}" refused "an operator the CRD does not know"
}

mutate_chart() {
  local mutant="${work_dir}/helmrelease-mutant.yaml"
  sed "s/version: ${tetragon_chart_version}/version: 1.7.2/" "${helmrelease}" >"${mutant}"
  if [ "$(declared_chart_version "${mutant}")" = "${tetragon_chart_version}" ]; then
    record_failure "chart mutation: a HelmRelease that asks for 1.7.2 still matches the reviewed version"
  else
    pass "chart mutation: a HelmRelease that asks for 1.7.2 no longer matches the reviewed digest"
  fi
}

install_binaries
check_chart
if [ -d "${work_dir}/tetragon/crds-yaml" ]; then
  start_servers
  install_crds
  check_policies "${policy_dir}" admitted "live set"
  check_modes "${policy_dir}" pass "live set"
fi

if [ "${mutation_test}" = true ]; then
  mutate_chart
  [ -d "${work_dir}/tetragon/crds-yaml" ] && mutate_policies
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} check(s) failed" >&2
  exit 1
fi
echo "all runtime-security checks passed"
