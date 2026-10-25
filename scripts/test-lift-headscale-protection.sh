#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-lift-headscale-protection.sh

Feeds scripts/lift-headscale-protection.sh plans in tofu show -json form
against a stubbed Hetzner API, and checks that it lifts the protection of
unfold-headscale exactly when the plan deletes that server, and never for any
other server or name."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/lift-headscale-protection.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H | --data | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "${method} ${url}" >>"${STUB_DIR}/calls"
case "${method} ${url}" in
  "GET https://hetzner.invalid/v1/servers/"*) echo "{\"server\":{\"name\":\"${LIVE_NAME}\"}}" ;;
  "POST https://hetzner.invalid/v1/servers/"*"/actions/change_protection") echo '{"action":{"id":77}}' ;;
  "GET https://hetzner.invalid/v1/actions/77") echo '{"action":{"status":"success"}}' ;;
  *) exit 22 ;;
esac
STUB
chmod +x "${work}/bin/curl"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}" HCLOUD_ENDPOINT="https://hetzner.invalid/v1" HCLOUD_TOKEN="test-token" LIVE_NAME="unfold-headscale"
failures=0

plan() {
  jq -n --arg address "$1" --arg name "$2" --argjson actions "$3" '{resource_changes: [
    {address: "hcloud_server.control_plane[\"unfold-cp-1\"]", change: {actions: ["no-op"], before: {id: "11", name: "unfold-cp-1"}}},
    {address: $address, change: {actions: $actions, before: {id: "4242", name: $name}}}]}'
}

lifts() {
  : >"${work}/calls"
  plan "$1" "$2" "$3" | "$tool" >/dev/null 2>&1 || return 2
  grep -q '^POST https://hetzner.invalid/v1/servers/4242/actions/change_protection$' "${work}/calls"
}

expect() {
  local title="$1" want="$2"
  shift 2
  local got=0
  "$@" || got=$?
  if [ "$got" = "$want" ]; then echo "ok: ${title}"; else echo "FAIL: ${title} (exit ${got}, wanted ${want})"; failures=$((failures + 1)); fi
}

expect "a replaced unfold-headscale is unprotected first" 0 lifts hcloud_server.headscale unfold-headscale '["delete","create"]'
expect "a deleted unfold-headscale is unprotected first" 0 lifts hcloud_server.headscale unfold-headscale '["delete"]'
expect "an in-place change of unfold-headscale lifts nothing" 1 lifts hcloud_server.headscale unfold-headscale '["update"]'
expect "an unchanged unfold-headscale lifts nothing" 1 lifts hcloud_server.headscale unfold-headscale '["no-op"]'
expect "a replaced control plane is never unprotected" 1 lifts 'hcloud_server.control_plane["unfold-cp-1"]' unfold-cp-1 '["delete","create"]'
expect "a replaced worker is never unprotected" 1 lifts 'hcloud_server.worker["unfold-app-1"]' unfold-app-1 '["delete","create"]'
expect "hcloud_server.headscale under another name is refused" 2 lifts hcloud_server.headscale unfold-cp-1 '["delete","create"]'
LIVE_NAME="unfold-cp-2" expect "an id that is another server in Hetzner is refused" 2 lifts hcloud_server.headscale unfold-headscale '["delete","create"]'
expect "stdin that is no plan is refused" 1 bash -c 'echo "not json" | "$1" >/dev/null 2>&1' _ "$tool"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
