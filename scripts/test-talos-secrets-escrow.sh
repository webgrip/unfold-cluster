#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-talos-secrets-escrow.sh

Proves that the Talos secrets the infra apply escrows to OpenBao bring the same
cluster identity back. Generates a fresh talos_machine_secrets, renders it with
infra/modules/talos-secrets-bundle, imports that file into an empty state the
way an apply into an empty state does, and fails unless every secret, the
service-account key and every certificate authority come back unchanged.
Needs tofu and jq, and the provider registry the first time."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${work}/plugins}"
mkdir -p "$TF_PLUGIN_CACHE_DIR" "${work}/escrow" "${work}/restore"

provider_block='terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }
}'

cat >"${work}/escrow/main.tf" <<EOF
${provider_block}

resource "talos_machine_secrets" "generated" {
  talos_version = "v1.14"
}

module "bundle" {
  source          = "${repo}/infra/modules/talos-secrets-bundle"
  machine_secrets = talos_machine_secrets.generated.machine_secrets
}

output "bundle" {
  value     = module.bundle.yaml
  sensitive = true
}

output "machine_secrets" {
  value     = talos_machine_secrets.generated.machine_secrets
  sensitive = true
}
EOF

cat >"${work}/restore/main.tf" <<EOF
${provider_block}

import {
  to = talos_machine_secrets.restored
  id = "${work}/bundle.yaml"
}

resource "talos_machine_secrets" "restored" {
  talos_version = "v1.14"

  lifecycle {
    ignore_changes = [talos_version]
  }
}

output "machine_secrets" {
  value     = talos_machine_secrets.restored.machine_secrets
  sensitive = true
}
EOF

tofu -chdir="${work}/escrow" init >/dev/null
tofu -chdir="${work}/escrow" apply -auto-approve >/dev/null
umask 077
tofu -chdir="${work}/escrow" output -raw bundle >"${work}/bundle.yaml"
tofu -chdir="${work}/escrow" output -json machine_secrets | jq -S . >"${work}/escrowed.json"

tofu -chdir="${work}/restore" init >/dev/null
tofu -chdir="${work}/restore" apply -auto-approve >"${work}/restore.log"
grep -q '1 imported, 0 added, 0 changed, 0 destroyed' "${work}/restore.log" \
  || { echo "FAIL: the restore did not import the escrowed bundle as the existing secrets" >&2; exit 1; }
tofu -chdir="${work}/restore" output -json machine_secrets | jq -S . >"${work}/restored.json"

if ! cmp -s "${work}/escrowed.json" "${work}/restored.json"; then
  echo "FAIL: the restored secrets differ from the escrowed ones in:" >&2
  jq -rn --slurpfile a "${work}/escrowed.json" --slurpfile b "${work}/restored.json" '
    $a[0] | paths(scalars) as $p | select(($a[0] | getpath($p)) != ($b[0] | getpath($p))) | $p | map(tostring) | join(".")' >&2
  exit 1
fi
echo "ok: the escrowed bundle restores the same secrets, keys and certificate authorities"
