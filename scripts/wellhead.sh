#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: wellhead.sh <wellhead arguments>

Runs the wellhead CLI at the version pinned below, downloaded on first use,
checksum-verified, into a cache directory; nothing is installed. mise run
wellhead -- <arguments> calls this. Runbook: docs/runbooks/external-secrets.md.
Needs curl, tar and sha256sum or shasum."

# renovate: datasource=github-releases depName=wellhead-dev/wellhead
readonly wellhead_version="v0.1.0"
readonly wellhead_sha256_linux_amd64="43f8a9f20d9e3cb1411125ca7b6ac627a478e34f5d11f5bda2a3eb36543b1a08"
readonly wellhead_sha256_linux_arm64="d42cc8b2903534a3b9de794dc7a7ded1be97b6fe0153de885e962d2a85598467"
readonly wellhead_sha256_darwin_amd64="2cc48ab86d91cb78c7e3681f32065c1179e2a883fd9aa19a939e059bf7d4551b"
readonly wellhead_sha256_darwin_arm64="d1ee0b2faeb4a21107faa71549bd5b595c6a58eeb31977d33789c02b8a69c00f"

case "${1:-}" in
  "" | -h | --help) echo "${usage}"; [ -n "${1:-}" ] && exit 0; exit 2 ;;
esac

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux_amd64 sha256="${wellhead_sha256_linux_amd64}" ;;
  Linux-aarch64 | Linux-arm64) platform=linux_arm64 sha256="${wellhead_sha256_linux_arm64}" ;;
  Darwin-x86_64) platform=darwin_amd64 sha256="${wellhead_sha256_darwin_amd64}" ;;
  Darwin-arm64) platform=darwin_arm64 sha256="${wellhead_sha256_darwin_arm64}" ;;
  *) echo "no wellhead binary is pinned for $(uname -s)-$(uname -m)" >&2; exit 2 ;;
esac

sha256_check() {
  if command -v sha256sum > /dev/null; then
    sha256sum -c --status -
  else
    shasum -a 256 -c --status -
  fi
}

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-wellhead/${wellhead_version}-${platform}"
readonly cache_dir
readonly archive="${cache_dir}/wellhead.tar.gz"
readonly binary="${cache_dir}/wellhead"

if ! { [ -x "${binary}" ] && [ -f "${archive}" ] && echo "${sha256}  ${archive}" | sha256_check; }; then
  mkdir -p "${cache_dir}"
  curl -fsSL --retry 3 -o "${archive}.partial" \
    "https://github.com/wellhead-dev/wellhead/releases/download/${wellhead_version}/wellhead_${wellhead_version#v}_${platform}.tar.gz"
  echo "${sha256}  ${archive}.partial" | sha256_check || { echo "wellhead ${wellhead_version} ${platform}: checksum mismatch" >&2; rm -f "${archive}.partial"; exit 2; }
  mv "${archive}.partial" "${archive}"
  tar -xzf "${archive}" -C "${cache_dir}" wellhead
fi

exec "${binary}" "$@"
