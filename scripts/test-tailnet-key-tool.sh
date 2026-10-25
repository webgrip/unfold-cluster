#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-tailnet-key-tool.sh

Runs infra/templates/unfold-tailnet-key.sh, the program OpenTofu calls on
unfold-headscale over SSH, against a stubbed headscale and systemctl, and
checks the policy, config, OIDC secret, host, identity provider, install,
gateway key, worker key and node tag modes: what they change, what they refuse, that a policy or
configuration Headscale cannot start with is rolled back, that the client
secret is never printed, and that Headscale is restarted for OIDC only when
it started without it and the identity provider answers."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/infra/templates/unfold-tailnet-key.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "${work}/bin" "${work}/state"
cat >"${work}/bin/headscale" <<'STUB'
#!/usr/bin/env bash
echo "headscale $*" >>"${STUB_LOG}"
[ ! -e "${STUB_DIR}/down" ] || exit 1
case "$1 $2" in
  "users list") echo '[{"id": 1}]' ;;
  "users create") echo '{}' ;;
  "preauthkeys create") echo '{"key": "hskey-auth-stub", "id": 5}' ;;
  "policy check") ! grep -q REFUSED "$4" ;;
  "nodes tag") [ ! -e "${STUB_DIR}/refuse-tag" ] && echo '{}' ;;
  "nodes list")
    if [ -e "${STUB_DIR}/nodes.json" ]; then
      cat "${STUB_DIR}/nodes.json"
    else
      echo '[{"id": 2, "given_name": "unfold-cp-2", "online": true, "node_key": "nodekey:secret"}, {"id": 1, "given_name": "unfold-cp-1", "online": false, "pre_auth_key": {"key": "hskey-auth-leak"}}]'
    fi
    ;;
  *) exit 1 ;;
esac
STUB
cat >"${work}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"${STUB_LOG}"
if [ "$1" = "show" ]; then
  echo "invocation-1"
  exit 0
fi
if grep -q NOSTART "${POLICY_PATH}" "${CONFIG_PATH}" 2>/dev/null; then touch "${STUB_DIR}/down"; else rm -f "${STUB_DIR}/down"; fi
STUB
cat >"${work}/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "journalctl $*" >>"${STUB_LOG}"
if [ -e "${STUB_DIR}/fell-back" ]; then
  echo 'WRN failed to set up OIDC provider, falling back to CLI based authentication error="dial tcp: i/o timeout"'
fi
echo "INF listening and serving HTTP"
STUB
cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"${STUB_LOG}"
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  *openid-configuration)
    [ ! -e "${STUB_DIR}/idp-down" ] || exit 7
    echo '{"issuer": "https://idp.invalid/application/o/unfold-headscale/"}'
    ;;
  *.tgz) cp "${STUB_DIR}/package.tgz" "$output" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${work}/bin/headscale" "${work}/bin/systemctl" "${work}/bin/journalctl" "${work}/bin/curl"

cat >"${work}/settings.env" <<EOF
NODE_USER=nodes
ADMIN_USER=admin
CONTROL_PLANE_TAG=tag:cp
CONTROL_PLANE_KEY_LIFETIME_HOURS=2160
RENEW_WHEN_DAYS_LEFT=45
WORKER_KEY_LIFETIME_HOURS=24
STATE_DIR=${work}/state
HEALTH_URL=https://headscale.invalid/health
HEALTH_CONNECT_TO=headscale.invalid:443:127.0.0.1:443
POLICY_PATH=${work}/acl.hujson
SELF_PATH=${work}/unfold-tailnet-key
HEADSCALE_START_SECONDS=2
CONFIG_PATH=${work}/config.yaml
OIDC_SECRET_PATH=${work}/oidc_client_secret
HOSTS_FILE=${work}/hosts
TAILSCALE_PATH=${work}/sbin/tailscale
TAILSCALED_PATH=${work}/sbin/tailscaled
TAILSCALED_DEFAULTS=${work}/default-tailscaled
SYSTEMD_DIR=${work}/systemd
TAILSCALE_PACKAGE_URL=https://pkgs.invalid/stable
EOF
mkdir -p "${work}/sbin" "${work}/systemd"

