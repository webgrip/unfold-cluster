#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: tofu-plan.sh [tofu plan arguments...]

Runs tofu plan with the arguments given and prints what it prints, with every
Headscale pre-auth key replaced by hskey-auth-<redacted>: the plan shows the
stored output of a tailnet key resource it replaces in plain text.

When the plan fails and every error it reports is a Hetzner API 5xx (an error
block ending in 'Status code: 5..'), it plans again, at most
TOFU_PLAN_ATTEMPTS times in all (default 3), waiting TOFU_PLAN_RETRY_SECONDS
(default 30) times the attempt number in between. Any other failure, or a 5xx
together with any other error, ends the run at once with tofu's exit code. A
plan changes nothing at Hetzner, and the only thing it may write elsewhere is
a tailnet key on unfold-headscale, which is minted once per slot and read
back on the next attempt. Never use it for tofu apply."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
esac

max_attempts="${TOFU_PLAN_ATTEMPTS:-3}"
retry_seconds="${TOFU_PLAN_RETRY_SECONDS:-30}"
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || { echo "::error::tofu-plan: TOFU_PLAN_ATTEMPTS is not a positive number" >&2; exit 2; }
[[ "$retry_seconds" =~ ^[0-9]+$ ]] || { echo "::error::tofu-plan: TOFU_PLAN_RETRY_SECONDS is not a number" >&2; exit 2; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

redact_preauth_keys() {
  awk '{ gsub(/hskey-auth-[A-Za-z0-9_-]+/, "hskey-auth-<redacted>"); print; fflush() }'
}

only_hetzner_server_errors() {
  local plain errors server_errors
  plain="$(sed -E 's/\x1b\[[0-9;]*m//g' "$log")"
  errors="$(grep -cE '^[│| ]*Error: ' <<<"$plain" || true)"
  server_errors="$(grep -cE '^[│| ]*Status code: 5[0-9]{2} *$' <<<"$plain" || true)"
  [ "$errors" -gt 0 ] && [ "$errors" -eq "$server_errors" ]
}

attempt=1
while true; do
  set +e
  tofu plan "$@" 2>&1 | redact_preauth_keys | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  [ "$status" -ne 0 ] || exit 0
  if [ "$attempt" -ge "$max_attempts" ] || ! only_hetzner_server_errors; then
    exit "$status"
  fi
  wait_seconds=$((retry_seconds * attempt))
  echo "::warning::tofu-plan: attempt ${attempt} of ${max_attempts} failed on a Hetzner API 5xx only; planning again in ${wait_seconds}s"
  sleep "$wait_seconds"
  attempt=$((attempt + 1))
done
