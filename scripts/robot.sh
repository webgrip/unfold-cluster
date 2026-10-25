#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153
set -euo pipefail
export LC_ALL=C

readonly usage="usage: robot.sh COMMAND

Talks to the Hetzner Robot webservice for the metal nodes. OpenTofu runs every
command; the read-only ones as external data sources (JSON on stdin and
stdout), the others from local-exec provisioners of a reviewed apply.

Read-only:
  quote          stdin {name, product, location, max_monthly_eur, max_setup_eur}
                 The server named NAME when Robot has it; otherwise the
                 product's monthly and setup price in LOCATION, primary IPv4
                 included, refused when either exceeds its ceiling.
  server         stdin {name}: number and addresses of the server named NAME.
  mac            stdin {name, record_path}: the MAC address the install
                 recorded for NAME, empty before the install.
  vswitch-id     stdin {name, vlan}: id of the vSwitch with that name and VLAN.
  status         SERVER_NUMBER: prints the server, rescue, firewall and
                 vSwitch state for a job log.

Changing (local-exec only):
  order          Orders server NAME once: never when Robot already has a
                 server of that name, an order is recorded in OpenBao or one
                 is in process, and never past SERVER_LIMIT servers, another
                 product or a price ceiling. A test order goes first.
  vswitch-ensure Creates the vSwitch VSWITCH_NAME on VLAN VSWITCH_VLAN unless it
                 exists.
  vswitch-attach Adds SERVER_NUMBER to VSWITCH_ID and waits until it is ready.
  firewall       Sets the Robot firewall of SERVER_NUMBER to FIREWALL_RULES
                 (JSON {input: [...], output: [...]}) and waits for it.
  install        Installs Talos on SERVER_NUMBER from the rescue system, unless
                 it already runs Talos (see docs/runbooks/metal-node.md).

order and install each make a fresh SSH key, register it in Robot for the
order or the rescue system, and remove it from Robot when they finish; no
private key outlives the command or reaches the OpenTofu state.

Environment: ROBOT_USER and ROBOT_PASSWORD (the Robot webservice user),
ROBOT_ENDPOINT (default https://robot-ws.your-server.de), OPENBAO_KV (default
scripts/openbao-kv.sh beside this script)."

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
readonly robot_endpoint="${ROBOT_ENDPOINT:-https://robot-ws.your-server.de}"
readonly openbao_kv="${OPENBAO_KV:-${script_dir}/openbao-kv.sh}"
session_key_fingerprint=""

workdir="$(mktemp -d)"
cleanup() {
  if [ -n "$session_key_fingerprint" ]; then
    robot_call DELETE "/key/${session_key_fingerprint}" || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT
chmod 0700 "$workdir"

fail() {
  echo "::error::robot: $*" >&2
  exit 1
}

say() {
  echo "$*" >&2
}

require_credentials() {
  [ -n "${ROBOT_USER:-}" ] && [ -n "${ROBOT_PASSWORD:-}" ] \
    || fail "ROBOT_USER and ROBOT_PASSWORD are not set; seed secret/hetzner/unfold-robot (docs/runbooks/metal-node.md)"
}

curl_config_quoted() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

robot_call() {
  local method="$1" path="$2"
  shift 2
  local body="${workdir}/body.json" status
  local form=()
  local field
  for field in "$@"; do
    form+=(--data-urlencode "$field")
  done
  status="$(curl -sS --max-time 60 -o "$body" -w '%{http_code}' -X "$method" "${form[@]}" \
    --config - "${robot_endpoint}${path}" <<CURLCONFIG
user = $(curl_config_quoted "${ROBOT_USER}:${ROBOT_PASSWORD}")
CURLCONFIG
)" || status="000"
  ROBOT_STATUS="$status"
  ROBOT_BODY="$(cat "$body" 2>/dev/null || true)"
}

robot_error_code() {
  jq -r '.error.code // empty' <<<"$ROBOT_BODY" 2>/dev/null || true
}

