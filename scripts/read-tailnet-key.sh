#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: read-tailnet-key.sh < query.json

OpenTofu's external program for the tailnet pre-auth keys on unfold-headscale.
Reads one JSON object on stdin with host, host_public_key, private_key and
request (\"control-plane\" or \"worker SERVER_ID\"), asks unfold-tailnet-key on
the server over SSH, and prints {\"key\": \"...\"}.

SSH trusts nothing but host_public_key. A server presenting any other host key
fails the run, whatever the mode.

With UNFOLD_TAILNET_MINT=allowed (apply runs) the server may make a key that
does not exist yet, and an unreachable or not yet healthy server is retried for
UNFOLD_TAILNET_WAIT_SECONDS (default 1500). Otherwise (plan-only runs) the
server only reads, one attempt is made, and an unreachable server gives an
empty key instead of failing the plan."

fail() {
  echo "read-tailnet-key: $*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

for tool in jq ssh mktemp; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

query="$(cat)"
field() {
  jq -er --arg name "$1" '.[$name] | select(type == "string" and length > 0)' <<<"$query" \
    || fail "the query has no $1"
}

host="$(field host)"
host_public_key="$(field host_public_key)"
request="$(field request)"
[[ "$request" =~ ^(control-plane|worker\ [0-9]+)$ ]] || fail "unknown request: $request"

if [ "${UNFOLD_TAILNET_MINT:-}" = "allowed" ]; then
  action="mint"
  deadline=$((SECONDS + ${UNFOLD_TAILNET_WAIT_SECONDS:-1500}))
else
  action="read"
  deadline=$SECONDS
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077
field private_key >"${workdir}/id"
printf '%s %s\n' "$host" "$host_public_key" >"${workdir}/known_hosts"

ask_server() {
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
    "tofu@${host}" "${request} ${action}" 2>"${workdir}/stderr"
}

host_key_was_refused() {
  grep -qiE 'host key verification failed|remote host identification has changed|host key for .* has changed' "${workdir}/stderr"
}

while true; do
  if key="$(ask_server)"; then
    key="${key//[$'\r\n ']/}"
    if [ "$action" = "read" ] || [[ "$key" == hskey-auth-* ]]; then
      break
    fi
  elif host_key_was_refused; then
    fail "${host} did not present the pinned SSH host key; refusing to talk to it"
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    if [ "$action" = "read" ]; then
      key=""
      break
    fi
    fail "no ${request} key from ${host} in time: $(tr '\n' ' ' <"${workdir}/stderr")"
  fi
  sleep 15
done

[ -z "$key" ] || [[ "$key" == hskey-auth-* ]] || fail "${host} answered something that is not a pre-auth key"
jq -n --arg key "$key" '{key: $key}'
