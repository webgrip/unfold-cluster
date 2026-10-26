#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-observability-metrics.sh [--mutation-test]

Proves the metric half of the observability stack without a cluster:

  rules     runs vmalert-tool's unit tests in tests/observability/rules against
            every PromQL rule in kubernetes/platform/observability/app/alerting/
            rules (cluster.yaml, supply-chain.yaml). Each alert needs at least
            one test where it fires with its exact labels and one where it
            stays quiet; an alert without both fails. Annotations are stripped
            for the unit tests and checked by vmalert -dryRun instead.
  pins      the Grafana CR's spec.version, its container image (which
            Renovate moves) and the operator's RELATED_IMAGE_GRAFANA are the
            same digest-pinned image.
  load      vmalert -dryRun loads every rule file, LogsQL ones included, with
            their templates; amtool accepts the Alertmanager configuration;
            vmauth -dryRun accepts the query endpoint's configuration.
  relabel   runs Alloy with the real discovery.relabel \"pod_metrics\" block from
            alloy/metrics/metrics.alloy over the pods in
            tests/observability/pod-targets.json, and requires each pod's job,
            component and address (or that it is dropped), because the alert
            rules select on those labels.

  --mutation-test  also replaces each alert's expression, one at a time, with
                   one that never fires and with one that always fires, and
                   requires the unit tests to fail both times; and breaks the
                   relabel rules and requires the relabel check to fail.

Downloads vmutils (vmalert, vmalert-tool, vmauth), Alertmanager, Alloy and yq
at pinned versions, checksum-verified, into a cache directory. Needs curl, jq,
sha256sum, tar and unzip."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly obs_dir="${repo_root}/kubernetes/platform/observability/app"
readonly rules_dir="${obs_dir}/alerting/rules"
readonly metric_rule_files=(cluster.yaml supply-chain.yaml)
readonly tests_dir="${repo_root}/tests/observability/rules"
readonly metrics_config="${obs_dir}/alloy/metrics/metrics.alloy"
readonly pod_targets="${repo_root}/tests/observability/pod-targets.json"

# renovate: datasource=github-releases depName=VictoriaMetrics/VictoriaMetrics
readonly vmutils_version="v1.148.0"
readonly vmutils_sha256_linux_amd64="54c72a7f335d76a8229032ed3aec5f4934ccd547186750065ea11408458ea7b2"

# renovate: datasource=github-releases depName=prometheus/alertmanager
readonly alertmanager_version="v0.34.1"
readonly alertmanager_sha256_linux_amd64="265b9d1e55ef0d5306a436018af6d2b686c2ce051f03d968f7464ecb1372a7e8"

# renovate: datasource=github-releases depName=grafana/alloy
readonly alloy_version="v1.21.2"
readonly alloy_sha256_linux_amd64_zip="1eadb46a0640127184250173acd9b4145e4d590680db37ffe66fa8afd07f04cf"

# renovate: datasource=github-releases depName=mikefarah/yq
readonly yq_version="v4.53.6"
readonly yq_sha256_linux_amd64="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"

readonly alloy_port="${OBSERVABILITY_TEST_PORT:-19600}"

readonly relabel_mutations=(
  's/regex         = "kyverno;kyverno;8000"/regex         = "kyverno;kyverno;9000"/'
  's/replacement   = "\$1:2112"/replacement   = "$1:2113"/'
  's/regex         = "kube-system;cilium;hubble-metrics"/regex         = "kube-system;cilium;hubble"/'
  's/\t\tregex         = ".+"\n\t\taction        = "keep"\n//'
)

mutation_test=false
case "${1:-}" in
  "") ;;
  --mutation-test) mutation_test=true ;;
  -h | --help) echo "${usage}"; exit 0 ;;
  *) echo "${usage}" >&2; exit 2 ;;
esac

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || { echo "only linux-amd64 binaries are pinned" >&2; exit 2; }

cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/unfold-observability-test"
readonly cache_dir
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/observability-metrics-test.XXXXXX")"
readonly work_dir
background_pids=()
failures=()

