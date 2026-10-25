#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: diagnose-cluster.sh [--redact-test]

Prints a read-only health report of the cluster for a public job log: the
Hetzner API rate-limit headroom, each node's Talos services, tailnet logs and
addresses, the etcd members, and the kube-system pods with the cloud
controller's and Cilium's logs. It changes nothing in Hetzner or the cluster.

Reads the talosconfig and kubeconfig from the OpenTofu state with
tofu output, so tofu init must have run in infra/. Both are written with
mode 0600 under RUNNER_TEMP (or TMPDIR) and removed on exit; neither is
printed. Every line printed passes through a redaction of token-looking
strings.

Needs HCLOUD_TOKEN in the environment for the rate-limit check. Installs
talosctl and kubectl at the pinned versions below, checksum-verified, when
they are not on PATH.

  --redact-test   read stdin, print it redacted, and exit
  --install-tools DIR
                  install the pinned talosctl and kubectl into DIR, when they
                  are not on PATH, and exit"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly infra_dir="${repo_root}/infra"
readonly hcloud_api="https://api.hetzner.cloud/v1"
readonly command_timeout_seconds=60

# renovate: datasource=github-releases depName=siderolabs/talos
readonly talosctl_version="v1.14.4"
readonly talosctl_sha256_linux_amd64="0a69e3f9b682c5cd844b78dae305f6056ceb86c5fcc6913dcea78c527ed97cee"
readonly talosctl_sha256_linux_arm64="a4430fad81b8dc54d99e0dc7b7ea5d0741b93645bc612cbeadf12855c4ec60bb"

# renovate: datasource=github-releases depName=kubernetes/kubernetes
readonly kubectl_version="v1.37.1"
readonly kubectl_sha256_linux_amd64="65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8"
readonly kubectl_sha256_linux_arm64="ff749f4b78d9c4f1ec87307df9b50119ed819e2094aa9810cb9acffc3286c8c7"

readonly kube_system_log_pattern='kube-apiserver|hcloud-cloud-controller-manager|cilium'

failed_checks=()

redact() {
  sed -E \
    -e 's/hskey-[A-Za-z0-9_-]+/hskey-<redacted>/g' \
    -e 's/tskey-[A-Za-z0-9_-]+/tskey-<redacted>/g' \
    -e 's/([Bb]earer)[[:space:]]+[^[:space:]"]+/\1 <redacted>/g' \
    -e "s/(for token ')[^']*/\\1<redacted>/g" \
    -e 's/([Aa]uth[_-]?[Kk]ey|[Tt]oken|[Pp]assword|[Ss]ecret)("?[[:space:]]*[=:][[:space:]]*"?)[^[:space:]",}]+/\1\2<redacted>/g' \
    -e 's/([0-9a-f]{32})([0-9a-f]{32})/\1@@hex@@\2/g' \
    -e ':token' \
    -e 's/(^|[^A-Za-z0-9])[A-Za-z0-9]{64}([^A-Za-z0-9]|$)/\1<redacted-64-char-token>\2/' \
    -e 't token' \
    -e 's/@@hex@@//g'
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

section() {
  printf '\n===== %s =====\n' "$*"
}

check() {
  local title="$1"
  shift
  section "$title"
  set +e
  timeout "$command_timeout_seconds" "$@" 2>&1 | redact
  local status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -ne 0 ]; then
    echo "(exit ${status})"
    failed_checks+=("$title")
  fi
  return 0
}

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) fail "no pinned binaries for $(uname -m)" ;;
  esac
}

install_pinned() {
  local name="$1" url="$2" expected_sha256="$3"
  local target="${tool_dir}/${name}"
  curl -fsSL --retry 3 -o "$target" "$url"
  echo "${expected_sha256}  ${target}" | sha256sum -c --quiet - || fail "${name} checksum mismatch, refusing to run it"
  chmod 0755 "$target"
}

