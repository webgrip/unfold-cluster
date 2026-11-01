#!/usr/bin/env bash
# Smoke tests for the guard-secrets PreToolUse hook. CI runs every skills/*/test.sh.
# Feeds the hook synthetic tool_input events and asserts the exit-2 deny contract.
set -euo pipefail
cd "$(dirname "$0")"
HOOK=scripts/guard_secrets.py

# fire <expected-rc> <json>  — run the hook with a tool_input event
fire() {
  local want="$1" json="$2" rc=0
  printf '%s' "$json" | python3 "$HOOK" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "$want" ] || { echo "FAIL: expected rc=$want got rc=$rc for: $json" >&2; exit 1; }
}

# denied (rc=2)
fire 2 '{"tool_input":{"file_path":"secrets.decrypted.yaml","content":"x"}}'
fire 2 '{"tool_input":{"file_path":"values.sops.yaml","content":"password: hunter2"}}'
fire 2 '{"tool_input":{"file_path":"app.sops.yml","new_string":"token: abc"}}'

# allowed (rc=0)
fire 0 '{"tool_input":{"file_path":"values.sops.yaml","content":"password: ENC[AES256,data:...]"}}'
fire 0 '{"tool_input":{"file_path":"README.md","content":"just docs"}}'
fire 0 '{"tool_input":{"file_path":"values.yaml","content":"replicas: 3"}}'
fire 0 '{"tool_input":{}}'
fire 0 'not json at all'

# absent gitleaks: still allowed (rc=0) and the skip is reported, not silent
PY3="$(python3 -c 'import sys; print(sys.executable)')"
out="$(printf '%s' '{"tool_input":{"file_path":"values.yaml","content":"replicas: 3"}}' | PATH=/nonexistent "$PY3" "$HOOK" 2>&1 >/dev/null)" || { echo "FAIL: absent gitleaks must not block" >&2; exit 1; }
case "$out" in *gitleaks*) ;; *) echo "FAIL: absent gitleaks must be reported on stderr" >&2; exit 1 ;; esac

fakes="$(mktemp -d)"
trap 'rm -rf "$fakes"' EXIT
mkdir -p "$fakes/mise-only" "$fakes/mise-without-gitleaks" "$fakes/tools"
printf '#!/bin/sh\nexit 1\n' > "$fakes/tools/gitleaks"
printf '#!/bin/sh\n[ "$1 $2" = "which gitleaks" ] && echo %s/tools/gitleaks\n' "$fakes" > "$fakes/mise-only/mise"
printf '#!/bin/sh\nexit 1\n' > "$fakes/mise-without-gitleaks/mise"
chmod +x "$fakes/tools/gitleaks" "$fakes/mise-only/mise" "$fakes/mise-without-gitleaks/mise"
event='{"tool_input":{"file_path":"values.yaml","content":"token: flagged"}}'

rc=0; printf '%s' "$event" | PATH="$fakes/mise-only" "$PY3" "$HOOK" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL: gitleaks found only through mise must still scan and block, got rc=$rc" >&2; exit 1; }

rc=0; out="$(printf '%s' "$event" | PATH="$fakes/mise-without-gitleaks" "$PY3" "$HOOK" 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: mise without gitleaks must not block, got rc=$rc" >&2; exit 1; }
case "$out" in *gitleaks*) ;; *) echo "FAIL: mise without gitleaks must be reported on stderr" >&2; exit 1 ;; esac

echo "guard-secrets: ok"
