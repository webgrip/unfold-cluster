#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-guard-encryption-rollout.sh

Feeds scripts/guard-encryption-rollout.sh plans in JSON and checks which it
lets through, then runs the same checks against mutants of the guard and fails
unless every mutant is caught."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
guard="${repo}/scripts/guard-encryption-rollout.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

reinstall() {
  local node="$1" actions="$2" before="$3" encrypted="$4"
  jq -n --arg node "$node" --argjson actions "$actions" --argjson before "$before" --argjson encrypted "$encrypted" '{
    type: "terraform_data", name: "disk_encryption_reinstall", index: $node,
    change: {actions: $actions, before: $before, after: {triggers_replace: [$encrypted]}}}'
}

server() {
  jq -n --arg node "$2" --arg name "$1" '{type: "hcloud_server", name: $name, index: $node, change: {actions: ["create"]}}'
}

no_op() {
  reinstall "$1" '["no-op"]' "{\"triggers_replace\":[$2]}" "$2"
}

plan() {
  jq -s '{resource_changes: .}'
}

failures=0
quiet=""
expect() {
  local name="$1"
  shift
  if "$@"; then
    [ -n "$quiet" ] || echo "ok: $name"
  else
    [ -n "$quiet" ] || echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

passes() { "$1" <"$2" >/dev/null 2>&1; }
refuses() { ! "$1" <"$2" >/dev/null 2>&1; }

{ no_op unfold-cp-1 false; no_op unfold-cp-2 false; no_op unfold-cp-3 false; no_op unfold-app-1 false; } | plan >"${work}/nothing.json"
{ reinstall unfold-cp-3 '["delete","create"]' '{"triggers_replace":[false]}' true; no_op unfold-cp-1 false; } | plan >"${work}/one.json"
{ reinstall unfold-cp-3 '["delete","create"]' '{"triggers_replace":[false]}' true; reinstall unfold-cp-2 '["delete","create"]' '{"triggers_replace":[false]}' true; } | plan >"${work}/two.json"
{ reinstall unfold-app-1 '["delete","create"]' '{"triggers_replace":[true]}' false; reinstall unfold-cp-2 '["delete","create"]' '{"triggers_replace":[false]}' true; } | plan >"${work}/two-mixed.json"
{ for node in unfold-cp-1 unfold-cp-2 unfold-cp-3 unfold-app-1; do reinstall "$node" '["create"]' null false; done; } | plan >"${work}/first-record.json"
{ reinstall unfold-cp-1 '["create"]' null true; reinstall unfold-cp-2 '["create"]' null true; } | plan >"${work}/first-record-encrypted.json"
{ server worker unfold-ci-1; reinstall unfold-ci-1 '["create"]' null true; server worker unfold-ci-2; reinstall unfold-ci-2 '["create"]' null true; reinstall unfold-cp-3 '["delete","create"]' '{"triggers_replace":[false]}' true; } | plan >"${work}/new-servers.json"
echo 'not json' >"${work}/garbage.json"

suite() {
  local g="$1"
  failures=0
  expect "a plan that re-installs nothing passes" passes "$g" "${work}/nothing.json"
  expect "a plan that re-installs one node passes" passes "$g" "${work}/one.json"
  expect "a plan that re-installs two control planes is refused" refuses "$g" "${work}/two.json"
  expect "a plan that re-installs one node each way is refused" refuses "$g" "${work}/two-mixed.json"
  expect "the first record of four plain nodes passes" passes "$g" "${work}/first-record.json"
  expect "the first record of two nodes listed as encrypted counts as two re-installs" refuses "$g" "${work}/first-record-encrypted.json"
  expect "new servers born encrypted do not count" passes "$g" "${work}/new-servers.json"
  expect "a plan that is not JSON is refused" refuses "$g" "${work}/garbage.json"
  expect "the one re-installed node is named" bash -c '"$1" <"$2" 2>&1 | grep -q "unfold-cp-3 (to encrypted)"' _ "$g" "${work}/one.json"
}

suite "$guard"
[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed against the real guard"; exit 1; }
echo "every check passed against the real guard"

mutate() {
  local name="$1" from="$2" to="$3" mutant="${work}/mutant.sh"
  grep -qF -- "$from" "$guard" || { echo "FAIL: mutant '${name}' no longer applies; update the test"; return 1; }
  "${repo}/scripts/write-mutant.sh" "$guard" "$from" "$to" "$mutant" || { echo "FAIL: mutant '${name}' could not be written"; return 1; }
  quiet=1
  suite "$mutant"
  quiet=""
  [ "$failures" -gt 0 ] || { echo "FAIL: mutant '${name}' survived"; return 1; }
  echo "ok: mutant '${name}' caught by ${failures} check(s)"
}

survivors=0
mutate "two re-installs allowed" '  *)
    echo "::error::this plan re-installs' '  9999)
    echo "::error::this plan re-installs' || survivors=$((survivors + 1))
mutate "new servers counted" '| select(.index as $node | $new_servers | index($node) | not)' '' || survivors=$((survivors + 1))
mutate "replacements not counted" '| select(.change.actions | index("create"))
    | select(.index as $node' '| select(.change.actions == ["create"])
    | select(.index as $node' || survivors=$((survivors + 1))
mutate "encrypted first records not counted" '| select((.change.before == null and .change.after.triggers_replace == [false]) | not)' '| select(.change.before != null)' || survivors=$((survivors + 1))

[ "$survivors" -eq 0 ] || { echo "${survivors} mutant(s) survived"; exit 1; }
echo "every mutant was caught"
