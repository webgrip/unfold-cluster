#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-headscale-config.sh

Renders infra/templates/headscale-config.yaml.tftpl and headscale-acl.hujson
with tofu, downloads the Headscale package pinned in infra/headscale.tf
(refusing any other sha256), and runs that very binary against them:

  configtest accepts the configuration, and refuses it with oidc.expiry, the
    key Headscale 0.29 removed in favour of node.expiry;
  policy check accepts the policy, and refuses it when tag:headscale has no
    owner;
  with the identity provider down, Headscale still starts, answers /health and
    logs that it fell back, so the tailnet keeps working when Authentik does
    not answer, which is what the server's idp reconcile heals later;
  the same configuration with only_start_if_oidc_is_available: true never
    answers, which proves the check above can fail.

Listening addresses, TLS and file paths are moved to a scratch directory and
loopback ports; the OIDC block, node expiry and policy are tested as rendered.
Needs tofu, curl, jq, sha256sum, gzip and tar; it reads the .deb itself."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "test-headscale-config: $*" >&2
  exit 1
}

pinned() {
  sed -n "s/^ *${1} *= *\"\\([^\"]*\\)\"$/\\1/p" "${repo}/infra/headscale.tf" | head -n 1
}

version="$(pinned headscale_version)"
sha256="$(pinned headscale_sha256)"
[ -n "$version" ] && [ -n "$sha256" ] || fail "no pinned Headscale version and sha256 in infra/headscale.tf"

package="${work}/headscale.deb"
curl -fsSL --retry 3 -o "$package" \
  "https://github.com/juanfont/headscale/releases/download/v${version}/headscale_${version}_linux_amd64.deb"
echo "${sha256}  ${package}" | sha256sum -c - >/dev/null || fail "the downloaded package does not have the pinned sha256"
ar_member() {
  local archive="$1" wanted="$2" offset=8 header name size
  [ "$(head -c 8 "$archive")" = '!<arch>' ] || fail "the package is not an ar archive"
  while [ "$offset" -lt "$(stat -c %s "$archive")" ]; do
    header="$( (tail -c +$((offset + 1)) "$archive" || true) | head -c 60)"
    name="$(printf '%s' "${header:0:16}" | sed 's/ *$//; s|/$||')"
    size="$(printf '%s' "${header:48:10}" | tr -d ' ')"
    if [ "$name" = "$wanted" ]; then
      (tail -c +$((offset + 61)) "$archive" || true) | head -c "$size"
      return
    fi
    offset=$((offset + 60 + size + size % 2))
  done
  fail "the package has no ${wanted}"
}
mkdir -p "${work}/package"
ar_member "$package" data.tar.gz | tar -xz -C "${work}/package"
headscale="${work}/package/usr/bin/headscale"
[ -x "$headscale" ] || fail "the package holds no usr/bin/headscale"

render() {
  mkdir -p "${work}/render"
  printf '%s\n' "$1" | (cd "${work}/render" && tofu console) | jq -r . | jq -r .
}

templates="${repo}/infra/templates"
render "jsonencode(templatefile(\"${templates}/headscale-acl.hujson\", { admin_user = \"ryan\", node_route = \"10.64.0.0/24\" }))" >"${work}/acl.hujson"
render "jsonencode(templatefile(\"${templates}/headscale-config.yaml.tftpl\", {
  hostname                = \"headscale.invalid\"
  ipv4                    = \"198.51.100.23\"
  acme_email              = \"\"
  user_node_expiry        = \"720h\"
  oidc_issuer             = \"https://127.0.0.1:9/application/o/unfold-headscale/\"
  oidc_client_id          = \"unfold-headscale\"
  oidc_client_secret_path = \"${work}/oidc_client_secret\"
  oidc_allowed_groups     = [\"unfold-admins\"]
}))" >"${work}/rendered.yaml"
grep -q '^oidc:' "${work}/rendered.yaml" || fail "the rendered configuration has no oidc block"
: >"${work}/oidc_client_secret"

port=$((20000 + RANDOM % 20000))
sed -e "s|^listen_addr: .*|listen_addr: 127.0.0.1:${port}|" \
  -e "s|^metrics_listen_addr: .*|metrics_listen_addr: 127.0.0.1:$((port + 1))|" \
  -e "s|^grpc_listen_addr: .*|grpc_listen_addr: 127.0.0.1:$((port + 2))|" \
  -e "s|stun_listen_addr: .*|stun_listen_addr: 127.0.0.1:$((port + 3))|" \
  -e "s|^tls_letsencrypt_hostname: .*|tls_letsencrypt_hostname: \"\"|" \
  -e "s|/var/lib/headscale|${work}/lib|g" \
  -e "s|/var/run/headscale|${work}/run|g" \
  -e "s|/etc/headscale/acl.hujson|${work}/acl.hujson|" \
  "${work}/rendered.yaml" >"${work}/config.yaml"
mkdir -p "${work}/lib/cache" "${work}/run"

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}"
    failures=$((failures + 1))
  fi
}

answers_health_within() {
  local config="$1" seconds="$2" log="$3"
  "$headscale" -c "$config" serve >"$log" 2>&1 &
  server_pid=$!
  local deadline=$((SECONDS + seconds)) healthy=1
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      healthy=0
      break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 1
  done
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  return "$healthy"
}

check "Headscale ${version} accepts the rendered configuration" \
  "$headscale" -c "${work}/config.yaml" configtest

check "Headscale ${version} refuses oidc.expiry, so node.expiry carries the 30 days" \
  bash -c 'sed "s|^  client_id: |  expiry: 720h\n  client_id: |" "$1" >"$1.expiry" && ! "$0" -c "$1.expiry" configtest >/dev/null 2>&1' "$headscale" "${work}/config.yaml"

check "Headscale ${version} accepts the rendered policy" \
  "$headscale" -c "${work}/config.yaml" --force policy check --bypass-grpc-and-access-database-directly -f "${work}/acl.hujson"

check "Headscale ${version} refuses the policy when tag:headscale has no owner, so the check above can fail" \
  bash -c 'grep -v "\"tag:headscale\": \[\"group:admin\"\]" "$1" >"$1.unowned" && ! "$0" -c "$2" --force policy check --bypass-grpc-and-access-database-directly -f "$1.unowned" >/dev/null 2>&1' "$headscale" "${work}/acl.hujson" "${work}/config.yaml"

if answers_health_within "${work}/config.yaml" 60 "${work}/serve.log" \
  && grep -qF 'falling back to CLI based authentication' "${work}/serve.log"; then
  echo "ok   with the identity provider down Headscale starts, answers /health and says it fell back"
else
  echo "FAIL with the identity provider down Headscale starts, answers /health and says it fell back"
  tail -n 20 "${work}/serve.log" >&2
  failures=$((failures + 1))
fi

sed 's|only_start_if_oidc_is_available: false|only_start_if_oidc_is_available: true|' "${work}/config.yaml" >"${work}/config-waits.yaml"
if answers_health_within "${work}/config-waits.yaml" 45 "${work}/serve-waits.log"; then
  echo "FAIL the same configuration waiting for its identity provider never answers"
  failures=$((failures + 1))
else
  echo "ok   the same configuration waiting for its identity provider never answers"
fi

if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
