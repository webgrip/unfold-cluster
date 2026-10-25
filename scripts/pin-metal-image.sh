#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: pin-metal-image.sh INSTALLER_IMAGE DISK_IMAGE_URL DISK_IMAGE_SHA256

Writes talos/metal-image.yaml, the image the metal nodes install and upgrade
with, from the three values a talos-kata-extension release prints. It refuses
an installer that is not pinned by digest or whose tag does not start with the
Talos version in talos/talenv.yaml, a disk image that is not fetched over
https from forgejo.webgrip.dev, and a checksum that is not a sha256. The
talos-kata-extension release job runs it in a fresh unfold-cluster checkout
and opens the pull request; a person can run it the same way."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
esac
[ "$#" -eq 3 ] || { echo "$usage" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly target="${METAL_IMAGE_FILE:-${repo_root}/talos/metal-image.yaml}"
installer_image="$1"
disk_image_url="$2"
disk_image_sha256="$3"

fail() {
  echo "error: $*" >&2
  exit 1
}

talos_version="$(sed -n 's/^talosVersion:[[:space:]]*//p' "${repo_root}/talos/talenv.yaml")"
[[ "$talos_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "no talosVersion in talos/talenv.yaml"

[[ "$installer_image" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+:([A-Za-z0-9._-]+)@sha256:[0-9a-f]{64}$ ]] \
  || fail "the installer must be pinned by tag and digest: ${installer_image}"
installer_tag="${BASH_REMATCH[2]}"
[[ "$installer_tag" == "${talos_version}-"* ]] \
  || fail "the installer tag ${installer_tag} is not for Talos ${talos_version}; release talos-kata-extension for it first"
[[ "$disk_image_url" =~ ^https://forgejo\.webgrip\.dev/api/packages/webgrip/generic/[a-z0-9-]+/${talos_version//./\\.}-[A-Za-z0-9._-]+/metal-amd64\.raw\.zst$ ]] \
  || fail "the disk image must be a Talos ${talos_version} metal-amd64.raw.zst package on forgejo.webgrip.dev: ${disk_image_url}"
[[ "$disk_image_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "not a sha256: ${disk_image_sha256}"

cat >"$target" <<YAML
---
installerImage: ${installer_image}
diskImageUrl: ${disk_image_url}
diskImageSha256: ${disk_image_sha256}
YAML
echo "pinned the metal image to ${installer_tag}" >&2