robot_expect() {
  local what="$1"
  shift
  local wanted
  for wanted in "$@"; do
    [ "$ROBOT_STATUS" = "$wanted" ] && return 0
  done
  fail "${what}: Robot answered HTTP ${ROBOT_STATUS} $(robot_error_code)"
}

robot_get() {
  robot_call GET "$1"
  robot_expect "GET $1" 200
  printf '%s' "$ROBOT_BODY"
}

servers_json() {
  robot_call GET /server
  case "$ROBOT_STATUS" in
    200) jq -c '[.[].server]' <<<"$ROBOT_BODY" ;;
    404) echo '[]' ;;
    *) fail "GET /server: Robot answered HTTP ${ROBOT_STATUS} $(robot_error_code)" ;;
  esac
}

server_named() {
  jq -c --arg name "$2" '[.[] | select(.server_name == $name and (.cancelled | not))] | first // empty' <<<"$1"
}

decimal_exceeds() {
  awk -v value="$1" -v ceiling="$2" 'BEGIN { exit !((value + 0) > (ceiling + 0)) }'
}

decimal_sum() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.4f", (a + 0) + (b + 0) }'
}

product_quote() {
  local product="$1" location="$2" max_monthly="$3" max_setup="$4"
  local product_json monthly setup addon monthly_total
  robot_call GET "/order/server/product/${product}"
  if [ "$ROBOT_STATUS" = "404" ]; then
    robot_call GET /order/server/product
    local candidates=""
    [ "$ROBOT_STATUS" != "200" ] || candidates="$(jq -r --arg p "${product:0:4}" '[.[].product | select(.id | ascii_downcase | startswith($p | ascii_downcase)) | .id] | join(", ")' <<<"$ROBOT_BODY")"
    fail "Robot sells no product ${product}; products starting like it: ${candidates:-none}"
  fi
  robot_expect "GET /order/server/product/${product}" 200
  product_json="$(jq -c '.product' <<<"$ROBOT_BODY")"
  [ "$(jq -r '.id' <<<"$product_json")" = "$product" ] || fail "Robot answered for product $(jq -r '.id' <<<"$product_json"), not ${product}; refusing"
  jq -e --arg l "$location" '.location | index($l)' <<<"$product_json" >/dev/null \
    || fail "${product} is not sold in ${location}; it is sold in $(jq -r '.location | join(", ")' <<<"$product_json")"
  monthly="$(jq -r --arg l "$location" '.prices[] | select(.location == $l) | .price.net' <<<"$product_json")"
  setup="$(jq -r --arg l "$location" '.prices[] | select(.location == $l) | .price_setup.net' <<<"$product_json")"
  addon="$(jq -r --arg l "$location" '[.orderable_addons[]? | select(.id == "primary_ipv4") | .prices[] | select(.location == $l) | .price.net] | first // empty' <<<"$product_json")"
  [ -n "$monthly" ] && [ -n "$setup" ] || fail "${product} has no price in ${location}"
  [ -n "$addon" ] || fail "${product} offers no primary_ipv4 addon in ${location}; without it the server would have no IPv4 address"
  monthly_total="$(decimal_sum "$monthly" "$addon")"
  if decimal_exceeds "$monthly_total" "$max_monthly"; then
    fail "${product} in ${location} costs ${monthly_total} EUR a month net with its IPv4 address, above the ceiling of ${max_monthly}; refusing"
  fi
  if decimal_exceeds "$setup" "$max_setup"; then
    fail "${product} in ${location} has a setup fee of ${setup} EUR net, above the ceiling of ${max_setup}; refusing"
  fi
  jq -nc --arg product "$product" --arg location "$location" --arg monthly "$monthly_total" --arg setup "$setup" \
    '{product: $product, location: $location, monthly_net_eur: $monthly, setup_net_eur: $setup}'
}

