#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: tofu output -raw homelab_gateway_tailnet_key | hand-gateway-key-to-openbao.sh

Writes the homelab gateway's tailnet pre-auth key from stdin to OpenBao at
secret/unfold/tailnet-homelab-gateway, property authkey, where the homelab's
External Secrets reads it. Logs in with this job's Forgejo OIDC token as role
ci-unfold-cluster. Writes only when the stored key differs, so reruns leave
the version history alone.

Environment: ACTIONS_ID_TOKEN_REQUEST_URL and ACTIONS_ID_TOKEN_REQUEST_TOKEN
(set by Forgejo with enable-openid-connect), OPENBAO_ADDR (default the
in-cluster address), OPENBAO_ROLE (default ci-unfold-cluster)."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

fail() {
  echo "::error::hand-gateway-key-to-openbao: $*"
  exit 1
}

readonly secret_path="secret/data/unfold/tailnet-homelab-gateway"
openbao_addr="${OPENBAO_ADDR:-http://openbao.security.svc.cluster.local:8200}"
openbao_role="${OPENBAO_ROLE:-ci-unfold-cluster}"

key="$(tr -d '\r\n ')"
[[ "$key" == hskey-auth-* ]] || fail "stdin holds no pre-auth key"
echo "::add-mask::${key}"

[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || fail "no OIDC token endpoint: the job needs enable-openid-connect: true"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077

case "${ACTIONS_ID_TOKEN_REQUEST_URL}" in *\?*) sep='&' ;; *) sep='?' ;; esac
code="$(curl -sS -o "${workdir}/oidc.json" -w '%{http_code}' \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}${sep}audience=openbao-ci" || true)"
[ "$code" = "200" ] || fail "OIDC token request HTTP ${code}"
oidc="$(jq -r '.value // empty' "${workdir}/oidc.json")"
[ -n "$oidc" ] || fail "the OIDC endpoint returned no token"
echo "::add-mask::${oidc}"

code="$(curl -sS -o "${workdir}/login.json" -w '%{http_code}' --request POST \
  --data "$(jq -nc --arg jwt "$oidc" --arg role "$openbao_role" '{jwt: $jwt, role: $role}')" \
  "${openbao_addr}/v1/auth/forgejo/login" || true)"
[ "$code" = "200" ] || fail "OpenBao login as ${openbao_role} HTTP ${code}"
token="$(jq -r '.auth.client_token // empty' "${workdir}/login.json")"
[ -n "$token" ] || fail "OpenBao login returned no token"
echo "::add-mask::${token}"
revoke() {
  curl -sS -o /dev/null --request POST -H "X-Vault-Token: ${token}" "${openbao_addr}/v1/auth/token/revoke-self" || true
}
trap 'revoke; rm -rf "$workdir"' EXIT

code="$(curl -sS -o "${workdir}/read.json" -w '%{http_code}' -H "X-Vault-Token: ${token}" "${openbao_addr}/v1/${secret_path}" || true)"
case "$code" in
  200) stored="$(jq -r '.data.data.authkey // empty' "${workdir}/read.json")" ;;
  404) stored="" ;;
  *) fail "OpenBao read ${secret_path} HTTP ${code}" ;;
esac

if [ "$stored" = "$key" ]; then
  echo "the gateway key in OpenBao is current"
  exit 0
fi

code="$(curl -sS -o "${workdir}/write.json" -w '%{http_code}' --request POST \
  -H "X-Vault-Token: ${token}" \
  --data "$(jq -nc --arg key "$key" '{data: {authkey: $key}}')" \
  "${openbao_addr}/v1/${secret_path}" || true)"
[ "$code" = "200" ] || fail "OpenBao write ${secret_path} HTTP ${code}"
echo "wrote the gateway key to ${secret_path#secret/data/} (version $(jq -r '.data.version' "${workdir}/write.json"))"
