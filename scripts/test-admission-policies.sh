#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-admission-policies.sh [--mutation-test]

Proves every admission policy in kubernetes/platform/admission-policies
against a real kube-apiserver at the cluster's Kubernetes version. It starts a
throwaway etcd and API server on loopback, applies the policies exactly as
Flux would, and sends every fixture under tests/admission-policies/<policy>/
as a server-side apply dry run, so a fixture naming an object that already
exists is checked as the UPDATE Flux would send:

  refused-*.yaml   must be refused (Deny) or warned about (Audit, Warn) by
                   the policy its directory is named after
  admitted-*.yaml  must be admitted with no word from that policy

While one policy's fixtures run, every other binding only warns, so a
Deny from a neighbouring policy cannot stand in for the one under test.

Every policy needs at least one fixture of each kind. Nothing outside the
throwaway API server is touched.

  --mutation-test  also neutralise each policy in turn (every validation
                   becomes true) and require all of its refused fixtures to
                   stop being refused. A fixture that still fails was never
                   testing its policy.

Downloads kube-apiserver, kubectl and etcd at the pinned versions below,
checksum-verified, into a cache directory. Needs curl, jq, sha256sum, tar and
node."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly policy_dir="${repo_root}/kubernetes/platform/admission-policies"
readonly fixture_dir="${repo_root}/tests/admission-policies"

# renovate: datasource=github-releases depName=kubernetes/kubernetes
readonly kubernetes_version="v1.37.1"
readonly kube_apiserver_sha256_linux_amd64="de9b1b43c10143f448408b3aaf15f44fd5248b97a56301417a1fe2f1fc47a691"
readonly kubectl_sha256_linux_amd64="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"

# renovate: datasource=github-releases depName=etcd-io/etcd
readonly etcd_version="v3.7.3"
readonly etcd_sha256_linux_amd64="5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775"

readonly etcd_client_port="${ADMISSION_TEST_ETCD_PORT:-23790}"
readonly etcd_peer_port="$((etcd_client_port + 1))"
readonly api_port="${ADMISSION_TEST_API_PORT:-16443}"
readonly ready_timeout_seconds=90
readonly sentinel_policy="admission-test-sentinel"

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only linux-amd64 binaries are pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-admission-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/admission-test.XXXXXX")"
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
  printf '%s,admission-test,admission-test,system:masters\n' "${token}" >"${work_dir}/tokens.csv"
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
    --allow-privileged=true \
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
  - name: admission-test
    user:
      token: ${token}
contexts:
  - name: throwaway
    context:
      cluster: throwaway
      user: admission-test
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
  until kubectl get namespace kube-system >/dev/null 2>&1; do sleep 1; done
}

sentinel_generation=0

wait_for_policies_to_settle() {
  sentinel_generation=$((sentinel_generation + 1))
  kubectl apply -f - >/dev/null <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: ${sentinel_policy}
spec:
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["configmaps"]
  validations:
    - expression: "false"
      message: sentinel generation ${sentinel_generation}
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: ${sentinel_policy}
spec:
  policyName: ${sentinel_policy}
  validationActions: ["Warn"]
EOF
  local answer
  for _ in $(seq 1 120); do
    answer="$(kubectl create configmap "${sentinel_policy}" --dry-run=server -o name 2>&1 || true)"
    if grep -q "sentinel generation ${sentinel_generation}\$" <<<"${answer}"; then
      return
    fi
    sleep 0.5
  done
  echo "the API server never started enforcing the applied admission policies" >&2
  exit 1
}

policy_names() {
  kubectl get validatingadmissionpolicies -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -vx "${sentinel_policy}"
}

dry_run() {
  kubectl apply --server-side --force-conflicts --field-manager=admission-test --dry-run=server -f "$1" 2>&1
}

policy_named_in() {
  grep -q "ValidatingAdmissionPolicy '$1'" <<<"$2"
}

failures=()

record_failure() {
  failures+=("$1")
  echo "FAIL  $1" >&2
}

denial_kind() {
  if grep -q "ValidatingAdmissionPolicy '$1' with binding '[^']*' denied request" <<<"$2"; then
    echo denied
  else
    echo warned
  fi
}

