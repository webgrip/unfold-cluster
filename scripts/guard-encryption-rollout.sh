#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: tofu show -json infra.tfplan | guard-encryption-rollout.sh

Reads a plan as JSON and refuses it when it re-installs more than one running
cloud node for disk encryption (terraform_data.disk_encryption_reinstall
created or replaced). Two re-installs in one apply could take two control
planes out of etcd at once, and three members cannot lose two. It does not
count a node whose server the same plan creates (it formats its volumes from
its first config), nor the first record of a node that stays plain. Prints the
node the plan re-installs, so the reviewer sees it next to the digest."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "::error::guard-encryption-rollout: jq is not installed" >&2; exit 1; }

reinstalls="$(jq -c '
  [.resource_changes[]?
    | select(.type == "hcloud_server" and (.name == "control_plane" or .name == "worker"))
    | select(.change.actions | index("create"))
    | .index] as $new_servers
  | [.resource_changes[]?
    | select(.type == "terraform_data" and .name == "disk_encryption_reinstall")
    | select(.change.actions | index("create"))
    | select(.index as $node | $new_servers | index($node) | not)
    | select((.change.before == null and .change.after.triggers_replace == [false]) | not)
    | {node: .index, encrypted: .change.after.triggers_replace[0]}]
')" || { echo "::error::guard-encryption-rollout: stdin is not a plan in JSON" >&2; exit 1; }

count="$(jq 'length' <<<"$reinstalls")"
describe() {
  jq -r '.[] | "\(.node) (\(if .encrypted then "to encrypted" else "back to plain" end))"' <<<"$reinstalls" | paste -sd, - | sed 's/,/, /g'
}

case "$count" in
  0) echo "this plan re-installs no running node" ;;
  1) echo "::notice::this plan wipes and re-installs $(describe): drained, out of etcd if a control plane, STATE and EPHEMERAL wiped" ;;
  *)
    echo "::error::this plan re-installs ${count} running nodes at once: $(describe). Add one node to disk_encryption_nodes per reviewed plan." >&2
    exit 1
    ;;
esac
