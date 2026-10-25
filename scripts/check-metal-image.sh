#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: check-metal-image.sh [FILE]

Checks talos/metal-image.yaml (or FILE), the installer and disk image the
metal nodes install and upgrade with, as Renovate changes it: both come from
the private registry forgejo.webgrip.dev/webgrip-talos, carry the same tag,
which starts with the Talos version in talos/talenv.yaml, and are pinned by
digest. Renovate's placeholder, every digest zero, passes and installs
nothing. It writes nothing; CI runs it on every pull request that touches
talos/."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly file="${1:-${repo_root}/talos/metal-image.yaml}"
readonly registry="forgejo.webgrip.dev/webgrip-talos"
readonly placeholder="0000000000000000000000000000000000000000000000000000000000000000"

fail() {
  echo "error: ${file}: $*" >&2
  exit 1
}

talos_version="$(sed -n 's/^talosVersion:[[:space:]]*//p' "${repo_root}/talos/talenv.yaml")"
[[ "$talos_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "no talosVersion in talos/talenv.yaml"

[ "$(grep -cvE '^(---|installerImage: .+|diskImage: .+)$' "$file")" = 0 ] || fail "holds something besides installerImage and diskImage"

reference_of() {
  sed -n "s/^$1: //p" "$file"
}

tags=()
digests=()
for key in installerImage:installer-unfold-metal diskImage:disk-unfold-metal; do
  reference="$(reference_of "${key%%:*}")"
  [[ "$reference" =~ ^${registry//./\\.}/${key#*:}:([A-Za-z0-9._-]+)@sha256:([0-9a-f]{64})$ ]] \
    || fail "${key%%:*} must be ${registry}/${key#*:}:<tag>@sha256:<digest>, not ${reference:-empty}"
  tags+=("${BASH_REMATCH[1]}")
  digests+=("${BASH_REMATCH[2]}")
done

[ "${tags[0]}" = "${tags[1]}" ] || fail "the installer (${tags[0]}) and the disk image (${tags[1]}) are from different releases"
[[ "${tags[0]}" =~ ^${talos_version//./\\.}-kata[0-9]+\.[0-9]+\.[0-9]+-webgrip\.[0-9]+$ ]] \
  || fail "the tag ${tags[0]} is not a release for Talos ${talos_version}"
if [ "${digests[0]}" = "$placeholder" ] || [ "${digests[1]}" = "$placeholder" ]; then
  [ "${digests[0]}" = "${digests[1]}" ] || fail "only one of the two images is pinned"
  echo "talos/metal-image.yaml holds Renovate's placeholder; nothing is installed until Renovate pins a release"
  exit 0
fi
[ "${digests[0]}" != "${digests[1]}" ] || fail "the installer and the disk image cannot share a digest"
echo "talos/metal-image.yaml pins ${tags[0]}"