pinned_sha256() {
  case "$1-$2" in
    talosctl-amd64) echo "$talosctl_sha256_linux_amd64" ;;
    talosctl-arm64) echo "$talosctl_sha256_linux_arm64" ;;
    kubectl-amd64) echo "$kubectl_sha256_linux_amd64" ;;
    kubectl-arm64) echo "$kubectl_sha256_linux_arm64" ;;
    *) fail "no pinned checksum for $1 on $2" ;;
  esac
}

ensure_tools() {
  local tool arch
  for tool in tofu curl jq sed awk sha256sum timeout; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
  done
  arch="$(host_arch)"
  if ! command -v talosctl >/dev/null; then
    install_pinned talosctl \
      "https://github.com/siderolabs/talos/releases/download/${talosctl_version}/talosctl-linux-${arch}" \
      "$(pinned_sha256 talosctl "$arch")"
  fi
  if ! command -v kubectl >/dev/null; then
    install_pinned kubectl \
      "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${arch}/kubectl" \
      "$(pinned_sha256 kubectl "$arch")"
  fi
  talosctl version --client --short 2>/dev/null || talosctl version --client
  kubectl version --client
}

report_rate_limit() {
  section "Hetzner Cloud API rate limit (per project)"
  [ -n "${HCLOUD_TOKEN:-}" ] || { echo "HCLOUD_TOKEN is not set; skipped"; failed_checks+=("rate limit"); return; }
  local headers status reset
  headers="$(curl -sS -o /dev/null -D - -w 'http-status: %{http_code}\n' \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "${hcloud_api}/locations?per_page=1" | tr -d '\r')" || { echo "request failed"; failed_checks+=("rate limit"); return; }
  status="$(printf '%s\n' "$headers" | awk -F': ' '/^http-status:/ {print $2}')"
  echo "HTTP ${status}"
  printf '%s\n' "$headers" | grep -i '^ratelimit-' || echo "no RateLimit headers in the answer"
  reset="$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1) == "ratelimit-reset" {print $2}')"
  if [ -n "$reset" ]; then
    echo "RateLimit-Reset is $(date -u -d "@${reset}" '+%Y-%m-%dT%H:%M:%SZ'): the bucket is full again then if nothing keeps calling"
  fi
  case "$status" in
    200) ;;
    429) echo "::warning::the Hetzner project's API budget is used up; something keeps calling it" ;;
    *) failed_checks+=("rate limit") ;;
  esac
}

read_state_outputs() {
  section "Nodes from the OpenTofu state"
  ( umask 077
    tofu -chdir="$infra_dir" output -raw talosconfig > "${state_dir}/talosconfig"
    tofu -chdir="$infra_dir" output -raw kubeconfig > "${state_dir}/kubeconfig" ) \
    || fail "tofu output could not read the talosconfig or kubeconfig; has the cluster been applied?"
  tofu -chdir="$infra_dir" output -json control_planes > "${state_dir}/control_planes.json"
  tofu -chdir="$infra_dir" output -json workers > "${state_dir}/workers.json" 2>/dev/null \
    || tofu -chdir="$infra_dir" output -json unfold_worker > "${state_dir}/workers.json"
  jq -r 'to_entries[] | "\(.key)\tcontrol plane\t\(.value.public_ipv4)\t\(.value.private_ip)"' "${state_dir}/control_planes.json"
  jq -r 'to_entries[] | "\(.key)\tworker \(.value.pool // "unfold")\t\(.value.public_ipv4)\t\(.value.private_ip)"' "${state_dir}/workers.json"
  mapfile -t control_plane_ips < <(jq -r '.[].public_ipv4' "${state_dir}/control_planes.json")
  mapfile -t worker_ips < <(jq -r '.[].public_ipv4' "${state_dir}/workers.json")
  [ "${#control_plane_ips[@]}" -gt 0 ] || fail "the state holds no control planes"
}

report_node() {
  local node="$1"
  check "${node}: talosctl version" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" version
  check "${node}: cluster members (discovery)" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" get members
  check "${node}: services" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" service
  check "${node}: ext-tailscale log, last 50 lines" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" logs ext-tailscale --tail 50
  check "${node}: addresses" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" get addresses
  check "${node}: host firewall chains" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" get nftableschains
  check "${node}: machined controllers log, last 150 lines" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" logs controller-runtime --tail 150
  check "${node}: kubelet log, last 60 lines" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" logs kubelet --tail 60
  check "${node}: SELinux state" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" get securitystate
  check "${node}: auditd log with SELinux denials, last 100 lines" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" logs auditd --tail 100
}

