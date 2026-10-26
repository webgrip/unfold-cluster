#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: test-observability-logs.sh [--mutation-test]

Proves the log half of the observability stack end to end, without a cluster:

  pipelines  runs Grafana Alloy at the version alloy-logs runs, with the real
             kubernetes/platform/observability/app/alloy/logs/pipelines.alloy and
             talos.alloy, file sources and sinks from tests/observability/alloy,
             and three real VictoriaLogs servers (Unfold's logs and audit stores
             and the homelab copy). It feeds every fixture in
             tests/observability/fixtures (pod, Talos service and kernel lines
             over TCP like Talos sends them, the API audit log, Hubble's egress
             flow log, Tetragon's export file), then checks each record in
             tests/observability/expectations.json field by field.
  rules      sends every LogsQL rule in alerting/rules/runtime.yaml (logs
             store) and alerting/rules/audit.yaml (audit store) to its store
             at the time named in expectations.json and requires the alert's
             labels, and the absence of the labels it must not report; a rule
             without an expectation fails.
  format     alloy fmt leaves every .alloy file unchanged, and alloy validate
             accepts the alloy-logs and alloy-metrics configurations.

  --mutation-test  also breaks the pipeline in each way listed below and
                   requires a record check to fail, and breaks each rule as
                   its expectation says and requires the rule check to fail.

Downloads Alloy, VictoriaLogs and yq at pinned versions, checksum-verified,
into a cache directory. Needs curl, jq, sha256sum, tar and unzip."

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly obs_dir="${repo_root}/kubernetes/platform/observability/app"
readonly logs_config_dir="${obs_dir}/alloy/logs"
readonly metrics_config="${obs_dir}/alloy/metrics/metrics.alloy"
readonly runtime_rules="${obs_dir}/alerting/rules/runtime.yaml"
readonly audit_rules="${obs_dir}/alerting/rules/audit.yaml"
readonly test_dir="${repo_root}/tests/observability"
readonly expectations="${test_dir}/expectations.json"

# renovate: datasource=github-releases depName=grafana/alloy
readonly alloy_version="v1.21.2"
readonly alloy_sha256_linux_amd64_zip="1eadb46a0640127184250173acd9b4145e4d590680db37ffe66fa8afd07f04cf"

# renovate: datasource=github-releases depName=VictoriaMetrics/VictoriaLogs
readonly victorialogs_version="v1.53.0"
readonly victorialogs_sha256_linux_amd64="55feba89713cafa952673f91b8b38e7701bb0290989263da671b47a0de16edd3"

# renovate: datasource=github-releases depName=mikefarah/yq
readonly yq_version="v4.53.6"
readonly yq_sha256_linux_amd64="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385"

readonly base_port="${OBSERVABILITY_TEST_PORT:-19500}"
readonly logs_port="${base_port}"
readonly audit_port="$((base_port + 1))"
readonly homelab_port="$((base_port + 2))"
readonly alloy_port="$((base_port + 3))"
readonly talos_services_port=6050
readonly talos_kernel_port=6051

readonly pipeline_mutations=(
  's/to_string(process.in_init_tree || `false`)/to_string(`true`)/'
  's/(,\\"node_labels\\"/(,\\"node_label\\"/'
  "s/policy             = \"policy_name || ''\"/policy             = \"''\"/"
  "s/sock_arg.daddr || ''/sock_arg.saddr || ''/"
  's/(file_arg.path || path_arg.path)/(path_arg.path)/'
  's/{{ else }}host{{ end }}/{{ else }}{{ end }}/'
  's/value  = "routine-read"/value  = "never"/'
  's/source.workloads\[0\].name || //'
  "s/ || 'kernel'//"
  's/stage.cri { }/stage.static_labels { values = { cri = "off" } }/'
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
work_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/observability-logs-test.XXXXXX")"
readonly work_dir
background_pids=()
failures=()

stop_all() {
  stop_processes
  [ -n "${KEEP_WORK_DIR:-}" ] || rm -rf "${work_dir}"
}
trap stop_all EXIT

stop_processes() {
  local pid
  for pid in "${background_pids[@]}"; do
    kill -KILL "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  background_pids=()
}

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
  local alloy_zip="${cache_dir}/alloy-${alloy_version}-linux-amd64.zip"
  download_verified "https://github.com/grafana/alloy/releases/download/${alloy_version}/alloy-linux-amd64.zip" \
    "${alloy_sha256_linux_amd64_zip}" "${alloy_zip}"
  unzip -q -o "${alloy_zip}" -d "${work_dir}/bin"
  alloy_bin="${work_dir}/bin/alloy-linux-amd64"
  chmod 0755 "${alloy_bin}"

  local vl_archive="${cache_dir}/victoria-logs-linux-amd64-${victorialogs_version}.tar.gz"
  download_verified "https://github.com/VictoriaMetrics/VictoriaLogs/releases/download/${victorialogs_version}/victoria-logs-linux-amd64-${victorialogs_version}.tar.gz" \
    "${victorialogs_sha256_linux_amd64}" "${vl_archive}"
  tar -xzf "${vl_archive}" -C "${work_dir}/bin" victoria-logs-prod
  victorialogs_bin="${work_dir}/bin/victoria-logs-prod"

  yq_bin="${cache_dir}/yq-${yq_version}"
  download_verified "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_amd64" \
    "${yq_sha256_linux_amd64}" "${yq_bin}"
  chmod 0755 "${yq_bin}"
}

store_url() {
  case "$1" in
    logs) echo "http://127.0.0.1:${logs_port}" ;;
    audit) echo "http://127.0.0.1:${audit_port}" ;;
    homelab) echo "http://127.0.0.1:${homelab_port}" ;;
  esac
}