command_quote() {
  require_credentials
  local query name product location max_monthly max_setup server
  query="$(cat)"
  name="$(jq -r '.name' <<<"$query")"
  product="$(jq -r '.product' <<<"$query")"
  location="$(jq -r '.location' <<<"$query")"
  max_monthly="$(jq -r '.max_monthly_eur' <<<"$query")"
  max_setup="$(jq -r '.max_setup_eur' <<<"$query")"
  server="$(server_named "$(servers_json)" "$name")"
  if [ -n "$server" ]; then
    jq -c --arg location "$location" '{state: "ordered", product: .product, location: $location, server_number: (.server_number | tostring), monthly_net_eur: "", setup_net_eur: ""}' <<<"$server"
    return
  fi
  product_quote "$product" "$location" "$max_monthly" "$max_setup" | jq -c '. + {state: "to-order", server_number: ""}'
}

command_server() {
  require_credentials
  local name server
  name="$(jq -r '.name')"
  server="$(server_named "$(servers_json)" "$name")"
  [ -n "$server" ] || fail "Robot has no server named ${name}; the order step names it"
  jq -c '{server_number: (.server_number | tostring), server_ip: (.server_ip // ""), server_ipv6_net: (.server_ipv6_net // ""), status: .status}' <<<"$server"
}

command_mac() {
  local query name record_path mac
  query="$(cat)"
  name="$(jq -r '.name' <<<"$query")"
  record_path="$(jq -r '.record_path' <<<"$query")"
  mac="$("$openbao_kv" get "$record_path" mac)"
  [ -n "$mac" ] || fail "no MAC address is recorded for ${name} at ${record_path}; the install records it"
  jq -nc --arg mac "$mac" '{mac: $mac}'
}

record_get() {
  "$openbao_kv" get "$RECORD_PATH" "$1"
}

record_put() {
  printf '%s\n' "$3" | "$openbao_kv" put "$1" "$RECORD_PATH" "$2" >&2
}

name_server() {
  local number="$1"
  robot_call POST "/server/${number}" "server_name=${NAME}"
  robot_expect "POST /server/${number}" 200
  say "server ${number} is named ${NAME} in Robot"
}

wait_for_transaction() {
  local transaction_id="$1" deadline status number
  deadline=$((SECONDS + ${ORDER_WAIT_SECONDS:-7200}))
  while :; do
    robot_call GET "/order/server/transaction/${transaction_id}"
    robot_expect "GET /order/server/transaction/${transaction_id}" 200
    status="$(jq -r '.transaction.status' <<<"$ROBOT_BODY")"
    number="$(jq -r '.transaction.server_number // empty' <<<"$ROBOT_BODY")"
    case "$status" in
      ready)
        [[ "$number" =~ ^[0-9]+$ ]] || fail "order ${transaction_id} is ready without a server number"
        echo "$number"
        return
        ;;
      cancelled) fail "order ${transaction_id} was cancelled by Hetzner; nothing is installed. Read the order in Robot before declaring the server again" ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || fail "order ${transaction_id} is still ${status}; the next apply waits for it again and never orders twice"
    say "order ${transaction_id} is ${status}; waiting"
    sleep "${ORDER_POLL_SECONDS:-60}"
  done
}

in_process_orders() {
  robot_call GET /order/server/transaction
  case "$ROBOT_STATUS" in
    200) jq -c '[.[].transaction | select(.status == "in process")]' <<<"$ROBOT_BODY" ;;
    404) echo '[]' ;;
    *) fail "GET /order/server/transaction: Robot answered HTTP ${ROBOT_STATUS} $(robot_error_code)" ;;
  esac
}

finish_order() {
  local transaction_id="$1" number
  number="$(wait_for_transaction "$transaction_id")"
  record_put number server_number "$number"
  name_server "$number"
}

