#!/bin/sh
set -eu

readonly usage="usage: unfold-tailnet-key renew
       unfold-tailnet-key control-plane read|mint
       unfold-tailnet-key worker SERVER_ID read|mint
       unfold-tailnet-key gateway GENERATION read|mint
       unfold-tailnet-key policy set < policy.hujson
       unfold-tailnet-key config set < config.yaml
       unfold-tailnet-key oidc-secret set < client-secret
       unfold-tailnet-key host apply TAILSCALE_VERSION TAILSCALE_SHA256
       unfold-tailnet-key idp reconcile
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
config set               install the Headscale configuration on stdin at CONFIG_PATH
                         and restart Headscale when it differs, creating an empty
                         OIDC client secret file first when there is none, and put
                         the previous configuration back if Headscale does not
                         come up with it
oidc-secret set          install the OIDC client secret on stdin at OIDC_SECRET_PATH,
                         readable by the headscale group only, and restart
                         Headscale when it differs and the configuration uses it;
                         never prints it
host apply VERSION SHA   install Tailscale VERSION from its static package when
                         another version or none is installed, refusing a package
                         whose sha256 is not SHA, and keep the timer that runs
                         idp reconcile every two minutes
idp reconcile            join this server to its own tailnet as HEADSCALE_TAG with a
                         single-use key when it is not on it, point the identity
                         provider's host in HOSTS_FILE at the tailnet address of
                         the GATEWAY_TAG node, and restart Headscale when it
                         started without OIDC and the provider answers now, at
                         most once every HEAL_INTERVAL_SECONDS
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
: "${HEADSCALE_TAG:=tag:headscale}"
: "${HEADSCALE_KEY_LIFETIME_HOURS:=1}"
: "${HEADSCALE_NODE_NAME:=unfold-headscale}"
: "${CONFIG_PATH:=/etc/headscale/config.yaml}"
: "${OIDC_SECRET_PATH:=/etc/headscale/oidc_client_secret}"
: "${HOSTS_FILE:=/etc/hosts}"
: "${HEAL_INTERVAL_SECONDS:=600}"
: "${TAILSCALE_PATH:=/usr/bin/tailscale}"
: "${TAILSCALED_PATH:=/usr/sbin/tailscaled}"
: "${TAILSCALED_DEFAULTS:=/etc/default/tailscaled}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${TAILSCALE_PACKAGE_URL:=https://pkgs.tailscale.com/stable}"

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

replace_and_restart() {
  target="$1"
  candidate="$2"
  what="$3"
  chmod 0644 "$candidate"
  cp -p "$target" "${target}.previous"
  mv "$candidate" "$target"
  systemctl restart headscale
  if ! wait_for_headscale; then
    mv "${target}.previous" "$target"
    systemctl restart headscale
    fail "headscale did not start with the new ${what}; the previous one is back"
  fi
  echo "${what} installed"
}

read_candidate() {
  cat >"$1"
  [ -s "$1" ] || { rm -f "$1"; fail "the $2 on stdin is empty"; }
}

set_policy() {
  candidate="${POLICY_PATH}.candidate"
  read_candidate "$candidate" policy
  if cmp -s "$candidate" "$POLICY_PATH"; then
    rm -f "$candidate"
    echo "policy unchanged"
    return
  fi
  headscale policy check -f "$candidate" >/dev/null 2>&1 \
    || { rm -f "$candidate"; fail "headscale refuses the policy on stdin"; }
  replace_and_restart "$POLICY_PATH" "$candidate" policy
}

give_secret_to_headscale() {
  if getent group headscale >/dev/null 2>&1; then
    chgrp headscale "$1"
  fi
  chmod 0640 "$1"
}

ensure_oidc_secret_file() {
  [ -e "$OIDC_SECRET_PATH" ] && return
  : >"$OIDC_SECRET_PATH"
  give_secret_to_headscale "$OIDC_SECRET_PATH"
}

set_config() {
  candidate="${CONFIG_PATH}.candidate"
  read_candidate "$candidate" configuration
  if cmp -s "$candidate" "$CONFIG_PATH"; then
    rm -f "$candidate"
    echo "configuration unchanged"
    return
  fi
  ensure_oidc_secret_file
  replace_and_restart "$CONFIG_PATH" "$candidate" configuration
}

config_uses_oidc_secret() {
  grep -qxF "  client_secret_path: ${OIDC_SECRET_PATH}" "$CONFIG_PATH"
}

set_oidc_secret() {
  candidate="${OIDC_SECRET_PATH}.candidate"
  read_candidate "$candidate" "client secret"
  if cmp -s "$candidate" "$OIDC_SECRET_PATH"; then
    rm -f "$candidate"
    echo "client secret unchanged"
    return
  fi
  give_secret_to_headscale "$candidate"
  mv "$candidate" "$OIDC_SECRET_PATH"
  if config_uses_oidc_secret; then
    systemctl restart headscale
    wait_for_headscale || fail "headscale did not start after the client secret changed"
  fi
  echo "client secret installed"
}

