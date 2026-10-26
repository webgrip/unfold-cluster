#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-ops-consoles.sh [--mutation-test]

Proves the two pieces of the operations consoles that run no chart:

  the Gateway API CRDs vendored in kubernetes/platform/gateway-api are the
    standard channel of the pinned release, byte for byte once the upstream
    licence header lines are dropped;
  authentik-relay, the Envoy that carries the consoles' OIDC calls to the
    homelab gateway, tunnels CONNECT authentik.webgrip.dev:443 to its upstream
    and answers 403 to every other host and port.

The relay runs from kubernetes/platform/ops-consoles/auth/authentik-relay.yaml
with only its listener and upstream addresses moved to loopback; a node HTTP
server stands in for the homelab gateway.

  --mutation-test  also swaps the one allowed authority for another and
                   requires Authentik to be refused and the other host to be
                   let through, so the allowlist and nothing else decides.

Downloads the Gateway API bundle and the Envoy binary at the pinned versions,
checksum-verified, into a cache directory. Needs curl, sha256sum and node."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root

# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
readonly gateway_crds_version="v1.6.3"
readonly standard_install_sha256="356c2b8e286a964dc20995435659ad1095386329974793af10bbfe3eff977fe5"

# renovate: datasource=github-releases depName=envoyproxy/envoy
readonly envoy_version="v1.40.1"
readonly envoy_sha256_linux_amd64="7104734ba4adaf505acff192cddf5427fb7b0c53827a2039171969fb2d694060"

readonly relay_config="${repo_root}/kubernetes/platform/ops-consoles/auth/authentik-relay.yaml"
readonly vendored_crds="${repo_root}/kubernetes/platform/gateway-api/standard-install.yaml"

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-consoles-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ops-consoles-test.XXXXXX")"
readonly work_dir
background_pids=()

cleanup() {
  for pid in "${background_pids[@]}"; do
    kill -KILL "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "${work_dir}"
}
trap cleanup EXIT

failures=()
record_failure() {
  failures+=("$1")
  echo "FAIL  $1" >&2
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

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

check_vendored_crds() {
  local upstream="${cache_dir}/gateway-api-${gateway_crds_version}-standard-install.yaml"
  download_verified \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${gateway_crds_version}/standard-install.yaml" \
    "${standard_install_sha256}" "${upstream}"
  if cmp -s <(grep -v '^#' "${upstream}") "${vendored_crds}"; then
    echo "ok    gateway-api: vendored CRDs are the ${gateway_crds_version} standard channel"
  else
    record_failure "gateway-api: ${vendored_crds#"${repo_root}/"} differs from the ${gateway_crds_version} standard channel without its licence header lines"
  fi
}

upstream_port=""
start_stand_in_gateway() {
  upstream_port="$(free_port)"
  node -e '
    require("http").createServer((req, res) => { res.end("reached the homelab gateway\n"); })
      .listen(Number(process.argv[1]), "127.0.0.1");
  ' "${upstream_port}" &
  background_pids+=("$!")
}

relay_pid=""
relay_port=""
start_relay() {
  local config="$1"
  relay_port="$(free_port)"
  sed -e "s/port_value: 3128/port_value: ${relay_port}/" \
      -e "s/address: 0.0.0.0/address: 127.0.0.1/" \
      -e "s/address: unfold-gateway.webgrip.dev/address: 127.0.0.1/" \
      -e "s/port_value: 443/port_value: ${upstream_port}/" \
      "${config}" >"${work_dir}/relay.yaml"
  "${envoy_bin}" -c "${work_dir}/relay.yaml" --base-id "$((RANDOM % 60000 + 1))" \
    --log-level warn >"${work_dir}/envoy.log" 2>&1 &
  relay_pid="$!"
  background_pids+=("${relay_pid}")
  for _ in $(seq 1 100); do
    if curl -s -o /dev/null "http://127.0.0.1:${relay_port}/" 2>/dev/null; then
      return
    fi
    sleep 0.1
  done
  tail -n 20 "${work_dir}/envoy.log" >&2
  record_failure "relay: Envoy did not start"
}

stop_relay() {
  kill -KILL "${relay_pid}" 2>/dev/null || true
  wait "${relay_pid}" 2>/dev/null || true
}

expect_tunnel() {
  local label="$1" authority="$2" answer
  answer="$(curl -s --max-time 5 -p -x "http://127.0.0.1:${relay_port}" "http://${authority}/" 2>&1 || true)"
  if grep -q "reached the homelab gateway" <<<"${answer}"; then
    echo "ok    ${label}: CONNECT ${authority} reaches the gateway"
  else
    record_failure "${label}: CONNECT ${authority} did not reach the gateway"
  fi
}

expect_refused() {
  local label="$1" authority="$2" answer
  answer="$(curl -s --max-time 5 -o /dev/null -w '%{http_connect}' -p -x "http://127.0.0.1:${relay_port}" "http://${authority}/" 2>/dev/null || true)"
  if [ "${answer}" = "403" ]; then
    echo "ok    ${label}: CONNECT ${authority} refused with 403"
  else
    record_failure "${label}: CONNECT ${authority} answered '${answer}', not 403"
  fi
}

check_relay() {
  start_stand_in_gateway
  start_relay "${relay_config}"
  expect_tunnel relay authentik.webgrip.dev:443
  expect_refused relay example.org:443
  expect_refused relay authentik.webgrip.dev:8443
  expect_refused relay unfold-gateway.webgrip.dev:8200
  stop_relay

  if [ "${mutation_test}" = true ]; then
    sed 's/- authentik.webgrip.dev:443/- example.org:443/' "${relay_config}" >"${work_dir}/mutated.yaml"
    start_relay "${work_dir}/mutated.yaml"
    expect_refused "mutation relay" authentik.webgrip.dev:443
    expect_tunnel "mutation relay" example.org:443
    stop_relay
  fi
}

envoy_bin="${cache_dir}/envoy-${envoy_version#v}"
[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only the linux-amd64 Envoy is pinned" >&2; exit 2; }
download_verified "https://github.com/envoyproxy/envoy/releases/download/${envoy_version}/envoy-${envoy_version#v}-linux-x86_64" \
  "${envoy_sha256_linux_amd64}" "${envoy_bin}"
chmod 0755 "${envoy_bin}"

check_vendored_crds
check_relay

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} ops-consoles check(s) failed" >&2
  exit 1
fi
echo "the vendored Gateway API CRDs are the pinned release and the relay opens Authentik and nothing else"
