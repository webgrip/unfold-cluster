#!/usr/bin/env bash
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

readonly usage="usage: check-unfold-release.sh [--mutation-test]

Checks that the Unfold release kubernetes/apps/unfold-staging/unfold pins
can be installed with the values staging gives it, before Renovate's pull
request merges itself:

  - downloads the chart the OCIRepository names from its registry and
    refuses it unless the manifest has the pinned digest;
  - takes spec.values from the HelmRelease, substitutes the postBuild
    variables of the unfold-staging Kustomization as Flux would, and runs
    helm template with them, so the chart's values.schema.json and its
    required values refuse a value staging lacks, a renamed one or a
    wrong type.

It does not see Secrets the release needs, Flux's post-renderers or the
cluster's admission policies: a release that fails there is rolled back by
the HelmRelease's upgrade remediation and raises UnfoldFluxReconcileFailing.

  --mutation-test  also requires the check to refuse a wrong digest, a value
                   the schema does not know and a value of the wrong type.

Downloads helm and yq at pinned versions, checksum-verified, into a cache
directory. Needs curl, jq, sha256sum and tar."

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "$usage"; exit 0 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly app_dir="${repo_root}/kubernetes/apps/unfold-staging/unfold"
readonly ocirepository="${app_dir}/ocirepository.yaml"
readonly helmrelease="${app_dir}/helmrelease.yaml"
readonly flux_kustomizations="${repo_root}/kubernetes/apps/unfold-staging/ks.yaml"
readonly release_namespace="unfold-staging"
readonly chart_media_type="application/vnd.cncf.helm.chart.content.v1.tar+gzip"

# renovate: datasource=github-releases depName=helm/helm
readonly helm_version="v4.3.1"
readonly helm_sha256_linux_amd64="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"

# renovate: datasource=github-releases depName=mikefarah/yq
readonly yq_version="v4.53.6"
readonly yq_sha256_linux_amd64="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-release-check"
readonly cache_dir
work_dir="$(mktemp -d)"
readonly work_dir
trap 'rm -rf "${work_dir}"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

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

install_tools() {
  local helm_archive="${cache_dir}/helm-${helm_version}-linux-amd64.tar.gz"
  download_verified "https://get.helm.sh/helm-${helm_version}-linux-amd64.tar.gz" \
    "${helm_sha256_linux_amd64}" "${helm_archive}"
  tar -xzf "${helm_archive}" -C "${work_dir}" linux-amd64/helm
  helm="${work_dir}/linux-amd64/helm"

  yq="${cache_dir}/yq-${yq_version}"
  download_verified "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64" \
    "${yq_sha256_linux_amd64}" "${yq}"
  chmod +x "${yq}"
}

pinned_reference() {
  url="$("${yq}" '.spec.url' "${ocirepository}")"
  tag="$("${yq}" '.spec.ref.tag' "${ocirepository}")"
  digest="$("${yq}" '.spec.ref.digest' "${ocirepository}")"
  [[ "${url}" =~ ^oci://([^/]+)/(.+)$ ]] || fail "${ocirepository}: spec.url ${url} is not an oci:// reference"
  registry="${BASH_REMATCH[1]}"
  repository="${BASH_REMATCH[2]}"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "${ocirepository}: spec.ref.digest must pin the chart by sha256"
}

fetch_chart() {
  local want_digest="$1" target="$2" token manifest layer_digest
  token="$(curl -fsS "https://${registry}/token?scope=repository:${repository}:pull&service=${registry}" | jq -r '.token')"
  manifest="${work_dir}/manifest.json"
  curl -fsS -o "${manifest}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://${registry}/v2/${repository}/manifests/${tag}"
  [ "sha256:$(sha256sum "${manifest}" | cut -d' ' -f1)" = "${want_digest}" ] \
    || return 1
  layer_digest="$(jq -r --arg type "${chart_media_type}" '[.layers[] | select(.mediaType == $type)][0].digest // empty' "${manifest}")"
  [ -n "${layer_digest}" ] || fail "${registry}/${repository}:${tag} holds no Helm chart layer"
  curl -fsSL -o "${target}" -H "Authorization: Bearer ${token}" \
    "https://${registry}/v2/${repository}/blobs/${layer_digest}"
  [ "sha256:$(sha256sum "${target}" | cut -d' ' -f1)" = "${layer_digest}" ] \
    || fail "the chart layer of ${tag} does not match its digest ${layer_digest}"
}

staging_values() {
  local target="$1" substitutions name value values
  substitutions="$("${yq}" ea 'select(.kind == "Kustomization" and .spec.path == "./kubernetes/apps/unfold-staging/unfold") | .spec.postBuild.substitute // {} | to_entries | .[] | .key + "=" + .value' "${flux_kustomizations}")"
  values="$("${yq}" '.spec.values' "${helmrelease}")"
  while IFS='=' read -r name value; do
    [ -n "${name}" ] || continue
    values="${values//\$\{${name}\}/${value}}"
  done <<<"${substitutions}"
  if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"${values}"; then
    fail "${helmrelease}: spec.values uses a variable the unfold-staging Kustomization does not substitute: $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' <<<"${values}" | sort -u | tr '\n' ' ')"
  fi
  printf '%s\n' "${values}" >"${target}"
}

renders() {
  "${helm}" template unfold "$1" --namespace "${release_namespace}" --values "$2" >/dev/null
}

install_tools
pinned_reference

chart="${work_dir}/unfold-${tag}.tgz"
fetch_chart "${digest}" "${chart}" \
  || fail "${registry}/${repository}:${tag} no longer has the pinned digest ${digest}"

values="${work_dir}/values.yaml"
staging_values "${values}"

renders "${chart}" "${values}" \
  || fail "Unfold ${tag} does not render with the values staging gives it; read the release notes and change kubernetes/apps/unfold-staging/unfold/helmrelease.yaml in this pull request"
echo "Unfold ${tag} (${digest}) renders with staging's values"

if [ "${mutation_test}" = true ]; then
  if fetch_chart "sha256:$(printf '0%.0s' {1..64})" "${work_dir}/mutant.tgz"; then
    fail "mutation: a chart whose manifest does not have the pinned digest was accepted"
  fi
  echo "mutation: a wrong pinned digest is refused"

  "${yq}" '.auth.notAField = true' "${values}" >"${work_dir}/unknown.yaml"
  if renders "${chart}" "${work_dir}/unknown.yaml" 2>/dev/null; then
    fail "mutation: a value the chart's schema does not know still renders"
  fi
  echo "mutation: a value the schema does not know is refused"

  "${yq}" '.auth.localLogin = 3' "${values}" >"${work_dir}/wrong-type.yaml"
  if renders "${chart}" "${work_dir}/wrong-type.yaml" 2>/dev/null; then
    fail "mutation: a value of the wrong type still renders"
  fi
  echo "mutation: a value of the wrong type is refused"
fi
