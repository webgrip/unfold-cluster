#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: write-cluster-secrets.sh

Server-side applies each Secret in CLUSTER_SECRETS to the running cluster,
under the field manager opentofu, taking over the fields the Talos seed
wrote. OpenTofu runs it from terraform_data.cluster_secrets whenever a value
read from OpenBao changes, so a rotated token reaches the cluster without a
new cluster or talosctl upgrade-k8s.

The API is reached on each control plane's public address, port 6443, which
the firewall opens to ADMIN_CIDRS, and the certificate is checked against
KUBE_API_SERVER_NAME, the private API address it is issued for. Retries every
endpoint until WAIT_SECONDS pass, because on the first apply the API server
and the seeded namespaces come up after OpenTofu bootstraps etcd.

Environment:
  CLUSTER_SECRETS          JSON list of v1 Secret objects with base64 data
  KUBE_API_ENDPOINTS       space-separated control plane addresses
  KUBE_API_SERVER_NAME     the name the API certificate is checked against
  KUBE_CA_CERTIFICATE      base64 PEM of the cluster CA
  KUBE_CLIENT_CERTIFICATE  base64 PEM of the admin client certificate
  KUBE_CLIENT_KEY          base64 PEM of the admin client key
  WAIT_SECONDS             how long to keep retrying, default 1800
  DRY_RUN                  server asks the API to validate and not store

Never prints a request or response body: both carry the Secret values."

readonly api_port=6443
readonly field_manager=opentofu
readonly retry_interval_seconds=10

fail() {
  echo "write-cluster-secrets: $*" >&2
  exit 1
}

require_environment() {
  local name
  for name in CLUSTER_SECRETS KUBE_API_ENDPOINTS KUBE_API_SERVER_NAME KUBE_CA_CERTIFICATE KUBE_CLIENT_CERTIFICATE KUBE_CLIENT_KEY; do
    [ -n "${!name:-}" ] || fail "${name} is not set"$'\n'"${usage}"
  done
}

require_tools() {
  local tool
  for tool in curl jq base64 mktemp; do
    command -v "$tool" >/dev/null || fail "${tool} is not installed"
  done
}

write_credentials() {
  umask 077
  printf '%s' "$KUBE_CA_CERTIFICATE" | base64 -d >"${work_dir}/ca.crt"
  printf '%s' "$KUBE_CLIENT_CERTIFICATE" | base64 -d >"${work_dir}/client.crt"
  printf '%s' "$KUBE_CLIENT_KEY" | base64 -d >"${work_dir}/client.key"
}

apply_secret_through() {
  local endpoint="$1" namespace="$2" name="$3" body_file="$4"
  curl --silent --show-error \
    --max-time 30 \
    --output "${work_dir}/response.json" \
    --write-out '%{http_code}' \
    --connect-to "${KUBE_API_SERVER_NAME}:${api_port}:${endpoint}:${api_port}" \
    --cacert "${work_dir}/ca.crt" \
    --cert "${work_dir}/client.crt" \
    --key "${work_dir}/client.key" \
    --request PATCH \
    --header 'Content-Type: application/apply-patch+yaml' \
    --data-binary "@${body_file}" \
    "https://${KUBE_API_SERVER_NAME}:${api_port}/api/v1/namespaces/${namespace}/secrets/${name}?fieldManager=${field_manager}&force=true${dry_run_parameter}" \
    2>/dev/null || true
}

status_reason() {
  jq -r 'select(.kind == "Status") | "\(.reason // "") \(.message // "")"' "${work_dir}/response.json" 2>/dev/null || true
}

apply_secret_until_deadline() {
  local index="$1" namespace name body_file status endpoint
  namespace="$(jq -er --argjson i "$index" '.[$i].metadata.namespace' <<<"$CLUSTER_SECRETS")"
  name="$(jq -er --argjson i "$index" '.[$i].metadata.name' <<<"$CLUSTER_SECRETS")"
  body_file="${work_dir}/secret-${index}.json"
  jq -c --argjson i "$index" '.[$i]' <<<"$CLUSTER_SECRETS" >"$body_file"

  while :; do
    for endpoint in $KUBE_API_ENDPOINTS; do
      status="$(apply_secret_through "$endpoint" "$namespace" "$name" "$body_file")"
      case "$status" in
        200 | 201)
          echo "write-cluster-secrets: applied ${namespace}/${name} through ${endpoint}" >&2
          return 0
          ;;
        400 | 422)
          fail "the API refused ${namespace}/${name} as malformed (HTTP ${status}): $(status_reason)"
          ;;
        *)
          echo "write-cluster-secrets: ${namespace}/${name} through ${endpoint}: HTTP ${status:-000} $(status_reason)" >&2
          ;;
      esac
    done
    [ "$SECONDS" -lt "$deadline" ] || fail "gave up on ${namespace}/${name} after ${WAIT_SECONDS:-1800} seconds"
    sleep "$retry_interval_seconds"
  done
}

main() {
  if [ "$#" -gt 0 ]; then
    echo "$usage"
    exit 64
  fi
  require_environment
  require_tools
  jq -e 'type == "array" and all(.[]; .kind == "Secret" and (.metadata.name | length > 0) and (.metadata.namespace | length > 0))' \
    <<<"$CLUSTER_SECRETS" >/dev/null || fail "CLUSTER_SECRETS is not a list of named, namespaced Secrets"

  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  write_credentials

  case "${DRY_RUN:-}" in
    "") dry_run_parameter="" ;;
    server) dry_run_parameter="&dryRun=All" ;;
    *) fail "DRY_RUN must be empty or server" ;;
  esac

  deadline=$((SECONDS + ${WAIT_SECONDS:-1800}))
  local count index
  count="$(jq 'length' <<<"$CLUSTER_SECRETS")"
  for ((index = 0; index < count; index++)); do
    apply_secret_until_deadline "$index"
  done
}

main "$@"
