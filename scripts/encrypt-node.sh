#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: encrypt-node.sh reinstall|rejoin|guard|kms
       encrypt-node.sh status NODE_IP

OpenTofu's local-exec for the rolling disk-encryption re-install
(infra/disk-encryption-rollout.tf), one cloud node per run.

reinstall  Waits until the node answers on the Talos API (a new server is
           still booting), then brings it to DESIRED (encrypted or plain) STATE and EPHEMERAL
           volumes by wiping them, so the machine config the apply sends next
           formats them again. Does nothing when the volumes already match, or
           when the node waits in maintenance mode for its first config (a new
           node, which formats its volumes from that config). Otherwise it
           refuses unless the cluster is healthy (guard), then cordons and
           drains the node, takes a control plane out of etcd and checks the
           other members still hold quorum, resets the node with STATE and
           EPHEMERAL wiped, deletes its Node object and waits until it answers
           in maintenance mode.
rejoin     Waits until the node unlocked its volumes as DESIRED, its Node is
           Ready and, for a control plane, etcd has every member again; then
           uncordons it. Fails after ENCRYPT_NODE_WAIT_SECONDS.
guard      The refusal on its own: every Kubernetes node Ready, etcd holding
           one member per control plane with each answering, and, when DESIRED
           is encrypted, the KMS answering TLS with a certificate that verifies.
kms        Whether the KMS at KMS_ENDPOINT answers TLS with a certificate that
           verifies against the system roots, as Talos checks it.
status     Prints the volume encryption of STATE and EPHEMERAL on NODE_IP.

Environment: NODE_NAME, NODE_IP (public), NODE_ROLE (controlplane|worker),
DESIRED (encrypted|plain), CONTROL_PLANE_IPS (space-separated public IPs),
KUBE_TLS_SERVER_NAME (a name in the API server certificate), KMS_ENDPOINT
(https://host:port), TALOSCONFIG (a talosconfig file; when it is unset, as in
the first apply of an empty state, reinstall and rejoin only act on nodes in
maintenance mode and say so). Optional: ENCRYPT_NODE_WAIT_SECONDS (1800),
ENCRYPT_NODE_POLL_SECONDS (10), ENCRYPT_NODE_DRAIN_TIMEOUT (600s)."

readonly wait_seconds="${ENCRYPT_NODE_WAIT_SECONDS:-1800}"
readonly poll_seconds="${ENCRYPT_NODE_POLL_SECONDS:-10}"
readonly drain_timeout="${ENCRYPT_NODE_DRAIN_TIMEOUT:-600s}"

fail() {
  echo "::error::encrypt-node ${NODE_NAME:-}: $*" >&2
  exit 1
}

say() {
  echo "encrypt-node ${NODE_NAME:-}: $*"
}

require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || fail "$name is empty"
  done
}

has_talosconfig() {
  [ -n "${TALOSCONFIG:-}" ] && [ -s "$TALOSCONFIG" ]
}

talos_at() {
  local address="$1"
  shift
  talosctl --talosconfig "$TALOSCONFIG" --endpoints "$address" --nodes "$address" "$@"
}

in_maintenance() {
  talosctl --insecure --endpoints "$NODE_IP" --nodes "$NODE_IP" get disks >/dev/null 2>&1
}

volume_encryption() {
  local address="$1"
  talos_at "$address" get volumestatus -o json \
    | jq -rs '
        map(select(.metadata.id == "STATE" or .metadata.id == "EPHEMERAL"))
        | sort_by(.metadata.id)
        | map("\(.metadata.id)=\(.spec.encryptionProvider // "" | if . == "" then "none" else . end):\(.spec.phase // "unknown")")
        | join(" ")'
}

providers_of() {
  sed -E 's/:[^ ]*//g' <<<"$1"
}

desired_provider() {
  if [ "$DESIRED" = "encrypted" ]; then echo luks2; else echo none; fi
}

expected_encryption() {
  local provider
  provider="$(desired_provider)"
  echo "EPHEMERAL=${provider}:ready STATE=${provider}:ready"
}

