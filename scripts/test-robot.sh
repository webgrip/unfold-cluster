#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-robot.sh

Runs scripts/robot.sh against a stubbed Hetzner Robot webservice, OpenBao,
talosctl and SSH, and checks the order path (one order at most, never twice,
never past the declared count, another product or a price ceiling, a test
order first), the read-only quote a plan shows, the vSwitch and firewall
steps, and the install guard that keeps a node running Talos from being
wiped."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/robot.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET out="" url="" fields=() config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w | --max-time | --retry | -H) shift 2 ;;
    --data-urlencode) fields+=("$2"); shift 2 ;;
    --config) config="$(cat)"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  https://registry.invalid/*)
    echo "registry ${url#https://registry.invalid}" >>"${STUB_DIR}/calls"
    case "$url" in
      */v2/token*)
        grep -qF 'user = "webgrip-ci:pull-token"' <<<"$config" || exit 22
        echo '{"token":"registry-bearer"}' ;;
      */manifests/*)
        grep -qF 'Bearer registry-bearer' <<<"$config" || exit 22
        cp "${STUB_DIR}/disk.manifest.json" "$out" ;;
      */blobs/*)
        grep -qF 'Bearer registry-bearer' <<<"$config" || exit 22
        cp "${STUB_DIR}/disk.raw.zst" "$out" ;;
      *) exit 22 ;;
    esac
    exit 0 ;;
esac
path="${url#https://robot.invalid}"
state="${STUB_DIR}/state"
field() { local f; for f in "${fields[@]}"; do [ "${f%%=*}" = "$1" ] && { printf '%s' "${f#*=}"; return; }; done; }
reply() { printf '%s' "$2" >"$out"; printf '%s' "$1"; }
echo "${method} ${path} ${fields[*]}" >>"${STUB_DIR}/calls"
case "${method} ${path}" in
  "GET /server")
    if [ "$(jq length "${state}/servers.json")" = 0 ]; then reply 404 '{"error":{"code":"SERVER_NOT_FOUND"}}'; else reply 200 "$(jq -c '[.[] | {server: .}]' "${state}/servers.json")"; fi ;;
  "GET /server/"*)
    server="$(jq -c --argjson n "${path#/server/}" '.[] | select(.server_number == $n)' "${state}/servers.json")"
    if [ -n "$server" ]; then reply 200 "{\"server\":${server}}"; else reply 404 '{"error":{"code":"SERVER_NOT_FOUND"}}'; fi ;;
  "POST /server/"*)
    number="${path#/server/}"
    jq --argjson n "$number" --arg name "$(field server_name)" 'map(if .server_number == $n then .server_name = $name else . end)' "${state}/servers.json" >"${state}/s.tmp" && mv "${state}/s.tmp" "${state}/servers.json"
    reply 200 "{\"server\":$(jq -c --argjson n "$number" '.[] | select(.server_number == $n)' "${state}/servers.json")}" ;;
  "GET /order/server/product")
    reply 200 "$(jq -c '[.[] | {product: .}]' "${state}/products.json")" ;;
  "GET /order/server/product/"*)
    product="$(jq -c --arg id "${path##*/}" '.[] | select(.id == $id)' "${state}/products.json")"
    if [ -n "$product" ]; then reply 200 "{\"product\":${product}}"; else reply 404 '{"error":{"code":"NOT_FOUND"}}'; fi ;;
  "GET /order/server/transaction")
    if [ "$(jq length "${state}/transactions.json")" = 0 ]; then reply 404 '{"error":{"code":"NOT_FOUND"}}'; else reply 200 "$(jq -c '[.[] | {transaction: .}]' "${state}/transactions.json")"; fi ;;
  "GET /order/server/transaction/"*)
    reply 200 "{\"transaction\":$(jq -c --arg id "${path##*/}" '.[] | select(.id == $id)' "${state}/transactions.json")}" ;;
  "POST /order/server/transaction")
    if [ "$(field test)" = "true" ]; then
      echo test-order >>"${STUB_DIR}/orders"
      reply 201 '{"transaction":{"id":"TEST","status":"in process","server_number":null}}'
    else
      echo real-order >>"${STUB_DIR}/orders"
      id="B20261025-$(wc -l <"${STUB_DIR}/orders")"
      jq --arg id "$id" --arg p "$(field product_id)" '. + [{id: $id, status: "ready", server_number: 2345678, product: {id: $p}}]' "${state}/transactions.json" >"${state}/t.tmp" && mv "${state}/t.tmp" "${state}/transactions.json"
      jq '. + [{server_number: 2345678, server_name: "", server_ip: "198.51.100.40", server_ipv6_net: "2a01:4f8::", product: "AX41-NVMe", status: "ready", cancelled: false}]' "${state}/servers.json" >"${state}/s.tmp" && mv "${state}/s.tmp" "${state}/servers.json"
      reply 201 "{\"transaction\":{\"id\":\"${id}\",\"status\":\"in process\",\"server_number\":null}}"
    fi ;;
  "GET /order/server_market/product")
    if [ "$(jq length "${state}/market.json")" = 0 ]; then reply 404 '{"error":{"code":"NOT_FOUND"}}'; else reply 200 "$(jq -c '[.[] | {product: .}]' "${state}/market.json")"; fi ;;
  "GET /order/server_market/product/"*)
    product="$(jq -c --argjson id "${path##*/}" '.[] | select(.id == $id)' "${state}/market.json")"
    if [ -n "$product" ]; then reply 200 "{\"product\":${product}}"; else reply 404 '{"error":{"code":"NOT_FOUND"}}'; fi ;;
  "GET /order/server_market/transaction")
    if [ "$(jq length "${state}/market-transactions.json")" = 0 ]; then reply 404 '{"error":{"code":"NOT_FOUND"}}'; else reply 200 "$(jq -c '[.[] | {transaction: .}]' "${state}/market-transactions.json")"; fi ;;
  "GET /order/server_market/transaction/"*)
    reply 200 "{\"transaction\":$(jq -c --arg id "${path##*/}" '.[] | select(.id == $id)' "${state}/market-transactions.json")}" ;;
  "POST /order/server_market/transaction")
    if [ "$(field test)" = "true" ]; then
      echo "test-market-order $(field product_id)" >>"${STUB_DIR}/orders"
      reply 201 '{"transaction":{"id":"TEST","status":"in process","server_number":null}}'
    else
      echo "real-market-order $(field product_id)" >>"${STUB_DIR}/orders"
      id="B20261026-$(wc -l <"${STUB_DIR}/orders")"
      jq --arg id "$id" --argjson p "$(field product_id)" '. + [{id: $id, status: "ready", server_number: 2345690, product: {id: $p}}]' "${state}/market-transactions.json" >"${state}/t.tmp" && mv "${state}/t.tmp" "${state}/market-transactions.json"
      jq '. + [{server_number: 2345690, server_name: "", server_ip: "198.51.100.50", server_ipv6_net: "", product: "Server Auction", dc: "FSN1-DC14", status: "ready", cancelled: false}]' "${state}/servers.json" >"${state}/s.tmp" && mv "${state}/s.tmp" "${state}/servers.json"
      reply 201 "{\"transaction\":{\"id\":\"${id}\",\"status\":\"in process\",\"server_number\":null}}"
    fi ;;
  "GET /key/"*)
    if grep -qxF "${path#/key/}" "${state}/keys" 2>/dev/null; then reply 200 '{"key":{}}'; else reply 404 '{"error":{"code":"NOT_FOUND"}}'; fi ;;
  "POST /key")
    reply 201 '{"key":{}}' ;;
  "DELETE /key/"*)
    reply 200 '' ;;
  "GET /vswitch")
    reply 200 "$(cat "${state}/vswitches.json")" ;;
  "POST /vswitch")
    jq --arg name "$(field name)" --argjson vlan "$(field vlan)" '. + [{id: 31337, name: $name, vlan: $vlan, cancelled: false}]' "${state}/vswitches.json" >"${state}/v.tmp" && mv "${state}/v.tmp" "${state}/vswitches.json"
    reply 201 '{"id":31337}' ;;
  "GET /vswitch/"*)
    reply 200 "{\"server\":$(cat "${state}/vswitch-servers.json")}" ;;
  "POST /vswitch/"*"/server")
    jq --argjson n "$(field 'server[]')" '. + [{server_number: $n, status: "ready"}]' "${state}/vswitch-servers.json" >"${state}/vs.tmp" && mv "${state}/vs.tmp" "${state}/vswitch-servers.json"
    reply 201 '' ;;
  "POST /firewall/"*)
    printf '%s\n' "${fields[@]}" >"${STUB_DIR}/firewall-form"
    reply 202 '{"firewall":{"status":"in process"}}' ;;
  "GET /firewall/"*)
    reply 200 '{"firewall":{"status":"active","rules":{"input":[{},{}]}}}' ;;
  "GET /boot/"*"/rescue")
    reply 200 '{"rescue":{"active":false}}' ;;
  "POST /boot/"*"/rescue")
    reply 200 "{\"rescue\":{\"active\":true,\"host_key\":[{\"fingerprint\":\"${RESCUE_HOST_FINGERPRINT}\"}]}}" ;;
  "POST /reset/"*)
    echo reset >>"${STUB_DIR}/resets"
    reply 200 '{"reset":{}}' ;;
  *) reply 500 '{"error":{"code":"STUB"}}' ;;
