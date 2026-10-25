#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-trivy-report-shipper.sh

Runs Vector's own unit tests (tests/trivy-report-shipper/vector-tests.yaml)
against the report shipper's configuration in
kubernetes/platform/trivy-operator/app/report-shipper/vector.yaml: the record
each Trivy report becomes before it is written to VictoriaLogs.

Downloads Vector at the version the shipper runs, checksum-verified, into a
cache directory. Needs curl, sha256sum and tar."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root

# renovate: datasource=github-releases depName=vectordotdev/vector extractVersion=^v(?<version>.+)$
readonly vector_version="0.60.0"
readonly vector_sha256_linux_amd64_musl="9584f402e67fea7ff2dd846f0a8bbb56fa32951bded11749093ff3780e1513cf"

case "${1:-}" in
  "") ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only the linux-amd64 binary is pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-trivy-report-shipper-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/trivy-report-shipper-test.XXXXXX")"
readonly work_dir
trap 'rm -rf "${work_dir}"' EXIT

archive="${cache_dir}/vector-${vector_version}-x86_64-unknown-linux-musl.tar.gz"
if ! { [ -f "${archive}" ] && echo "${vector_sha256_linux_amd64_musl}  ${archive}" | sha256sum -c --status -; }; then
  mkdir -p "${cache_dir}"
  curl -fsSL --retry 3 -o "${archive}.partial" \
    "https://github.com/vectordotdev/vector/releases/download/v${vector_version}/vector-${vector_version}-x86_64-unknown-linux-musl.tar.gz"
  echo "${vector_sha256_linux_amd64_musl}  ${archive}.partial" | sha256sum -c --quiet -
  mv "${archive}.partial" "${archive}"
fi
tar -xzf "${archive}" -C "${work_dir}" --strip-components=3 "./vector-x86_64-unknown-linux-musl/bin/vector"

grep -q "timberio/vector:${vector_version}-" "${repo_root}/kubernetes/platform/trivy-operator/app/report-shipper/deployment.yaml" \
  || { echo "the report shipper runs a different Vector than ${vector_version}; move this script's pin with it" >&2; exit 1; }

"${work_dir}/vector" test \
  "${repo_root}/kubernetes/platform/trivy-operator/app/report-shipper/vector.yaml" \
  "${repo_root}/tests/trivy-report-shipper/vector-tests.yaml"
