#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: build-talos-snapshot.sh [--dry-run | --cleanup]

Builds the Hetzner Cloud snapshot the cluster nodes boot from, out of
talos/schematics/cloud.yaml and the Talos version in talos/talenv.yaml,
and prints its id on stdout. A snapshot with the same Talos version and
schematic is reused instead of built again.

  --dry-run   resolve the schematic and image URL, check both, touch nothing at Hetzner
  --cleanup   remove servers and keys a failed build left behind in the project

Needs HCLOUD_TOKEN (read and write) in the environment, except with --dry-run.
SNAPSHOT_LOCATION (default fsn1) and SNAPSHOT_SERVER_TYPE (default cx23) pick
the temporary server; keep its disk no larger than the smallest node's."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly schematic_file="${repo_root}/talos/schematics/cloud.yaml"
readonly talenv_file="${repo_root}/talos/talenv.yaml"
readonly variables_file="${repo_root}/infra/variables.tf"
readonly image_factory="https://factory.talos.dev"
readonly hcloud_api="https://api.hetzner.cloud/v1"
readonly location="${SNAPSHOT_LOCATION:-fsn1}"
readonly temporary_server_type="${SNAPSHOT_SERVER_TYPE:-cx23}"

# renovate: datasource=github-releases depName=apricote/hcloud-upload-image extractVersion=^v(?<version>.+)$
readonly upload_tool_version="1.5.0"
readonly upload_tool_sha256_linux_x86_64="1b8b74e919a8192b23bdbd61fa145bbe49bd76f8595ec52d46f9f9b37a048596"
readonly upload_tool_sha256_linux_arm64="cf6736a34b7c28d4f84982be7a07c9422caad3a419606cd38f18f47405ae598b"
readonly upload_tool_sha256_darwin_arm64="fca6aeed3a25ca3a8f2e386e29b60fbc931fa13e62d6b962722a97fd8ac5d9a7"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

say() {
  echo "$*" >&2
}

require_tools() {
  local tool
  for tool in curl jq tar sed; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
  done
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail "sha256sum or shasum is needed"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

pinned_talos_version() {
  local version
  version="$(sed -n 's/^talosVersion:[[:space:]]*//p' "$talenv_file")"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "no talosVersion in $talenv_file"
  echo "$version"
}

schematic_id_from_image_factory() {
  local id
  id="$(curl -fsS --retry 3 -X POST --data-binary "@${schematic_file}" "${image_factory}/schematics" | jq -r '.id // empty')"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || fail "Image Factory returned no schematic id for $schematic_file"
  echo "$id"
}

schematic_id_in_infra() {
  sed -n '/variable "talos_cloud_schematic"/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$variables_file"
}

hcloud_get() {
  local path="$1"
  shift
  curl -fsS --retry 3 --config - -G "$@" "${hcloud_api}${path}" <<CURLCONFIG
header = "Authorization: Bearer ${HCLOUD_TOKEN}"
CURLCONFIG
}

existing_snapshot_id() {
  hcloud_get /images \
    --data-urlencode "type=snapshot" \
    --data-urlencode "architecture=x86" \
    --data-urlencode "label_selector=${label_selector}" \
    --data-urlencode "sort=created:desc" \
    | jq -r '.images[0].id // empty'
}

upload_tool="${workdir}/hcloud-upload-image"

install_upload_tool() {
  local platform expected archive
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) platform="Linux_x86_64" expected="$upload_tool_sha256_linux_x86_64" ;;
    Linux/aarch64 | Linux/arm64) platform="Linux_arm64" expected="$upload_tool_sha256_linux_arm64" ;;
    Darwin/arm64) platform="Darwin_arm64" expected="$upload_tool_sha256_darwin_arm64" ;;
    *) fail "no pinned hcloud-upload-image build for $(uname -s)/$(uname -m)" ;;
  esac
  archive="${workdir}/hcloud-upload-image.tar.gz"
  curl -fsSL --retry 3 -o "$archive" \
    "https://github.com/apricote/hcloud-upload-image/releases/download/v${upload_tool_version}/hcloud-upload-image_${platform}.tar.gz"
  [ "$(sha256_of "$archive")" = "$expected" ] || fail "hcloud-upload-image ${upload_tool_version} does not match its pinned checksum"
  tar -xzf "$archive" -C "$workdir" hcloud-upload-image
}

require_token() {
  [ -n "${HCLOUD_TOKEN:-}" ] || fail "HCLOUD_TOKEN is not set; export the read and write token first"
}

mode="${1:-build}"
case "$mode" in
  build | --dry-run | --cleanup) ;;
  -h | --help) echo "$usage"; exit 0 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

require_tools

if [ "$mode" = "--cleanup" ]; then
  require_token
  install_upload_tool
  "$upload_tool" cleanup
  exit 0
fi

talos_version="$(pinned_talos_version)"
schematic_id="$(schematic_id_from_image_factory)"
infra_schematic_id="$(schematic_id_in_infra)"
[ "$schematic_id" = "$infra_schematic_id" ] \
  || fail "talos/schematics/cloud.yaml is schematic ${schematic_id}, but infra/variables.tf installs ${infra_schematic_id:-nothing}; update talos_cloud_schematic first"

image_url="${image_factory}/image/${schematic_id}/${talos_version}/hcloud-amd64.raw.xz"
curl -fsSI --retry 3 "$image_url" >/dev/null || fail "Image Factory does not serve $image_url"

readonly labels="os=talos,talos-version=${talos_version},talos-schematic=${schematic_id:0:32},cluster=unfold-main"
readonly label_selector="os==talos,talos-version==${talos_version},talos-schematic==${schematic_id:0:32},cluster==unfold-main"

say "Talos ${talos_version}, schematic ${schematic_id}"
say "image ${image_url}"
say "labels ${labels}"
say "temporary server ${temporary_server_type} in ${location}"

if [ "$mode" = "--dry-run" ]; then
  say "dry run: nothing was created at Hetzner"
  exit 0
fi

require_token

snapshot_id="$(existing_snapshot_id)"
if [ -n "$snapshot_id" ]; then
  say "a snapshot with these labels exists already; reusing it"
  echo "$snapshot_id"
  exit 0
fi

install_upload_tool
say "building the snapshot; this takes a few minutes and bills the temporary server by the hour"
"$upload_tool" upload \
  --image-url "$image_url" \
  --compression xz \
  --server-type "$temporary_server_type" \
  --location "$location" \
  --labels "$labels" \
  --description "Talos ${talos_version} unfold-cluster cloud ${schematic_id:0:12}" \
  || fail "the upload failed; run this script with --cleanup to remove what it left behind"

snapshot_id="$(existing_snapshot_id)"
[ -n "$snapshot_id" ] || fail "the upload finished, but no snapshot carries the labels ${labels}"
echo "$snapshot_id"