esac
STUB

cat >"${work}/bin/openbao-kv" <<'STUB'
#!/usr/bin/env bash
file="${STUB_DIR}/kv_$(printf '%s' "${2:-$3}" | tr '/' '_')"
case "$1" in
  get) if [ -s "$file" ]; then jq -j --arg p "$3" '.[$p] // empty' "$file"; fi ;;
  put)
    value="$(tr -d '\n')"
    [ -s "${STUB_DIR}/kv_$(printf '%s' "$3" | tr '/' '_')" ] || echo '{}' >"${STUB_DIR}/kv_$(printf '%s' "$3" | tr '/' '_')"
    file="${STUB_DIR}/kv_$(printf '%s' "$3" | tr '/' '_')"
    jq --arg p "$4" --arg v "$value" '.[$p] = $v' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
    echo "put $4" >>"${STUB_DIR}/calls"
    ;;
esac
STUB

cat >"${work}/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
state="$(cat "${STUB_DIR}/talos-state")"
case "$* ${state}" in
  *"get disks --insecure maintenance") echo disks; exit 0 ;;
  *"version --insecure configured") echo "rpc error: tls: certificate required" >&2; exit 1 ;;
  *) echo "connection refused" >&2; exit 1 ;;
esac
STUB

cat >"${work}/bin/ssh-keyscan" <<'STUB'
#!/usr/bin/env bash
cat "${STUB_DIR}/host.pub.line"
STUB