command_order() {
  require_credentials
  local servers server number transaction_id orders matching key_fingerprint
  for variable in NAME PRODUCT LOCATION MAX_MONTHLY_EUR MAX_SETUP_EUR SERVER_LIMIT METAL_NAME_PREFIX RECORD_PATH; do
    [ -n "${!variable:-}" ] || fail "${variable} is not set"
  done

  servers="$(servers_json)"
  server="$(server_named "$servers" "$NAME")"
  if [ -n "$server" ]; then
    number="$(jq -r '.server_number' <<<"$server")"
    say "Robot has ${NAME} already (server ${number}); no order"
    record_put number server_number "$number"
    return
  fi

  transaction_id="$(record_get transaction_id)"
  if [ -n "$transaction_id" ]; then
    say "OpenBao records order ${transaction_id} for ${NAME}; waiting for it instead of ordering"
    finish_order "$transaction_id"
    return
  fi

  orders="$(in_process_orders)"
  matching="$(jq -c --arg p "$PRODUCT" '[.[] | select(.product.id == $p)]' <<<"$orders")"
  case "$(jq 'length' <<<"$matching")" in
    0) ;;
    1)
      transaction_id="$(jq -r '.[0].id' <<<"$matching")"
      say "order ${transaction_id} for ${PRODUCT} is in process and recorded nowhere; adopting it for ${NAME} instead of ordering"
      record_put robot-transaction transaction_id "$transaction_id"
      finish_order "$transaction_id"
      return
      ;;
    *) fail "$(jq 'length' <<<"$matching") orders for ${PRODUCT} are in process; refusing to order or guess. Record the right one in OpenBao ${RECORD_PATH} transaction_id" ;;
  esac

  local owned
  owned="$(jq --arg prefix "$METAL_NAME_PREFIX" '[.[] | select((.cancelled | not) and (.server_name | startswith($prefix)))] | length' <<<"$servers")"
  owned=$((owned + $(jq 'length' <<<"$orders")))
  [ "$owned" -lt "$SERVER_LIMIT" ] \
    || fail "${owned} metal servers exist or are in process, and ${SERVER_LIMIT} are declared; refusing to order ${NAME}"

  product_quote "$PRODUCT" "$LOCATION" "$MAX_MONTHLY_EUR" "$MAX_SETUP_EUR" >"${workdir}/quote.json"
  say "ordering ${PRODUCT} in ${LOCATION} for ${NAME}: $(jq -r '.monthly_net_eur' "${workdir}/quote.json") EUR a month net with its IPv4 address, setup $(jq -r '.setup_net_eur' "${workdir}/quote.json")"

  new_session_key "order-${NAME}"
  key_fingerprint="$session_key_fingerprint"
  keep_session_key_for_the_delivery
  local order_fields=(
    "product_id=${PRODUCT}"
    "location=${LOCATION}"
    "authorized_key[]=${key_fingerprint}"
    "addon[]=primary_ipv4"
  )

  robot_call POST /order/server/transaction "${order_fields[@]}" "test=true"
  robot_expect "test order of ${PRODUCT}" 200 201
  say "Robot accepted the test order; placing the real one"

  robot_call POST /order/server/transaction "${order_fields[@]}"
  robot_expect "order of ${PRODUCT}" 200 201
  transaction_id="$(jq -r '.transaction.id // empty' <<<"$ROBOT_BODY")"
  [ -n "$transaction_id" ] || fail "Robot accepted the order but returned no transaction id; look in Robot before anything else"
  record_put robot-transaction transaction_id "$transaction_id"
  say "ordered: transaction ${transaction_id}"
  finish_order "$transaction_id"
}

command_vswitch_id() {
  require_credentials
  local query name vlan id
  query="$(cat)"
  name="$(jq -r '.name' <<<"$query")"
  vlan="$(jq -r '.vlan' <<<"$query")"
  id="$(vswitch_lookup "$name" "$vlan")"
  [ -n "$id" ] || fail "Robot has no vSwitch ${name} on VLAN ${vlan}; the apply creates it"
  jq -nc --arg id "$id" '{id: $id}'
}

