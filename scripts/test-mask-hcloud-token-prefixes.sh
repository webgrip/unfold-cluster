#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-mask-hcloud-token-prefixes.sh

Proves, without a runner and without a real token, that a Hetzner error
quoting a token's start reaches a job log as '***...':

  * mask-hcloud-token-prefixes.sh is run on three fake tokens, one per
    variable it reads;
  * its ::add-mask:: values are applied the way forgejo-runner's log
    reporter applies them (internal/pkg/report/mask.go): every mask is a
    plain substring, the longest replaced first, each by ***;
  * Hetzner's 429 line, a shorter quote, a whole token and an unrelated line
    are pushed through, and each result is compared with the exact expected
    text;
  * a control run with no masks must leave the quote visible, so a broken
    check cannot pass by masking nothing or everything;
  * diagnose-cluster.sh --redact-test must hide the quote of a token it was
    never given, the case of Talos's VIP controller and the cloud controller.

MASK_SCRIPT points at another mask script, for a mutation check."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly mask_script="${MASK_SCRIPT:-${repo_root}/scripts/mask-hcloud-token-prefixes.sh}"
readonly diagnose_script="${repo_root}/scripts/diagnose-cluster.sh"
readonly masked='***'

failures=0

fake_token() {
  printf 'unfold-cluster mask test %s' "$1" | sha256sum | cut -d' ' -f1
}

hetzner_rate_limit_line() {
  printf "Error: Limit of '3600' requests per hour for token '%s...' reached. (rate_limit_exceeded)" "$1"
}

masks_from() {
  sed -n 's/^::add-mask:://p' | awk '{ print length($0) "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr | cut -f2-
}

apply_masks() {
  local line="$1"
  shift
  local mask
  for mask in "$@"; do
    line="${line//"$mask"/"$masked"}"
  done
  printf '%s' "$line"
}

expect() {
  local case_name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "ok   ${case_name}"
  else
    echo "FAIL ${case_name}"
    echo "     expected: ${expected}"
    echo "     actual:   ${actual//[A-Za-z0-9]/x}"
    failures=$((failures + 1))
  fi
}

main() {
  case "${1:-}" in
    -h | --help) echo "$usage"; exit 0 ;;
    "") ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac

  local tofu_token cluster_token vip_token
  tofu_token="$(fake_token tofu)"
  cluster_token="$(fake_token cluster)"
  vip_token="$(fake_token vip)"

  local -a masks
  mapfile -t masks < <(
    HCLOUD_TOKEN="$tofu_token" \
      TF_VAR_hcloud_cluster_token="$cluster_token" \
      TF_VAR_hcloud_vip_token="$vip_token" \
      "$mask_script" | masks_from
  )

  local expected_quote
  expected_quote="$(hetzner_rate_limit_line "$masked")"

  expect "control: with no masks the 32-character quote stays visible" \
    "$(apply_masks "$(hetzner_rate_limit_line "${tofu_token:0:32}")")" \
    "$(hetzner_rate_limit_line "${tofu_token:0:32}")"

  local name token
  for name in tofu cluster vip; do
    token="$(fake_token "$name")"
    expect "${name} token: Hetzner's 429 quote of 32 characters" \
      "$(apply_masks "$(hetzner_rate_limit_line "${token:0:32}")" "${masks[@]}")" \
      "$expected_quote"
    expect "${name} token: a quote cut at 16 characters" \
      "$(apply_masks "$(hetzner_rate_limit_line "${token:0:16}")" "${masks[@]}")" \
      "$expected_quote"
    expect "${name} token: the whole token is one ***" \
      "$(apply_masks "Authorization: Bearer ${token}" "${masks[@]}")" \
      "Authorization: Bearer ${masked}"
  done

  expect "a line without a token is unchanged" \
    "$(apply_masks "Refreshing state... [id=172334019]" "${masks[@]}")" \
    "Refreshing state... [id=172334019]"

  local unknown_token
  unknown_token="$(fake_token never-masked)"
  expect "diagnose redaction hides the quote of a token the job never loaded" \
    "$(hetzner_rate_limit_line "${unknown_token:0:32}" | "$diagnose_script" --redact-test)" \
    "Error: Limit of '3600' requests per hour for token '<redacted>' reached. (rate_limit_exceeded)"

  if [ "$failures" -gt 0 ]; then
    echo "${failures} case(s) failed"
    exit 1
  fi
  echo "all cases passed"
}

main "$@"
