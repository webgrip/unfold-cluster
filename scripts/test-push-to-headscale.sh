#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-push-to-headscale.sh

Runs scripts/push-to-headscale.sh, OpenTofu's local-exec for unfold-headscale,
against a stubbed ssh, and checks the request each mode sends, what it sends
on stdin, that SSH trusts only the pinned host key, that a refused host key is
not retried, and that the OIDC client secret appears in nothing it prints,
not even when the server refuses it."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
push="${repo}/scripts/push-to-headscale.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "${work}/bin"
cat >"${work}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_DIR}/ssh-args"
cat >"${STUB_DIR}/ssh-stdin"
for argument in "$@"; do
  case "$argument" in
    UserKnownHostsFile=*) cp "${argument#UserKnownHostsFile=}" "${STUB_DIR}/known-hosts" ;;
  esac
done
case "$(cat "${STUB_DIR}/answer" 2>/dev/null || echo ok)" in
  ok) echo "done" ;;
  refuse) echo "unfold-tailnet-key: the server says no" >&2; exit 1 ;;
  hostkey) echo "Host key verification failed." >&2; exit 255 ;;
esac
STUB
chmod +x "${work}/bin/ssh"

export PATH="${work}/bin:${PATH}" STUB_DIR="$work" \
  HEADSCALE_HOST=198.51.100.23 \
  HEADSCALE_HOST_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey" \
  HEADSCALE_TOFU_KEY="-----BEGIN OPENSSH PRIVATE KEY-----mock-----END OPENSSH PRIVATE KEY-----" \
  UNFOLD_TAILNET_WAIT_SECONDS=0

secret="canary-oidc-secret-$$"
secret_b64="$(printf '%s' "$secret" | base64 -w0)"
sha="$(printf '%064d' 7)"

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
answer() {
  echo "$1" >"${work}/answer"
}
request_was() {
  [ "$(tail -n 1 "${work}/ssh-args")" = "$1" ]
}

answer ok
check "policy sends the decoded policy to policy set" \
  bash -c 'CONTENT_B64="$(printf "{}" | base64 -w0)" "$0" policy >/dev/null && [ "$(tail -n 1 "$1/ssh-args")" = "policy set" ] && [ "$(cat "$1/ssh-stdin")" = "{}" ]' "$push" "$work"

check "config sends the decoded configuration to config set" \
  bash -c 'CONTENT_B64="$(printf "server_url: x\n" | base64 -w0)" "$0" config >/dev/null && [ "$(tail -n 1 "$1/ssh-args")" = "config set" ] && [ "$(cat "$1/ssh-stdin")" = "server_url: x" ]' "$push" "$work"

check "oidc-secret sends the secret on stdin to oidc-secret set and never on the command line" \
  bash -c 'CONTENT_B64="$2" "$0" oidc-secret >/dev/null && [ "$(tail -n 1 "$1/ssh-args")" = "oidc-secret set" ] && [ "$(cat "$1/ssh-stdin")" = "$3" ] && ! grep -qF "$3" "$1/ssh-args"' "$push" "$work" "$secret_b64" "$secret"

check "host sends nothing on stdin and the pinned version and sha256 to host apply" \
  bash -c 'TAILSCALE_VERSION=1.104.2 TAILSCALE_SHA256="$2" "$0" host >/dev/null && [ "$(tail -n 1 "$1/ssh-args")" = "host apply 1.104.2 $2" ] && [ ! -s "$1/ssh-stdin" ]' "$push" "$work" "$sha"

check "host refuses a version that is not one, without calling the server" \
  bash -c 'rm -f "$1/ssh-args"; ! (TAILSCALE_VERSION="1.2;id" TAILSCALE_SHA256="$2" "$0" host 2>/dev/null) && [ ! -e "$1/ssh-args" ]' "$push" "$work" "$sha"

check "host refuses a sha256 that is not one" \
  bash -c '! (TAILSCALE_VERSION=1.104.2 TAILSCALE_SHA256=abc "$0" host 2>/dev/null)' "$push"

check "a content mode without content is refused" \
  bash -c '! (CONTENT_B64="" "$0" config 2>/dev/null)' "$push"

check "SSH trusts only the pinned host key" \
  bash -c 'CONTENT_B64="$(printf "{}" | base64 -w0)" "$0" policy >/dev/null && grep -qx "StrictHostKeyChecking=yes" "$1/ssh-args" && grep -qx "GlobalKnownHostsFile=/dev/null" "$1/ssh-args" && [ "$(cat "$1/known-hosts")" = "198.51.100.23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey" ]' "$push" "$work"

answer hostkey
check "a server with another host key is refused" \
  bash -c 'out="$(CONTENT_B64="$1" "$0" oidc-secret 2>&1)"; [ $? -eq 1 ] && grep -q "did not present the pinned SSH host key" <<<"$out"' "$push" "$secret_b64"

answer refuse
check "a refused client secret fails without printing it" \
  bash -c 'out="$(CONTENT_B64="$1" "$0" oidc-secret 2>&1)"; status=$?; [ "$status" -eq 1 ] && grep -q "the server says no" <<<"$out" && ! grep -qF "$2" <<<"$out" && ! grep -qF "$1" <<<"$out"' "$push" "$secret_b64" "$secret"

answer ok
check "an accepted client secret prints nothing of it" \
  bash -c 'out="$(CONTENT_B64="$1" "$0" oidc-secret 2>&1)" && ! grep -qF "$2" <<<"$out"' "$push" "$secret_b64" "$secret"

check "an unknown mode is a usage error" \
  bash -c '"$0" secret 2>/dev/null; [ $? -eq 2 ]' "$push"

if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
