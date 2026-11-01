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

Runs wellhead through scripts/wellhead.sh, which pins its version."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wellhead-check.XXXXXX")"
readonly work_dir
trap 'rm -rf "${work_dir}"' EXIT
readonly wellhead="${repo_root}/scripts/wellhead.sh"

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
