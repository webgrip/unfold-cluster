#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: disk-kms-key.sh < query.json

OpenTofu's external program for the disk KMS master key, the AES-256 key the
KMS on unfold-headscale seals every node's LUKS2 key with. OpenBao holds the
only original: the query names its KV path and property ({\"path\": ...,
\"property\": ...}), and this prints {\"master_key\": \"<base64 of 32 bytes>\"}.

When OpenBao holds no key and UNFOLD_TAILNET_MINT=allowed (set only on apply
runs, the same switch that lets them mint tailnet keys), it makes one from
32 bytes of /dev/urandom, writes it, reads it back and prints what OpenBao
holds. Otherwise it prints an empty key, which an apply run refuses (a
precondition on unfold-headscale) and a plan-only run shows as a change of a
sensitive value. A key that OpenBao holds is never replaced: every encrypted
disk depends on it.

OPENBAO_KV (default scripts/openbao-kv.sh next to this file) is the KV client."

fail() {
  echo "disk-kms-key: $*" >&2
  exit 1
}

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

command -v jq >/dev/null || fail "jq is not installed"
kv="${OPENBAO_KV:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/openbao-kv.sh}"

query="$(cat)"
kv_path="$(jq -er '.path | select(type == "string" and length > 0)' <<<"$query")" || fail "the query has no path"
property="$(jq -er '.property | select(type == "string" and length > 0)' <<<"$query")" || fail "the query has no property"

is_master_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]
}

stored="$("$kv" get "$kv_path" "$property")" || fail "OpenBao could not be read"

if [ -z "$stored" ] && [ "${UNFOLD_TAILNET_MINT:-read-only}" = "allowed" ]; then
  head -c 32 /dev/urandom | base64 -w0 | "$kv" put disk-kms-key "$kv_path" "$property" >/dev/null || fail "OpenBao refused the new key"
  stored="$("$kv" get "$kv_path" "$property")" || fail "OpenBao could not be read back"
  [ -n "$stored" ] || fail "OpenBao holds no key after writing one"
fi

[ -z "$stored" ] || is_master_key "$stored" || fail "${kv_path} ${property} in OpenBao is not base64 of 32 bytes; refusing to seal disks with it"

jq -cn --arg key "$stored" '{master_key: $key}'
