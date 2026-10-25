#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-runtime-security.sh [--mutation-test]

Proves the runtime-security pieces in kubernetes/platform/runtime-security and
the Tetragon part of the Vector pipeline without touching any cluster:

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
  vector    runs Vector's own unit tests in tests/runtime-security against
            kubernetes/platform/observability/vector/vector.yaml, and checks
            that the Tetragon records reach the homelab sink

  --mutation-test  also breaks each check on purpose and requires it to fail:
                   a policy without policy-mode, a policy with an operator the
                   CRD does not know, and each Vector mutation listed below.

Downloads kube-apiserver, kubectl, etcd and Vector at pinned versions,
checksum-verified, into a cache directory. Needs curl, jq, sha256sum, tar
and node."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly runtime_dir="${repo_root}/kubernetes/platform/runtime-security"
readonly policy_dir="${runtime_dir}/policies"
readonly helmrelease="${runtime_dir}/tetragon/helmrelease.yaml"
readonly vector_config="${repo_root}/kubernetes/platform/observability/vector/vector.yaml"
readonly vector_tests="${repo_root}/tests/runtime-security/vector-tetragon.test.yaml"

readonly tetragon_chart_version="1.7.1"
readonly tetragon_chart_sha256="79ec0f7d35b6fcad99ca317348deac136c00b674430c28be17aa818d2015c632"

# renovate: datasource=github-releases depName=kubernetes/kubernetes
readonly kubernetes_version="v1.37.1"
readonly kube_apiserver_sha256_linux_amd64="de9b1b43c10143f448408b3aaf15f44fd5248b97a56301417a1fe2f1fc47a691"
readonly kubectl_sha256_linux_amd64="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"

# renovate: datasource=github-releases depName=etcd-io/etcd
readonly etcd_version="v3.7.3"
readonly etcd_sha256_linux_amd64="5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775"

# renovate: datasource=github-releases depName=vectordotdev/vector
readonly vector_version="v0.60.0"
readonly vector_sha256_linux_amd64_musl="9584f402e67fea7ff2dd846f0a8bbb56fa32951bded11749093ff3780e1513cf"

readonly etcd_client_port="${RUNTIME_TEST_ETCD_PORT:-23890}"
readonly etcd_peer_port="$((etcd_client_port + 1))"
readonly api_port="${RUNTIME_TEST_API_PORT:-16543}"
readonly ready_timeout_seconds=90

readonly vector_mutations=(
  's/bool(process.in_init_tree) ?? false/true/'
  's/string(argument.sock_arg.daddr) ?? ""/""/'
  's/string(argument.file_arg.path) ?? //'
  's/del(event.node_labels)/event.node_labels = event.node_labels/'
  's/"policy": policy,/"policy": "",/'
  's/location = if namespace == "" { "host" }/location = if namespace == "" { "" }/'
)

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

  local vector_archive="${cache_dir}/vector-${vector_version#v}-x86_64-unknown-linux-musl.tar.gz"
  download_verified "https://github.com/vectordotdev/vector/releases/download/${vector_version}/vector-${vector_version#v}-x86_64-unknown-linux-musl.tar.gz" \
    "${vector_sha256_linux_amd64_musl}" "${vector_archive}"
  tar -xzf "${vector_archive}" -C "${work_dir}" ./vector-x86_64-unknown-linux-musl/bin/vector

  kube_apiserver="${k8s_dir}/kube-apiserver"
  kubectl_bin="${k8s_dir}/kubectl"
  etcd_bin="${work_dir}/etcd-${etcd_version}-linux-amd64/etcd"
  vector_bin="${work_dir}/vector-x86_64-unknown-linux-musl/bin/vector"
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

run_vector_tests() {
  VECTOR_SELF_NODE_NAME=runtime-test "${vector_bin}" test "$1" "${vector_tests}" >"${work_dir}/vector-test.log" 2>&1
}

tetragon_reaches_homelab() {
  VECTOR_SELF_NODE_NAME=runtime-test "${vector_bin}" graph --config "$1" 2>/dev/null \
    | grep -q '"tetragon_records" -> "homelab"'
}

check_vector() {
  if run_vector_tests "${vector_config}"; then
    pass "vector: $(grep -c '\.\.\. passed$' "${work_dir}/vector-test.log") Tetragon unit tests pass"
  else
    record_failure "vector: the Tetragon unit tests fail: $(grep -E 'failed|error' "${work_dir}/vector-test.log" | head -n 5)"
  fi
  if tetragon_reaches_homelab "${vector_config}"; then
    pass "vector: tetragon_records feeds the homelab sink"
  else
    record_failure "vector: tetragon_records does not feed the homelab sink"
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

mutate_vector() {
  local mutation mutant="${work_dir}/vector-mutant.yaml"
  for mutation in "${vector_mutations[@]}"; do
    sed "${mutation}" "${vector_config}" >"${mutant}"
    if cmp -s "${mutant}" "${vector_config}"; then
      record_failure "vector mutation ${mutation}: matched nothing in vector.yaml"
    elif run_vector_tests "${mutant}"; then
      record_failure "vector mutation ${mutation}: the unit tests still pass"
    else
      pass "vector mutation ${mutation}: the unit tests fail"
    fi
  done
  sed '/^      - egress_flow_records$/{n;/^      - tetragon_records$/d}' "${vector_config}" >"${mutant}"
  if cmp -s "${mutant}" "${vector_config}"; then
    record_failure "vector mutation: could not remove tetragon_records from the homelab sink"
  elif tetragon_reaches_homelab "${mutant}"; then
    record_failure "vector mutation: without the sink input the graph check still passes"
  else
    pass "vector mutation: without the sink input the graph check fails"
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
check_vector

if [ "${mutation_test}" = true ]; then
  mutate_chart
  [ -d "${work_dir}/tetragon/crds-yaml" ] && mutate_policies
  mutate_vector
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} check(s) failed" >&2
  exit 1
fi
echo "all runtime-security checks passed"
