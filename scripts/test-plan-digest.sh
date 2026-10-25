#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-plan-digest.sh

Plans tailnet key resources shaped like infra/tailnet.tf with tofu, once with
the key a plan-only run reads (none, or the one already stored) and once with
the key an apply run mints, and checks that scripts/plan-digest.sh gives both
plans one digest. Then checks that it still tells apart every plan that
differs in anything else: another resource's sensitive input, a key
resource's triggers, its action, or a resource only one plan has. Needs tofu."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/plan-digest.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TF_IN_AUTOMATION=1 TF_INPUT=0

cat >"${work}/main.tf" <<'HCL'
variable "key" {
  type    = string
  default = ""
}

variable "generation" {
  type    = string
  default = "1"
}

variable "other_secret" {
  type    = string
  default = "first"
}

variable "with_extra" {
  type    = bool
  default = false
}

resource "terraform_data" "control_plane_tailnet_key" {
  for_each = toset(["unfold-cp-1"])

  input            = sensitive(var.key)
  triggers_replace = [var.generation]

  lifecycle {
    ignore_changes = [input]
  }
}

resource "terraform_data" "worker_tailnet_key" {
  for_each = toset(["unfold-app-1"])

  input            = sensitive(var.key)
  triggers_replace = [var.generation]

  lifecycle {
    ignore_changes = [input]
  }
}

resource "terraform_data" "homelab_gateway_tailnet_key" {
  input            = sensitive(var.key)
  triggers_replace = [var.generation]

  lifecycle {
    ignore_changes = [input]
  }
}

resource "terraform_data" "cluster_secrets" {
  input = sensitive(var.other_secret)
}

resource "terraform_data" "z_after_the_key_blocks" {
  input = sensitive(var.other_secret)
}

resource "terraform_data" "extra" {
  count = var.with_extra ? 1 : 0
}
HCL

tofu -chdir="$work" init >/dev/null

digest_of() {
  local name="$1"
  shift
  tofu -chdir="$work" plan -out="${name}.tfplan" "$@" >/dev/null
  tofu -chdir="$work" show -no-color "${name}.tfplan" >"${work}/${name}.txt"
  "$tool" <"${work}/${name}.txt"
}

failures=0
expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

created_unread="$(digest_of created-unread)"
created_minted="$(digest_of created-minted -var key=hskey-auth-minted)"
expect "the raw plans differ in the key's input line, as runs 168 and 169 did" \
  bash -c '! cmp -s "$1/created-unread.txt" "$1/created-minted.txt"' _ "$work"
expect "a key the plan-only run cannot read and the minted key give one digest" \
  test "$created_unread" = "$created_minted"

tofu -chdir="$work" apply -auto-approve -var key=hskey-auth-first >/dev/null
replaced_reread="$(digest_of replaced-reread -var generation=2 -var key=hskey-auth-first)"
replaced_unread="$(digest_of replaced-unread -var generation=2)"
replaced_minted="$(digest_of replaced-minted -var generation=2 -var key=hskey-auth-renewed)"
expect "a replacement planned with the stored key, no key or a renewed key gives one digest" \
  test "${replaced_reread}/${replaced_unread}" = "${replaced_minted}/${replaced_minted}"

unchanged="$(digest_of unchanged -var key=hskey-auth-renewed)"
other_secret="$(digest_of other-secret -var key=hskey-auth-renewed -var other_secret=second)"
expect "a change to another resource's sensitive input changes the digest" test "$unchanged" != "$other_secret"
expect "a key generation bump changes the digest" test "$unchanged" != "$replaced_minted"
extra="$(digest_of extra -var key=hskey-auth-renewed -var with_extra=true)"
expect "a resource only one plan has changes the digest" test "$unchanged" != "$extra"
removed="$(digest_of removed -destroy)"
expect "a plan that destroys the keys differs from one that keeps them" test "$unchanged" != "$removed"

expect "the normalized text keeps every key resource's header and triggers" bash -c '
  "$1" --normalized <"$2/replaced-minted.txt" >"$2/normalized.txt"
  for name in "control_plane_tailnet_key[\"unfold-cp-1\"]" "worker_tailnet_key[\"unfold-app-1\"]" homelab_gateway_tailnet_key; do
    grep -qF "# terraform_data.${name} must be replaced" "$2/normalized.txt" || exit 1
  done
  [ "$(grep -cE "^ +~ triggers_replace = \[" "$2/normalized.txt")" -eq 3 ]
' _ "$tool" "$work"
digest_of keys-and-secrets -var generation=3 -var other_secret=third >/dev/null
expect "the normalized text keeps the input lines of the resources before and after the key blocks" bash -c '
  [ "$("$1" --normalized <"$2/keys-and-secrets.txt" | grep -cE "^ +~ input += \(sensitive value\)$")" -eq 2 ]
' _ "$tool" "$work"
expect "the digest is a SHA-256 of the normalized text" bash -c '
  [ "$("$1" <"$2/unchanged.txt")" = "$("$1" --normalized <"$2/unchanged.txt" | sha256sum | cut -d" " -f1)" ]
' _ "$tool" "$work"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
