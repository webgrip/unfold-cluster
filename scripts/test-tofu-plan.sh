#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-tofu-plan.sh

Runs scripts/tofu-plan.sh against a stubbed tofu that fails the way Hetzner
failed run 171 (internal server error, Status code: 500) or in other ways, and
checks that it plans again only after a failure made of Hetzner 5xx errors
alone, at most TOFU_PLAN_ATTEMPTS times, passes its arguments and tofu's exit
code through, and never prints a Headscale pre-auth key."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/tofu-plan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/tofu" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_DIR}/calls"
call="$(wc -l <"${STUB_DIR}/calls")"
outcome="$(sed -n "${call}p" "${STUB_DIR}/outcomes")"
outcome="${outcome:-ok}"
error_block() {
  printf '\033[31m│\033[0m \033[0m\033[1m\033[31mError: \033[0m\033[0m\033[1m%s\033[0m\n' "$1"
  printf '\033[31m│\033[0m \033[0m\n'
  printf '\033[31m│\033[0m \033[0m  with hcloud_primary_ip.headscale,\n'
  printf '\033[31m│\033[0m \033[0m%s\n' "$2"
  printf '\033[31m│\033[0m \033[0m\n'
  [ -z "$3" ] || printf '\033[31m│\033[0m \033[0mStatus code: %s\n' "$3"
  printf '\033[31m╵\033[0m\033[0m\n'
}
echo "      ~ output = \"hskey-auth-0123abcd-SeCrEtVaLuE_x\" -> (known after apply)"
case "$outcome" in
  ok) echo "Plan: 0 to add, 0 to change, 0 to destroy."; exit 0 ;;
  500)
    echo "Planning failed. OpenTofu encountered an error while generating this plan."
    error_block "API request failed" "internal server error (server_error)" 500
    exit 1
    ;;
  503)
    error_block "API request failed" "service unavailable (unavailable)" 503
    exit 1
    ;;
  429)
    error_block "API request failed" "limit of 3600 requests per hour reached (rate_limit_exceeded)" 429
    exit 1
    ;;
  invalid)
    error_block "Invalid reference" "A reference to a resource type must be followed by an attribute" ""
    exit 1
    ;;
  500-and-invalid)
    error_block "API request failed" "internal server error (server_error)" 500
    error_block "Resource postcondition failed" "unfold-headscale did not return a worker pre-auth key." ""
    exit 1
    ;;
esac
STUB
chmod +x "${work}/bin/tofu"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}" TOFU_PLAN_RETRY_SECONDS=0
failures=0

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

run_with() {
  : >"${work}/calls"
  printf '%s\n' "$@" >"${work}/outcomes"
  set +e
  "$tool" -lock-timeout=5m -out=infra.tfplan >"${work}/out" 2>&1
  echo "$?" >"${work}/status"
  set -e
}
calls() { wc -l <"${work}/calls" | tr -d ' '; }
status() { cat "${work}/status"; }

run_with ok
expect "a plan that succeeds runs once" test "$(calls)/$(status)" = "1/0"
expect "the arguments reach tofu plan" test "$(head -n 1 "${work}/calls")" = "plan -lock-timeout=5m -out=infra.tfplan"
expect "a pre-auth key in the plan is never printed" bash -c '! grep -q "SeCrEtVaLuE" "$1" && grep -q "hskey-auth-<redacted>" "$1"' _ "${work}/out"

run_with 500 ok
expect "run 171's 500 is planned again, and the second plan wins" test "$(calls)/$(status)" = "2/0"
expect "the retry is announced" grep -q '^::warning::tofu-plan: attempt 1 of 3 failed on a Hetzner API 5xx only' "${work}/out"

run_with 503 500 ok
expect "every 5xx is retried" test "$(calls)/$(status)" = "3/0"

run_with 500 500 500 ok
expect "a 5xx that persists stops after three attempts with tofu's exit code" test "$(calls)/$(status)" = "3/1"

TOFU_PLAN_ATTEMPTS=1 run_with 500 ok
expect "TOFU_PLAN_ATTEMPTS=1 never retries" test "$(calls)/$(status)" = "1/1"

run_with 429 ok
expect "a rate limit is not retried" test "$(calls)/$(status)" = "1/1"

run_with invalid ok
expect "a configuration error is not retried" test "$(calls)/$(status)" = "1/1"

run_with 500-and-invalid ok
expect "a 5xx together with another error is not retried" test "$(calls)/$(status)" = "1/1"

expect "an attempt count that is not a number is refused" bash -c '! TOFU_PLAN_ATTEMPTS=many "$1" >/dev/null 2>&1' _ "$tool"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