installed_tailscale_version() {
  if [ -x "$TAILSCALE_PATH" ] && [ -x "$TAILSCALED_PATH" ]; then
    "$TAILSCALE_PATH" version 2>/dev/null | head -n 1
  fi
}

install_tailscale() {
  version="$1"
  sha256="$2"
  if [ "$(installed_tailscale_version)" = "$version" ]; then
    echo "tailscale ${version} present"
    return
  fi
  download="$(mktemp -d)"
  package="${download}/tailscale.tgz"
  if ! curl -fsSL --max-time 300 -o "$package" "${TAILSCALE_PACKAGE_URL}/tailscale_${version}_amd64.tgz"; then
    rm -rf "$download"
    fail "could not download tailscale ${version}"
  fi
  if ! echo "${sha256}  ${package}" | sha256sum -c - >/dev/null 2>&1; then
    rm -rf "$download"
    fail "the tailscale ${version} package does not have sha256 ${sha256}; nothing installed"
  fi
  tar -xzf "$package" -C "$download"
  unpacked="${download}/tailscale_${version}_amd64"
  install -m 0755 "${unpacked}/tailscaled" "$TAILSCALED_PATH"
  install -m 0755 "${unpacked}/tailscale" "$TAILSCALE_PATH"
  install -m 0644 "${unpacked}/systemd/tailscaled.service" "${SYSTEMD_DIR}/tailscaled.service"
  [ -e "$TAILSCALED_DEFAULTS" ] || install -m 0644 "${unpacked}/systemd/tailscaled.defaults" "$TAILSCALED_DEFAULTS"
  rm -rf "$download"
  systemctl daemon-reload
  systemctl enable tailscaled >/dev/null 2>&1
  systemctl restart tailscaled
  echo "tailscale ${version} installed"
}

idp_service_unit() {
  cat <<UNIT
[Unit]
Description=Keep unfold-headscale on its own tailnet and its identity provider in reach
After=headscale.service tailscaled.service
Wants=tailscaled.service

[Service]
Type=oneshot
ExecStart=${SELF_PATH} idp reconcile
UNIT
}

idp_timer_unit() {
  cat <<UNIT
[Unit]
Description=Reconcile unfold-headscale's own tailnet node and identity provider route

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT
}

write_unit_when_changed() {
  unit_candidate="${SYSTEMD_DIR}/${1}.candidate"
  cat >"$unit_candidate"
  chmod 0644 "$unit_candidate"
  if cmp -s "$unit_candidate" "${SYSTEMD_DIR}/${1}"; then
    rm -f "$unit_candidate"
    return 1
  fi
  mv "$unit_candidate" "${SYSTEMD_DIR}/${1}"
}

apply_host() {
  install_tailscale "$1" "$2"
  units_changed=false
  idp_service_unit | write_unit_when_changed unfold-headscale-idp.service && units_changed=true
  idp_timer_unit | write_unit_when_changed unfold-headscale-idp.timer && units_changed=true
  if [ "$units_changed" = true ]; then
    systemctl daemon-reload
    echo "identity provider timer installed"
  fi
  systemctl enable --now unfold-headscale-idp.timer >/dev/null 2>&1
}

config_value() {
  sed -n "s|^${1}: *\\(.*\\)\$|\\1|p" "$CONFIG_PATH" | head -n 1
}

oidc_issuer() {
  sed -n 's|^  issuer: *\(https://[^ ]*\)$|\1|p' "$CONFIG_PATH" | head -n 1
}

host_of() {
  printf '%s' "$1" | sed -n 's|^https://\([^/:]*\).*$|\1|p'
}

on_own_tailnet() {
  "$TAILSCALE_PATH" status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1
}

join_own_tailnet() {
  [ -x "$TAILSCALE_PATH" ] || fail "tailscale is not installed yet; host apply installs it"
  if on_own_tailnet; then
    echo "on its own tailnet"
    return
  fi
  require_headscale
  require_public_health
  key_file="${STATE_DIR}/self.authkey"
  key_from "$(headscale preauthkeys create \
    --user "$(user_id "$NODE_USER")" \
    --tags "$HEADSCALE_TAG" \
    --expiration "${HEADSCALE_KEY_LIFETIME_HOURS}h" \
    -o json)" >"$key_file"
  if ! "$TAILSCALE_PATH" up --reset \
    --login-server="$(config_value server_url)" \
    --auth-key="file:${key_file}" \
    --hostname="$HEADSCALE_NODE_NAME" \
    --accept-dns=false \
    --accept-routes=false \
    --timeout=60s >/dev/null 2>&1; then
    rm -f "$key_file"
    fail "could not join its own tailnet as ${HEADSCALE_TAG}"
  fi
  rm -f "$key_file"
  echo "joined its own tailnet as ${HEADSCALE_TAG}"
}

