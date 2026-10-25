#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-check-metal-image.sh

Runs scripts/check-metal-image.sh against the committed pin, a pinned release
and broken variants of it."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/check-metal-image.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

talos="$(sed -n 's/^talosVersion:[[:space:]]*//p' "${repo}/talos/talenv.yaml")"
one="$(printf '1%.0s' $(seq 64))"
two="$(printf '2%.0s' $(seq 64))"

pin() {
  printf -- '---\ninstallerImage: %s\ndiskImage: %s\n' "$1" "$2" >"${work}/pin.yaml"
  "$tool" "${work}/pin.yaml" >/dev/null 2>&1
}

installer="forgejo.webgrip.dev/webgrip-talos/installer-unfold-metal:${talos}-kata4.3.1-webgrip.1@sha256:${one}"
disk="forgejo.webgrip.dev/webgrip-talos/disk-unfold-metal:${talos}-kata4.3.1-webgrip.1@sha256:${two}"

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}
refused() { ! pin "$@"; }

expect "the committed pin passes" "$tool"
expect "a pinned release passes" pin "$installer" "$disk"
expect "an installer outside the private registry is refused" refused "${installer/webgrip-talos\/installer-unfold-metal/webgrip/installer-unfold-metal}" "$disk"
expect "a public generic package is refused" refused "$installer" "https://forgejo.webgrip.dev/api/packages/webgrip/generic/talos-metal-unfold/${talos}/metal-amd64.raw.zst"
expect "an installer without a digest is refused" refused "${installer%@*}" "$disk"
expect "two releases are refused" refused "$installer" "${disk/webgrip.1/webgrip.2}"
expect "another Talos version is refused" refused "${installer//${talos}/v1.13.10}" "${disk//${talos}/v1.13.10}"
expect "one image pinned and one placeholder is refused" refused "$installer" "${disk%@*}@sha256:$(printf '0%.0s' $(seq 64))"
expect "a third key is refused" bash -c 'printf -- "---\ninstallerImage: %s\ndiskImage: %s\ndiskImageUrl: https://example.com/x\n" "$2" "$3" > "$4/pin.yaml"; ! "$1" "$4/pin.yaml" >/dev/null 2>&1' _ "$tool" "$installer" "$disk" "$work"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