export PATH="${work}/bin:${PATH}" STUB_DIR="$work" STUB_LOG="${work}/calls.log" \
  UNFOLD_TAILNET_SETTINGS="${work}/settings.env" POLICY_PATH="${work}/acl.hujson" CONFIG_PATH="${work}/config.yaml"

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
run_tool() {
  sh "$tool" "$@"
}
restarts() {
  grep -c '^systemctl restart' "$STUB_LOG" 2>/dev/null || true
}

echo '{"acls": ["old"]}' >"${work}/acl.hujson"
cp "$tool" "${work}/unfold-tailnet-key"

check "an unchanged policy restarts nothing" \
  bash -c '[ "$(sh "$0" policy set <"$1")" = "policy unchanged" ] && ! grep -q "^systemctl" "$2"' "$tool" "${work}/acl.hujson" "$STUB_LOG"

check "a new policy is installed and Headscale restarted" \
  bash -c 'echo "{\"acls\": [\"new\"]}" | sh "$0" policy set >/dev/null && grep -q new "$1" && [ "$(grep -c "^systemctl restart" "$2")" = 1 ]' "$tool" "${work}/acl.hujson" "$STUB_LOG"

check "a policy Headscale refuses is not installed" \
  bash -c '! (echo "{\"acls\": [\"REFUSED\"]}" | sh "$0" policy set 2>/dev/null) && grep -q new "$1" && [ ! -e "$1.candidate" ]' "$tool" "${work}/acl.hujson"

check "a policy Headscale cannot start with is rolled back" \
  bash -c '! (echo "{\"acls\": [\"NOSTART\"]}" | sh "$0" policy set 2>/dev/null) && grep -q new "$1" && [ ! -e "$2/down" ]' "$tool" "${work}/acl.hujson" "$work"

check "an empty policy is refused" \
  bash -c '! (sh "$0" policy set </dev/null 2>/dev/null) && grep -q new "$1"' "$tool" "${work}/acl.hujson"

check "policy takes only set" \
  bash -c 'sh "$0" policy get </dev/null 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "the same program is not reinstalled" \
  bash -c '[ "$(sh "$0" install <"$0")" = "program unchanged" ]' "$tool"

check "a new program is installed" \
  bash -c '{ cat "$0"; echo "true"; } | sh "$0" install >/dev/null && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "a program that does not parse is refused" \
  bash -c '! (printf "#!/bin/sh\nif then\n" | sh "$0" install 2>/dev/null) && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "a program for another interpreter is refused" \
  bash -c '! (printf "#!/bin/bash\ntrue\n" | sh "$0" install 2>/dev/null) && tail -n 1 "$1" | grep -qx true' "$tool" "${work}/unfold-tailnet-key"

check "the gateway key is minted with the gateway tag" \
  bash -c '[ "$(sh "$0" gateway 1 mint)" = "hskey-auth-stub" ] && grep -q -- "--tags tag:homelab-gateway" "$1"' "$tool" "$STUB_LOG"

check "a second mint of the same generation makes no new key" \
  bash -c 'before="$(grep -c "preauthkeys create" "$1")"; sh "$0" gateway 1 mint >/dev/null && [ "$(grep -c "preauthkeys create" "$1")" = "$before" ]' "$tool" "$STUB_LOG"

check "read returns the minted key and nothing for an unminted generation" \
  bash -c '[ "$(sh "$0" gateway 1 read)" = "hskey-auth-stub" ] && [ -z "$(sh "$0" gateway 2 read)" ]' "$tool"

