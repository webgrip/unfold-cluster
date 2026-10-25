#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: push-to-headscale.sh install|policy

OpenTofu's local-exec for unfold-headscale. Sends CONTENT_B64, decoded, on
stdin to unfold-tailnet-key on the server over SSH: 'install' replaces the
program itself, 'policy' runs 'policy set' with the Headscale policy.

Environment: HEADSCALE_HOST, HEADSCALE_HOST_PUBLIC_KEY (the pinned ed25519
host key), HEADSCALE_TOFU_KEY (the tofu user's private key), CONTENT_B64.
SSH trusts nothing but the pinned host key. An unreachable server, or one
whose Headscale does not answer on its socket yet, is retried for
UNFOLD_TAILNET_WAIT_SECONDS (default 1500), because a new server answers only
once cloud-init has finished and Headscale has its certificate."

fail() {
  echo "push-to-headscale: $*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  install) request="install" ;;
  policy) request="policy set" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

for tool in base64 ssh mktemp; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
for name in HEADSCALE_HOST HEADSCALE_HOST_PUBLIC_KEY HEADSCALE_TOFU_KEY CONTENT_B64; do
  [ -n "${!name:-}" ] || fail "$name is empty"
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077
printf '%s\n' "$HEADSCALE_TOFU_KEY" >"${workdir}/id"
printf '%s %s\n' "$HEADSCALE_HOST" "$HEADSCALE_HOST_PUBLIC_KEY" >"${workdir}/known_hosts"
printf '%s' "$CONTENT_B64" | base64 -d >"${workdir}/content" || fail "CONTENT_B64 is not base64"
[ -s "${workdir}/content" ] || fail "nothing to send"

send() {
  ssh -F /dev/null \
    -i "${workdir}/id" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${workdir}/known_hosts" \
    -o GlobalKnownHostsFile=/dev/null \
    -o HostKeyAlgorithms=ssh-ed25519 \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "tofu@${HEADSCALE_HOST}" "$request" <"${workdir}/content" 2>"${workdir}/stderr"
}

headscale_still_starting() {
  grep -q 'headscale does not answer on its socket yet' "${workdir}/stderr"
}

deadline=$((SECONDS + ${UNFOLD_TAILNET_WAIT_SECONDS:-1500}))
until send; do
  status=$?
  if grep -qiE 'host key verification failed|remote host identification has changed|host key for .* has changed' "${workdir}/stderr"; then
    fail "${HEADSCALE_HOST} did not present the pinned SSH host key; refusing to talk to it"
  fi
  if [ "$status" -ne 255 ] && ! headscale_still_starting; then
    fail "unfold-tailnet-key ${request} refused (a server created before this mode existed is replaced by raising headscale_generation): $(tr '\n' ' ' <"${workdir}/stderr")"
  fi
  [ "$SECONDS" -lt "$deadline" ] || fail "${HEADSCALE_HOST} unreachable: $(tr '\n' ' ' <"${workdir}/stderr")"
  sleep 15
done