vswitch_lookup() {
  robot_call GET /vswitch
  case "$ROBOT_STATUS" in
    200) jq -r --arg n "$1" --argjson v "$2" '[.[] | select(.name == $n and .vlan == $v and (.cancelled | not)) | .id] | first // empty' <<<"$ROBOT_BODY" ;;
    404) echo "" ;;
    *) fail "GET /vswitch: Robot answered HTTP ${ROBOT_STATUS} $(robot_error_code)" ;;
  esac
}

command_vswitch_ensure() {
  require_credentials
  local id
  id="$(vswitch_lookup "$VSWITCH_NAME" "$VSWITCH_VLAN")"
  if [ -n "$id" ]; then
    say "vSwitch ${VSWITCH_NAME} (VLAN ${VSWITCH_VLAN}) exists: ${id}"
    return
  fi
  robot_call POST /vswitch "name=${VSWITCH_NAME}" "vlan=${VSWITCH_VLAN}"
  robot_expect "POST /vswitch" 200 201
  say "created vSwitch ${VSWITCH_NAME} (VLAN ${VSWITCH_VLAN}): $(jq -r '.id' <<<"$ROBOT_BODY")"
}

vswitch_server_status() {
  robot_call GET "/vswitch/${VSWITCH_ID}"
  robot_expect "GET /vswitch/${VSWITCH_ID}" 200
  jq -r --argjson n "$SERVER_NUMBER" '[.server[]? | select(.server_number == $n) | .status] | first // empty' <<<"$ROBOT_BODY"
}

command_vswitch_attach() {
  require_credentials
  local status deadline
  status="$(vswitch_server_status)"
  if [ -z "$status" ]; then
    robot_call POST "/vswitch/${VSWITCH_ID}/server" "server[]=${SERVER_NUMBER}"
    robot_expect "POST /vswitch/${VSWITCH_ID}/server" 200 201
    say "added server ${SERVER_NUMBER} to vSwitch ${VSWITCH_ID}"
  fi
  deadline=$((SECONDS + ${VSWITCH_WAIT_SECONDS:-1800}))
  while :; do
    status="$(vswitch_server_status)"
    case "$status" in
      ready) say "server ${SERVER_NUMBER} is ready on vSwitch ${VSWITCH_ID}"; return ;;
      failed) fail "Robot failed to add server ${SERVER_NUMBER} to vSwitch ${VSWITCH_ID}" ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || fail "server ${SERVER_NUMBER} is still ${status:-absent} on vSwitch ${VSWITCH_ID}"
    sleep "${VSWITCH_POLL_SECONDS:-20}"
  done
}

firewall_form() {
  jq -r '
    ["input", "output"][] as $direction
    | (.[$direction] // []) | to_entries[]
    | .key as $index
    | .value | to_entries[]
    | "rules[\($direction)][\($index)][\(.key)]=\(.value)"' <<<"$1"
}

command_firewall() {
  require_credentials
  [ -n "${FIREWALL_RULES:-}" ] || fail "FIREWALL_RULES is not set"
  local rule_count fields=() line deadline status
  rule_count="$(jq '[((.input // []) | length), ((.output // []) | length)] | max' <<<"$FIREWALL_RULES")"
  [ "$rule_count" -le 10 ] || fail "Robot allows 10 firewall rules per direction; the declared set has ${rule_count}"
  jq -e '.input | length > 0' <<<"$FIREWALL_RULES" >/dev/null || fail "an empty input rule set would block the server; refusing"
  while IFS= read -r line; do
    fields+=("$line")
  done < <(firewall_form "$FIREWALL_RULES")
  robot_call POST "/firewall/${SERVER_NUMBER}" "status=active" "filter_ipv6=true" "whitelist_hos=true" "${fields[@]}"
  robot_expect "POST /firewall/${SERVER_NUMBER}" 200 201 202
  deadline=$((SECONDS + ${FIREWALL_WAIT_SECONDS:-600}))
  while :; do
    robot_call GET "/firewall/${SERVER_NUMBER}"
    robot_expect "GET /firewall/${SERVER_NUMBER}" 200
    status="$(jq -r '.firewall.status' <<<"$ROBOT_BODY")"
    case "$status" in
      active)
        say "the Robot firewall of server ${SERVER_NUMBER} is active with $(jq '.firewall.rules.input | length' <<<"$ROBOT_BODY") input rules"
        return
        ;;
      "in process") ;;
      *) fail "the Robot firewall of server ${SERVER_NUMBER} is ${status}" ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || fail "the Robot firewall of server ${SERVER_NUMBER} is still in process"
    sleep "${FIREWALL_POLL_SECONDS:-15}"
  done
}

