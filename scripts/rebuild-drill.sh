#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: rebuild-drill.sh guard|teardown
       rebuild-drill.sh verify INFRA_DIR
       rebuild-drill.sh tailnet INFRA_DIR

The steps of the rebuild drill (.forgejo/workflows/rebuild-drill.yml) that are
not OpenTofu. Every Hetzner call uses HCLOUD_TOKEN, the drill project's token,
never production's.

guard     refuses unless the Hetzner project behind HCLOUD_TOKEN is empty,
          then marks it as the drill's with a placement group named
          rebuild-drill-marker. An empty project is the drill's starting point,
          and it is what keeps a production token, seeded by mistake, from
          being used: production is never empty.
teardown  refuses unless the project carries that marker, then lifts every
          protection and deletes every server, load balancer, volume, IP,
          network, firewall, placement group, SSH key, certificate and
          snapshot in it, and fails unless the project is empty afterwards.
verify    checks, through the public control plane addresses and the state in
          INFRA_DIR, what the bootstrap checklist's stage D checks by hand:
          every node Ready in its pool, three etcd members, Flux reconciling a
          verified commit and owning its seed, the Secrets OpenTofu writes.
tailnet   waits up to TAILNET_WAIT_SECONDS (default 900) until Headscale lists
          every cluster node online, asked over the tofu user's SSH key, which
          may run nothing but unfold-tailnet-key.

talosctl and kubectl must be on PATH for verify (diagnose-cluster.sh
--install-tools). HCLOUD_ENDPOINT overrides https://api.hetzner.cloud/v1."

readonly api="${HCLOUD_ENDPOINT:-https://api.hetzner.cloud/v1}"
readonly marker="rebuild-drill-marker"
readonly resource_kinds="servers load_balancers volumes floating_ips primary_ips networks firewalls placement_groups ssh_keys certificates images"

fail() {
  echo "::error::rebuild-drill: $*" >&2
  exit 1
}

hcloud() {
  [ -n "${HCLOUD_TOKEN:-}" ] || fail "HCLOUD_TOKEN is not set"
  curl -fsS --retry 3 --max-time 30 -H "Authorization: Bearer ${HCLOUD_TOKEN}" -H 'Content-Type: application/json' "$@"
}

list_kind() {
  local kind="$1" query="per_page=50"
  [ "$kind" != "images" ] || query="${query}&type=snapshot"
  hcloud "${api}/${kind}?${query}" | jq -c --arg kind "$kind" '.[$kind] // [] | map({id, name: (.name // .description // ""), protection})'
}

project_inventory() {
  local kind
  for kind in $resource_kinds; do
    list_kind "$kind" | jq -c --arg kind "$kind" '.[] | . + {kind: $kind}'
  done
}

wait_action() {
  local action_id="$1" status
  [ -n "$action_id" ] && [ "$action_id" != "null" ] || return 0
  for _ in $(seq "${HCLOUD_ACTION_POLLS:-90}"); do
    status="$(hcloud "${api}/actions/${action_id}" | jq -r '.action.status')"
    case "$status" in
      success) return 0 ;;
      error) fail "Hetzner action ${action_id} failed" ;;
    esac
    sleep 2
  done
  fail "Hetzner action ${action_id} did not finish"
}

unprotect() {
  local kind="$1" id="$2" body='{"delete":false}'
  case "$kind" in
    servers) body='{"delete":false,"rebuild":false}' ;;
    load_balancers | volumes | floating_ips | primary_ips | networks | images) ;;
    *) return 0 ;;
  esac
  wait_action "$(hcloud -X POST --data "$body" "${api}/${kind}/${id}/actions/change_protection" | jq -r '.action.id')"
}

delete_resource() {
  local kind="$1" id="$2"
  if [ "$kind" = "volumes" ]; then
    hcloud -X POST "${api}/volumes/${id}/actions/detach" >/dev/null 2>&1 || true
  fi
  local answer
  answer="$(hcloud -X DELETE "${api}/${kind}/${id}" || true)"
  [ -n "$answer" ] || return 0
  wait_action "$(jq -r '.action.id // empty' <<<"$answer" 2>/dev/null || true)"
}

