#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: check-wellhead.sh [--mutation-test]

Runs wellhead lint over kubernetes/: every ExternalSecret must say where its
value comes from (wellhead.dev/origin), and one a person provides must say how
to get it and how to check it (wellhead spec v1alpha1, rules WH001 to WH015).
Runbook: docs/runbooks/external-secrets.md.

  --mutation-test  also removes wellhead.dev/origin from each file that
                   carries it, one file at a time, and requires lint to fail.
                   A file lint still passes was never checked.

Downloads the wellhead CLI at the pinned version below, checksum-verified,
into a cache directory. Needs curl, sha256sum and tar."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root

# renovate: datasource=github-releases depName=wellhead-dev/wellhead
readonly wellhead_version="v0.1.0"
readonly wellhead_sha256_linux_amd64="43f8a9f20d9e3cb1411125ca7b6ac627a478e34f5d11f5bda2a3eb36543b1a08"

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only the linux-amd64 binary is pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-wellhead"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wellhead-check.XXXXXX")"
readonly work_dir
trap 'rm -rf "${work_dir}"' EXIT

install_wellhead() {
  local archive="${cache_dir}/wellhead_${wellhead_version#v}_linux_amd64.tar.gz"
  if ! { [ -f "${archive}" ] && echo "${wellhead_sha256_linux_amd64}  ${archive}" | sha256sum -c --status -; }; then
    mkdir -p "${cache_dir}"
    curl -fsSL --retry 3 -o "${archive}.partial" \
      "https://github.com/wellhead-dev/wellhead/releases/download/${wellhead_version}/wellhead_${wellhead_version#v}_linux_amd64.tar.gz"
    echo "${wellhead_sha256_linux_amd64}  ${archive}.partial" | sha256sum -c --quiet -
    mv "${archive}.partial" "${archive}"
  fi
  tar -xzf "${archive}" -C "${work_dir}" wellhead
}

install_wellhead
readonly wellhead="${work_dir}/wellhead"

"${wellhead}" lint "${repo_root}/kubernetes"

if [ "${mutation_test}" = true ]; then
  mapfile -t annotated < <(grep -rl --include='*.yaml' 'wellhead.dev/origin' "${repo_root}/kubernetes" | sort)
  [ "${#annotated[@]}" -gt 0 ] || { echo "no file carries wellhead.dev/origin" >&2; exit 1; }
  for file in "${annotated[@]}"; do
    rm -rf "${work_dir}/kubernetes"
    cp -r "${repo_root}/kubernetes" "${work_dir}/kubernetes"
    sed -i '/wellhead\.dev\/origin:/d' "${work_dir}/kubernetes/${file#"${repo_root}/kubernetes/"}"
    if "${wellhead}" lint "${work_dir}/kubernetes" > /dev/null; then
      echo "FAIL  mutation: lint passed ${file#"${repo_root}/"} without wellhead.dev/origin" >&2
      exit 1
    fi
    echo "ok    mutation: lint refuses ${file#"${repo_root}/"} without wellhead.dev/origin"
  done
fi
