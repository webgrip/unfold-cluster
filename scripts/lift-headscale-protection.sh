#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: tofu show -json infra.tfplan | lift-headscale-protection.sh

Hetzner refuses to delete a server with delete protection, and the hcloud
provider does not lift it before a replacement. Run between the digest check
and tofu apply, this lifts delete and rebuild protection on unfold-headscale
when, and only when, the reviewed plan replaces or deletes that server
(hcloud_server.headscale, named unfold-headscale), so a raised
headscale_generation needs one apply. It touches no other resource; the new
server is created with both protections on again. A plan that does not delete
unfold-headscale changes nothing.

Environment: HCLOUD_TOKEN, and HCLOUD_ENDPOINT (default
https://api.hetzner.cloud/v1)."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

fail() {
  echo "::error::lift-headscale-protection: $*" >&2
  exit 1
}

for tool in curl jq; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

readonly api="${HCLOUD_ENDPOINT:-https://api.hetzner.cloud/v1}"
plan="$(cat)"
jq -e '.resource_changes | type == "array"' <<<"$plan" >/dev/null 2>&1 || fail "stdin is not a plan in tofu show -json form"

deletion="$(jq -c '[.resource_changes[]
  | select(.address == "hcloud_server.headscale" and (.change.actions | index("delete")))
  | {id: (.change.before.id | tostring), name: .change.before.name}] | first // empty' <<<"$plan")"

if [ -z "$deletion" ]; then
  echo "the plan does not replace unfold-headscale; no protection lifted"
  exit 0
fi

server_id="$(jq -r .id <<<"$deletion")"
server_name="$(jq -r .name <<<"$deletion")"
[[ "$server_id" =~ ^[0-9]+$ ]] || fail "the plan names no numeric id for hcloud_server.headscale"
[ "$server_name" = "unfold-headscale" ] || fail "hcloud_server.headscale in the plan is named ${server_name}, not unfold-headscale; refusing"
[ -n "${HCLOUD_TOKEN:-}" ] || fail "HCLOUD_TOKEN is not set"

hcloud() {
  curl -fsS --max-time 30 -H "Authorization: Bearer ${HCLOUD_TOKEN}" -H 'Content-Type: application/json' "$@"
}

live_name="$(hcloud "${api}/servers/${server_id}" | jq -r '.server.name // empty')" || fail "Hetzner did not answer for server ${server_id}"
[ "$live_name" = "unfold-headscale" ] || fail "server ${server_id} is ${live_name:-gone} in Hetzner, not unfold-headscale; refusing"

action_id="$(hcloud -X POST --data '{"delete":false,"rebuild":false}' "${api}/servers/${server_id}/actions/change_protection" | jq -r '.action.id')" \
  || fail "Hetzner refused to lift the protection of server ${server_id}"

for _ in $(seq 60); do
  status="$(hcloud "${api}/actions/${action_id}" | jq -r '.action.status')"
  case "$status" in
    success)
      echo "lifted delete and rebuild protection on unfold-headscale (server ${server_id}); the plan replaces it"
      exit 0
      ;;
    error) fail "Hetzner action ${action_id} failed" ;;
  esac
  sleep 2
done
fail "Hetzner action ${action_id} did not finish in time"
