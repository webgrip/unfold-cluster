#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-disk-kms-key.sh

Runs scripts/disk-kms-key.sh against a stubbed OpenBao KV client and checks
when it mints, that it never replaces a stored key and what it refuses; then
runs the checks against mutants and fails unless every mutant is caught."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
program="${repo}/scripts/disk-kms-key.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"${work}/kv" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  get) cat "${STUB_DIR}/stored" 2>/dev/null || true ;;
  put) echo "put $2 $3 $4" >>"${STUB_DIR}/calls"; tr -d '\n' >"${STUB_DIR}/stored" ;;
esac
STUB
chmod +x "${work}/kv"

readonly query='{"path":"unfold-cluster/disk-kms","property":"master_key"}'
existing="$(head -c 32 /dev/urandom | base64 -w0)"

fresh() {
  stub="$(mktemp -d "${work}/case.XXXXXX")"
  : >"${stub}/calls"
}

run_program() {
  local p="$1" mint="$2"
  printf '%s' "$query" | env STUB_DIR="$stub" OPENBAO_KV="${work}/kv" UNFOLD_TAILNET_MINT="$mint" "$p" >"${stub}/out" 2>"${stub}/err"
}

key_out() { jq -r '.master_key' "${stub}/out"; }

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

suite() {
  local p="$1" status
  failures=0

  fresh; printf '%s' "$existing" >"${stub}/stored"; run_program "$p" read-only && status=0 || status=$?
  expect "a stored key is returned on a plan" bash -c '[ "$1" -eq 0 ] && [ "$(jq -r .master_key "$2")" = "$3" ]' _ "$status" "${stub}/out" "$existing"

  fresh; printf '%s' "$existing" >"${stub}/stored"; run_program "$p" allowed || true
  expect "an apply never replaces a stored key" bash -c '[ ! -s "$1" ] && [ "$(jq -r .master_key "$2")" = "$3" ]' _ "${stub}/calls" "${stub}/out" "$existing"

  fresh; run_program "$p" read-only && status=0 || status=$?
  expect "a plan without a stored key returns an empty key and writes nothing" bash -c '[ "$1" -eq 0 ] && [ -z "$(jq -r .master_key "$2")" ] && [ ! -s "$3" ]' _ "$status" "${stub}/out" "${stub}/calls"

  fresh; run_program "$p" allowed && status=0 || status=$?
  expect "an apply without a stored key mints one, writes it and returns what OpenBao holds" \
    bash -c '[ "$1" -eq 0 ] && grep -q "put disk-kms-key unfold-cluster/disk-kms master_key" "$2" && [ "$(jq -r .master_key "$3")" = "$(cat "$4")" ] && [ "$(base64 -d "$4" | wc -c)" -eq 32 ]' _ "$status" "${stub}/calls" "${stub}/out" "${stub}/stored"
  expect "the minted key is not printed outside the JSON" bash -c '! grep -qF "$(cat "$1")" "$2"' _ "${stub}/stored" "${stub}/err"

  fresh; head -c 16 /dev/urandom | base64 -w0 >"${stub}/stored"; run_program "$p" allowed && status=0 || status=$?
  expect "a stored key of the wrong length is refused, not replaced" bash -c '[ "$1" -ne 0 ] && [ ! -s "$2" ]' _ "$status" "${stub}/calls"
}

suite "$program"
[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed against the real program"; exit 1; }
echo "every check passed against the real program"

mutate() {
  local name="$1" from="$2" to="$3" mutant="${work}/mutant.sh"
  grep -qF -- "$from" "$program" || { echo "FAIL: mutant '${name}' no longer applies; update the test"; return 1; }
  "${repo}/scripts/write-mutant.sh" "$program" "$from" "$to" "$mutant" || { echo "FAIL: mutant '${name}' could not be written"; return 1; }
  quiet=1
  suite "$mutant"
  quiet=""
  [ "$failures" -gt 0 ] || { echo "FAIL: mutant '${name}' survived"; return 1; }
  echo "ok: mutant '${name}' caught by ${failures} check(s)"
}

survivors=0
mutate "mints on plan-only runs" '[ "${UNFOLD_TAILNET_MINT:-read-only}" = "allowed" ]' 'true' || survivors=$((survivors + 1))
mutate "replaces a stored key" 'if [ -z "$stored" ] && [ "${UNFOLD_TAILNET_MINT' 'if [ "${UNFOLD_TAILNET_MINT' || survivors=$((survivors + 1))
mutate "accepts any stored value" '[ -z "$stored" ] || is_master_key "$stored" || fail' 'true || fail' || survivors=$((survivors + 1))

[ "$survivors" -eq 0 ] || { echo "${survivors} mutant(s) survived"; exit 1; }
echo "every mutant was caught"