volumes_match_desired() {
  local actual
  actual="$(volume_encryption "$NODE_IP" 2>/dev/null)" || return 1
  [ "$actual" = "$(expected_encryption)" ]
}

control_plane_ips() {
  read -r -a cps <<<"$CONTROL_PLANE_IPS"
  [ "${#cps[@]}" -gt 0 ] || fail "CONTROL_PLANE_IPS names no control plane"
}

peer_ip() {
  local address
  for address in "${cps[@]}"; do
    [ "$address" != "$NODE_IP" ] && { echo "$address"; return; }
  done
  fail "no control plane other than this node to ask"
}

kube_setup() {
  peer="$(peer_ip)"
  talos_at "$peer" kubeconfig "${work}/kubeconfig" --force >/dev/null || fail "could not read a kubeconfig through ${peer}"
}

kube() {
  kubectl --kubeconfig "${work}/kubeconfig" --server "https://${peer}:6443" \
    --tls-server-name "$KUBE_TLS_SERVER_NAME" --request-timeout=30s "$@"
}

nodes_not_ready() {
  kube get nodes -o json | jq -r '
    .items[]
    | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 0)
    | .metadata.name'
}

etcd_member_count() {
  local listing
  listing="$(talos_at "$peer" etcd members)" || return 1
  printf '%s\n' "$listing" | awk 'NR > 1 && NF > 0' | wc -l | tr -d ' '
}

etcd_members_answer() {
  local address
  for address in "${cps[@]}"; do
    talos_at "$address" etcd status >/dev/null 2>&1 || return 1
  done
}

kms_answers() {
  curl --silent --show-error --output /dev/null --http2 --max-time 20 "${KMS_ENDPOINT}/"
}

require_healthy_cluster() {
  local not_ready members
  not_ready="$(nodes_not_ready)" || fail "the Kubernetes API did not answer through ${peer}; refusing"
  [ -z "$not_ready" ] || fail "refusing: node(s) not Ready: $(echo "$not_ready" | tr '\n' ' ')- finish the previous node first"
  members="$(etcd_member_count)" || fail "etcd members did not answer through ${peer}; refusing"
  [ "$members" -eq "${#cps[@]}" ] || fail "refusing: etcd has ${members} member(s), expected ${#cps[@]}"
  etcd_members_answer || fail "refusing: an etcd member does not answer its status"
  if [ "$DESIRED" = "encrypted" ]; then
    kms_answers || fail "refusing: the KMS at ${KMS_ENDPOINT} does not answer TLS with a verified certificate"
  fi
  say "guard passed: every node Ready, etcd ${members}/${#cps[@]} members answering"
}

wait_until() {
  local what="$1"
  shift
  local deadline=$((SECONDS + wait_seconds))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "gave up after ${wait_seconds}s waiting for ${what}"
    sleep "$poll_seconds"
  done
  say "$what"
}

drain() {
  kube cordon "$NODE_NAME" >/dev/null || fail "could not cordon"
  if ! kube drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout="$drain_timeout"; then
    kube uncordon "$NODE_NAME" >/dev/null || true
    fail "drain did not finish within ${drain_timeout}; the node is uncordoned and untouched"
  fi
  say "drained"
}

leave_etcd() {
  local members
  talos_at "$NODE_IP" etcd leave || fail "etcd leave failed; the node is cordoned and its volumes untouched"
  members="$(etcd_member_count)" || fail "etcd did not answer after the leave"
  [ "$members" -eq "$((${#cps[@]} - 1))" ] || fail "etcd has ${members} member(s) after the leave, expected $((${#cps[@]} - 1)); stopping before the wipe"
  say "left etcd; ${members} members keep quorum"
}

reset_node() {
  talos_at "$NODE_IP" reset --graceful=false --reboot \
    --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --wait=false \
    || fail "reset failed"
  say "reset with STATE and EPHEMERAL wiped; rebooting"
  kube delete node "$NODE_NAME" --wait=false >/dev/null || echo "::warning::could not delete Node ${NODE_NAME}; the kubelet re-registers it"
  wait_until "in maintenance mode, waiting for the encrypted config" in_maintenance
}