guard() {
  local inventory
  inventory="$(project_inventory)"
  if [ -n "$inventory" ]; then
    echo "the drill project is not empty:" >&2
    jq -r '"  \(.kind) \(.id) \(.name)"' <<<"$inventory" >&2
    fail "refusing to start: the drill needs an empty Hetzner project, and production is never empty. Run the drill with teardown-only if a crashed drill left these behind."
  fi
  hcloud -X POST --data "{\"name\":\"${marker}\",\"type\":\"spread\",\"labels\":{\"rebuild-drill\":\"true\"}}" "${api}/placement_groups" >/dev/null
  echo "the project is empty and now marked as the drill's"
}

teardown() {
  local marked
  marked="$(list_kind placement_groups | jq -r --arg m "$marker" 'map(select(.name == $m)) | length')"
  [ "$marked" = "1" ] || fail "the project behind HCLOUD_TOKEN carries no ${marker}; refusing to delete anything in it"
  local round kind entry id
  for round in 1 2 3; do
    for kind in $resource_kinds; do
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        id="$(jq -r .id <<<"$entry")"
        [ "$kind" != "placement_groups" ] || [ "$(jq -r .name <<<"$entry")" != "$marker" ] || continue
        echo "deleting ${kind} ${id} $(jq -r .name <<<"$entry")"
        unprotect "$kind" "$id" || true
        delete_resource "$kind" "$id" || true
      done < <(list_kind "$kind" | jq -c '.[]')
    done
    [ "$(project_inventory | jq -s --arg m "$marker" 'map(select(.name != $m)) | length')" = "0" ] && break
    echo "round ${round} left resources behind; trying again"
    sleep "${TEARDOWN_RETRY_SECONDS:-20}"
  done
  local left
  left="$(project_inventory | jq -s -c --arg m "$marker" 'map(select(.name != $m))')"
  [ "$left" = "[]" ] || fail "the drill project still holds: ${left}"
  delete_resource placement_groups "$(list_kind placement_groups | jq -r --arg m "$marker" '.[] | select(.name == $m) | .id')"
  [ -z "$(project_inventory)" ] || fail "the drill project is not empty after the teardown"
  echo "the drill project is empty; nothing is billed any more"
}

state_files() {
  local infra_dir="$1"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  umask 077
  tofu -chdir="$infra_dir" output -raw talosconfig >"${work}/talosconfig"
  tofu -chdir="$infra_dir" output -raw kubeconfig >"${work}/kubeconfig"
  tofu -chdir="$infra_dir" output -json control_planes >"${work}/control_planes.json"
  tofu -chdir="$infra_dir" output -json workers >"${work}/workers.json"
}

failures=()
expect() {
  local title="$1"
  shift
  if "$@" >"${work}/check.out" 2>&1; then
    echo "PASS ${title}"
  else
    echo "FAIL ${title}: $(tail -n 3 "${work}/check.out" | tr '\n' ' ' | cut -c1-300)"
    failures+=("$title")
  fi
}

kube() {
  local server tls_name
  server="https://$(jq -r '[.[].public_ipv4][0]' "${work}/control_planes.json"):6443"
  tls_name="$(kubectl --kubeconfig "${work}/kubeconfig" config view -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#^https://([^:/]+).*#\1#')"
  kubectl --kubeconfig "${work}/kubeconfig" --server "$server" --tls-server-name "$tls_name" --request-timeout=20s "$@"
}

talos() {
  local node
  node="$(jq -r '[.[].public_ipv4][0]' "${work}/control_planes.json")"
  talosctl --talosconfig "${work}/talosconfig" --endpoints "$node" --nodes "$node" "$@"
}

nodes_ready_in_their_pools() {
  local nodes expected
  nodes="$(kube get nodes -o json)"
  expected="$(jq -s -c '(.[0] | keys) + (.[1] | keys) | sort' "${work}/control_planes.json" "${work}/workers.json")"
  jq -e --argjson expected "$expected" --slurpfile workers "${work}/workers.json" '
    .items as $items
    | ([$items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | .metadata.name] | sort) == $expected
    and all($workers[0] | to_entries[]; . as $w | any($items[]; .metadata.name == $w.key and .metadata.labels["node.webgrip.io/pool"] == $w.value.pool))
  ' <<<"$nodes"
}

three_etcd_members() {
  [ "$(talos etcd members | tail -n +2 | grep -c .)" = "3" ]
}

ready() {
  kube get "$@" -o json | jq -e '(.items // [.]) | length > 0 and all(.[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))'
}

source_verified() {
  kube -n flux-system get gitrepository flux-system -o json \
    | jq -e 'any(.status.conditions[]; .type == "SourceVerified" and .status == "True")'
}