wait_for_http() {
  local url="$1" waited=0
  until curl -fs -o /dev/null "${url}"; do
    waited=$((waited + 1))
    [ "${waited}" -lt 60 ] || return 1
    sleep 0.5
  done
}

start_stores() {
  local name port
  for name in logs audit homelab; do
    port="${logs_port}"
    [ "${name}" = audit ] && port="${audit_port}"
    [ "${name}" = homelab ] && port="${homelab_port}"
    "${victorialogs_bin}" -storageDataPath "${work_dir}/data-${name}" -httpListenAddr "127.0.0.1:${port}" \
      -retentionPeriod 100y >"${work_dir}/vl-${name}.log" 2>&1 &
    background_pids+=("$!")
  done
  for name in logs audit homelab; do
    wait_for_http "$(store_url "${name}")/health" || { echo "VictoriaLogs ${name} did not start" >&2; exit 1; }
  done
}

start_alloy() {
  local pipelines="$1" config_dir="${work_dir}/alloy-config"
  rm -rf "${config_dir}" "${work_dir}/alloy-data"
  mkdir -p "${config_dir}"
  cp "${pipelines}" "${config_dir}/pipelines.alloy"
  cp "${logs_config_dir}/talos.alloy" "${config_dir}/talos.alloy"
  cp "${test_dir}/alloy/sources.alloy" "${test_dir}/alloy/sinks.alloy" "${config_dir}/"
  NODE_NAME=unfold-cp-1 \
    FIXTURE_DIR="${work_dir}/fixtures" \
    LOGS_URL="$(store_url logs)" AUDIT_URL="$(store_url audit)" HOMELAB_URL="$(store_url homelab)" \
    "${alloy_bin}" run --stability.level=experimental \
    --server.http.listen-addr "127.0.0.1:${alloy_port}" \
    --storage.path "${work_dir}/alloy-data" "${config_dir}" >"${work_dir}/alloy.log" 2>&1 &
  background_pids+=("$!")
  wait_for_http "http://127.0.0.1:${alloy_port}/-/ready" || { echo "Alloy did not become ready; its log:" >&2; tail -n 30 "${work_dir}/alloy.log" >&2; exit 1; }
}

send_over_tcp() {
  local port="$1" file="$2" waited=0
  until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    waited=$((waited + 1))
    [ "${waited}" -lt 40 ] || { echo "nothing listens on ${port}" >&2; return 1; }
    sleep 0.25
  done
  exec 3<>"/dev/tcp/127.0.0.1/${port}"
  cat "${file}" >&3
  exec 3>&-
}

logsql_query() {
  curl -fsS "$(store_url "$1")/select/logsql/query" --data-urlencode "query=$2" --data-urlencode "limit=10" 2>/dev/null || true
}

ingest_fixtures() {
  local pipelines="$1"
  stop_processes
  rm -rf "${work_dir}"/data-* "${work_dir}/fixtures"
  cp -r "${test_dir}/fixtures" "${work_dir}/fixtures"
  start_stores
  start_alloy "${pipelines}"
  send_over_tcp "${talos_services_port}" "${work_dir}/fixtures/talos-services.jsonl"
  send_over_tcp "${talos_kernel_port}" "${work_dir}/fixtures/talos-kernel.jsonl"
  local waited=0 expected_streams
  expected_streams="$(jq '[.records[] | select(.count == null)] | length' "${expectations}")"
  until [ "$(count_present_records)" -ge "${expected_streams}" ] || [ "${waited}" -ge 40 ]; do
    waited=$((waited + 1))
    sleep 0.5
  done
  sleep 2
}