new_session_key() {
  local purpose="$1" fingerprint
  rm -f "${workdir}/rescue.key" "${workdir}/rescue.key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "unfold-metal-${purpose}" -f "${workdir}/rescue.key" </dev/null
  fingerprint="$(ssh-keygen -E md5 -lf "${workdir}/rescue.key.pub" | awk '{print $2}' | sed 's/^MD5://')"
  robot_call POST /key "name=unfold-metal-${purpose}-$(date -u +%Y%m%d%H%M%S)" "data=$(cat "${workdir}/rescue.key.pub")"
  robot_expect "POST /key" 200 201
  session_key_fingerprint="$fingerprint"
  say "registered a fresh SSH key ${fingerprint} in Robot for ${purpose}; it is removed when this step ends"
}

keep_session_key_for_the_delivery() {
  session_key_fingerprint=""
}

talos_state() {
  local output
  if output="$(timeout 30 talosctl --nodes "$SERVER_IP" --endpoints "$SERVER_IP" get disks --insecure 2>&1)"; then
    echo maintenance
    return
  fi
  if output="$(timeout 30 talosctl --nodes "$SERVER_IP" --endpoints "$SERVER_IP" version --insecure 2>&1)" \
    || grep -qiE 'certificate|tls|x509|authentication' <<<"$output"; then
    echo configured
    return
  fi
  echo none
}

ensure_talosctl() {
  command -v talosctl >/dev/null && return
  mkdir -p "${workdir}/bin"
  "${script_dir}/diagnose-cluster.sh" --install-tools "${workdir}/bin" >&2
  PATH="${workdir}/bin:${PATH}"
}

ssh_rescue() {
  ssh -i "${workdir}/rescue.key" -o UserKnownHostsFile="${workdir}/known_hosts" -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -o ConnectTimeout=10 "root@${SERVER_IP}" "$@"
}

pin_rescue_host_key() {
  local expected="$1" scanned line fingerprint
  scanned="$(ssh-keyscan -T 10 "$SERVER_IP" 2>/dev/null)" || return 1
  [ -n "$scanned" ] || return 1
  if [ -z "$expected" ]; then
    say "::warning::Robot returned no rescue host key for server ${SERVER_NUMBER}; trusting the first key seen"
    printf '%s\n' "$scanned" >"${workdir}/known_hosts"
    return 0
  fi
  : >"${workdir}/known_hosts"
  while IFS= read -r line; do
    printf '%s\n' "$line" >"${workdir}/scanned.key"
    for algorithm in sha256 md5; do
      fingerprint="$(ssh-keygen -E "$algorithm" -lf "${workdir}/scanned.key" | awk '{print $2}' | sed -E 's/^(SHA256|MD5)://')"
      if grep -qxF "$fingerprint" <<<"$expected"; then
        printf '%s\n' "$line" >>"${workdir}/known_hosts"
      fi
    done
  done <<<"$scanned"
  [ -s "${workdir}/known_hosts" ] || fail "the rescue system of ${SERVER_IP} presents no host key Robot announced; refusing to send it anything"
}

wait_until() {
  local what="$1" seconds="$2"
  shift 2
  local deadline=$((SECONDS + seconds))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "${what} did not happen within ${seconds} seconds"
    sleep "${INSTALL_POLL_SECONDS:-15}"
  done
}