report_etcd() {
  local node
  local failures_before
  for node in "${control_plane_ips[@]}"; do
    failures_before="${#failed_checks[@]}"
    check "etcd members, asked through ${node}" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" etcd members
    [ "${#failed_checks[@]}" -gt "$failures_before" ] || return 0
  done
}

kube_system_containers() {
  local node="$1"
  "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" containers -k 2>/dev/null \
    | grep -oE 'kube-system/[^[:space:]]+:[^[:space:]]+' \
    | grep -E "$kube_system_log_pattern" || true
}

report_kube_system_via_talos() {
  local node container
  for node in "${control_plane_ips[@]}" "${worker_ips[@]}"; do
    check "${node}: Kubernetes containers" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" containers -k
    while IFS= read -r container; do
      check "${node}: log of ${container}, last 100 lines" "${talosctl_cmd[@]}" --endpoints "$node" --nodes "$node" logs -k "$container" --tail 100
    done < <(kube_system_containers "$node")
  done
}

report_kubernetes() {
  local configured_server kube_server kube_tls_name
  configured_server="$(kubectl --kubeconfig "${state_dir}/kubeconfig" config view -o jsonpath='{.clusters[0].cluster.server}')"
  kube_tls_name="$(printf '%s' "$configured_server" | sed -E 's#^https://([^:/]+).*#\1#')"
  kube_server="https://${control_plane_ips[0]}:6443"
  section "Kubernetes API"
  echo "The kubeconfig points at ${configured_server}, the private VIP, reachable only inside the network or over the tailnet."
  echo "Asking ${kube_server} instead, the firewall's 6443 rule for ADMIN_CIDRS, and checking the certificate against ${kube_tls_name}, a name it is issued for."
  local kube=(kubectl --kubeconfig "${state_dir}/kubeconfig" --server "$kube_server" --tls-server-name "$kube_tls_name" --request-timeout=20s)
  check "kubectl get nodes" "${kube[@]}" get nodes -o wide
  check "kubectl get pods -A" "${kube[@]}" get pods -A -o wide
  check "kube-system events" "${kube[@]}" get events -n kube-system --sort-by=.lastTimestamp
  check "hcloud-cloud-controller-manager log, last 100 lines" "${kube[@]}" logs -n kube-system deploy/hcloud-cloud-controller-manager --tail 100 --all-containers
  check "Flux sources and kustomizations" "${kube[@]}" get gitrepositories,kustomizations -A
}

summarize() {
  section "Summary"
  if [ "${#failed_checks[@]}" -eq 0 ]; then
    echo "every check answered"
    return
  fi
  local title
  for title in "${failed_checks[@]}"; do
    echo "::warning::no answer from: ${title}"
  done
}

main() {
  case "${1:-}" in
    --redact-test) redact; exit 0 ;;
    --install-tools)
      [ -n "${2:-}" ] || { echo "$usage" >&2; exit 2; }
      tool_dir="$2"
      mkdir -p "$tool_dir"
      PATH="${PATH}:${tool_dir}"
      ensure_tools
      exit 0
      ;;
    -h | --help) echo "$usage"; exit 0 ;;
    "") ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac

  state_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diagnose.XXXXXX")"
  chmod 0700 "$state_dir"
  trap 'rm -rf "$state_dir"' EXIT
  tool_dir="${state_dir}/bin"
  mkdir -p "$tool_dir"
  PATH="${PATH}:${tool_dir}"

  ensure_tools
  talosctl_cmd=(talosctl --talosconfig "${state_dir}/talosconfig")
  report_rate_limit
  read_state_outputs

  local node
  for node in "${control_plane_ips[@]}" "${worker_ips[@]}"; do
    report_node "$node"
  done
  report_etcd
  report_kube_system_via_talos
  report_kubernetes
  summarize
}

main "$@"