count_present_records() {
  local present=0 index total store query
  total="$(jq '.records | length' "${expectations}")"
  for ((index = 0; index < total; index++)); do
    jq -e ".records[${index}].count == null" "${expectations}" >/dev/null || continue
    store="$(jq -r ".records[${index}].store" "${expectations}")"
    query="$(jq -r ".records[${index}].query" "${expectations}")"
    [ -n "$(logsql_query "${store}" "${query}")" ] && present=$((present + 1))
  done
  echo "${present}"
}

check_records() {
  local mode="$1" index total name store query result expected_count actual_count field expected actual
  local broken=0
  total="$(jq '.records | length' "${expectations}")"
  for ((index = 0; index < total; index++)); do
    name="$(jq -r ".records[${index}].name" "${expectations}")"
    store="$(jq -r ".records[${index}].store" "${expectations}")"
    query="$(jq -r ".records[${index}].query" "${expectations}")"
    result="$(logsql_query "${store}" "${query}")"
    expected_count="$(jq -r ".records[${index}].count // \"\"" "${expectations}")"
    if [ -n "${expected_count}" ]; then
      actual_count="$(printf '%s' "${result}" | grep -c . || true)"
      if [ "${actual_count}" != "${expected_count}" ]; then
        broken=$((broken + 1))
        [ "${mode}" = expect-pass ] && record_failure "record: ${name}: ${actual_count} records for '${query}' in ${store}, want ${expected_count}"
      elif [ "${mode}" = expect-pass ]; then
        pass "record: ${name}"
      fi
      continue
    fi
    if [ -z "${result}" ]; then
      broken=$((broken + 1))
      [ "${mode}" = expect-pass ] && record_failure "record: ${name}: nothing in ${store} matches '${query}'"
      continue
    fi
    local record_ok=true
    while IFS=$'\t' read -r field expected; do
      actual="$(printf '%s' "${result}" | head -n 1 | jq -r --arg field "${field}" '.[$field] // ""')"
      if [ "${actual}" != "${expected}" ]; then
        record_ok=false
        [ "${mode}" = expect-pass ] && record_failure "record: ${name}: ${field} is '${actual}', want '${expected}'"
      fi
    done < <(jq -r ".records[${index}].fields | to_entries[] | [.key, .value] | @tsv" "${expectations}")
    if [ "${record_ok}" = true ]; then
      [ "${mode}" = expect-pass ] && pass "record: ${name}"
    else
      broken=$((broken + 1))
    fi
  done
  echo "${broken}" >"${work_dir}/broken-records"
}

rule_expression() {
  "${yq_bin}" -r ".groups[].rules[] | select(.alert == \"$2\") | .expr" "$1"
}

rule_store() {
  jq -r ".rules[\"$1\"].store // \"logs\"" "${expectations}"
}

rule_result() {
  curl -fsS "$(store_url "${3:-logs}")/select/logsql/stats_query" --data-urlencode "query=$1" --data-urlencode "time=$2" 2>/dev/null \
    | jq -c '.data.result // []' 2>/dev/null || echo '[]'
}

rule_fires_with_labels() {
  local expression="$1" at="$2" alert="$3"
  rule_result "${expression}" "${at}" "$(rule_store "${alert}")" | jq -e --argjson want "$(jq ".rules[\"${alert}\"].labels" "${expectations}")" \
    'any(.[]; .metric as $m | ($want | to_entries | all(.value == ($m[.key] // ""))))' >/dev/null
}

rules_file_of() {
  if "${yq_bin}" -e ".groups[].rules[] | select(.alert == \"$1\")" "${audit_rules}" >/dev/null 2>&1; then
    echo "${audit_rules}"
  else
    echo "${runtime_rules}"
  fi
}

check_rules() {
  local rules_file="$1" alert expression at quiet
  for alert in $("${yq_bin}" -r '.groups[].rules[].alert' "${rules_file}"); do
    if ! jq -e ".rules[\"${alert}\"]" "${expectations}" >/dev/null; then
      record_failure "rule: ${alert} has no expectation in tests/observability/expectations.json"
      continue
    fi
    expression="$(rule_expression "${rules_file}" "${alert}")"
    at="$(jq -r ".rules[\"${alert}\"].fires_at" "${expectations}")"
    if rule_fires_with_labels "${expression}" "${at}" "${alert}"; then
      pass "rule: ${alert} fires at ${at} with the expected labels"
    else
      record_failure "rule: ${alert} does not fire at ${at} with $(jq -c ".rules[\"${alert}\"].labels" "${expectations}"); got $(rule_result "${expression}" "${at}" "$(rule_store "${alert}")")"
    fi
    if jq -e ".rules[\"${alert}\"].absent_labels" "${expectations}" >/dev/null; then
      if rule_result "${expression}" "${at}" "$(rule_store "${alert}")" | jq -e --argjson unwanted "$(jq ".rules[\"${alert}\"].absent_labels" "${expectations}")" \
        'any(.[]; .metric as $m | ($unwanted | to_entries | all(.value == ($m[.key] // ""))))' >/dev/null; then
        record_failure "rule: ${alert} also reports $(jq -c ".rules[\"${alert}\"].absent_labels" "${expectations}"), which it must not"
      else
        pass "rule: ${alert} does not report $(jq -c ".rules[\"${alert}\"].absent_labels" "${expectations}")"
      fi
    fi
    quiet="$(jq -r ".rules[\"${alert}\"].quiet_at // \"\"" "${expectations}")"
    if [ -n "${quiet}" ]; then
      if [ "$(rule_result "${expression}" "${quiet}" "$(rule_store "${alert}")")" = "[]" ]; then
        pass "rule: ${alert} stays quiet at ${quiet}"
      else
        record_failure "rule: ${alert} fires at ${quiet}, where it must stay quiet"
      fi
    fi
  done
}