cat >"${work}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >>"${STUB_DIR}/calls"
case "$*" in
  *" reboot") echo maintenance >"${STUB_DIR}/talos-state"; exit 0 ;;
  *"cat > /tmp/talos.raw.zst") cat >"${STUB_DIR}/uploaded.raw.zst"; exit 0 ;;
esac
program="$(cat)"
echo "$program" >"${STUB_DIR}/rescue-program"
case "$*" in
  *ALLOW_WIPE_OF_TALOS=no*) [ "${RESCUE_DISK_HAS_TALOS:-no}" = no ] || { echo "REFUSED a disk holds Talos partitions"; exit 3; } ;;
esac
echo "MAC=a8:a1:59:0b:1c:2d"
echo INSTALLED
STUB

chmod +x "${work}/bin/"*

ssh-keygen -q -t ed25519 -N '' -C rescue-client -f "${work}/client" </dev/null
ssh-keygen -q -t ed25519 -N '' -C rescue-host -f "${work}/host" </dev/null
printf '198.51.100.40 %s\n' "$(cut -d' ' -f1,2 "${work}/host.pub")" >"${work}/host.pub.line"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}" ROBOT_ENDPOINT="https://robot.invalid" ROBOT_USER="test-user" ROBOT_PASSWORD='p"w\d'
export OPENBAO_KV="${work}/bin/openbao-kv" ORDER_POLL_SECONDS=0 VSWITCH_POLL_SECONDS=0 FIREWALL_POLL_SECONDS=0 INSTALL_POLL_SECONDS=0
RESCUE_HOST_FINGERPRINT="$(ssh-keygen -E sha256 -lf "${work}/host.pub" | awk '{print $2}' | sed 's/^SHA256://')"
export RESCUE_HOST_FINGERPRINT
head -c 4096 /dev/urandom >"${work}/disk.raw.zst"
jq -nc --arg layer "sha256:$(sha256sum "${work}/disk.raw.zst" | cut -d' ' -f1)" \
  '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", artifactType: "application/vnd.webgrip.talos.metal-disk.v1", layers: [{digest: $layer, size: 4096}]}' >"${work}/disk.manifest.json"
printf 'sha256:%s' "$(sha256sum "${work}/disk.manifest.json" | cut -d' ' -f1)" >"${work}/disk.manifest.digest"
failures=0

market_offer() {
  jq -nc --argjson id "$1" --arg cpu "$2" --argjson memory "$3" --arg dc "$4" --arg price "$5" --arg setup "${6:-0.0000}" --arg disks "${7:-2x SSD M.2 NVMe 512 GB}" '{
    id: $id, name: "Server Auction", description: [$cpu, ($memory | tostring) + " GB RAM", $disks], cpu: $cpu, cpu_benchmark: 13000,
    memory_size: $memory, hdd_size: 512, hdd_text: (if ($disks | test("NVMe")) then "NVMe" else "ENT.HDD" end), hdd_count: 2, datacenter: $dc, network_speed: "1 Gbit/s",
    price: $price, price_setup: $setup, fixed_price: false,
    orderable_addons: [{id: "primary_ipv4", name: "Primary IPv4", min: 0, max: 1, prices: [{location: ($dc | split("-")[0]), price: {net: "1.7000", gross: "2.0230"}, price_setup: {net: "0.0000", gross: "0.0000"}}]}]
  }'
}