in_maintenance_mode() {
  [ "$(talos_state)" = "maintenance" ]
}

readonly rescue_install_program='
set -euo pipefail
talos_labels="$(lsblk -rno LABEL,PARTLABEL 2>/dev/null | grep -wE "STATE|EPHEMERAL|META" || true)"
if [ -n "$talos_labels" ] && [ "$ALLOW_WIPE_OF_TALOS" != "yes" ]; then
  echo "REFUSED a disk holds Talos partitions"
  exit 3
fi
disks="$(lsblk -dnro NAME,TYPE | awk "\$2 == \"disk\" && \$1 ~ /^nvme/ {print \$1}" | sort)"
[ -n "$disks" ] || { echo "REFUSED no NVMe disk"; exit 4; }
target="$(head -n 1 <<<"$disks")"
[ "$target" = "$EXPECTED_DISK" ] || { echo "REFUSED the first NVMe disk is $target, not $EXPECTED_DISK"; exit 4; }
interface="$(ip -o route get 1.1.1.1 | sed -E "s/.* dev ([^ ]+).*/\1/")"
echo "MAC=$(cat "/sys/class/net/${interface}/address")"
command -v zstd >/dev/null || { apt-get update -qq && apt-get install -y -qq zstd >/dev/null; }
curl -fsSL --retry 3 -o /tmp/talos.raw.zst "$DISK_IMAGE_URL"
echo "$DISK_IMAGE_SHA256  /tmp/talos.raw.zst" | sha256sum -c --quiet -
mdadm --stop --scan >/dev/null 2>&1 || true
for disk in $disks; do
  wipefs -af "/dev/$disk" >/dev/null
done
zstd -dc /tmp/talos.raw.zst | dd of="/dev/$target" bs=4M conv=fsync status=none
sync
echo INSTALLED
'