mutate_rules() {
  local alert mutation mutant expression at
  for alert in $(jq -r '.rules | keys[]' "${expectations}"); do
    mutation="$(jq -r ".rules[\"${alert}\"].mutation" "${expectations}")"
    mutant="${work_dir}/rule-mutant.yaml"
    expression="$(rule_expression "$(rules_file_of "${alert}")" "${alert}")"
    printf '%s\n' "${expression}" | sed "${mutation}" >"${mutant}"
    if [ "$(cat "${mutant}")" = "${expression}" ]; then
      record_failure "rule mutation ${alert}: '${mutation}' matched nothing in its expression"
      continue
    fi
    at="$(jq -r ".rules[\"${alert}\"].fires_at" "${expectations}")"
    if rule_fires_with_labels "$(cat "${mutant}")" "${at}" "${alert}"; then
      record_failure "rule mutation ${alert}: '${mutation}' still fires with the expected labels"
    else
      pass "rule mutation ${alert}: '${mutation}' no longer fires"
    fi
  done
}

mutate_pipelines() {
  local mutation mutant="${work_dir}/pipelines-mutant.alloy"
  for mutation in "${pipeline_mutations[@]}"; do
    sed "${mutation}" "${logs_config_dir}/pipelines.alloy" >"${mutant}"
    if cmp -s "${mutant}" "${logs_config_dir}/pipelines.alloy"; then
      record_failure "pipeline mutation ${mutation}: matched nothing in pipelines.alloy"
      continue
    fi
    ingest_fixtures "${mutant}"
    check_records expect-fail >/dev/null
    if [ "$(cat "${work_dir}/broken-records")" -gt 0 ]; then
      pass "pipeline mutation ${mutation}: $(cat "${work_dir}/broken-records") record check(s) fail"
    else
      record_failure "pipeline mutation ${mutation}: every record check still passes"
    fi
  done
}

check_format() {
  local file formatted
  for file in "${logs_config_dir}"/*.alloy "${metrics_config}" "${test_dir}"/alloy/*.alloy; do
    formatted="$("${alloy_bin}" fmt "${file}" 2>&1)" || { record_failure "format: alloy fmt refuses ${file#"${repo_root}/"}: ${formatted}"; continue; }
    if [ "${formatted}" = "$(cat "${file}")" ]; then
      pass "format: ${file#"${repo_root}/"} is formatted"
    else
      record_failure "format: ${file#"${repo_root}/"} differs from alloy fmt"
    fi
  done
  if NODE_NAME=validate "${alloy_bin}" validate --stability.level=experimental "${logs_config_dir}" >"${work_dir}/validate-logs.log" 2>&1; then
    pass "format: alloy validate accepts the alloy-logs configuration"
  else
    record_failure "format: alloy validate refuses the alloy-logs configuration: $(tail -n 5 "${work_dir}/validate-logs.log")"
  fi
  if "${alloy_bin}" validate "${metrics_config}" >"${work_dir}/validate-metrics.log" 2>&1; then
    pass "format: alloy validate accepts the alloy-metrics configuration"
  else
    record_failure "format: alloy validate refuses the alloy-metrics configuration: $(tail -n 5 "${work_dir}/validate-metrics.log")"
  fi
}

install_binaries
check_format
ingest_fixtures "${logs_config_dir}/pipelines.alloy"
check_records expect-pass
check_rules "${runtime_rules}"
check_rules "${audit_rules}"

if [ "${mutation_test}" = true ]; then
  mutate_rules
  mutate_pipelines
fi

if [ "${#failures[@]}" -gt 0 ]; then
  echo "${#failures[@]} check(s) failed" >&2
  exit 1
fi
echo "all observability log checks passed"