market_offers() {
  {
    market_offer 3097578 "Intel Core i7-8700" 64 FSN1-DC14 80.0000
    market_offer 3097654 "Intel Core i7-8700" 64 HEL1-DC2 80.0000
    market_offer 3100001 "Intel Core i5-12500" 64 FSN1-DC1 99.0000
    market_offer 3100002 "Intel Xeon E3-1275V6" 64 FSN1-DC8 40.0000
    market_offer 3100003 "AMD Ryzen 7 3700X" 32 FSN1-DC8 45.0000
    market_offer 3100004 "AMD Ryzen 7 3700X" 64 NBG1-DC3 70.0000 0.0000 "2x HDD SATA 2,0 TB Enterprise"
    market_offer 3100005 "AMD Ryzen 7 3700X" 64 FSN1-DC8 60.0000 39.0000
    market_offer 3100006 "Intel Core i9-9900K" 128 SIN1-DC1 50.0000
  } | jq -s .
}

reset_state() {
  rm -rf "${work}/state" "${work}"/kv_* "${work}/calls" "${work}/orders" "${work}/resets" "${work}/firewall-form"
  mkdir -p "${work}/state"
  echo '[]' >"${work}/state/servers.json"
  echo '[]' >"${work}/state/transactions.json"
  echo '[]' >"${work}/state/vswitches.json"
  echo '[]' >"${work}/state/vswitch-servers.json"
  echo '[]' >"${work}/state/market-transactions.json"
  market_offers >"${work}/state/market.json"
  echo none >"${work}/talos-state"
  touch "${work}/calls" "${work}/orders" "${work}/resets"
  jq -n '[{
    id: "AX41-NVMe", name: "AX41-NVMe", location: ["FSN1", "NBG1", "HEL1"],
    prices: [{location: "FSN1", price: {net: "49.0000", gross: "58.3100"}, price_setup: {net: "0.0000", gross: "0.0000"}}],
    orderable_addons: [{id: "primary_ipv4", name: "Primary IPv4", min: 0, max: 1,
      prices: [{location: "FSN1", price: {net: "1.7000", gross: "2.0230"}, price_setup: {net: "0.0000", gross: "0.0000"}}]}]
  }]' >"${work}/state/products.json"
}

add_server() {
  jq --argjson n "$1" --arg name "$2" --arg product "${3:-AX41-NVMe}" --arg dc "${4:-FSN1-DC14}" '. + [{server_number: $n, server_name: $name, server_ip: "198.51.100.41", server_ipv6_net: "", product: $product, dc: $dc, status: "ready", cancelled: false}]' \
    "${work}/state/servers.json" >"${work}/state/s.tmp" && mv "${work}/state/s.tmp" "${work}/state/servers.json"
}

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

real_orders() { grep -c '^real-order$' "${work}/orders" || true; }
test_orders() { grep -c '^test-order$' "${work}/orders" || true; }
recorded() { jq -r --arg p "$1" '.[$p] // empty' "${work}/kv_unfold-cluster_metal_unfold-metal-1" 2>/dev/null || true; }

quote() {
  jq -nc --arg max "${1:-65}" --arg setup "${2:-0}" --arg product "${3:-AX41-NVMe}" --arg location "${4:-FSN1}" \
    '{name: "unfold-metal-1", product: $product, location: $location, max_monthly_eur: $max, max_setup_eur: $setup}' | "$tool" quote 2>"${work}/err"
}

order() {
  NAME=unfold-metal-1 PRODUCT="${PRODUCT:-AX41-NVMe}" LOCATION=FSN1 CPU_VENDOR=amd MAX_MONTHLY_EUR="${MAX_MONTHLY_EUR:-65}" MAX_SETUP_EUR=0 \
    SERVER_LIMIT="${SERVER_LIMIT:-1}" METAL_NAME_PREFIX=unfold-metal- RECORD_PATH=unfold-cluster/metal/unfold-metal-1 \
    "$tool" order >"${work}/out" 2>&1
}

install() {
  [ -s "${work}/kv_unfold-cluster_metal-image-pull" ] || printf '{"username":"webgrip-ci","token":"%s"}' "${PULL_TOKEN:-pull-token}" >"${work}/kv_unfold-cluster_metal-image-pull"
  NAME=unfold-metal-1 SERVER_NUMBER=2345678 SERVER_IP=198.51.100.40 INSTALL_GENERATION="${INSTALL_GENERATION:-1}" \
    DISK_IMAGE="registry.invalid/webgrip-talos/disk-unfold-metal:v1.14.4-kata4.3.1-webgrip.1@${DISK_MANIFEST_DIGEST:-$(cat "${work}/disk.manifest.digest")}" \
    PULL_CREDENTIAL=unfold-cluster/metal-image-pull RECORD_PATH=unfold-cluster/metal/unfold-metal-1 "$tool" install >"${work}/out" 2>&1
}

export tool work
export -f quote order install