command_install() {
  require_credentials
  for variable in NAME SERVER_NUMBER SERVER_IP INSTALL_GENERATION DISK_IMAGE_URL DISK_IMAGE_SHA256 RECORD_PATH; do
    [ -n "${!variable:-}" ] || fail "${variable} is not set"
  done
  [[ "$DISK_IMAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "DISK_IMAGE_SHA256 is not a sha256"
  [[ "$DISK_IMAGE_URL" == https://* ]] || fail "DISK_IMAGE_URL must be https"
  ensure_talosctl

  local state allow_wipe="no"
  state="$(talos_state)"
  case "$state" in
    maintenance)
      if [ -n "$(record_get mac)" ]; then
        say "${NAME} (${SERVER_IP}) already boots this install into Talos maintenance mode; nothing to install"
        return
      fi
      [ "$INSTALL_GENERATION" -gt 1 ] || fail "${NAME} is in Talos maintenance mode, but no install of it is recorded; raise install_generation to install it again"
      allow_wipe="yes"
      ;;
    configured)
      [ "$INSTALL_GENERATION" -gt 1 ] \
        || fail "${NAME} (${SERVER_IP}) runs a configured Talos; refusing to reinstall it. A reinstall wipes the node: raise its install_generation in a reviewed change"
      say "${NAME} runs Talos and install_generation ${INSTALL_GENERATION} asks for a reinstall; wiping it"
      allow_wipe="yes"
      ;;
    none)
      [ "$INSTALL_GENERATION" -le 1 ] || allow_wipe="yes"
      ;;
  esac

  local expected_host_keys output mac
  new_session_key "rescue-${NAME}"

  robot_call GET "/boot/${SERVER_NUMBER}/rescue"
  robot_expect "GET /boot/${SERVER_NUMBER}/rescue" 200
  if [ "$(jq -r '.rescue.active' <<<"$ROBOT_BODY")" = "true" ]; then
    robot_call DELETE "/boot/${SERVER_NUMBER}/rescue"
    robot_expect "DELETE /boot/${SERVER_NUMBER}/rescue" 200
  fi
  robot_call POST "/boot/${SERVER_NUMBER}/rescue" "os=linux" "authorized_key[]=${session_key_fingerprint}"
  robot_expect "POST /boot/${SERVER_NUMBER}/rescue" 200
  expected_host_keys="$(jq -r '[.rescue.host_key[]? | (.fingerprint // .) | tostring | sub("^(SHA256|MD5):"; "")] | .[]' <<<"$ROBOT_BODY")"
  say "rescue system armed for server ${SERVER_NUMBER}; resetting it"

  robot_call POST "/reset/${SERVER_NUMBER}" "type=hw"
  robot_expect "POST /reset/${SERVER_NUMBER}" 200
  wait_until "the rescue system of ${SERVER_IP} answering SSH" "${RESCUE_WAIT_SECONDS:-900}" pin_rescue_host_key "$expected_host_keys"

  output="$(ssh_rescue env \
    "ALLOW_WIPE_OF_TALOS=${allow_wipe}" \
    "EXPECTED_DISK=${EXPECTED_DISK:-nvme0n1}" \
    "DISK_IMAGE_URL=${DISK_IMAGE_URL}" \
    "DISK_IMAGE_SHA256=${DISK_IMAGE_SHA256}" \
    bash -s <<<"$rescue_install_program" 2>&1)" || {
    grep -E '^REFUSED' <<<"$output" >&2 || true
    fail "the install in the rescue system of ${NAME} failed; the server stays in rescue until the next reset"
  }
  grep -qx INSTALLED <<<"$output" || fail "the rescue system did not confirm the install"
  mac="$(sed -n 's/^MAC=//p' <<<"$output" | head -n 1)"
  [[ "$mac" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]] || fail "the rescue system reported no MAC address"
  record_put mac mac "$mac"
  ssh_rescue reboot >/dev/null 2>&1 || true
  say "Talos written to ${NAME}; waiting for it to boot into maintenance mode"
  wait_until "${NAME} booting Talos" "${TALOS_BOOT_WAIT_SECONDS:-1200}" in_maintenance_mode
  say "${NAME} (${SERVER_IP}) runs Talos in maintenance mode; the machine config follows"
}

command_status() {
  require_credentials
  local number="${1:-}"
  [[ "$number" =~ ^[0-9]+$ ]] || fail "status needs a server number"
  robot_call GET "/server/${number}"
  echo "server: HTTP ${ROBOT_STATUS}"
  jq '.server | {server_number, server_name, product, dc, status, cancelled, paid_until}' <<<"$ROBOT_BODY" 2>/dev/null || true
  robot_call GET "/boot/${number}/rescue"
  echo "rescue: HTTP ${ROBOT_STATUS}"
  jq '.rescue | {active, os}' <<<"$ROBOT_BODY" 2>/dev/null || true
  robot_call GET "/firewall/${number}"
  echo "firewall: HTTP ${ROBOT_STATUS}"
  jq '.firewall | {status, filter_ipv6, whitelist_hos, input: [.rules.input[]? | {name, ip_version, src_ip, dst_port, protocol, tcp_flags, action}]}' <<<"$ROBOT_BODY" 2>/dev/null || true
  robot_call GET /vswitch
  echo "vswitches: HTTP ${ROBOT_STATUS}"
  jq -c '.[]? | {id, name, vlan, cancelled}' <<<"$ROBOT_BODY" 2>/dev/null || true
}

for tool in curl jq awk sed; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

case "${1:-}" in
  quote) command_quote ;;
  server) command_server ;;
  mac) command_mac ;;
  vswitch-id) command_vswitch_id ;;
  status) shift; command_status "$@" ;;
  order) command_order ;;
  vswitch-ensure) command_vswitch_ensure ;;
  vswitch-attach) command_vswitch_attach ;;
  firewall) command_firewall ;;
  install) command_install ;;
  -h | --help) echo "$usage" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
