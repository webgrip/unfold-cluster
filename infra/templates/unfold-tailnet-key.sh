#!/bin/sh
set -eu

readonly usage="usage: unfold-tailnet-key renew
       unfold-tailnet-key control-plane read|mint
       unfold-tailnet-key worker SERVER_ID read|mint
       unfold-tailnet-key gateway GENERATION read|mint
       unfold-tailnet-key policy set < policy.hujson
       unfold-tailnet-key install < unfold-tailnet-key
       unfold-tailnet-key nodes list

renew                    make sure the control planes' reusable tag:cp pre-auth key
                         has more than RENEW_WHEN_DAYS_LEFT days left, creating the
                         Headscale users and a new key when it has not, and expiring
                         the key it replaces
control-plane read       print the control planes' key, or nothing when there is none
control-plane mint       renew, check Headscale's public health endpoint, print the key
worker SERVER_ID read    print the single-use tag:node key made for that Hetzner
                         server, or nothing when none was made
worker SERVER_ID mint    the same, first making the key when none was made: one per
                         server, expiring after WORKER_KEY_LIFETIME_HOURS
gateway GENERATION read  print the single-use GATEWAY_TAG key made for that
                         generation of the homelab gateway, or nothing
gateway GENERATION mint  the same, first making the key when none was made
policy set               check the policy on stdin against the running Headscale,
                         install it at POLICY_PATH and restart Headscale when it
                         differs, and put the previous policy back if Headscale
                         does not come up with it
install                  replace this program with the one on stdin after a
                         syntax check, when it differs
nodes list               print the nodes Headscale knows as JSON, name and
                         whether it is online, and nothing else"

settings_file="${UNFOLD_TAILNET_SETTINGS:-/etc/unfold-tailnet/settings.env}"
# shellcheck source=/dev/null
. "$settings_file"

: "${NODE_USER:?}" "${ADMIN_USER:?}" "${CONTROL_PLANE_TAG:?}" "${WORKER_TAG:?}"
: "${CONTROL_PLANE_KEY_LIFETIME_HOURS:?}" "${RENEW_WHEN_DAYS_LEFT:?}" "${WORKER_KEY_LIFETIME_HOURS:?}"
: "${STATE_DIR:?}" "${HEALTH_URL:?}" "${HEALTH_CONNECT_TO:?}"
: "${GATEWAY_TAG:=tag:homelab-gateway}"
: "${GATEWAY_KEY_LIFETIME_HOURS:=168}"
: "${POLICY_PATH:=/etc/headscale/acl.hujson}"
: "${SELF_PATH:=/usr/local/sbin/unfold-tailnet-key}"
: "${HEADSCALE_START_SECONDS:=60}"

key_file="${STATE_DIR}/control-plane.authkey"
key_id_file="${STATE_DIR}/control-plane.authkey.id"

fail() {
  echo "unfold-tailnet-key: $*" >&2
  exit 1
}

user_id() {
  headscale users list --name "$1" -o json | jq -r '(. // [])[0].id // empty'
}

ensure_user() {
  [ -n "$(user_id "$1")" ] || headscale users create "$1" -o json >/dev/null
}

require_headscale() {
  headscale users list -o json >/dev/null 2>&1 || fail "headscale does not answer on its socket yet"
  ensure_user "$NODE_USER"
  ensure_user "$ADMIN_USER"
}

require_public_health() {
  curl -fsS --max-time 5 --connect-to "$HEALTH_CONNECT_TO" "$HEALTH_URL" >/dev/null \
    || fail "${HEALTH_URL} does not pass yet"
}

seconds_left_on_control_plane_key() {
  if [ ! -s "$key_file" ] || [ ! -s "$key_id_file" ]; then
    echo 0
    return
  fi
  headscale preauthkeys list -o json | jq -r \
    --argjson id "$(cat "$key_id_file")" \
    --argjson now "$(date +%s)" \
    '[(. // [])[] | select(.id == $id) | .expiration.seconds - $now] | first // 0'
}

key_from() {
  printf '%s' "$1" | jq -er '.key | select(startswith("hskey-auth-"))' || fail "headscale returned no pre-auth key"
}

create_control_plane_key() {
  replaced_key_id="$(cat "$key_id_file" 2>/dev/null || true)"
  created="$(headscale preauthkeys create \
    --user "$(user_id "$NODE_USER")" \
    --reusable \
    --tags "$CONTROL_PLANE_TAG" \
    --expiration "${CONTROL_PLANE_KEY_LIFETIME_HOURS}h" \
    -o json)"
  key_from "$created" >"${key_file}.new"
  printf '%s' "$created" | jq -er '.id' >"${key_id_file}.new"
  mv "${key_file}.new" "$key_file"
  mv "${key_id_file}.new" "$key_id_file"
  if [ -n "$replaced_key_id" ]; then
    headscale preauthkeys expire --id "$replaced_key_id" -o json >/dev/null || true
  fi
}

renew_control_plane_key() {
  if [ "$(seconds_left_on_control_plane_key)" -le "$((RENEW_WHEN_DAYS_LEFT * 86400))" ]; then
    create_control_plane_key
  fi
}

worker_key_file() {
  echo "${STATE_DIR}/workers/${1}.authkey"
}

