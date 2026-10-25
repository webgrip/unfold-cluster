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
  signed with any other key fails.

A wrongly signed image is also proven against the real registry: the signed
fixture must fail once the policy trusts a different key.

  --mutation-test  also neutralise each policy (its validation becomes true
                   and required becomes false) and require every refused case
                   to pass; a refused case that still fails was never testing
                   the policy. Then remove each of the two gates alone and
                   require the other to still refuse an unsigned image.

Downloads the Kyverno CLI, cosign and crane at the pinned versions below,
checksum-verified, into a cache directory. Needs curl, sha256sum, tar, sed,
awk and network access to ghcr.io."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly policy_dir="${repo_root}/kubernetes/platform/kyverno/policies"
readonly fixture_dir="${repo_root}/tests/image-signatures"
readonly public_policy="${policy_dir}/webgrip-image-signatures.yaml"
readonly zot_policy="${policy_dir}/webgrip-image-signatures-zot.yaml"
readonly zot_address="zot.zot.svc.cluster.local:5000"

# renovate: datasource=github-releases depName=kyverno/kyverno
readonly kyverno_version="v1.19.2"
readonly kyverno_sha256_linux_amd64="357eaf1df8bc24ddd5a73979fadeaae6a032e8710f11af264229756e4956bf4a"

# renovate: datasource=github-releases depName=sigstore/cosign
readonly cosign_version="v2.6.5"
readonly cosign_sha256_linux_amd64="c3b4f5410e608af03a5eb0aaac84a4313d8da131248e08ff1759ac70c79d1644"

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
  cat "${public_policy}" "${zot_policy}" >"${policy_set}"
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
  COSIGN_PASSWORD="" "${cosign_bin}" sign --yes --key "$1" --tlog-upload=false --allow-http-registry "$2" >/dev/null 2>&1
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

check_throwaway_registry() {
  start_registry
  local signed unsigned other
  signed="$(push_fixture_image signed)"
  unsigned="$(push_fixture_image unsigned)"
  other="$(push_fixture_image other-key)"
  sign "${work_dir}/trusted.key" "${signed}"
  sign "${work_dir}/other.key" "${other}"
  pod_for signed "${signed}" "${work_dir}/zot-signed.yaml"
  pod_for unsigned "${unsigned}" "${work_dir}/zot-unsigned.yaml"
  pod_for other-key "${other}" "${work_dir}/zot-other-key.yaml"

  with_trusted_key "${zot_policy}" "${work_dir}/trusted.pub" | sed "s|${zot_address}|${registry}|" >"${work_dir}/zot-policy.yaml"
  grep -q "${registry}/webgrip/\*" "${work_dir}/zot-policy.yaml" \
    || record_failure "the Zot policy no longer names ${zot_address}/webgrip/*"
  expect pass "${work_dir}/zot-policy.yaml" "${work_dir}/zot-signed.yaml" "zot policy, signed with the trusted key"
  expect fail "${work_dir}/zot-policy.yaml" "${work_dir}/zot-unsigned.yaml" "zot policy, unsigned"
  expect fail "${work_dir}/zot-policy.yaml" "${work_dir}/zot-other-key.yaml" "zot policy, signed with another key"
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
  expect pass "${work_dir}/zot-neutralised.yaml" "${work_dir}/zot-other-key.yaml" "mutation, neutralised zot policy, another key"

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

check_real_registry
check_throwaway_registry
if [ "${mutation_test}" = true ]; then
  mutation_cases
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} image signature check(s) failed" >&2
  exit 1
fi
echo "every webgrip image is judged by its signature: signed passes, unsigned and wrongly signed fail"
