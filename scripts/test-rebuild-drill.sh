#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-rebuild-drill.sh

Runs the guard and teardown of scripts/rebuild-drill.sh against a stubbed
Hetzner API, and checks the two promises the drill's safety rests on: it never
starts in a project that holds anything, and it never deletes anything in a
project it did not mark as its own."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/rebuild-drill.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET url="" data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -H | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#https://hetzner.invalid/v1/}"
path="${path%%\?*}"
echo "${method} ${path}" >>"${STUB_DIR}/calls"
store="${STUB_DIR}/project"
kind="${path%%/*}"
case "${method} ${path}" in
  "GET actions/"*) echo '{"action":{"status":"success"}}' ;;
  "POST "*"/actions/"*) echo '{"action":{"id":1}}' ;;
  "POST placement_groups")
    jq --argjson pg "$(jq -c '{id: 900, name, protection: {delete: false}}' <<<"$data")" '.placement_groups += [$pg]' "$store" >"${store}.new" && mv "${store}.new" "$store"
    echo '{}'
    ;;
  "DELETE "*)
    id="${path#*/}"
    [ "$id" != "${UNDELETABLE:-none}" ] || exit 22
    jq --arg kind "$kind" --argjson id "$id" '.[$kind] |= map(select(.id != $id))' "$store" >"${store}.new" && mv "${store}.new" "$store"
    echo '{"action":{"id":1}}'
    ;;
  "GET "*) jq -c --arg kind "$kind" '{($kind): (.[$kind] // [])}' "$store" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "${work}/bin/curl"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}" HCLOUD_ENDPOINT="https://hetzner.invalid/v1" HCLOUD_TOKEN="drill-token" TEARDOWN_RETRY_SECONDS=0
failures=0

project() {
  printf '%s' "$1" >"${work}/project"
  : >"${work}/calls"
}

count() {
  jq '[.[] | length] | add // 0' "${work}/project"
}

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

production='{"servers":[{"id":11,"name":"unfold-cp-1","protection":{"delete":true}}],"primary_ips":[{"id":21,"name":"unfold-headscale-ipv4","protection":{"delete":true}}]}'

project "$production"
expect "the guard refuses a project that holds anything" bash -c '! "$1" guard >/dev/null 2>&1' _ "$tool"
expect "a refused guard marks nothing" test "$(count)" = 2

project "$production"
expect "the teardown refuses a project without the drill's marker" bash -c '! "$1" teardown >/dev/null 2>&1' _ "$tool"
expect "an unmarked project keeps everything" bash -c '[ "$(jq -c . "$1")" = "$(jq -c . <<<"$2")" ] && ! grep -q "^DELETE\|change_protection" "$3"' _ "${work}/project" "$production" "${work}/calls"

project '{}'
expect "the guard accepts an empty project" bash -c '"$1" guard >/dev/null' _ "$tool"
expect "and marks it as the drill's" test "$(jq -r '.placement_groups[0].name' "${work}/project")" = rebuild-drill-marker

jq '. + {
  servers: [{id: 1, name: "unfold-cp-1", protection: {delete: true, rebuild: true}}, {id: 2, name: "unfold-headscale", protection: {delete: true, rebuild: true}}],
  primary_ips: [{id: 3, name: "unfold-headscale-ipv4", protection: {delete: true}}],
  networks: [{id: 4, name: "unfold-cluster", protection: {delete: true}}],
  volumes: [{id: 5, name: "pvc-zot", protection: {delete: false}}],
  images: [{id: 6, description: "talos v1.14.4", protection: {delete: false}}],
  firewalls: [{id: 7, name: "unfold-nodes"}],
  ssh_keys: [{id: 8, name: "unfold-admin"}]}' "${work}/project" >"${work}/drilled"
project "$(cat "${work}/drilled")"
expect "the teardown empties a marked project" bash -c '"$1" teardown >/dev/null && [ "$(jq "[.[] | length] | add" "$2")" = 0 ]' _ "$tool" "${work}/project"
expect "it lifts the servers' protection before deleting them" bash -c 'grep -n "servers/1" "$1" | head -n 1 | grep -q change_protection' _ "${work}/calls"

project "$(cat "${work}/drilled")"
expect "a resource Hetzner will not delete fails the teardown" bash -c '! UNDELETABLE=4 "$1" teardown >/dev/null 2>&1' _ "$tool"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
