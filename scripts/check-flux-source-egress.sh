#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: check-flux-source-egress.sh [--mutation-test] [kubernetes-dir]

Fails when a Flux source in the tree (GitRepository, HelmRepository,
OCIRepository, Bucket) names a host that the source-controller-egress
CiliumNetworkPolicy does not list under toFQDNs. Once flux-system's egress
is enforced, such a source can no longer be fetched, and a fix to it could
not reach the cluster through Flux either.

Hosts a source only redirects to (CDNs, GitHub release assets) cannot be read
from the tree; docs/runbooks/egress-by-name.md lists them with their reason.

  --mutation-test  also prove the check: it must pass on the tree as it is,
                   fail when a listed host is removed from the policy, and
                   fail when a source on an unlisted host is added."

kubernetes_dir_default="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kubernetes"
readonly kubernetes_dir_default
readonly policy_relative_path="platform/network-policy/flux-system-egress.yaml"

source_hosts() {
  local tree="$1"
  find "$tree" -name '*.yaml' -print0 |
    xargs -0 awk '
      FNR == 1 || /^---/ { kind = "" }
      /^kind: (GitRepository|HelmRepository|OCIRepository|Bucket)$/ { kind = $2 }
      kind != "" && /^  (url|endpoint): / {
        url = $2
        sub(/^[a-z]+:\/\//, "", url)
        sub(/[\/:].*$/, "", url)
        print url
      }
    ' | sort -u
}

allowed_hosts() {
  local policy="$1"
  awk '
    /^---/ { in_policy = 0 }
    /^  name: source-controller-egress$/ { in_policy = 1 }
    in_policy && /matchName: / { print $NF }
  ' "$policy" | tr -d '"' | sort -u
}

check_tree() {
  local tree="$1"
  local policy="${tree}/${policy_relative_path}"
  local missing
  missing="$(comm -23 <(source_hosts "$tree") <(allowed_hosts "$policy"))"
  if [[ -n "$missing" ]]; then
    printf 'source-controller-egress does not name these Flux source hosts:\n%s\n' "$missing" >&2
    return 1
  fi
  printf 'every Flux source host is named by source-controller-egress (%s hosts)\n' "$(source_hosts "$tree" | wc -l | tr -d ' ')"
}

mutation_test() {
  local tree="$1"
  local scratch
  scratch="$(mktemp -d)"
  local result=0
  run_mutations "$tree" "$scratch" || result=$?
  rm -rf "$scratch"
  return "$result"
}

run_mutations() {
  local tree="$1"
  local scratch="$2"

  check_tree "$tree" >/dev/null || { echo "mutation test: the unmodified tree must pass" >&2; return 1; }

  cp -R "$tree" "${scratch}/removed-host"
  sed -i '/matchName: charts.hetzner.cloud/d' "${scratch}/removed-host/${policy_relative_path}"
  if check_tree "${scratch}/removed-host" 2>/dev/null; then
    echo "mutation test: removing charts.hetzner.cloud from the policy was not caught" >&2
    return 1
  fi

  cp -R "$tree" "${scratch}/added-source"
  printf -- '---\napiVersion: source.toolkit.fluxcd.io/v1\nkind: HelmRepository\nmetadata:\n  name: unlisted\nspec:\n  url: https://charts.example.org/stable\n' \
    >"${scratch}/added-source/platform/unlisted-helmrepository.yaml"
  if check_tree "${scratch}/added-source" 2>/dev/null; then
    echo "mutation test: a HelmRepository on an unlisted host was not caught" >&2
    return 1
  fi

  echo "mutation test: passes as is, catches a removed host and an added source"
}

main() {
  local mutation=false
  local tree="$kubernetes_dir_default"
  while (($#)); do
    case "$1" in
      --mutation-test) mutation=true ;;
      -h | --help) echo "$usage"; return 0 ;;
      *) tree="$1" ;;
    esac
    shift
  done

  check_tree "$tree"
  if [[ "$mutation" == true ]]; then
    mutation_test "$tree"
  fi
}

main "$@"
