#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-pin-metal-image.sh

Runs scripts/pin-metal-image.sh against a scratch file and checks that it
writes the three pins a release prints and refuses what OpenTofu would refuse."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/pin-metal-image.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export METAL_IMAGE_FILE="${work}/metal-image.yaml"
failures=0

talos="$(sed -n 's/^talosVersion:[[:space:]]*//p' "${repo}/talos/talenv.yaml")"
digest="$(printf '1%.0s' $(seq 64))"
sha="$(printf '2%.0s' $(seq 64))"
installer="forgejo.webgrip.dev/webgrip/talos-installer-unfold-metal:${talos}-kata4.3.1-webgrip.1@sha256:${digest}"
url="https://forgejo.webgrip.dev/api/packages/webgrip/generic/talos-metal-unfold/${talos}-kata4.3.1-webgrip.1/metal-amd64.raw.zst"

expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

refuses() {
  : >"$METAL_IMAGE_FILE"
  ! "$tool" "$@" >/dev/null 2>&1 && [ ! -s "$METAL_IMAGE_FILE" ]
}

"$tool" "$installer" "$url" "$sha" 2>/dev/null
expect "the three pins are written" test "$(sed -n 's/^installerImage: //p;s/^diskImageUrl: //p;s/^diskImageSha256: //p' "$METAL_IMAGE_FILE" | tr '\n' ' ')" = "${installer} ${url} ${sha} "
expect "an installer without a digest is refused" refuses "${installer%@*}" "$url" "$sha"
expect "an installer for another Talos version is refused" refuses "${installer/${talos}/v1.13.10}" "$url" "$sha"
expect "a disk image over http is refused" refuses "$installer" "${url/https/http}" "$sha"
expect "a disk image from another host is refused" refuses "$installer" "${url/forgejo.webgrip.dev/example.com}" "$sha"
expect "a disk image for another Talos version is refused" refuses "$installer" "${url/${talos}/v1.13.10}" "$sha"
expect "a checksum that is not a sha256 is refused" refuses "$installer" "$url" "${sha:0:63}"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
