#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-openbao-kv.sh

Runs scripts/openbao-kv.sh against a stubbed curl that plays Forgejo's OIDC
endpoint and OpenBao's KV engine, and checks what it writes, what it keeps,
what it refuses and that it never prints a value. The Talos secrets bundle it
escrows is rendered by infra/modules/talos-secrets-bundle and piped from
tofu output -raw exactly as the infra workflow does, so it needs tofu."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/openbao-kv.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin" "${work}/kv"

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" data="" url="" write_out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w) write_out=1; shift 2 ;;
    -H | --request) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >>"${STUB_DIR}/calls"
reply() { printf '%s' "$2" >"${out:-/dev/null}"; [ -z "$write_out" ] || printf '%s' "$1"; }
case "$url" in
  *audience=openbao-ci) reply 200 '{"value":"oidc-jwt"}' ;;
  */v1/auth/forgejo/login) reply 200 '{"auth":{"client_token":"bao-token"}}' ;;
  */v1/auth/token/revoke-self) reply 204 '' ;;
  */v1/secret/data/*)
    file="${STUB_DIR}/kv/$(printf '%s' "${url##*/v1/secret/data/}" | tr '/' '_')"
    if [ -z "$data" ]; then
      if [ -s "$file" ]; then reply 200 "{\"data\":{\"data\":$(cat "$file")}}"; else reply 404 '{"errors":[]}'; fi
    else
      [ "${data:0:1}" = "@" ] && data="$(cat "${data:1}")"
      printf '%s' "$data" | jq -c '.data' >"$file"
      echo "write $url" >>"${STUB_DIR}/calls"
      reply 200 '{"data":{"version":7}}'
    fi
    ;;
  *) reply 500 '' ;;
esac
STUB
chmod +x "${work}/bin/curl"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}"
export ACTIONS_ID_TOKEN_REQUEST_URL="https://forgejo.invalid/token" ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
failures=0

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

writes() { grep -c '^write ' "${work}/calls" || true; }
stored() { jq -r --arg p "$2" '.[$p] // empty' "${work}/kv/$1"; }

printf '198.51.100.23\n' | "$tool" put ipv4 unfold/headscale-address ipv4 >"${work}/out" 2>&1
expect "a new address is written" test "$(stored unfold_headscale-address ipv4)" = "198.51.100.23"
expect "the write is reported without the value" bash -c '! grep -q 198.51.100.23 "$1"' _ "${work}/out"

printf '203.0.113.9\n' | "$tool" put ipv4 unfold/headscale-address drill_ipv4 >/dev/null 2>&1
expect "a second property keeps the first" test "$(stored unfold_headscale-address ipv4)/$(stored unfold_headscale-address drill_ipv4)" = "198.51.100.23/203.0.113.9"

before="$(writes)"
printf '198.51.100.23\n' | "$tool" put ipv4 unfold/headscale-address ipv4 >"${work}/out" 2>&1
expect "an unchanged value is not written again" test "$(writes)" = "$before"

printf '\n' | "$tool" put ipv4 unfold/headscale-address drill_ipv4 >/dev/null 2>&1
expect "an empty line clears an address" test -z "$(stored unfold_headscale-address drill_ipv4)"

for refused in 10.64.0.11 100.64.0.1 not-an-address; do
  expect "${refused} is refused as an address" bash -c '! printf "%s\n" "$1" | "$2" put ipv4 unfold/headscale-address ipv4 >/dev/null 2>&1' _ "$refused" "$tool"
done

printf 'hskey-auth-abc123\n' | "$tool" put authkey unfold/tailnet-homelab-gateway authkey >"${work}/out" 2>&1
expect "a pre-auth key is written and masked" bash -c 'grep -q "^::add-mask::hskey-auth-abc123$" "$1" && [ "$(jq -r .authkey "$2")" = hskey-auth-abc123 ]' _ "${work}/out" "${work}/kv/unfold_tailnet-homelab-gateway"
expect "anything but a pre-auth key is refused" bash -c '! printf "tskey-auth-x\n" | "$1" put authkey unfold/tailnet-homelab-gateway authkey >/dev/null 2>&1' _ "$tool"

bundle=$'cluster:\n  id: abc\ncerts:\n  k8sserviceaccount:\n    key: LS0t\n'
printf '%s' "$bundle" | "$tool" put talos-secrets unfold-cluster/talos-secrets bundle >/dev/null 2>&1
expect "a secrets bundle is stored whole" test "$(stored unfold-cluster_talos-secrets bundle)" = "${bundle%$'\n'}"
expect "a file that is not a secrets bundle is refused" bash -c '! printf "cluster:\n  id: x\n" | "$1" put talos-secrets unfold-cluster/talos-secrets bundle >/dev/null 2>&1' _ "$tool"

mkdir -p "${work}/bundle-module"
cat >"${work}/bundle-module/main.tf" <<EOF
locals {
  pair = { cert = "canary-crt", key = "canary-key" }
}

