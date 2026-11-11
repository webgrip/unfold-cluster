#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-image-signatures.sh [--mutation-test]

Proves the Kyverno ImageValidatingPolicies in kubernetes/platform/kyverno/policies
with the Kyverno CLI, which runs the same image verification engine as the
admission controller.

Against the real registry and the estate's real key (tests/image-signatures/):
  admitted-*.yaml  must pass every policy: webgrip images signed with the
                   cosign-webgrip key, and images the policies do not cover
  refused-*.yaml   must fail a policy: webgrip images without that signature

And on a throwaway registry on loopback, with throwaway keys, for the Zot
policy (plain HTTP inside the cluster):
  an image signed with the trusted key passes, an unsigned one fails, and one
  signed with any other key fails. Each signed case runs in both formats:
  cosign 3's Sigstore bundle, stored as an OCI referrer, and the legacy .sig
  tag that the estate's signing jobs still write.

A wrongly signed image is also proven against the real registry: the signed
fixture must fail once the policy trusts a different key.

The unfold-hq policy trusts a keyless signature from the unfold-hq/unfold
release workflow. No unfold-hq image exists to test it against yet, so a copy
of it that matches ghcr.io/ploeg-hq/* and trusts ploeg-hq/ploeg's release
workflow must admit a ploegd release signed that way; the policy itself must
refuse that image as signed by someone else, and must refuse it by tag alone.

  --mutation-test  also neutralise each policy (its validation becomes true
                   and required becomes false) and require every refused case,
                   the keyless one included, to pass; a refused case that
                   still fails was never testing the policy. Then remove each of the two gates alone and
                   require the other to still refuse an unsigned image.

Downloads the Kyverno CLI, cosign and crane at the pinned versions below,
checksum-verified, into a cache directory. Needs curl, sha256sum, tar, sed,
awk and network access to ghcr.io and tuf-repo-cdn.sigstore.dev."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly policy_dir="${repo_root}/kubernetes/platform/kyverno/policies"
readonly fixture_dir="${repo_root}/tests/image-signatures"
readonly public_policy="${policy_dir}/webgrip-image-signatures.yaml"
readonly zot_policy="${policy_dir}/webgrip-image-signatures-zot.yaml"
readonly unfold_hq_policy="${policy_dir}/unfold-hq-image-signatures.yaml"
readonly keyless_signed_image="ghcr.io/ploeg-hq/ploegd@sha256:3ef1912b91ca7edef845b471ed44c7aba10f8aed31cdb87e59d8bd4a4ae528e0"
readonly keyless_signed_tag="ghcr.io/ploeg-hq/ploegd:0.2.0-rc.104"
readonly keyless_signer_sed_escaped='^https://github\\.com/ploeg-hq/ploeg/\\.github/workflows/release\\.yml@refs/heads/development$'
readonly zot_address="zot.zot.svc.cluster.local:5000"

# renovate: datasource=github-releases depName=kyverno/kyverno
readonly kyverno_version="v1.19.2"
readonly kyverno_sha256_linux_amd64="357eaf1df8bc24ddd5a73979fadeaae6a032e8710f11af264229756e4956bf4a"

# renovate: datasource=github-releases depName=sigstore/cosign
readonly cosign_version="v3.1.4"
readonly cosign_sha256_linux_amd64="424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa"

# renovate: datasource=github-releases depName=google/go-containerregistry
readonly crane_version="v0.22.1"
readonly crane_sha256_linux_amd64="0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"

readonly registry_port="${IMAGE_SIGNATURE_TEST_REGISTRY_PORT:-25000}"
readonly registry="127.0.0.1:${registry_port}"

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only linux-amd64 binaries are pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-image-signature-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/image-signature-test.XXXXXX")"
readonly work_dir
registry_pid=""

stop_registry() {
  if [ -n "${registry_pid}" ]; then
    kill -KILL "${registry_pid}" 2>/dev/null || true
    wait "${registry_pid}" 2>/dev/null || true
  fi
  rm -rf "${work_dir}"
}
trap stop_registry EXIT

download_verified() {
  local url="$1" sha256="$2" target="$3"
  if [ -f "${target}" ] && echo "${sha256}  ${target}" | sha256sum -c --status -; then
    return
  fi
  mkdir -p "$(dirname "${target}")"
  curl -fsSL --retry 3 -o "${target}.partial" "${url}"
  echo "${sha256}  ${target}.partial" | sha256sum -c --quiet -
  mv "${target}.partial" "${target}"
}

install_binaries() {
  local kyverno_archive="${cache_dir}/kyverno-cli-${kyverno_version}.tar.gz"
  download_verified "https://github.com/kyverno/kyverno/releases/download/${kyverno_version}/kyverno-cli_${kyverno_version}_linux_x86_64.tar.gz" \
    "${kyverno_sha256_linux_amd64}" "${kyverno_archive}"
  tar -xzf "${kyverno_archive}" -C "${work_dir}" kyverno

  local crane_archive="${cache_dir}/go-containerregistry-${crane_version}.tar.gz"
  download_verified "https://github.com/google/go-containerregistry/releases/download/${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
    "${crane_sha256_linux_amd64}" "${crane_archive}"
  tar -xzf "${crane_archive}" -C "${work_dir}" crane

  download_verified "https://github.com/sigstore/cosign/releases/download/${cosign_version}/cosign-linux-amd64" \
    "${cosign_sha256_linux_amd64}" "${cache_dir}/cosign-${cosign_version}"
  install -m 0755 "${cache_dir}/cosign-${cosign_version}" "${work_dir}/cosign"

  kyverno_bin="${work_dir}/kyverno"
  crane_bin="${work_dir}/crane"
  cosign_bin="${work_dir}/cosign"
}

with_trusted_key() {
  local policy="$1" public_key="$2"
  awk -v key_file="${public_key}" '
    /^          data: \|$/ {
      print
      while ((getline line < key_file) > 0) print "            " line
      replacing = 1
      next
    }
    replacing && /^            / { next }
    { replacing = 0; print }
  ' "${policy}"
}

without_expression_gate() {
  sed -E 's/^(    - expression: ).*$/\1"true"/; /^        (images|&&)/d' "$1"
}

without_required_gate() {
  sed 's/^    required: true$/    required: false/' "$1"
}

neutralised() {
  without_expression_gate "$1" | without_required_gate /dev/stdin
}

failures=()

record_failure() {
  failures+=("$1")
  echo "FAIL  $1" >&2
}

verdict() {
  local policy="$1" resource="$2" output
  output="$("${kyverno_bin}" apply "${policy}" --resource "${resource}" 2>&1 || true)"
  if grep -q '^pass: [0-9]*, fail: 0, warn: 0, error: 0' <<<"${output}"; then
    echo pass
  elif grep -q '^pass: [0-9]*, fail: [1-9]' <<<"${output}"; then
    echo fail
  else
    echo "error: ${output}"
  fi
}

expect() {
  local wanted="$1" policy="$2" resource="$3" label="$4" got
  got="$(verdict "${policy}" "${resource}")"
  if [ "${got}" = "${wanted}" ]; then
    echo "ok    ${label}: ${wanted}"
  else
    record_failure "${label}: wanted ${wanted}, got ${got}"
  fi
}

fixtures_named() {
  find "${fixture_dir}" -maxdepth 1 -type f -name "$1-*.yaml" | sort
}

check_real_registry() {
  local policy_set="${work_dir}/policies.yaml" fixture
  cat "${public_policy}" "${zot_policy}" "${unfold_hq_policy}" >"${policy_set}"
  [ -n "$(fixtures_named refused)" ] && [ -n "$(fixtures_named admitted)" ] \
    || record_failure "tests/image-signatures needs at least one refused-*.yaml and one admitted-*.yaml"
  while read -r fixture; do
    expect pass "${policy_set}" "${fixture}" "real registry ${fixture#"${repo_root}/"}"
  done < <(fixtures_named admitted)
  while read -r fixture; do
    expect fail "${policy_set}" "${fixture}" "real registry ${fixture#"${repo_root}/"}"
  done < <(fixtures_named refused)

  with_trusted_key "${public_policy}" "${work_dir}/other.pub" >"${work_dir}/wrong-key.yaml"
  expect fail "${work_dir}/wrong-key.yaml" "${fixture_dir}/admitted-signed-webgrip-image.yaml" \
    "real registry signed image under a policy that trusts another key"
}

pod_for() {
  local name="$1" image="$2" target="$3"
  cat >"${target}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: image-signature-test
spec:
  containers:
    - name: app
      image: ${image}
EOF
}

push_fixture_image() {
  local tag="$1"
  head -c 256 /dev/urandom >"${work_dir}/payload"
  tar -C "${work_dir}" -cf "${work_dir}/layer.tar" payload
  "${crane_bin}" append --insecure -f "${work_dir}/layer.tar" -t "${registry}/webgrip/fixture:${tag}" >/dev/null 2>&1
  echo "${registry}/webgrip/fixture:${tag}@$("${crane_bin}" digest --insecure "${registry}/webgrip/fixture:${tag}")"
}

sign() {
  local format="$1" key="$2" image="$3" format_flags
  case "${format}" in
    bundle) format_flags=(--signing-config "${work_dir}/no-tlog-signing-config.json") ;;
    legacy) format_flags=(--new-bundle-format=false --use-signing-config=false --tlog-upload=false) ;;
  esac
  COSIGN_PASSWORD="" "${cosign_bin}" sign --yes --key "${key}" "${format_flags[@]}" --allow-http-registry "${image}" >/dev/null 2>&1
}

start_registry() {
  "${crane_bin}" registry serve --address "${registry}" >"${work_dir}/registry.log" 2>&1 &
  registry_pid="$!"
  for _ in $(seq 1 50); do
    curl -fsS "http://${registry}/v2/" >/dev/null 2>&1 && return
    sleep 0.2
  done
  echo "the throwaway registry did not start; its log:" >&2
  cat "${work_dir}/registry.log" >&2
  exit 1
}

trusting_ploeg_releases() {
  sed -E \
    -e 's|"ghcr\.io/unfold-hq/\*"|"ghcr.io/ploeg-hq/*"|' \
    -e "s|^( *subjectRegExp: ).*$|\\1'${keyless_signer_sed_escaped}'|" \
    "$1"
}

check_keyless() {
  pod_for keyless-signed "${keyless_signed_image}" "${work_dir}/keyless-signed.yaml"
  pod_for keyless-tag "${keyless_signed_tag}" "${work_dir}/keyless-tag.yaml"
  trusting_ploeg_releases "${unfold_hq_policy}" >"${work_dir}/ploeg-releases.yaml"
  grep -q "ghcr.io/ploeg-hq/\*" "${work_dir}/ploeg-releases.yaml" \
    || record_failure "the unfold-hq policy no longer names ghcr.io/unfold-hq/*"
  expect pass "${work_dir}/ploeg-releases.yaml" "${work_dir}/keyless-signed.yaml" \
    "keyless, the unfold-hq policy trusting ploeg-hq releases admits a ploegd release"
  expect fail "${work_dir}/ploeg-releases.yaml" "${work_dir}/keyless-tag.yaml" \
    "keyless, the same image by tag alone"
  sed 's|"ghcr\.io/unfold-hq/\*"|"ghcr.io/ploeg-hq/*"|' "${unfold_hq_policy}" >"${work_dir}/unfold-hq-on-ploeg.yaml"
  expect fail "${work_dir}/unfold-hq-on-ploeg.yaml" "${work_dir}/keyless-signed.yaml" \
    "keyless, the unfold-hq release identity refuses an image another workflow signed"
}

check_throwaway_registry() {
  start_registry
  local format signed unsigned other
  unsigned="$(push_fixture_image unsigned)"
  pod_for unsigned "${unsigned}" "${work_dir}/zot-unsigned.yaml"
  for format in bundle legacy; do
    signed="$(push_fixture_image "signed-${format}")"
    other="$(push_fixture_image "other-key-${format}")"
    sign "${format}" "${work_dir}/trusted.key" "${signed}"
    sign "${format}" "${work_dir}/other.key" "${other}"
    pod_for "signed-${format}" "${signed}" "${work_dir}/zot-signed-${format}.yaml"
    pod_for "other-key-${format}" "${other}" "${work_dir}/zot-other-key-${format}.yaml"
  done

  with_trusted_key "${zot_policy}" "${work_dir}/trusted.pub" | sed "s|${zot_address}|${registry}|" >"${work_dir}/zot-policy.yaml"
  grep -q "${registry}/webgrip/\*" "${work_dir}/zot-policy.yaml" \
    || record_failure "the Zot policy no longer names ${zot_address}/webgrip/*"
  expect fail "${work_dir}/zot-policy.yaml" "${work_dir}/zot-unsigned.yaml" "zot policy, unsigned"
  for format in bundle legacy; do
    expect pass "${work_dir}/zot-policy.yaml" "${work_dir}/zot-signed-${format}.yaml" "zot policy, ${format} signature from the trusted key"
    expect fail "${work_dir}/zot-policy.yaml" "${work_dir}/zot-other-key-${format}.yaml" "zot policy, ${format} signature from another key"
  done
}

mutation_cases() {
  local fixture
  neutralised "${public_policy}" >"${work_dir}/public-neutralised.yaml"
  neutralised "${work_dir}/zot-policy.yaml" >"${work_dir}/zot-neutralised.yaml"
  while read -r fixture; do
    expect pass "${work_dir}/public-neutralised.yaml" "${fixture}" "mutation, neutralised policy ${fixture#"${repo_root}/"}"
  done < <(fixtures_named refused)
  with_trusted_key "${work_dir}/public-neutralised.yaml" "${work_dir}/other.pub" >"${work_dir}/wrong-key-neutralised.yaml"
  expect pass "${work_dir}/wrong-key-neutralised.yaml" "${fixture_dir}/admitted-signed-webgrip-image.yaml" \
    "mutation, neutralised policy that trusts another key"
  expect pass "${work_dir}/zot-neutralised.yaml" "${work_dir}/zot-unsigned.yaml" "mutation, neutralised zot policy, unsigned"
  expect pass "${work_dir}/zot-neutralised.yaml" "${work_dir}/zot-other-key-bundle.yaml" "mutation, neutralised zot policy, another key"
  neutralised "${work_dir}/unfold-hq-on-ploeg.yaml" >"${work_dir}/unfold-hq-neutralised.yaml"
  expect pass "${work_dir}/unfold-hq-neutralised.yaml" "${work_dir}/keyless-signed.yaml" \
    "mutation, neutralised unfold-hq policy, another signer"

  without_expression_gate "${public_policy}" >"${work_dir}/public-required-only.yaml"
  without_required_gate "${public_policy}" >"${work_dir}/public-expression-only.yaml"
  expect fail "${work_dir}/public-required-only.yaml" "${fixture_dir}/refused-unsigned-webgrip-image.yaml" \
    "mutation, validation expression neutralised, required alone still refuses unsigned"
  expect fail "${work_dir}/public-expression-only.yaml" "${fixture_dir}/refused-unsigned-webgrip-image.yaml" \
    "mutation, required off, the validation expression alone still refuses unsigned"
}

install_binaries
(cd "${work_dir}" && COSIGN_PASSWORD="" "${cosign_bin}" generate-key-pair --output-key-prefix trusted >/dev/null 2>&1)
(cd "${work_dir}" && COSIGN_PASSWORD="" "${cosign_bin}" generate-key-pair --output-key-prefix other >/dev/null 2>&1)
"${cosign_bin}" signing-config create --out "${work_dir}/no-tlog-signing-config.json" >/dev/null 2>&1

check_real_registry
check_keyless
check_throwaway_registry
if [ "${mutation_test}" = true ]; then
  mutation_cases
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} image signature check(s) failed" >&2
  exit 1
fi
echo "every webgrip and unfold-hq image is judged by its signature: signed passes, unsigned and wrongly signed fail"