check_refused() {
  local policy="$1" fixture="$2" output
  output="$(dry_run "${fixture}" || true)"
  if policy_named_in "${policy}" "${output}"; then
    echo "ok    ${policy}: $(denial_kind "${policy}" "${output}") ${fixture#"${repo_root}/"}"
  else
    record_failure "${policy}: ${fixture#"${repo_root}/"} was not refused; the server said: ${output}"
  fi
}

check_admitted() {
  local policy="$1" fixture="$2" output status=0
  output="$(dry_run "${fixture}")" || status=$?
  if [ "${status}" -eq 0 ] && ! policy_named_in "${policy}" "${output}"; then
    echo "ok    ${policy}: admitted ${fixture#"${repo_root}/"}"
  else
    record_failure "${policy}: ${fixture#"${repo_root}/"} was not admitted cleanly; the server said: ${output}"
  fi
}

fixtures_of() {
  find "${fixture_dir}/$1" -maxdepth 1 -type f -name "$2-*.yaml" 2>/dev/null | sort
}

readonly original_bindings="${work_dir}/bindings.json"

without_server_fields() {
  jq '.items |= map(del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status))'
}

record_original_bindings() {
  kubectl get validatingadmissionpolicybindings -o json | without_server_fields >"${original_bindings}"
}

only_warn_outside() {
  jq --arg policy "$1" --arg sentinel "${sentinel_policy}" '.items |= map(
      if .spec.policyName == $policy or .metadata.name == $sentinel then . else .spec.validationActions = ["Warn"] end)' \
    "${original_bindings}" | kubectl replace -f - >/dev/null
  wait_for_policies_to_settle
}

restore_bindings() {
  kubectl replace -f "${original_bindings}" >/dev/null
  wait_for_policies_to_settle
}

check_policy() {
  local policy="$1" fixture refused admitted
  refused="$(fixtures_of "${policy}" refused)"
  admitted="$(fixtures_of "${policy}" admitted)"
  if [ -z "${refused}" ] || [ -z "${admitted}" ]; then
    record_failure "${policy}: needs at least one refused-*.yaml and one admitted-*.yaml under tests/admission-policies/${policy}/"
    return
  fi
  while read -r fixture; do check_refused "${policy}" "${fixture}"; done <<<"${refused}"
  while read -r fixture; do check_admitted "${policy}" "${fixture}"; done <<<"${admitted}"
}

check_every_policy() {
  local policy
  while read -r policy; do
    only_warn_outside "${policy}"
    check_policy "${policy}"
  done < <(policy_names)
  restore_bindings
}

neutralise_and_expect_admission() {
  local policy="$1" original="${work_dir}/${1}.json" fixture output
  kubectl get validatingadmissionpolicy "${policy}" -o json >"${original}"
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)
      | .spec.validations |= map(.expression = "true")' "${original}" \
    | kubectl replace -f - >/dev/null
  only_warn_outside "${policy}"
  while read -r fixture; do
    output="$(dry_run "${fixture}" || true)"
    if policy_named_in "${policy}" "${output}"; then
      record_failure "mutation ${policy}: ${fixture#"${repo_root}/"} is still refused with every validation neutralised"
    else
      echo "ok    mutation ${policy}: neutralised, ${fixture#"${repo_root}/"} no longer refused"
    fi
  done < <(fixtures_of "${policy}" refused)
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)' "${original}" \
    | kubectl replace -f - >/dev/null
  wait_for_policies_to_settle
}

install_binaries
start_servers
kubectl apply -f "${fixture_dir}/cluster-objects.yaml" >/dev/null
kubectl apply -k "${policy_dir}" >/dev/null
wait_for_policies_to_settle
record_original_bindings

check_every_policy
if [ "${mutation_test}" = true ]; then
  while read -r policy; do
    neutralise_and_expect_admission "${policy}"
  done < <(policy_names)
  check_every_policy
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} admission policy check(s) failed" >&2
  exit 1
fi
echo "every admission policy refuses its refused fixtures and admits its admitted ones"
