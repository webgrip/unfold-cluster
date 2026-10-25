#!/usr/bin/env bash
set -euo pipefail

readonly shortest_masked_prefix=16

readonly usage="usage: mask-hcloud-token-prefixes.sh

Prints a Forgejo Actions ::add-mask:: command for every Hetzner Cloud token in
the environment and for each of its prefixes of ${shortest_masked_prefix} characters or more.

Hetzner's API errors quote the start of the token they refused, today its
first 32 characters followed by '...', and the runner masks only strings it
was told about. Masking every prefix hides any such quote, whatever length
Hetzner cuts it at, while the runner replaces the longest match first, so a
whole token still shows as a single ***.

Reads HCLOUD_TOKEN, TF_VAR_hcloud_cluster_token, TF_VAR_hcloud_vip_token and
TF_VAR_hcloud_autoscaler_token;
an unset or empty one is skipped. Run it in its own step right after the
OpenBao read: a mask applies to the lines printed after it."

readonly token_variables=(HCLOUD_TOKEN TF_VAR_hcloud_cluster_token TF_VAR_hcloud_vip_token TF_VAR_hcloud_autoscaler_token)

print_masks_for() {
  local token="$1"
  local length
  for ((length = ${#token}; length >= shortest_masked_prefix; length--)); do
    printf '::add-mask::%s\n' "${token:0:length}"
  done
}

main() {
  case "${1:-}" in
    -h | --help) echo "$usage"; exit 0 ;;
    "") ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac

  local name token
  for name in "${token_variables[@]}"; do
    token="${!name:-}"
    [ -z "$token" ] || print_masks_for "$token"
  done
}

main "$@"