reset_state
expect "a quote within the ceiling shows the price with the IPv4 address" test "$(quote | jq -r '[.state, .monthly_net_eur, .setup_net_eur] | join(" ")')" = "to-order 50.7000 0.0000"
expect "a quote above the monthly ceiling fails the plan" bash -c '! "$@"' _ quote 50
expect "the refusal names the ceiling" grep -q "above the ceiling of 50" "${work}/err"
expect "a quote above the setup ceiling fails the plan" bash -c 'jq "(.[0].prices[0].price_setup.net) = \"39.0000\"" "$1/state/products.json" > "$1/p" && mv "$1/p" "$1/state/products.json"; ! "$2" 65 0' _ "$work" quote
reset_state
expect "an unknown product fails the plan and lists the near ones" bash -c '! "$1" 65 0 AX41 && grep -q "AX41-NVMe" "$2/err"' _ quote "$work"
expect "a location the product is not sold in fails the plan" bash -c '! "$1" 65 0 AX41-NVMe FAL1' _ quote
expect "a quote orders nothing" test "$(real_orders)$(test_orders)" = "00"
add_server 2345678 unfold-metal-1
expect "a quote for an ordered server shows its number" test "$(quote | jq -r '[.state, .server_number] | join(" ")')" = "ordered 2345678"

reset_state
expect "the first order succeeds" order
expect "it placed one test order before one real order" test "$(test_orders)/$(real_orders)/$(grep -n '' "${work}/orders" | tr '\n' ' ')" = "1/1/1:test-order 2:real-order "
expect "it recorded the order and the server number in OpenBao" test "$(recorded transaction_id)/$(recorded server_number)" = "B20261025-2/2345678"
expect "it named the server in Robot" test "$(jq -r '.[0].server_name' "${work}/state/servers.json")" = "unfold-metal-1"
expect "it registered a fresh key and ordered with it" bash -c 'grep -q "^POST /key name=unfold-metal-order-unfold-metal-1-" "$1" && grep -qE "authorized_key\[\]=([0-9a-f]{2}:){15}[0-9a-f]{2}" "$1"' _ "${work}/calls"
expect "the order key stays in Robot for the delivery" bash -c '! grep -q "^DELETE /key/" "$1"' _ "${work}/calls"
expect "it ordered the primary IPv4 addon" grep -q 'addon\[\]=primary_ipv4' "${work}/calls"
expect "the robot password never reaches the command line" bash -c '! grep -qF "$1" "$2/calls"' _ "$ROBOT_PASSWORD" "$work"
expect "a second run orders nothing" bash -c '"$1" && [ "$(grep -c "^real-order$" "$2/orders")" = 1 ]' _ order "$work"

reset_state
add_server 2345600 unfold-metal-1
expect "a server Robot already has under the name is never ordered again" bash -c '"$1" && [ "$(grep -c order "$2/orders")" = 0 ] && [ "$(jq -r .server_number "$2/kv_unfold-cluster_metal_unfold-metal-1")" = 2345600 ]' _ order "$work"

reset_state
printf '{"transaction_id":"B20261025-9"}' >"${work}/kv_unfold-cluster_metal_unfold-metal-1"
jq '. + [{id: "B20261025-9", status: "ready", server_number: 2345679, product: {id: "AX41-NVMe"}}]' "${work}/state/transactions.json" >"${work}/t" && mv "${work}/t" "${work}/state/transactions.json"
add_server 2345679 ""
expect "an order recorded in OpenBao is waited for, not placed again" bash -c '"$1" && [ "$(grep -c order "$2/orders")" = 0 ]' _ order "$work"
expect "the recorded order's server gets the name" test "$(jq -r '.[0].server_name' "${work}/state/servers.json")" = "unfold-metal-1"

reset_state
jq '. + [{id: "B20261025-7", status: "in process", server_number: null, product: {id: "AX41-NVMe"}}]' "${work}/state/transactions.json" >"${work}/t" && mv "${work}/t" "${work}/state/transactions.json"
ORDER_WAIT_SECONDS=0 order || true
expect "an unrecorded order in process is adopted, not doubled" test "$(real_orders)/$(recorded transaction_id)" = "0/B20261025-7"

reset_state
jq '. + [{id: "B1", status: "in process", product: {id: "AX41-NVMe"}}, {id: "B2", status: "in process", product: {id: "AX41-NVMe"}}]' "${work}/state/transactions.json" >"${work}/t" && mv "${work}/t" "${work}/state/transactions.json"
expect "two unrecorded orders in process are refused" bash -c '! "$1" && [ "$(grep -c order "$2/orders")" = 0 ]' _ order "$work"