check "a generation that is not a number is refused" \
  bash -c 'sh "$0" gateway "1;id" read 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "nodes list prints each node's name and whether it is online, sorted" \
  bash -c '[ "$(sh "$0" nodes list)" = "[{\"name\":\"unfold-cp-1\",\"online\":false},{\"name\":\"unfold-cp-2\",\"online\":true}]" ]' "$tool"

check "nodes list never prints a key" \
  bash -c '! sh "$0" nodes list | grep -q -e hskey -e nodekey' "$tool"

check "nodes takes only list" \
  bash -c 'sh "$0" nodes delete 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "the worker mode reads nothing for an unknown slot" \
  bash -c '[ -z "$(sh "$0" worker 42 tag:hub read)" ]' "$tool"

check "a worker key is minted with its pool's role tag" \
  bash -c '[ "$(sh "$0" worker 42 tag:hub mint)" = "hskey-auth-stub" ] && tail -n 1 "$1" | grep -q -- "preauthkeys create --user 1 --tags tag:hub --expiration 24h"' "$tool" "$STUB_LOG"

check "a second mint of the same slot and tag makes no new key" \
  bash -c 'before="$(grep -c "preauthkeys create" "$1")"; sh "$0" worker 42 tag:hub mint >/dev/null && [ "$(grep -c "preauthkeys create" "$1")" = "$before" ]' "$tool" "$STUB_LOG"

check "the same slot under another role gets its own key, never the stored one of the earlier role" \
  bash -c '[ -z "$(sh "$0" worker 42 tag:ci read)" ] && sh "$0" worker 42 tag:ci mint >/dev/null && tail -n 1 "$1" | grep -q -- "--tags tag:ci "' "$tool" "$STUB_LOG"

check "a worker key is never minted for the control planes, the gateway, Headscale or the retired tag:node" \
  bash -c 'for tag in tag:cp tag:homelab-gateway tag:headscale tag:node "tag:hub tag:cp"; do sh "$0" worker 42 "$tag" mint 2>/dev/null; [ $? -eq 2 ] || exit 1; done' "$tool"

check "the worker mode without a tag is a usage error" \
  bash -c 'sh "$0" worker 42 read 2>/dev/null; [ $? -eq 2 ]' "$tool"

cat >"${work}/config.yaml" <<'EOF'
server_url: https://headscale.invalid
oidc:
  issuer: https://idp.invalid/application/o/unfold-headscale/
EOF

check "an unchanged configuration restarts nothing" \
  bash -c 'before="$(grep -c "^systemctl restart" "$2")"; [ "$(sh "$0" config set <"$1")" = "configuration unchanged" ] && [ "$(grep -c "^systemctl restart" "$2")" = "$before" ]' "$tool" "${work}/config.yaml" "$STUB_LOG"

check "a new configuration is installed, Headscale restarted, and an empty client secret file made first" \
  bash -c 'before="$(grep -c "^systemctl restart" "$2")"; { cat "$1"; echo "  client_secret_path: $3"; } | sh "$0" config set >/dev/null && grep -q client_secret_path "$1" && [ -e "$3" ] && [ ! -s "$3" ] && [ "$(stat -c %a "$3")" = 640 ] && [ "$(grep -c "^systemctl restart" "$2")" = "$((before + 1))" ]' "$tool" "${work}/config.yaml" "$STUB_LOG" "${work}/oidc_client_secret"

check "a configuration Headscale cannot start with is rolled back" \
  bash -c '! ({ cat "$1"; echo "NOSTART: true"; } | sh "$0" config set 2>/dev/null) && ! grep -q NOSTART "$1" && grep -q client_secret_path "$1" && [ ! -e "$2/down" ]' "$tool" "${work}/config.yaml" "$work"

check "an empty configuration is refused" \
  bash -c '! (sh "$0" config set </dev/null 2>/dev/null) && grep -q client_secret_path "$1"' "$tool" "${work}/config.yaml"

check "config takes only set" \
  bash -c 'sh "$0" config get </dev/null 2>/dev/null; [ $? -eq 2 ]' "$tool"

client_secret="canary-client-secret-$$"
check "a new client secret is installed, readable by its group only, and Headscale restarted" \
  bash -c 'before="$(grep -c "^systemctl restart" "$2")"; out="$(printf "%s" "$3" | sh "$0" oidc-secret set 2>&1)" && [ "$out" = "client secret installed" ] && [ "$(cat "$1")" = "$3" ] && [ "$(stat -c %a "$1")" = 640 ] && [ "$(grep -c "^systemctl restart" "$2")" = "$((before + 1))" ]' "$tool" "${work}/oidc_client_secret" "$STUB_LOG" "$client_secret"

check "the same client secret restarts nothing" \
  bash -c 'before="$(grep -c "^systemctl restart" "$1")"; [ "$(printf "%s" "$2" | sh "$0" oidc-secret set)" = "client secret unchanged" ] && [ "$(grep -c "^systemctl restart" "$1")" = "$before" ]' "$tool" "$STUB_LOG" "$client_secret"

check "an empty client secret is refused and the installed one kept" \
  bash -c '! (sh "$0" oidc-secret set </dev/null 2>/dev/null) && [ "$(cat "$1")" = "$2" ]' "$tool" "${work}/oidc_client_secret" "$client_secret"

check "a client secret the configuration does not use yet is installed without a restart" \
  bash -c 'cp "$1" "$1.saved"; grep -v client_secret_path "$1.saved" >"$1"; before="$(grep -c "^systemctl restart" "$2")"; printf "%s-next" "$3" | sh "$0" oidc-secret set >/dev/null && [ "$(grep -c "^systemctl restart" "$2")" = "$before" ]; status=$?; cp "$1.saved" "$1"; exit "$status"' "$tool" "${work}/config.yaml" "$STUB_LOG" "$client_secret"

package_dir="${work}/package/tailscale_1.2.3_amd64"
mkdir -p "${package_dir}/systemd"
cat >"${package_dir}/tailscale" <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >>"${STUB_LOG}"
case "$1" in
  version) echo "1.2.3"; echo "  tailscale commit: stub" ;;
  status) if [ -e "${STUB_DIR}/joined" ]; then echo '{"BackendState": "Running"}'; else echo '{"BackendState": "NeedsLogin"}'; fi ;;
  up)
    for argument in "$@"; do
      case "$argument" in
        --auth-key=file:*) grep -q '^hskey-auth-' "${argument#--auth-key=file:}" || exit 1 ;;
      esac
    done
    touch "${STUB_DIR}/joined"
    ;;
