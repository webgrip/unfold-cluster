#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-tailnet-key-tool.sh

Runs infra/templates/unfold-tailnet-key.sh, the program OpenTofu calls on
unfold-headscale over SSH, against a stubbed headscale and systemctl, and
checks the policy, install and gateway key modes: what they change, what they
refuse, and that a policy Headscale cannot start with is rolled back."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/infra/templates/unfold-tailnet-key.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "${work}/bin" "${work}/state"
cat >"${work}/bin/headscale" <<'STUB'
#!/usr/bin/env bash
echo "headscale $*" >>"${STUB_LOG}"
[ ! -e "${STUB_DIR}/down" ] || exit 1
case "$1 $2" in
  "users list") echo '[{"id": 1}]' ;;
  "users create") echo '{}' ;;
  "preauthkeys create") echo '{"key": "hskey-auth-stub", "id": 5}' ;;
  "policy check") ! grep -q REFUSED "$4" ;;
  *) exit 1 ;;
esac
STUB
cat >"${work}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"${STUB_LOG}"
if grep -q NOSTART "${POLICY_PATH}"; then touch "${STUB_DIR}/down"; else rm -f "${STUB_DIR}/down"; fi
STUB
chmod +x "${work}/bin/headscale" "${work}/bin/systemctl"

cat >"${work}/settings.env" <<EOF
NODE_USER=nodes
ADMIN_USER=admin
CONTROL_PLANE_TAG=tag:cp
CONTROL_PLANE_KEY_LIFETIME_HOURS=2160
RENEW_WHEN_DAYS_LEFT=45
WORKER_TAG=tag:node
WORKER_KEY_LIFETIME_HOURS=24
STATE_DIR=${work}/state
HEALTH_URL=https://headscale.invalid/health
HEALTH_CONNECT_TO=headscale.invalid:443:127.0.0.1:443
POLICY_PATH=${work}/acl.hujson
SELF_PATH=${work}/unfold-tailnet-key
HEADSCALE_START_SECONDS=2
EOF

export PATH="${work}/bin:${PATH}" STUB_DIR="$work" STUB_LOG="${work}/calls.log" \
  UNFOLD_TAILNET_SETTINGS="${work}/settings.env" POLICY_PATH="${work}/acl.hujson"

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}"
    failures=$((failures + 1))
  fi
}
run_tool() {
  sh "$tool" "$@"
}
restarts() {
  grep -c '^systemctl restart' "$STUB_LOG" 2>/dev/null || true
}

echo '{"acls": ["old"]}' >"${work}/acl.hujson"
cp "$tool" "${work}/unfold-tailnet-key"

check "an unchanged policy restarts nothing" \
  bash -c '[ "$(sh "$0" policy set <"$1")" = "policy unchanged" ] && ! grep -q "^systemctl" "$2"' "$tool" "${work}/acl.hujson" "$STUB_LOG"

check "a new policy is installed and Headscale restarted" \
  bash -c 'echo "{\"acls\": [\"new\"]}" | sh "$0" policy set >/dev/null && grep -q new "$1" && [ "$(grep -c "^systemctl restart" "$2")" = 1 ]' "$tool" "${work}/acl.hujson" "$STUB_LOG"

check "a policy Headscale refuses is not installed" \
  bash -c '! (echo "{\"acls\": [\"REFUSED\"]}" | sh "$0" policy set 2>/dev/null) && grep -q new "$1" && [ ! -e "$1.candidate" ]' "$tool" "${work}/acl.hujson"

check "a policy Headscale cannot start with is rolled back" \
  bash -c '! (echo "{\"acls\": [\"NOSTART\"]}" | sh "$0" policy set 2>/dev/null) && grep -q new "$1" && [ ! -e "$2/down" ]' "$tool" "${work}/acl.hujson" "$work"

check "an empty policy is refused" \
  bash -c '! (sh "$0" policy set </dev/null 2>/dev/null) && grep -q new "$1"' "$tool" "${work}/acl.hujson"

check "policy takes only set" \
  bash -c 'sh "$0" policy get </dev/null 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "the same program is not reinstalled" \
  bash -c '[ "$(sh "$0" install <"$0")" = "program unchanged" ]' "$tool"

check "a new program is installed" \
  bash -c '{ cat "$0"; echo "true"; } | sh "$0" install >/dev/null && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "a program that does not parse is refused" \
  bash -c '! (printf "#!/bin/sh\nif then\n" | sh "$0" install 2>/dev/null) && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "a program for another interpreter is refused" \
  bash -c '! (printf "#!/bin/bash\ntrue\n" | sh "$0" install 2>/dev/null) && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "the gateway key is minted with the gateway tag" \
  bash -c '[ "$(sh "$0" gateway 1 mint)" = "hskey-auth-stub" ] && grep -q -- "--tags tag:homelab-gateway" "$1"' "$tool" "$STUB_LOG"

check "a second mint of the same generation makes no new key" \
  bash -c 'before="$(grep -c "preauthkeys create" "$1")"; sh "$0" gateway 1 mint >/dev/null && [ "$(grep -c "preauthkeys create" "$1")" = "$before" ]' "$tool" "$STUB_LOG"

check "read returns the minted key and nothing for an unminted generation" \
  bash -c '[ "$(sh "$0" gateway 1 read)" = "hskey-auth-stub" ] && [ -z "$(sh "$0" gateway 2 read)" ]' "$tool"

check "a generation that is not a number is refused" \
  bash -c 'sh "$0" gateway "1;id" read 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "the worker mode still reads nothing for an unknown server" \
  bash -c '[ -z "$(sh "$0" worker 42 read)" ]' "$tool"

echo "restarts: $(restarts)"
if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