flux_owns_its_seed() {
  [ "$(kube -n flux-system get gitrepository,kustomization flux-system -o jsonpath='{.items[*].metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')" = "flux-system flux-system" ]
}

opentofu_wrote() {
  kube -n "$1" get secret "$2" --show-managed-fields -o json | jq -e 'any(.metadata.managedFields[]; .manager == "opentofu")'
}

verify() {
  state_files "$1"
  local attempt
  for attempt in $(seq 40); do
    if nodes_ready_in_their_pools >/dev/null 2>&1 && ready -n flux-system kustomization flux-system >/dev/null 2>&1; then
      break
    fi
    echo "waiting for the nodes and Flux (${attempt}/40)"
    sleep 30
  done
  expect "every node is Ready, each worker in its pool" nodes_ready_in_their_pools
  expect "etcd has three members" three_etcd_members
  expect "Flux's source is Ready" ready -n flux-system gitrepository flux-system
  expect "Flux verified the signature of the commit it applies" source_verified
  expect "Flux applied kubernetes/clusters/main" ready -n flux-system kustomization flux-system
  expect "the Flux operator and instance are Ready" ready -n flux-system helmrelease flux-operator
  expect "the FluxInstance is Ready" ready -n flux-system fluxinstance flux
  expect "Flux owns its own GitRepository and Kustomization" flux_owns_its_seed
  expect "Cilium is Ready under Flux" ready -n kube-system helmrelease cilium
  expect "the cloud controller is Ready under Flux" ready -n kube-system helmrelease hcloud-cloud-controller-manager
  expect "the CSI driver is Ready under Flux" ready -n kube-system helmrelease hcloud-csi
  expect "OpenTofu wrote kube-system/hcloud" opentofu_wrote kube-system hcloud
  expect "OpenTofu wrote etcd-backup/etcd-backup" opentofu_wrote etcd-backup etcd-backup
  if [ "${#failures[@]}" -gt 0 ]; then
    fail "${#failures[@]} check(s) failed: ${failures[*]}"
  fi
  echo "every check passed"
}

headscale_nodes() {
  local host
  host="$(tofu -chdir="$1" output -raw headscale_ssh_known_hosts | awk '{split($1, a, ","); print a[2]}')"
  ssh -F /dev/null -i "${work}/id" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${work}/known_hosts" -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519 \
    -o ConnectTimeout=10 -o LogLevel=ERROR "tofu@${host}" "nodes list"
}

tailnet() {
  local infra_dir="$1" expected listed
  state_files "$infra_dir"
  tofu -chdir="$infra_dir" output -raw headscale_tofu_ssh_private_key >"${work}/id"
  tofu -chdir="$infra_dir" output -raw headscale_ssh_known_hosts | awk '{split($1, a, ","); print a[2], $2, $3}' >"${work}/known_hosts"
  expected="$(jq -s -c '(.[0] | keys) + (.[1] | keys) | sort' "${work}/control_planes.json" "${work}/workers.json")"
  local deadline=$((SECONDS + ${TAILNET_WAIT_SECONDS:-900}))
  while :; do
    listed="$(headscale_nodes "$infra_dir" 2>/dev/null || echo '[]')"
    if jq -e --argjson expected "$expected" '[.[] | select(.online) | .name] as $online | all($expected[]; . as $n | $online | index($n))' <<<"$listed" >/dev/null; then
      echo "Headscale lists every node online: $(jq -c '[.[] | select(.online) | .name]' <<<"$listed")"
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "not every node is online in Headscale: wanted ${expected}, Headscale lists ${listed}"
    echo "waiting for the nodes to join Headscale: $(jq -c '[.[] | select(.online) | .name]' <<<"$listed" 2>/dev/null || echo none) online"
    sleep 30
  done
}

for tool in curl jq; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

case "${1:-}" in
  -h | --help) echo "$usage" ;;
  guard) [ "$#" -eq 1 ] || { echo "$usage" >&2; exit 2; }; guard ;;
  teardown) [ "$#" -eq 1 ] || { echo "$usage" >&2; exit 2; }; teardown ;;
  verify) [ "$#" -eq 2 ] || { echo "$usage" >&2; exit 2; }; verify "$2" ;;
  tailnet) [ "$#" -eq 2 ] || { echo "$usage" >&2; exit 2; }; tailnet "$2" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