reset_state
add_server 1111111 unfold-metal-2
expect "an order past the declared count is refused" bash -c '! "$1" && [ "$(grep -c order "$2/orders")" = 0 ] && grep -q "1 are declared" "$2/out"' _ order "$work"
expect "the same order is placed when two servers are declared" bash -c 'SERVER_LIMIT=2 "$1" && [ "$(grep -c "^real-order$" "$2/orders")" = 1 ]' _ order "$work"

reset_state
expect "an order above the price ceiling is refused before anything is sent" bash -c 'MAX_MONTHLY_EUR=50 "$1"; [ "$?" != 0 ] && [ "$(grep -c order "$2/orders")" = 0 ]' _ order "$work"
expect "an order for a product Robot does not sell is refused" bash -c 'PRODUCT=AX42 "$1"; [ "$?" != 0 ] && [ "$(grep -c order "$2/orders")" = 0 ]' _ order "$work"

reset_state
VSWITCH_NAME=unfold-main VSWITCH_VLAN=4000 "$tool" vswitch-ensure 2>/dev/null
VSWITCH_NAME=unfold-main VSWITCH_VLAN=4000 "$tool" vswitch-ensure 2>/dev/null
expect "the vSwitch is created once" test "$(grep -c '^POST /vswitch ' "${work}/calls")" = 1
expect "its id is read back" test "$(jq -nc '{name: "unfold-main", vlan: "4000"}' | "$tool" vswitch-id | jq -r .id)" = 31337
VSWITCH_ID=31337 SERVER_NUMBER=2345678 "$tool" vswitch-attach 2>/dev/null
VSWITCH_ID=31337 SERVER_NUMBER=2345678 "$tool" vswitch-attach 2>/dev/null
expect "the server is attached once" test "$(grep -c '^POST /vswitch/31337/server' "${work}/calls")" = 1

rules='{"input":[{"name":"private","ip_version":"ipv4","src_ip":"10.64.0.0/16","action":"accept"},{"name":"apid","ip_version":"ipv4","protocol":"tcp","dst_port":"50000","src_ip":"203.0.113.7/32","action":"accept"}],"output":[{"name":"all","action":"accept"}]}'
SERVER_NUMBER=2345678 FIREWALL_RULES="$rules" "$tool" firewall 2>/dev/null
expect "the firewall is sent as Robot's form fields" grep -qx 'rules\[input\]\[1\]\[dst_port\]=50000' "${work}/firewall-form"
expect "the firewall is active and filters IPv6" bash -c 'grep -qx status=active "$1" && grep -qx filter_ipv6=true "$1"' _ "${work}/firewall-form"
expect "eleven input rules are refused" bash -c '! SERVER_NUMBER=1 FIREWALL_RULES="$(jq -nc "{input: [range(11) | {action: \"accept\"}]}")" "$1" firewall 2>/dev/null' _ "$tool"
expect "an empty input rule set is refused" bash -c '! SERVER_NUMBER=1 FIREWALL_RULES="{\"input\":[]}" "$1" firewall 2>/dev/null' _ "$tool"


reset_state
echo configured >"${work}/talos-state"
expect "a node running a configured Talos is never reinstalled" bash -c '! "$1" && [ ! -s "$2/resets" ] && ! grep -q "/rescue" "$2/calls"' _ install "$work"
expect "the refusal says how to reinstall" grep -q "raise its install_generation" "${work}/out"

reset_state
expect "a fresh server is installed" install
expect "the rescue key is removed from Robot afterwards" grep -q "^DELETE /key/" "${work}/calls"
expect "it was reset into the rescue system once" test "$(wc -l <"${work}/resets")" = 1
expect "the install recorded the MAC address" test "$(recorded mac)" = "a8:a1:59:0b:1c:2d"
expect "the rescue program checks the image before writing it" grep -q 'sha256sum -c' "${work}/rescue-program"
expect "the disk image came from the private registry with the pull token" grep -q "^registry /v2/webgrip-talos/disk-unfold-metal/blobs/sha256:" "${work}/calls"
expect "the rescue system received exactly the pinned layer" cmp -s "${work}/disk.raw.zst" "${work}/uploaded.raw.zst"
expect "the rescue checks the layer digest again" grep -q "DISK_IMAGE_SHA256=$(sha256sum "${work}/disk.raw.zst" | cut -d' ' -f1)" "${work}/calls"
expect "the rescue program refuses Talos disks unless a wipe is allowed" grep -q 'ALLOW_WIPE_OF_TALOS" != "yes"' "${work}/rescue-program"
expect "the first install does not allow wiping Talos" grep -q 'ALLOW_WIPE_OF_TALOS=no' "${work}/calls"
expect "a rerun on the installed node does nothing" bash -c '"$1" && [ "$(wc -l < "$2/resets")" = 1 ]' _ install "$work"

