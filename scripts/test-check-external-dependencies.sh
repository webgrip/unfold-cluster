#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-check-external-dependencies.sh

Runs scripts/check-external-dependencies.sh against copies of this
repository. The unchanged copy must pass. Each mutant must fail and name the
host it introduced or dropped: a new URL host in a manifest, a new Cilium
matchName, a new image registry pinned by digest, a new name under
webgrip.dev, and a host deleted from the inventory's host list. A host that
appears only in a test script, under .invalid or in cluster DNS must still
pass, so the check stays quiet about what never leaves the cluster."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fresh_copy() {
  local copy="${work}/$1"
  mkdir -p "$copy"
  (cd "$repo" && tar -cf - --exclude=.git --exclude=.terraform infra kubernetes talos scripts .forgejo docs) | tar -xf - -C "$copy"
  echo "$copy"
}

expect_pass() {
  local name="$1" copy="$2" output
  if output="$("${copy}/scripts/check-external-dependencies.sh" "$copy" 2>&1)" && grep -q 'external hosts the code names are listed' <<<"$output"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: expected a pass, got:"; echo "$output" | sed 's/^/     /'
    failures=$((failures + 1))
  fi
}

expect_missing() {
  local name="$1" copy="$2" host="$3" output status=0
  output="$("${copy}/scripts/check-external-dependencies.sh" "$copy" 2>&1)" || status=$?
  if [ "$status" -eq 1 ] && grep -qF "missing from docs/architecture/external-dependencies.md: ${host} " <<<"$output"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: expected exit 1 naming ${host}, got exit ${status}:"; echo "$output" | sed 's/^/     /'
    failures=$((failures + 1))
  fi
}

expect_pass "the repository as it is passes" "$(fresh_copy unchanged)"

copy="$(fresh_copy url-host)"
printf -- '---\napiVersion: source.toolkit.fluxcd.io/v1\nkind: HelmRepository\nmetadata:\n  name: mutant\nspec:\n  url: https://charts.mutant-upstream.test\n' > "${copy}/kubernetes/platform/mutant-source.yaml"
expect_missing "a chart repository on a new host fails" "$copy" "charts.mutant-upstream.test"

copy="$(fresh_copy fqdn)"
printf -- '    - toFQDNs:\n        - matchName: api.mutant-provider.test\n' >> "${copy}/kubernetes/platform/zot/networkpolicy.yaml"
expect_missing "a new egress name in a network policy fails" "$copy" "api.mutant-provider.test"

copy="$(fresh_copy registry)"
printf -- 'image: registry.mutant.test/team/tool:1.0@sha256:%064d\n' 0 > "${copy}/kubernetes/platform/mutant-image.yaml"
expect_missing "an image from a new registry fails" "$copy" "registry.mutant.test"

copy="$(fresh_copy owned-zone)"
printf 'variable "mutant" {\n  default = "kms-two.webgrip.dev"\n}\n' > "${copy}/infra/mutant.tf"
expect_missing "a new name under webgrip.dev fails" "$copy" "kms-two.webgrip.dev"

copy="$(fresh_copy dropped-row)"
"${repo}/scripts/write-mutant.sh" "${copy}/docs/architecture/external-dependencies.md" "\`api.hetzner.cloud\`" "api-hetzner-cloud" "${copy}/docs/architecture/external-dependencies.md"
expect_missing "a host dropped from the inventory fails" "$copy" "api.hetzner.cloud"

copy="$(fresh_copy ignored)"
printf 'curl https://only-in-a-test.mutant.test\n' > "${copy}/scripts/test-mutant.sh"
printf -- 'a: https://placeholder.invalid\nb: http://zot.zot.svc.cluster.local:5000\nc: https://127.0.0.1:9\n' > "${copy}/kubernetes/platform/mutant-internal.yaml"
expect_pass "test scripts, placeholders and cluster DNS stay quiet" "$copy"

if [ "$failures" -gt 0 ]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all cases passed"