module "talos_secrets_bundle" {
  source = "${repo}/infra/modules/talos-secrets-bundle"
  machine_secrets = {
    cluster    = { id = "canary-cluster-id", secret = "canary-cluster-secret" }
    secrets    = { bootstrap_token = "canary-bootstrap", secretbox_encryption_secret = "canary-secretbox" }
    trustdinfo = { token = "canary-trustd" }
    certs = {
      etcd               = local.pair
      k8s                = local.pair
      k8s_aggregator     = local.pair
      k8s_serviceaccount = { key = "canary-serviceaccount" }
      os                 = local.pair
    }
  }
}

output "talos_secrets_bundle" {
  value     = module.talos_secrets_bundle.yaml
  sensitive = true
}
EOF
tofu -chdir="${work}/bundle-module" init -input=false >/dev/null
tofu -chdir="${work}/bundle-module" apply -auto-approve -input=false >/dev/null
rendered="$(tofu -chdir="${work}/bundle-module" output -raw talos_secrets_bundle)"
tofu -chdir="${work}/bundle-module" output -raw talos_secrets_bundle \
  | "$tool" put talos-secrets unfold-cluster/rendered-talos-secrets bundle >"${work}/out" 2>&1 || true
expect "the bundle tofu renders is accepted from tofu output -raw" grep -q '^wrote bundle to unfold-cluster/rendered-talos-secrets' "${work}/out"
expect "the rendered bundle is stored whole" test "$(stored unfold-cluster_rendered-talos-secrets bundle)" = "$rendered"
expect "the rendered bundle is never printed" bash -c '! grep -q canary "$1"' _ "${work}/out"
expect "an empty sensitive output is refused" bash -c '! printf "" | "$1" put talos-secrets unfold-cluster/talos-secrets bundle >/dev/null 2>&1' _ "$tool"

kms_key="$(head -c 32 /dev/urandom | base64 -w0)"
printf '%s\n' "$kms_key" | "$tool" put disk-kms-key unfold-cluster/disk-kms master_key >"${work}/kms-out" 2>&1
expect "a disk KMS master key is stored" test "$(stored unfold-cluster_disk-kms master_key)" = "$kms_key"
expect "a disk KMS master key is masked before anything else is printed" grep -qF "::add-mask::${kms_key}" "${work}/kms-out"
expect "a 16-byte key is refused" bash -c '! head -c 16 /dev/urandom | base64 -w0 | "$1" put disk-kms-key unfold-cluster/disk-kms master_key >/dev/null 2>&1' _ "$tool"
expect "a key that is not base64 is refused" bash -c '! printf "%044d\n" 0 | tr 0 - | "$1" put disk-kms-key unfold-cluster/disk-kms master_key >/dev/null 2>&1' _ "$tool"

known_hosts_line="headscale.webgrip.dev,198.51.100.23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDy5LGeG3jjYA5HxMiHteWkI9s1BdJPy8vVlMZBpZTnb"
printf '%s\n' "$known_hosts_line" | "$tool" put known-hosts unfold/headscale-address ssh_known_hosts >/dev/null 2>&1
expect "a known_hosts line is stored beside the address" test "$(stored unfold_headscale-address ssh_known_hosts)/$(stored unfold_headscale-address ipv4)" = "${known_hosts_line}/198.51.100.23"
for refused in "headscale.webgrip.dev ssh-ed25519 AAAA" "headscale.webgrip.dev,198.51.100.23 ssh-rsa AAAAB3NzaC1yc2E" "headscale.webgrip.dev,198.51.100.23 ssh-ed25519 AAAA extra" ""; do
  expect "'${refused}' is refused as a known_hosts line" bash -c '! printf "%s\n" "$1" | "$2" put known-hosts unfold/headscale-address ssh_known_hosts >/dev/null 2>&1' _ "$refused" "$tool"
done

expect "get prints the stored property" test "$("$tool" get unfold-cluster/talos-secrets bundle 2>/dev/null)" = "${bundle%$'\n'}"
expect "get prints nothing for an absent secret" test -z "$("$tool" get unfold-cluster/nothing-here bundle 2>/dev/null)"
expect "get keeps the workflow masks off stdout" bash -c '! "$1" get unfold-cluster/talos-secrets bundle 2>/dev/null | grep -q add-mask' _ "$tool"

expect "a path outside the KV naming is refused" bash -c '! printf "198.51.100.23\n" | "$1" put ipv4 "../sys/policy" ipv4 >/dev/null 2>&1' _ "$tool"
expect "without OIDC nothing is sent" bash -c '! printf "198.51.100.23\n" | env -u ACTIONS_ID_TOKEN_REQUEST_URL "$1" put ipv4 unfold/headscale-address ipv4 >/dev/null 2>&1' _ "$tool"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
