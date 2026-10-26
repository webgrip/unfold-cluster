#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: check-external-dependencies.sh [repository-root]

Fails when the code names a host outside the cluster that
docs/architecture/external-dependencies.md does not list in its
'Hosts the code names' section, so a new external dependency cannot land
without a row that says what breaks when it is down.

A host counts when it appears in infra/, kubernetes/, talos/, scripts/
(test scripts excluded) or .forgejo/workflows/ as:

  - the host of an http://, https:// or oci:// URL;
  - a Cilium toFQDNs matchName or matchPattern;
  - the registry of an image pinned by digest (host/path[:tag]@sha256:...);
  - a name under webgrip.dev or unfoldhq.dev.

Names that never leave the cluster or are placeholders are ignored:
*.cluster.local, *.svc, *.local, *.invalid, example.org/com/net,
localhost and IP addresses.

Prints every missing host with one file that names it, and exits 1.
Exits 0 when every host is listed."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
esac

root="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
inventory="${root}/docs/architecture/external-dependencies.md"
[ -f "$inventory" ] || { echo "check-external-dependencies: ${inventory} does not exist" >&2; exit 2; }

source_files() {
  local dir
  for dir in infra kubernetes talos scripts .forgejo/workflows; do
    [ -d "${root}/${dir}" ] || continue
    find "${root}/${dir}" -type f \( -name '*.tf' -o -name '*.tftpl' -o -name '*.yaml' -o -name '*.yml' -o -name '*.sh' -o -name '*.hujson' -o -name '*.json' \) \
      -not -path '*/infra/tests/*' -not -path '*/.terraform/*' -not -name 'test-*.sh'
  done
}

hosts_in() {
  local file="$1"
  {
    grep -oE '(https?|oci)://[A-Za-z0-9*._-]+' "$file" | sed -E 's#^[a-z]+://##'
    grep -oE 'match(Name|Pattern):[[:space:]]*"?[A-Za-z0-9*._-]+' "$file" | sed -E 's/^match(Name|Pattern):[[:space:]]*"?//'
    grep -oE '[a-z0-9-]+(\.[a-z0-9-]+)+/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?@sha256:' "$file" | cut -d/ -f1
    grep -oE '[a-z0-9-]+(\.[a-z0-9-]+)*\.(webgrip|unfoldhq)\.dev' "$file"
  } | tr 'A-Z' 'a-z' | sed -E 's/\.+$//' || true
}

is_external() {
  local host="$1"
  case "$host" in
    *.*) ;;
    *) return 1 ;;
  esac
  case "$host" in
    '*.' | *.cluster.local | *.svc | *.local | *.invalid | localhost | example.org | example.com | example.net | *.example.org | *.example.com | *.example.net) return 1 ;;
  esac
  [[ "$host" =~ ^[0-9.]+$ ]] && return 1
  return 0
}

listed="$(awk '/^## Hosts the code names/{inside=1; next} /^## /{inside=0} inside' "$inventory" | grep -oE '`[^`]+`' | tr -d '`' | tr 'A-Z' 'a-z' | sort -u)"
[ -n "$listed" ] || { echo "check-external-dependencies: ${inventory} has no 'Hosts the code names' section with backticked hosts" >&2; exit 2; }

declare -A first_seen=()
while IFS= read -r file; do
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    is_external "$host" || continue
    [ -n "${first_seen[$host]:-}" ] || first_seen[$host]="${file#"${root}/"}"
  done < <(hosts_in "$file")
done < <(source_files | sort)

missing=0
for host in $(printf '%s\n' "${!first_seen[@]}" | sort); do
  if ! grep -qxF -- "$host" <<<"$listed"; then
    echo "missing from docs/architecture/external-dependencies.md: ${host} (named in ${first_seen[$host]})"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "check-external-dependencies: ${missing} external host(s) have no row; add each to the dependency table and the 'Hosts the code names' section"
  exit 1
fi
echo "check-external-dependencies: all ${#first_seen[@]} external hosts the code names are listed"