create_worker_key() {
  mkdir -p "${STATE_DIR}/workers"
  key_from "$(headscale preauthkeys create \
    --user "$(user_id "$NODE_USER")" \
    --tags "$WORKER_TAG" \
    --expiration "${WORKER_KEY_LIFETIME_HOURS}h" \
    -o json)" >"$(worker_key_file "$1").new"
  mv "$(worker_key_file "$1").new" "$(worker_key_file "$1")"
}

gateway_key_file() {
  echo "${STATE_DIR}/gateway/${1}.authkey"
}

create_gateway_key() {
  mkdir -p "${STATE_DIR}/gateway"
  key_from "$(headscale preauthkeys create \
    --user "$(user_id "$NODE_USER")" \
    --tags "$GATEWAY_TAG" \
    --expiration "${GATEWAY_KEY_LIFETIME_HOURS}h" \
    -o json)" >"$(gateway_key_file "$1").new"
  mv "$(gateway_key_file "$1").new" "$(gateway_key_file "$1")"
}

wait_for_headscale() {
  deadline=$(($(date +%s) + HEADSCALE_START_SECONDS))
  until headscale users list -o json >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

set_policy() {
  candidate="${POLICY_PATH}.candidate"
  cat >"$candidate"
  [ -s "$candidate" ] || fail "the policy on stdin is empty"
  if cmp -s "$candidate" "$POLICY_PATH"; then
    rm -f "$candidate"
    echo "policy unchanged"
    return
  fi
  headscale policy check -f "$candidate" >/dev/null 2>&1 \
    || { rm -f "$candidate"; fail "headscale refuses the policy on stdin"; }
  chmod 0644 "$candidate"
  cp -p "$POLICY_PATH" "${POLICY_PATH}.previous"
  mv "$candidate" "$POLICY_PATH"
  systemctl restart headscale
  if ! wait_for_headscale; then
    mv "${POLICY_PATH}.previous" "$POLICY_PATH"
    systemctl restart headscale
    fail "headscale did not start with the new policy; the previous one is back"
  fi
  echo "policy installed"
}

install_self() {
  candidate="${SELF_PATH}.candidate"
  cat >"$candidate"
  head -n 1 "$candidate" | grep -qx '#!/bin/sh' || { rm -f "$candidate"; fail "stdin is not a /bin/sh program"; }
  sh -n "$candidate" || { rm -f "$candidate"; fail "stdin does not parse"; }
  if cmp -s "$candidate" "$SELF_PATH"; then
    rm -f "$candidate"
    echo "program unchanged"
    return
  fi
  chmod 0755 "$candidate"
  mv "$candidate" "$SELF_PATH"
  echo "program installed"
}

list_nodes() {
  headscale nodes list -o json | jq -c '[(. // [])[] | {name: (.given_name // .name), online: (.online // false)}] | sort_by(.name)'
}

print_if_present() {
  if [ -s "$1" ]; then
    cat "$1"
  fi
}

usage_error() {
  echo "$usage" >&2
  exit 2
}

mode="${1:-}"
case "$mode" in
  renew)
    [ "$#" -eq 1 ] || usage_error
    ;;
  control-plane)
    [ "$#" -eq 2 ] || usage_error
    action="$2"
    ;;
  worker)
    [ "$#" -eq 3 ] || usage_error
    server_id="$2"
    action="$3"
    case "$server_id" in
      '' | *[!0-9]*) usage_error ;;
    esac
    ;;
  gateway)
    [ "$#" -eq 3 ] || usage_error
    generation="$2"
    action="$3"
    case "$generation" in
      '' | *[!0-9]*) usage_error ;;
    esac
    ;;
  policy)
    [ "$#" -eq 2 ] || usage_error
    action="$2"
    [ "$action" = "set" ] || usage_error
    ;;
  install)
    [ "$#" -eq 1 ] || usage_error
    ;;
  nodes)
    [ "$#" -eq 2 ] || usage_error
    action="$2"
    [ "$action" = "list" ] || usage_error
    ;;
  *) usage_error ;;
esac
case "${action:-renew}" in
  renew | read | mint | set | list) ;;
  *) usage_error ;;
esac

umask 077
mkdir -p "$STATE_DIR"
exec 9>"${STATE_DIR}/lock"
flock 9

case "$mode/${action:-}" in
  renew/)
    require_headscale
    renew_control_plane_key
    ;;
  control-plane/read)
    print_if_present "$key_file"
    ;;
  control-plane/mint)
    require_headscale
    renew_control_plane_key
    require_public_health
    cat "$key_file"
    ;;
  worker/read)
    print_if_present "$(worker_key_file "$server_id")"
    ;;
  worker/mint)
    if [ ! -s "$(worker_key_file "$server_id")" ]; then
      require_headscale
      require_public_health
      create_worker_key "$server_id"
    fi
    cat "$(worker_key_file "$server_id")"
    ;;
  gateway/read)
    print_if_present "$(gateway_key_file "$generation")"
    ;;
  gateway/mint)
    if [ ! -s "$(gateway_key_file "$generation")" ]; then
      require_headscale
      create_gateway_key "$generation"
    fi
    cat "$(gateway_key_file "$generation")"
    ;;
  policy/set)
    require_headscale
    set_policy
    ;;
  install/)
    install_self
    ;;
  nodes/list)
    require_headscale
    list_nodes
    ;;
esac