esac
STUB
printf '#!/bin/sh\n' >"${package_dir}/tailscaled"
echo "[Service]" >"${package_dir}/systemd/tailscaled.service"
echo 'PORT="41641"' >"${package_dir}/systemd/tailscaled.defaults"
chmod +x "${package_dir}/tailscale" "${package_dir}/tailscaled"
tar -czf "${work}/package.tgz" -C "${work}/package" tailscale_1.2.3_amd64
package_sha="$(sha256sum "${work}/package.tgz" | cut -d' ' -f1)"
wrong_sha="$(printf '%064d' 0)"

check "a package with another sha256 is refused and nothing installed" \
  bash -c '! (sh "$0" host apply 1.2.3 "$2" 2>/dev/null) && [ ! -e "$1/sbin/tailscale" ] && [ ! -e "$1/systemd/unfold-headscale-idp.timer" ]' "$tool" "$work" "$wrong_sha"

check "host apply installs Tailscale and the identity provider timer and enables both" \
  bash -c 'sh "$0" host apply 1.2.3 "$3" >/dev/null && [ -x "$1/sbin/tailscale" ] && [ -x "$1/sbin/tailscaled" ] && [ -e "$1/default-tailscaled" ] && grep -qx "ExecStart=$1/unfold-tailnet-key idp reconcile" "$1/systemd/unfold-headscale-idp.service" && grep -qx "OnUnitActiveSec=2min" "$1/systemd/unfold-headscale-idp.timer" && grep -q "^systemctl enable --now unfold-headscale-idp.timer" "$2" && grep -q "^systemctl restart tailscaled" "$2"' "$tool" "$work" "$STUB_LOG" "$package_sha"