node_answers() {
  in_maintenance || { has_talosconfig && volume_encryption "$NODE_IP" >/dev/null 2>&1; }
}

reinstall() {
  require_env NODE_NAME NODE_IP NODE_ROLE DESIRED CONTROL_PLANE_IPS KUBE_TLS_SERVER_NAME KMS_ENDPOINT
  wait_until "answers on the Talos API" node_answers
  if in_maintenance; then
    say "waits in maintenance mode for its first config, which formats its volumes ${DESIRED}; nothing to wipe"
    return
  fi
  has_talosconfig || fail "no TALOSCONFIG to reach a configured node"
  local actual providers
  actual="$(volume_encryption "$NODE_IP")" || fail "the node's Talos API did not answer its volume status"
  providers="$(providers_of "$actual")"
  case "$providers" in
    "EPHEMERAL="*" STATE="*) ;;
    *) fail "the node reports '${actual}', not both STATE and EPHEMERAL; refusing to wipe what it cannot read" ;;
  esac
  if [ "$providers" = "$(providers_of "$(expected_encryption)")" ]; then
    say "volumes already ${DESIRED} (${actual}); nothing to do"
    return
  fi
  say "volumes are ${actual}, want ${DESIRED}: re-installing"
  control_plane_ips
  kube_setup
  require_healthy_cluster
  drain
  if [ "$NODE_ROLE" = "controlplane" ]; then
    leave_etcd
  fi
  reset_node
}

etcd_complete() {
  local members
  members="$(etcd_member_count 2>/dev/null)" || return 1
  [ "$members" -eq "${#cps[@]}" ] && etcd_members_answer
}

node_ready() {
  kube get node "$NODE_NAME" -o json 2>/dev/null \
    | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' >/dev/null
}

rejoin() {
  require_env NODE_NAME NODE_IP NODE_ROLE DESIRED CONTROL_PLANE_IPS KUBE_TLS_SERVER_NAME
  if ! has_talosconfig; then
    echo "::warning::encrypt-node ${NODE_NAME}: no TALOSCONFIG (first apply of an empty state); the diagnose run reports its volumes"
    return
  fi
  control_plane_ips
  wait_until "volumes unlocked $(expected_encryption)" volumes_match_desired
  kube_setup
  wait_until "Node Ready" node_ready
  if [ "$NODE_ROLE" = "controlplane" ]; then
    wait_until "etcd has all ${#cps[@]} members answering" etcd_complete
  fi
  kube uncordon "$NODE_NAME" >/dev/null || fail "could not uncordon"
  say "rejoined with $(volume_encryption "$NODE_IP")"
}

guard() {
  require_env NODE_IP DESIRED CONTROL_PLANE_IPS KUBE_TLS_SERVER_NAME KMS_ENDPOINT
  has_talosconfig || fail "no TALOSCONFIG"
  control_plane_ips
  kube_setup
  require_healthy_cluster
}

status() {
  local address="$1"
  has_talosconfig || fail "no TALOSCONFIG"
  local summary entries
  summary="$(volume_encryption "$address")" || fail "${address} did not answer its volume status"
  read -r -a entries <<<"$summary"
  printf '%s\n' "${entries[@]}"
  case "$(providers_of "$summary")" in
    "EPHEMERAL=luks2 STATE=luks2") echo "encrypted: STATE and EPHEMERAL are LUKS2" ;;
    *) echo "plain: STATE or EPHEMERAL is not LUKS2" ;;
  esac
}

for tool in talosctl kubectl jq curl awk; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077

case "${1:-}" in
  reinstall) reinstall ;;
  rejoin) rejoin ;;
  guard) guard ;;
  kms)
    require_env KMS_ENDPOINT
    kms_answers || fail "the KMS at ${KMS_ENDPOINT} does not answer TLS with a verified certificate"
    echo "the KMS at ${KMS_ENDPOINT} answers TLS with a certificate that verifies"
    ;;
  status) [ -n "${2:-}" ] || { echo "$usage" >&2; exit 2; }; status "$2" ;;
  -h | --help) echo "$usage" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