reset_state
RESCUE_DISK_HAS_TALOS=yes
export RESCUE_DISK_HAS_TALOS
expect "Talos found on the disks in rescue stops the first install" bash -c '! "$1" && grep -q REFUSED "$2/out" && [ -z "$(jq -r ".mac // empty" "$2/kv_unfold-cluster_metal_unfold-metal-1" 2>/dev/null)" ]' _ install "$work"
unset RESCUE_DISK_HAS_TALOS

reset_state
echo configured >"${work}/talos-state"
expect "a raised install_generation reinstalls a configured node" bash -c 'INSTALL_GENERATION=2 "$1" && grep -q "ALLOW_WIPE_OF_TALOS=yes" "$2/calls"' _ install "$work"

reset_state
printf '198.51.100.40 %s\n' "$(cut -d' ' -f1,2 "${work}/client.pub")" >"${work}/host.pub.line.real"
cp "${work}/host.pub.line" "${work}/host.pub.keep"
cp "${work}/host.pub.line.real" "${work}/host.pub.line"
expect "a rescue host key Robot did not announce gets nothing" bash -c 'RESCUE_WAIT_SECONDS=0 "$1"; [ "$?" != 0 ] && ! grep -q "bash -s" "$2/calls"' _ install "$work"
cp "${work}/host.pub.keep" "${work}/host.pub.line"

reset_state
expect "a wrong pull token stops the install before the server is touched" bash -c 'PULL_TOKEN=wrong "$1"; [ "$?" != 0 ] && [ ! -s "$2/resets" ] && ! grep -q "/rescue" "$2/calls"' _ install "$work"

reset_state
expect "a disk image whose manifest does not match its pin is refused before the reset" bash -c 'DISK_MANIFEST_DIGEST="sha256:$(printf "3%.0s" $(seq 64))" "$1"; [ "$?" != 0 ] && [ ! -s "$2/resets" ]' _ install "$work"

reset_state
cp "${work}/disk.raw.zst" "${work}/disk.keep"
head -c 4096 /dev/urandom >"${work}/disk.raw.zst"
expect "a blob that does not match the manifest's layer is refused before the reset" bash -c '! "$1" && [ ! -s "$2/resets" ]' _ install "$work"
cp "${work}/disk.keep" "${work}/disk.raw.zst"

adopt() {
  NAME=unfold-metal-1 SERVER_NUMBER="${1:-2345680}" PRODUCT=AX41 LOCATION=FSN1 CPU_VENDOR=intel RECORD_PATH=unfold-cluster/metal/unfold-metal-1 \
    "$tool" adopt >"${work}/out" 2>&1
}
export -f adopt

reset_state
add_server 2345680 "" AX41-NVMe FSN1-DC14
expect "a hand-ordered AX41 in FSN1 is adopted" adopt
expect "the adopted server is named and recorded" test "$(jq -r '.[0].server_name' "${work}/state/servers.json")/$(recorded server_number)" = "unfold-metal-1/2345680"
expect "adopting never calls the order API" bash -c '! grep -q " /order/" "$1/calls" && [ ! -s "$1/orders" ]' _ "$work"
expect "the plan reads the adopted server by its number" test "$(jq -nc '{name: "unfold-metal-1", server_number: "2345680", product: "AX41", location: "FSN1", cpu_vendor: "intel"}' | "$tool" server 2>/dev/null | jq -r .server_ip)" = "198.51.100.41"

reset_state
add_server 2345681 "" AX42-1 FSN1-DC14
expect "another product is refused" bash -c '! "$1" 2345681 && grep -q "not AX41" "$2/out" && ! grep -q "^POST /server/" "$2/calls"' _ adopt "$work"
expect "the plan refuses another product too" bash -c '! jq -nc "{name: \"unfold-metal-1\", server_number: \"2345681\", product: \"AX41\", location: \"FSN1\"}" | "$1" server >/dev/null 2>&1' _ "$tool"

reset_state
add_server 2345682 "" AX41-NVMe NBG1-DC3
expect "another location is refused" bash -c '! "$1" 2345682 && grep -q "not FSN1" "$2/out"' _ adopt "$work"

reset_state
expect "a server number not on this account is refused" bash -c '! "$1" 9999999 && grep -q "no server 9999999 on this account" "$2/out"' _ adopt "$work"

reset_state
jq '. + [{server_number: 2345683, server_name: "", server_ip: "198.51.100.42", product: "AX41-NVMe", dc: "FSN1-DC1", status: "ready", cancelled: true}]' "${work}/state/servers.json" >"${work}/s" && mv "${work}/s" "${work}/state/servers.json"
expect "a cancelled server is refused" bash -c '! "$1" 2345683' _ adopt "$work"
expect "no refused adoption reached the order API" bash -c '! grep -q " /order/" "$1/calls"' _ "$work"