check "host apply of the installed version downloads nothing" \
  bash -c 'before="$(grep -c "^curl.*\.tgz" "$1")"; [ "$(sh "$0" host apply 1.2.3 "$2" | head -n 1)" = "tailscale 1.2.3 present" ] && [ "$(grep -c "^curl.*\.tgz" "$1")" = "$before" ]' "$tool" "$STUB_LOG" "$package_sha"

check "host apply refuses a version or sha256 that is not one" \
  bash -c 'sh "$0" host apply "1.2;id" "$1" 2>/dev/null; [ $? -eq 2 ] || exit 1; sh "$0" host apply 1.2.3 nothex 2>/dev/null; [ $? -eq 2 ]' "$tool" "$package_sha"

printf '127.0.0.1 localhost\n100.64.0.99 idp.invalid\n' >"${work}/hosts"
cat >"${work}/nodes.json" <<'EOF'
[
  {"id": 7, "given_name": "homelab-gateway", "online": false, "last_seen": {"seconds": 100}, "tags": ["tag:homelab-gateway"], "ip_addresses": ["100.64.0.7", "fd7a:115c:a1e0::7"]},
  {"id": 9, "given_name": "homelab-gateway-1", "online": true, "last_seen": {"seconds": 50}, "tags": ["tag:homelab-gateway"], "ip_addresses": ["fd7a:115c:a1e0::9", "100.64.0.9"]},
  {"id": 3, "given_name": "unfold-cp-1", "online": true, "last_seen": {"seconds": 900}, "tags": ["tag:cp"], "ip_addresses": ["100.64.0.3"]}
]
EOF

check "idp reconcile joins its own tailnet with a single-use tag:headscale key it does not keep" \
  bash -c 'sh "$0" idp reconcile >/dev/null; [ -e "$1/joined" ] && grep -q -- "preauthkeys create --user 1 --tags tag:headscale --expiration 1h -o json" "$2" && grep -q -- "up --reset --login-server=https://headscale.invalid --auth-key=file:" "$2" && [ ! -e "$1/state/self.authkey" ]' "$tool" "$work" "$STUB_LOG"

check "idp reconcile never passes a key on the command line" \
  bash -c '! grep -q "hskey-auth" "$0"' "$STUB_LOG"

check "idp reconcile points the identity provider at the online gateway's IPv4 and keeps every other line" \
  bash -c '[ "$(grep -c "idp.invalid" "$0")" = 1 ] && grep -qx "100.64.0.9 idp.invalid" "$0" && grep -qx "127.0.0.1 localhost" "$0"' "${work}/hosts"

check "a second idp reconcile mints no key and leaves the hosts file alone" \
  bash -c 'before="$(grep -c "preauthkeys create" "$1")"; cp "$2" "$2.before"; sh "$0" idp reconcile >/dev/null && [ "$(grep -c "preauthkeys create" "$1")" = "$before" ] && cmp -s "$2" "$2.before"' "$tool" "$STUB_LOG" "${work}/hosts"

check "Headscale running with OIDC is not restarted" \
  bash -c 'before="$(grep -c "^systemctl restart headscale" "$1")"; sh "$0" idp reconcile | grep -qx "headscale runs with OIDC" && [ "$(grep -c "^systemctl restart headscale" "$1")" = "$before" ]' "$tool" "$STUB_LOG"

touch "${work}/fell-back" "${work}/idp-down"
check "Headscale without OIDC is left running while the identity provider is down" \
  bash -c 'before="$(grep -c "^systemctl restart headscale" "$1")"; sh "$0" idp reconcile | grep -q "tailnet nodes are unaffected" && [ "$(grep -c "^systemctl restart headscale" "$1")" = "$before" ]' "$tool" "$STUB_LOG"

rm -f "${work}/idp-down"
check "Headscale without OIDC is restarted once the identity provider answers" \
  bash -c 'before="$(grep -c "^systemctl restart headscale" "$1")"; sh "$0" idp reconcile | grep -q "^restarted headscale" && [ "$(grep -c "^systemctl restart headscale" "$1")" = "$((before + 1))" ]' "$tool" "$STUB_LOG"