gateway_tailnet_ipv4() {
  headscale nodes list -o json | jq -r --arg tag "$GATEWAY_TAG" '
    [(. // [])[] | select((.tags // []) | index($tag))]
    | sort_by([(.online // false), (.last_seen.seconds // 0)])
    | last // {}
    | [(.ip_addresses // [])[] | select(test("^[0-9]+(\\.[0-9]+){3}$"))]
    | first // empty'
}

point_host_at() {
  host="$1"
  address="$2"
  hosts_candidate="$(mktemp)"
  awk -v host="$host" '{ for (i = 2; i <= NF; i++) if ($i == host) next; print }' "$HOSTS_FILE" >"$hosts_candidate"
  printf '%s %s\n' "$address" "$host" >>"$hosts_candidate"
  if cmp -s "$hosts_candidate" "$HOSTS_FILE"; then
    rm -f "$hosts_candidate"
    echo "${host} already points at ${address}"
    return
  fi
  cat "$hosts_candidate" >"$HOSTS_FILE"
  rm -f "$hosts_candidate"
  echo "${host} now points at ${address}"
}

route_idp() {
  require_headscale
  address="$(gateway_tailnet_ipv4)"
  [ -n "$address" ] || fail "no ${GATEWAY_TAG} node with an IPv4 address on the tailnet yet"
  point_host_at "$1" "$address"
}

headscale_started_without_oidc() {
  invocation="$(systemctl show -p InvocationID --value headscale 2>/dev/null || true)"
  [ -n "$invocation" ] || return 1
  journalctl "_SYSTEMD_INVOCATION_ID=${invocation}" -o cat --no-pager 2>/dev/null \
    | grep -qF 'falling back to CLI based authentication'
}

idp_answers() {
  curl -fsS --max-time 10 "${1}.well-known/openid-configuration" 2>/dev/null \
    | jq -e --arg issuer "$1" '.issuer == $issuer' >/dev/null 2>&1
}

heal_oidc() {
  issuer="$1"
  if ! headscale_started_without_oidc; then
    echo "headscale runs with OIDC"
    return
  fi
  if ! idp_answers "$issuer"; then
    echo "headscale runs without OIDC: ${issuer} does not answer; tailnet nodes are unaffected, browser logins wait"
    return
  fi
  heal_file="${STATE_DIR}/oidc-heal.last"
  last_heal="$(cat "$heal_file" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ "$((now - last_heal))" -lt "$HEAL_INTERVAL_SECONDS" ]; then
    echo "headscale runs without OIDC; restarted it less than ${HEAL_INTERVAL_SECONDS}s ago, waiting"
    return
  fi
  echo "$now" >"$heal_file"
  systemctl restart headscale
  wait_for_headscale || fail "headscale did not come back after the restart that enables OIDC"
  echo "restarted headscale, whose OIDC provider answers now"
}

reconcile_idp() {
  outcome=0
  ( join_own_tailnet ) || outcome=1
  issuer="$(oidc_issuer)"
  if [ -z "$issuer" ]; then
    echo "no OIDC issuer in ${CONFIG_PATH}"
    return "$outcome"
  fi
  ( route_idp "$(host_of "$issuer")" ) || outcome=1
  ( heal_oidc "$issuer" ) || outcome=1
  return "$outcome"
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
  policy | config | oidc-secret)
    [ "$#" -eq 2 ] || usage_error
    action="$2"
    [ "$action" = "set" ] || usage_error
    ;;
  host)
    [ "$#" -eq 4 ] || usage_error
    action="$2"
    tailscale_version="$3"
    tailscale_sha256="$4"
    [ "$action" = "apply" ] || usage_error
    printf '%s' "$tailscale_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || usage_error
    printf '%s' "$tailscale_sha256" | grep -qE '^[0-9a-f]{64}$' || usage_error
    ;;
  idp)
    [ "$#" -eq 2 ] || usage_error
    action="$2"
    [ "$action" = "reconcile" ] || usage_error
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
  renew | read | mint | set | list | apply | reconcile) ;;
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
  config/set)
    set_config
    ;;
  oidc-secret/set)
    set_oidc_secret
    ;;
  host/apply)
    apply_host "$tailscale_version" "$tailscale_sha256"
    ;;
  idp/reconcile)
    reconcile_idp
    ;;
  install/)
    install_self
    ;;
  nodes/list)
    require_headscale
    list_nodes
    ;;
esac