stop_all() {
  local pid
  for pid in "${background_pids[@]}"; do
    kill -KILL "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "${work_dir}"
}
trap stop_all EXIT

record_failure() {
  failures+=("$1")
  echo "FAIL  $1" >&2
}

pass() {
  echo "ok    $1"
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

install_binaries() {
  mkdir -p "${work_dir}/bin"
  local vmutils="${cache_dir}/vmutils-linux-amd64-${vmutils_version}.tar.gz"
  download_verified "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${vmutils_version}/vmutils-linux-amd64-${vmutils_version}.tar.gz" \
    "${vmutils_sha256_linux_amd64}" "${vmutils}"
  tar -xzf "${vmutils}" -C "${work_dir}/bin" vmalert-prod vmalert-tool-prod vmauth-prod

  local am="${cache_dir}/alertmanager-${alertmanager_version#v}.linux-amd64.tar.gz"
  download_verified "https://github.com/prometheus/alertmanager/releases/download/${alertmanager_version}/alertmanager-${alertmanager_version#v}.linux-amd64.tar.gz" \
    "${alertmanager_sha256_linux_amd64}" "${am}"
  tar -xzf "${am}" -C "${work_dir}/bin" --strip-components=1 "alertmanager-${alertmanager_version#v}.linux-amd64/amtool"

  local alloy_zip="${cache_dir}/alloy-${alloy_version}-linux-amd64.zip"
  download_verified "https://github.com/grafana/alloy/releases/download/${alloy_version}/alloy-linux-amd64.zip" \
    "${alloy_sha256_linux_amd64_zip}" "${alloy_zip}"
  unzip -q -o "${alloy_zip}" -d "${work_dir}/bin"
  chmod 0755 "${work_dir}/bin/alloy-linux-amd64"

  yq_bin="${cache_dir}/yq-${yq_version}"
  download_verified "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64" \
    "${yq_sha256_linux_amd64}" "${yq_bin}"
  chmod 0755 "${yq_bin}"
}

stage_unit_tests() {
  local target="$1" file
  rm -rf "${target}"
  mkdir -p "${target}"
  for file in "${metric_rule_files[@]}"; do
    "${yq_bin}" 'del(.groups[].rules[].annotations)' "${rules_dir}/${file}" >"${target}/${file}"
  done
  cp "${tests_dir}"/*.test.yaml "${target}/"
}

run_unit_tests() {
  local dir="$1" files="${2:-*.test.yaml}"
  (cd "${dir}" && "${work_dir}/bin/vmalert-tool-prod" unittest --disableAlertgroupLabel --files "${files}") >"${work_dir}/unittest.log" 2>&1
}

test_files_for() {
  grep -l "alertname: $1\$" "${tests_dir}"/*.test.yaml | xargs -n 1 basename | paste -sd, -
}

alert_has_test() {
  local alert="$1" condition="$2" file
  for file in "${tests_dir}"/*.test.yaml; do
    if [ "$("${yq_bin}" -r "[.tests[].alert_rule_test[] | select(.alertname == \"${alert}\") | (.exp_alerts | length) ${condition}] | any" "${file}")" = "true" ]; then
      return 0
    fi
  done
  return 1
}

check_rule_coverage() {
  local file alert
  for file in "${metric_rule_files[@]}"; do
    for alert in $("${yq_bin}" -r '.groups[].rules[].alert' "${rules_dir}/${file}"); do
      alert_has_test "${alert}" "> 0" || record_failure "rules: ${alert} has no test where it fires"
      if [ "${alert}" != Watchdog ]; then
        alert_has_test "${alert}" "== 0" || record_failure "rules: ${alert} has no test where it stays quiet"
      fi
    done
  done
}

check_rules() {
  stage_unit_tests "${work_dir}/unit"
  if run_unit_tests "${work_dir}/unit"; then
    pass "rules: every vmalert-tool unit test passes"
  else
    record_failure "rules: vmalert-tool unit tests fail: $(grep -v '^\s*$' "${work_dir}/unittest.log" | tail -n 20)"
  fi
  check_rule_coverage
}

check_load() {
  if "${work_dir}/bin/vmalert-prod" -dryRun -rule="${rules_dir}/cluster.yaml" -rule="${rules_dir}/supply-chain.yaml" >"${work_dir}/dryrun-metrics.log" 2>&1; then
    pass "load: vmalert loads the PromQL rules and their templates"
  else
    record_failure "load: vmalert refuses the PromQL rules: $(tail -n 5 "${work_dir}/dryrun-metrics.log")"
  fi
  if "${work_dir}/bin/vmalert-prod" -dryRun -rule.defaultRuleType=vlogs -rule="${rules_dir}/runtime.yaml" -rule="${rules_dir}/audit.yaml" >"${work_dir}/dryrun-logs.log" 2>&1; then
    pass "load: vmalert loads the LogsQL rules and their templates"
  else
    record_failure "load: vmalert refuses the LogsQL rules: $(tail -n 5 "${work_dir}/dryrun-logs.log")"
  fi
  if "${work_dir}/bin/amtool" check-config "${obs_dir}/alerting/alertmanager.yml" >"${work_dir}/amtool.log" 2>&1; then
    pass "load: amtool accepts the Alertmanager configuration"
  else
    record_failure "load: amtool refuses alertmanager.yml: $(tail -n 5 "${work_dir}/amtool.log")"
  fi
  if QUERY_TOKEN=unit-test "${work_dir}/bin/vmauth-prod" -dryRun -auth.config="${obs_dir}/query/vmauth.yaml" >"${work_dir}/vmauth.log" 2>&1; then
    pass "load: vmauth accepts the query endpoint configuration"
  else
    record_failure "load: vmauth refuses query/vmauth.yaml: $(tail -n 5 "${work_dir}/vmauth.log")"
  fi
}

replace_expression() {
  local source="$1" alert="$2" expression="$3" target="$4"
  "${yq_bin}" "(.groups[].rules[] | select(.alert == \"${alert}\") | .expr) = \"${expression}\"" "${source}" >"${target}"
}

mutate_rules() {
  local file alert expression mutant_dir="${work_dir}/mutant"
  for file in "${metric_rule_files[@]}"; do
    for alert in $("${yq_bin}" -r '.groups[].rules[].alert' "${rules_dir}/${file}"); do
      for expression in "vector(1) > 2" "vector(1)"; do
        [ "${alert}" = Watchdog ] && [ "${expression}" = "vector(1)" ] && continue
        stage_unit_tests "${mutant_dir}"
        replace_expression "${mutant_dir}/${file}" "${alert}" "${expression}" "${mutant_dir}/${file}.new"
        mv "${mutant_dir}/${file}.new" "${mutant_dir}/${file}"
        if run_unit_tests "${mutant_dir}" "$(test_files_for "${alert}")"; then
          record_failure "rule mutation ${alert} = ${expression}: the unit tests still pass"
        else
          pass "rule mutation ${alert} = ${expression}: the unit tests fail"
        fi
      done
    done
  done
}

relabel_config() {
  local source="$1" target="$2"
  {
    printf 'local.file "pod_targets" {\n\tfilename = "%s"\n\tdetector = "poll"\n}\n\n' "${pod_targets}"
    awk '/^discovery.relabel "pod_metrics" \{/ { found = 1 } found { print } found && /^}/ { exit }' "${source}" \
      | sed 's#targets = discovery.kubernetes.pods.targets#targets = encoding.from_json(local.file.pod_targets.content).targets#'
  } >"${target}"
}

relabel_output() {
  local config_dir="${work_dir}/relabel" pid waited=0
  rm -rf "${config_dir}" "${work_dir}/relabel-data"
  mkdir -p "${config_dir}"
  relabel_config "$1" "${config_dir}/relabel.alloy"
  "${work_dir}/bin/alloy-linux-amd64" run --server.http.listen-addr "127.0.0.1:${alloy_port}" \
    --storage.path "${work_dir}/relabel-data" "${config_dir}" >"${work_dir}/relabel.log" 2>&1 &
  pid="$!"
  background_pids+=("${pid}")
  until curl -fs -o /dev/null "http://127.0.0.1:${alloy_port}/-/ready"; do
    waited=$((waited + 1))
    if [ "${waited}" -ge 60 ] || ! kill -0 "${pid}" 2>/dev/null; then
      echo "Alloy did not start with the relabel rules; its log:" >&2
      tail -n 20 "${work_dir}/relabel.log" >&2
      return 1
    fi
    sleep 0.5
  done
  curl -fsS "http://127.0.0.1:${alloy_port}/api/v0/web/components/discovery.relabel.pod_metrics" \
    | jq -c '[.exports[] | select(.name == "output") | .value.value[] | [.value[] | {(.key): .value.value}] | add]'
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

relabel_mismatches() {
  local output="$1"
  jq -r --argjson got "${output}" '
    .expect[] as $want
    | ($got | map(select(.__meta_kubernetes_pod_name == $want.pod and .__meta_kubernetes_namespace == $want.namespace and (.__meta_kubernetes_pod_container_port_number // "") == $want.port)) | first) as $target
    | if $want.dropped == true then
        (if $target == null then empty else "\($want.namespace)/\($want.pod):\($want.port) should be dropped but became job \($target.job)" end)
      elif $target == null then "\($want.namespace)/\($want.pod) was dropped, want job \($want.labels.job)"
      else ($want.labels | to_entries[] | select(($target[.key] // "") != .value) | "\($want.namespace)/\($want.pod): \(.key) is \($target[.key] // "" | tostring), want \(.value)")
      end' "${pod_targets}"
}

check_relabel() {
  local output mismatches
  output="$(relabel_output "${metrics_config}")" || { record_failure "relabel: Alloy did not run the pod_metrics rules"; return; }
  mismatches="$(relabel_mismatches "${output}")"
  if [ -z "${mismatches}" ]; then
    pass "relabel: every pod in pod-targets.json gets its job, component and address, or is dropped"
  else
    record_failure "relabel: ${mismatches}"
  fi
}

mutate_relabel() {
  local mutation mutant="${work_dir}/metrics-mutant.alloy" output
  for mutation in "${relabel_mutations[@]}"; do
    sed -z "${mutation}" "${metrics_config}" >"${mutant}"
    if cmp -s "${mutant}" "${metrics_config}"; then
      record_failure "relabel mutation ${mutation}: matched nothing in metrics.alloy"
      continue
    fi
    output="$(relabel_output "${mutant}")" || { pass "relabel mutation ${mutation}: Alloy refuses the broken rules"; continue; }
    if [ -n "$(relabel_mismatches "${output}")" ]; then
      pass "relabel mutation ${mutation}: the relabel check fails"
    else
      record_failure "relabel mutation ${mutation}: the relabel check still passes"
    fi
  done
}

check_grafana_pin() {
  local version container operator
  version="$("${yq_bin}" -r '.spec.version' "${repo_root}/kubernetes/platform/observability/grafana/grafana.yaml")"
  container="$("${yq_bin}" -r '.spec.deployment.spec.template.spec.containers[] | select(.name == "grafana") | .image' "${repo_root}/kubernetes/platform/observability/grafana/grafana.yaml")"
  operator="$("${yq_bin}" -r '.spec.values.env[] | select(.name == "RELATED_IMAGE_GRAFANA") | .value' "${repo_root}/kubernetes/platform/observability/grafana-operator/helmrelease.yaml")"
  if [ "${version}" = "${container}" ] && [ "${version}" = "${operator}" ] && [[ "${version}" == *@sha256:* ]]; then
    pass "pins: the Grafana CR's version, its container image and the operator's default name one pinned image"
  else
    record_failure "pins: Grafana images differ (spec.version ${version}, container ${container}, RELATED_IMAGE_GRAFANA ${operator}); Renovate moves the container image, so set the other two to it"
  fi
}

install_binaries
check_grafana_pin
check_rules
check_load
check_relabel

if [ "${mutation_test}" = true ]; then
  mutate_rules
  mutate_relabel
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} check(s) failed" >&2
  exit 1
fi
echo "all observability metric checks passed"