check "a second restart for OIDC waits for the heal interval" \
  bash -c 'before="$(grep -c "^systemctl restart headscale" "$1")"; sh "$0" idp reconcile | grep -q "waiting$" && [ "$(grep -c "^systemctl restart headscale" "$1")" = "$before" ]' "$tool" "$STUB_LOG"
rm -f "${work}/fell-back"

echo '[]' >"${work}/nodes.json"
check "idp reconcile fails without a gateway on the tailnet and keeps the last address" \
  bash -c '! (sh "$0" idp reconcile >/dev/null 2>&1) && grep -qx "100.64.0.9 idp.invalid" "$1"' "$tool" "${work}/hosts"

check "idp takes only reconcile" \
  bash -c 'sh "$0" idp route 2>/dev/null; [ $? -eq 2 ]' "$tool"

check "no mode printed or kept the client secret outside its file" \
  bash -c '! grep -rqF "$0" "$1" "$2"' "$client_secret" "$STUB_LOG" "${work}/state"

echo "restarts: $(restarts)"
cat >"${work}/nodes.json" <<'EOF'
[
  {"id": 11, "name": "unfold-app-1", "given_name": "unfold-app-1", "tags": ["tag:node"]},
  {"id": 12, "name": "unfold-app-1", "given_name": "unfold-app-1-stale", "tags": ["tag:node"]},
  {"id": 3, "name": "unfold-cp-1", "given_name": "unfold-cp-1", "tags": ["tag:cp"]}
]
EOF
: >"$STUB_LOG"
check "nodes tag gives every node of that name the role tag, the stale entry included" \
  bash -c '[ "$(sh "$0" nodes tag unfold-app-1 tag:hub)" = "unfold-app-1 now has tag:hub" ] && grep -qx "headscale nodes tag --identifier 11 --tags tag:hub -o json" "$1" && grep -qx "headscale nodes tag --identifier 12 --tags tag:hub -o json" "$1" && ! grep -q -- "--identifier 3 " "$1"' "$tool" "$STUB_LOG"

: >"$STUB_LOG"
check "nodes tag leaves a node that already has its role tag alone" \
  bash -c '[ "$(sh "$0" nodes tag unfold-cp-1 tag:cp)" = "unfold-cp-1 already has tag:cp" ] && ! grep -q "nodes tag" "$1"' "$tool" "$STUB_LOG"

check "nodes tag leaves a node not on the tailnet yet to the key it joins with" \
  bash -c '[ "$(sh "$0" nodes tag unfold-ci-1 tag:ci)" = "unfold-ci-1 is not on the tailnet yet; it joins with a tag:ci key" ] && ! grep -q "nodes tag" "$1"' "$tool" "$STUB_LOG"

check "nodes tag replaces a node carrying its role tag and another" \
  bash -c 'echo "[{\"id\": 3, \"name\": \"unfold-cp-1\", \"tags\": [\"tag:cp\", \"tag:hub\"]}]" >"$2/nodes.json"; sh "$0" nodes tag unfold-cp-1 tag:cp >/dev/null && grep -qx "headscale nodes tag --identifier 3 --tags tag:cp -o json" "$1"' "$tool" "$STUB_LOG" "$work"

touch "${work}/refuse-tag"
check "nodes tag fails when Headscale refuses the tag" \
  bash -c '! (sh "$0" nodes tag unfold-cp-1 tag:cp >/dev/null 2>&1)' "$tool"
rm -f "${work}/refuse-tag"

check "nodes tag never hands out the gateway, Headscale or retired tag, nor takes a name that is not one" \
  bash -c 'for tag in tag:homelab-gateway tag:headscale tag:node; do sh "$0" nodes tag unfold-app-1 "$tag" 2>/dev/null; [ $? -eq 2 ] || exit 1; done; sh "$0" nodes tag "app;id" tag:hub 2>/dev/null; [ $? -eq 2 ]' "$tool"

if [ "$failures" -gt 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
