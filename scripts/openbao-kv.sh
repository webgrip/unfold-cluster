#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: openbao-kv.sh put KIND PATH PROPERTY < value
       openbao-kv.sh get PATH PROPERTY

Reads or writes one property of a secret in the homelab OpenBao's KV engine
(secret/PATH), logged in with this job's Forgejo OIDC token as role
ci-unfold-cluster. What that role may read and write is
kubernetes/apps/security/openbao/bootstrap/ci-unfold-cluster.hcl in
homelab-cluster.

put   writes stdin to PROPERTY and keeps the secret's other properties. It
      writes only when the stored value differs, so reruns leave the version
      history alone. KIND names what stdin must hold, and the value is refused
      otherwise:
        authkey        a Headscale pre-auth key (hskey-auth-...), masked in the log
        ipv4           a public IPv4 address, or an empty line to clear it
        talos-secrets  a talosctl secrets bundle
get   prints PROPERTY, or nothing when the secret or the property is absent.

Neither prints a value. Environment: ACTIONS_ID_TOKEN_REQUEST_URL and
ACTIONS_ID_TOKEN_REQUEST_TOKEN (set by Forgejo with enable-openid-connect),
OPENBAO_ADDR (default the in-cluster address), OPENBAO_ROLE (default
ci-unfold-cluster)."

fail() {
  echo "::error::openbao-kv: $*" >&2
  exit 1
}

usage_error() {
  echo "$usage" >&2
  exit 2
}

is_public_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  local c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  ((a == 169 && b == 254)) && return 1
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  return 0
}

has_yaml_key() {
  local indent="$1" key="$2" document="$3"
  grep -qE "^${indent}(${key}|\"${key}\"):" <<<"$document"
}

checked_value() {
  local kind="$1" value
  case "$kind" in
    authkey)
      value="$(tr -d '\r\n ')"
      [[ "$value" == hskey-auth-* ]] || fail "stdin holds no pre-auth key"
      echo "::add-mask::${value}" >&3
      ;;
    ipv4)
      value="$(tr -d '\r\n ')"
      [ -z "$value" ] || is_public_ipv4 "$value" || fail "stdin holds no public IPv4 address"
      ;;
    talos-secrets)
      value="$(cat)"
      if ! has_yaml_key '' cluster "$value" || ! has_yaml_key '' certs "$value" || ! has_yaml_key ' +' k8sserviceaccount "$value"; then
        fail "stdin holds no talosctl secrets bundle"
      fi
      ;;
    *) usage_error ;;
  esac
  printf '%s' "$value"
}

mode="${1:-}"
case "$mode" in
  -h | --help) echo "$usage"; exit 0 ;;
  put) [ "$#" -eq 4 ] || usage_error; kind="$2"; kv_path="$3"; property="$4" ;;
  get) [ "$#" -eq 3 ] || usage_error; kv_path="$2"; property="$3" ;;
  *) usage_error ;;
esac
[[ "$kv_path" =~ ^[a-z0-9-]+(/[a-z0-9-]+)+$ ]] || fail "not a KV path: ${kv_path}"
[[ "$property" =~ ^[A-Za-z0-9_]+$ ]] || fail "not a property name: ${property}"

if [ "$mode" = "get" ]; then
  exec 3>&2
else
  exec 3>&1
fi

if [ "$mode" = "put" ]; then
  value="$(checked_value "$kind")"
fi

for tool in curl jq mktemp; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || fail "no OIDC token endpoint: the job needs enable-openid-connect: true"

readonly secret_url_path="secret/data/${kv_path}"
openbao_addr="${OPENBAO_ADDR:-http://openbao.security.svc.cluster.local:8200}"
openbao_role="${OPENBAO_ROLE:-ci-unfold-cluster}"

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
echo "::add-mask::${oidc}" >&3

code="$(curl -sS -o "${workdir}/login.json" -w '%{http_code}' --request POST \
  --data "$(jq -nc --arg jwt "$oidc" --arg role "$openbao_role" '{jwt: $jwt, role: $role}')" \
  "${openbao_addr}/v1/auth/forgejo/login" || true)"
[ "$code" = "200" ] || fail "OpenBao login as ${openbao_role} HTTP ${code}"
token="$(jq -r '.auth.client_token // empty' "${workdir}/login.json")"
[ -n "$token" ] || fail "OpenBao login returned no token"
echo "::add-mask::${token}" >&3
revoke() {
  curl -sS -o /dev/null --request POST -H "X-Vault-Token: ${token}" "${openbao_addr}/v1/auth/token/revoke-self" || true
}
trap 'revoke; rm -rf "$workdir"' EXIT

code="$(curl -sS -o "${workdir}/read.json" -w '%{http_code}' -H "X-Vault-Token: ${token}" "${openbao_addr}/v1/${secret_url_path}" || true)"
case "$code" in
  200) stored_data="$(jq -c '.data.data // {}' "${workdir}/read.json")" ;;
  404) stored_data="{}" ;;
  *) fail "OpenBao read ${kv_path} HTTP ${code}" ;;
esac

if [ "$mode" = "get" ]; then
  jq -j --arg p "$property" '.[$p] // empty' <<<"$stored_data"
  exit 0
fi

if [ "$(jq -r --arg p "$property" '.[$p] // empty' <<<"$stored_data")" = "$value" ]; then
  echo "${kv_path} ${property} in OpenBao is current"
  exit 0
fi

jq -n --argjson stored "$stored_data" --arg p "$property" --arg v "$value" '{data: ($stored + {($p): $v})}' >"${workdir}/write.json"
code="$(curl -sS -o "${workdir}/written.json" -w '%{http_code}' --request POST \
  -H "X-Vault-Token: ${token}" --data @"${workdir}/write.json" \
  "${openbao_addr}/v1/${secret_url_path}" || true)"
[ "$code" = "200" ] || fail "OpenBao write ${kv_path} HTTP ${code}"
echo "wrote ${property} to ${kv_path} (version $(jq -r '.data.version' "${workdir}/written.json"))"