criteria_json="$(jq -nc '{cpu_cores: {"Intel Core i7-8700": 6, "Intel Core i5-12500": 6, "Intel Core i9-9900K": 8, "AMD Ryzen 7 3700X": 8}, min_cores: 6, min_memory_gb: 64, disk_type: "NVMe", datacenters: ["FSN1", "NBG1", "HEL1"], max_monthly_eur: 85, max_setup_eur: 0}')"
export criteria_json
pick() {
  jq -nc --arg c "$criteria_json" '{name: "unfold-metal-1", record_path: "unfold-cluster/metal/unfold-metal-1", criteria: $c}' | "$tool" auction-pick 2>"${work}/err"
}
auction() {
  NAME=unfold-metal-1 PRODUCT="$1" CRITERIA="$criteria_json" ORDER_CATALOGUE=server_market SERVER_LIMIT="${SERVER_LIMIT:-1}" \
    METAL_NAME_PREFIX=unfold-metal- RECORD_PATH=unfold-cluster/metal/unfold-metal-1 "$tool" order >"${work}/out" 2>&1
}
export -f pick auction

reset_state
expect "the plan picks the cheapest allowed offer and shows what it is" test "$(pick | jq -r '[.state, .product_id, .cpu, .cpu_vendor, .memory_gb, .datacenter, .monthly_net_eur, .setup_net_eur] | join("|")')" = "to-order|3097578|Intel Core i7-8700|intel|64|FSN1-DC14|81.7|0"
expect "a pick reads the market and orders nothing" bash -c '[ ! -s "$1/orders" ] && ! grep -q "^POST /order" "$1/calls"' _ "$work"
jq '[.[] | select(.id != 3097578 and .id != 3097654)]' "${work}/state/market.json" >"${work}/m" && mv "${work}/m" "${work}/state/market.json"
expect "with the i7 offers gone the AMD offer with 64 GB, NVMe and no setup fee is not taken when its disks are HDD" test "$(pick | jq -r .state)" = "unavailable"
expect "an empty match is reported, not failed" grep -q "no server on the market matches" "${work}/err"

reset_state
expect "the picked offer is ordered: test order first, then that exact id" bash -c '"$1" 3097578 && [ "$(cat "$2/orders" | tr "\n" ",")" = "test-market-order 3097578,real-market-order 3097578," ]' _ auction "$work"
expect "the order records the vendor of the bought CPU" test "$(recorded cpu_vendor)/$(recorded server_number)" = "intel/2345690"
expect "the bought server is named" test "$(jq -r '.[] | select(.server_number == 2345690) | .server_name' "${work}/state/servers.json")" = "unfold-metal-1"
expect "a second apply orders nothing" bash -c '"$1" 3097654 && [ "$(grep -c "^real-market-order" "$2/orders")" = 1 ]' _ auction "$work"
expect "after the order the plan reports the server, not a new pick" test "$(pick | jq -r '[.state, .server_number] | join(" ")')" = "ordered 2345690"

reset_state
jq '[.[] | select(.id != 3097578)]' "${work}/state/market.json" >"${work}/m" && mv "${work}/m" "${work}/state/market.json"
expect "an offer sold since the plan is not ordered" bash -c '! "$1" 3097578 && grep -q "is gone" "$2/out" && [ ! -s "$2/orders" ]' _ auction "$work"
expect "an offer above the ceiling is refused" bash -c '! "$1" 3100001 && grep -q "no longer meets the criteria" "$2/out" && [ ! -s "$2/orders" ]' _ auction "$work"
expect "a CPU outside the allowlist is refused even when cheaper" bash -c '! "$1" 3100002 && [ ! -s "$2/orders" ]' _ auction "$work"
expect "too little memory is refused" bash -c '! "$1" 3100003 && [ ! -s "$2/orders" ]' _ auction "$work"
expect "a setup fee is refused" bash -c '! "$1" 3100005 && [ ! -s "$2/orders" ]' _ auction "$work"
expect "a datacenter outside eu-central is refused" bash -c '! "$1" 3100006 && [ ! -s "$2/orders" ]' _ auction "$work"

reset_state
add_server 1111111 unfold-metal-2
expect "an auction order past the declared count is refused" bash -c '! "$1" 3097578 && [ ! -s "$2/orders" ]' _ auction "$work"

reset_state
jq '. + [{id: "B9", status: "in process", server_number: null, product: {id: 3097578}}]' "${work}/state/market-transactions.json" >"${work}/t" && mv "${work}/t" "${work}/state/market-transactions.json"
ORDER_WAIT_SECONDS=0 auction 3097578 || true
expect "an unrecorded market order in process is adopted, not doubled" test "$(grep -c "market-order" "${work}/orders")/$(recorded transaction_id)" = "0/B9"

reset_state
expect "without credentials nothing is called" bash -c '! printf "{}" | env -u ROBOT_PASSWORD "$1" quote >/dev/null 2>&1 && [ ! -s "$2/calls" ]' _ "$tool" "$work"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
