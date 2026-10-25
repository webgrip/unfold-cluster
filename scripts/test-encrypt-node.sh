#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-encrypt-node.sh

Runs scripts/encrypt-node.sh against stubbed talosctl, kubectl and openssl that
play a three-control-plane cluster, and checks what it wipes, what it refuses
and in which order. Then runs the same checks against mutants of the script,
each with one safety step removed, and fails unless every mutant is caught."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
insecure="" node="" words=() wipes=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --insecure) insecure=1; shift ;;
    --nodes | -n) node="$2"; shift 2 ;;
    --talosconfig | --endpoints | -e | -o) shift 2 ;;
    --system-labels-to-wipe) wipes+=("$2"); shift 2 ;;
    -*) shift ;;
    *) words+=("$1"); shift ;;
  esac
done
echo "talosctl ${insecure:+insecure }${node} ${words[*]}${wipes:+ wipe ${wipes[*]}}" >>"${STUB_DIR}/calls"
if [ -e "${STUB_DIR}/booting" ]; then
  left="$(cat "${STUB_DIR}/booting")"
  if [ "$left" -gt 0 ]; then
    echo $((left - 1)) >"${STUB_DIR}/booting"
    exit 1
  fi
fi
if [ -n "$insecure" ]; then
  [ -e "${STUB_DIR}/maintenance" ]
  exit
fi
[ -e "${STUB_DIR}/maintenance" ] && [ "$node" = "${NODE_IP:-}" ] && exit 1
case "${words[*]}" in
  "get volumestatus") cat "${STUB_DIR}/volumes.json" ;;
  "etcd members")
    echo "NODE ID HOSTNAME PEER-URLS CLIENT-URLS LEARNER"
    for i in $(seq "$(cat "${STUB_DIR}/etcd_members")"); do echo "${node} id${i} cp-${i} https://p https://c false"; done
    ;;
  "etcd status") [ ! -e "${STUB_DIR}/etcd_down_${node}" ] ;;
  "etcd leave")
    [ -e "${STUB_DIR}/leave_noop" ] || echo $(( $(cat "${STUB_DIR}/etcd_members") - 1 )) >"${STUB_DIR}/etcd_members"
    ;;
  "reset") touch "${STUB_DIR}/maintenance" ;;
  kubeconfig*) echo "apiVersion: v1" >"${words[1]}" ;;
  *) echo "unexpected talosctl ${words[*]}" >&2; exit 3 ;;
esac
STUB

cat >"${work}/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
words=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kubeconfig | --server | --tls-server-name | -o) shift 2 ;;
    -*) shift ;;
    *) words+=("$1"); shift ;;
  esac
done
echo "kubectl ${words[*]}" >>"${STUB_DIR}/calls"
case "${words[*]}" in
  "get nodes") cat "${STUB_DIR}/nodes.json" ;;
  "get node "*) jq --arg n "${words[2]}" '.items[] | select(.metadata.name == $n)' "${STUB_DIR}/nodes.json" ;;
  "drain "*) [ ! -e "${STUB_DIR}/drain_fails" ] ;;
  "cordon "* | "uncordon "* | "delete node "*) ;;
  *) echo "unexpected kubectl ${words[*]}" >&2; exit 3 ;;
esac
STUB

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"${STUB_DIR}/calls"
[ ! -e "${STUB_DIR}/kms_down" ]
STUB
chmod +x "${work}/bin/"*

volumes() {
  local state="$1" ephemeral="$2" phase="${3:-ready}"
  local provider_state="" provider_ephemeral=""
  [ "$state" = luks2 ] && provider_state=luks2
  [ "$ephemeral" = luks2 ] && provider_ephemeral=luks2
  jq -n --arg p "$provider_state" --arg ph "$phase" '{metadata: {id: "STATE"}, spec: {phase: $ph, encryptionProvider: $p}}'
  [ "$ephemeral" = absent ] || jq -n --arg p "$provider_ephemeral" --arg ph "$phase" '{metadata: {id: "EPHEMERAL"}, spec: {phase: $ph, encryptionProvider: $p}}'
  jq -n '{metadata: {id: "IMAGECACHE"}, spec: {phase: "missing"}}'
}

nodes() {
  local not_ready="${1:-}" name
  {
    for name in unfold-cp-1 unfold-cp-2 unfold-cp-3 unfold-app-1; do
      local status=True
      [ "$name" = "$not_ready" ] && status=False
      jq -n --arg n "$name" --arg s "$status" '{metadata: {name: $n}, status: {conditions: [{type: "Ready", status: $s}]}}'
    done
  } | jq -s '{items: .}'
}

scenario() {
  stub="$(mktemp -d "${work}/scenario.XXXXXX")"
  : >"${stub}/calls"
  echo 3 >"${stub}/etcd_members"
  volumes plain plain >"${stub}/volumes.json"
  nodes >"${stub}/nodes.json"
  echo "talosconfig" >"${stub}/talosconfig"
}

run_node() {
  local script="$1" name="$2" ip="$3" role="$4" desired="$5"
  shift 5
  env PATH="${work}/bin:${PATH}" STUB_DIR="$stub" \
    NODE_NAME="$name" NODE_IP="$ip" NODE_ROLE="$role" DESIRED="$desired" \
    CONTROL_PLANE_IPS="198.51.100.11 198.51.100.12 198.51.100.13" \
    KUBE_TLS_SERVER_NAME=10.64.0.10 KMS_ENDPOINT=https://headscale.example.org:4050 \
    TALOSCONFIG="${TALOSCONFIG_OVERRIDE-${stub}/talosconfig}" \
    ENCRYPT_NODE_WAIT_SECONDS="${WAIT_SECONDS_OVERRIDE:-1}" ENCRYPT_NODE_POLL_SECONDS=0 \
    "$script" "$@" >"${stub}/out" 2>&1
}

cp3() { run_node "$1" unfold-cp-3 198.51.100.13 controlplane "$2" "${@:3}"; }
app1() { run_node "$1" unfold-app-1 198.51.100.21 worker "$2" "${@:3}"; }

called() { grep -qF -- "$1" "${stub}/calls"; }
not_called() { ! called "$1"; }
said() { grep -qF -- "$1" "${stub}/out"; }
in_order() {
  local previous=0 line pattern
  for pattern in "$@"; do
    line="$(grep -nF -- "$pattern" "${stub}/calls" | cut -d: -f1 | awk -v after="$previous" '$1 > after' | head -1)"
    [ -n "$line" ] || return 1
    previous="$line"
  done
}

failures=0
quiet=""
expect() {
  local name="$1"
  shift
  if "$@"; then
    [ -n "$quiet" ] || echo "ok: $name"
  else
    [ -n "$quiet" ] || echo "FAIL: $name"
    failures=$((failures + 1))
  fi
}

suite() {
  local s="$1"
  failures=0

  scenario; cp3 "$s" encrypted reinstall && local status=0 || status=$?
  expect "a healthy control plane is drained, leaves etcd, then is wiped" \
    in_order "kubectl cordon unfold-cp-3" "kubectl drain unfold-cp-3" "talosctl 198.51.100.13 etcd leave" "talosctl 198.51.100.13 reset wipe STATE EPHEMERAL" "kubectl delete node unfold-cp-3" "talosctl insecure 198.51.100.13 get disks"
  expect "the re-install of a healthy control plane succeeds" test "$status" -eq 0
  expect "the guard asks every etcd member before the wipe" in_order "talosctl 198.51.100.11 etcd status" "talosctl 198.51.100.12 etcd status" "talosctl 198.51.100.13 etcd status" "kubectl cordon unfold-cp-3"
  expect "the guard checks the KMS certificate before the wipe" in_order "curl https://headscale.example.org:4050/" "kubectl cordon unfold-cp-3"

  scenario; app1 "$s" encrypted reinstall || true
  expect "a worker is wiped without touching etcd" in_order "kubectl drain unfold-app-1" "talosctl 198.51.100.21 reset wipe STATE EPHEMERAL"
  expect "a worker never leaves etcd" not_called "etcd leave"

  scenario; volumes luks2 luks2 >"${stub}/volumes.json"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "an encrypted node is left alone" bash -c '[ "$1" -eq 0 ] && ! grep -qE "drain|reset|leave" "$2"' _ "$status" "${stub}/calls"
  expect "it says why it did nothing" said "nothing to do"

  scenario; volumes luks2 luks2 waiting >"${stub}/volumes.json"; cp3 "$s" encrypted reinstall || true
  expect "an encrypted node still unlocking is not wiped again" not_called "reset"

  scenario; touch "${stub}/maintenance"; app1 "$s" encrypted reinstall && status=0 || status=$?
  expect "a new node in maintenance mode is not wiped" bash -c '[ "$1" -eq 0 ] && ! grep -qE "drain|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/maintenance"; echo 4 >"${stub}/booting"; WAIT_SECONDS_OVERRIDE=60 TALOSCONFIG_OVERRIDE="" app1 "$s" encrypted reinstall && status=0 || status=$?
  expect "a new server still booting is waited for, then left to its first config" bash -c '[ "$1" -eq 0 ] && ! grep -qE "drain|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; echo 1000000 >"${stub}/booting"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "a node that never answers fails the run and is not wiped" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; nodes unfold-cp-2 >"${stub}/nodes.json"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "a node that is not Ready elsewhere stops the run before the drain" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"
  expect "the refusal names the unhealthy node" said "unfold-cp-2"

  scenario; echo 2 >"${stub}/etcd_members"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "etcd with a missing member stops the run" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/etcd_down_198.51.100.12"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "an etcd member that does not answer stops the run" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/kms_down"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "an unreachable KMS stops an encrypting run" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/kms_down"; volumes luks2 luks2 >"${stub}/volumes.json"; app1 "$s" plain reinstall && status=0 || status=$?
  expect "going back to plain volumes does not need the KMS" bash -c '[ "$1" -eq 0 ] && grep -q "reset wipe" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/drain_fails"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "a drain that does not finish uncordons and wipes nothing" bash -c '[ "$1" -ne 0 ] && grep -q "kubectl uncordon unfold-cp-3" "$2" && ! grep -qE "etcd leave|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; touch "${stub}/leave_noop"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "an etcd leave that did not shrink the membership stops before the wipe" bash -c '[ "$1" -ne 0 ] && ! grep -q "reset" "$2"' _ "$status" "${stub}/calls"

  scenario; volumes plain absent >"${stub}/volumes.json"; cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "a node that reports only one of its volumes is not wiped" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; TALOSCONFIG_OVERRIDE="" cp3 "$s" encrypted reinstall && status=0 || status=$?
  expect "a configured node is not touched without a talosconfig" bash -c '[ "$1" -ne 0 ] && ! grep -qE "cordon|reset" "$2"' _ "$status" "${stub}/calls"

  scenario; volumes luks2 luks2 >"${stub}/volumes.json"; cp3 "$s" encrypted rejoin && status=0 || status=$?
  expect "a rejoined control plane with LUKS2 volumes, Ready and three etcd members passes" bash -c '[ "$1" -eq 0 ] && grep -q "kubectl uncordon unfold-cp-3" "$2"' _ "$status" "${stub}/calls"

  scenario; cp3 "$s" encrypted rejoin && status=0 || status=$?
  expect "a node that came back with plain volumes fails the rejoin" bash -c '[ "$1" -ne 0 ] && ! grep -q uncordon "$2"' _ "$status" "${stub}/calls"

  scenario; volumes luks2 luks2 >"${stub}/volumes.json"; echo 2 >"${stub}/etcd_members"; cp3 "$s" encrypted rejoin && status=0 || status=$?
  expect "a control plane that did not rejoin etcd fails the rejoin" test "$status" -ne 0

  scenario; volumes luks2 luks2 >"${stub}/volumes.json"; nodes unfold-app-1 >"${stub}/nodes.json"; app1 "$s" encrypted rejoin && status=0 || status=$?
  expect "a worker whose Node is not Ready fails the rejoin" test "$status" -ne 0

  scenario; TALOSCONFIG_OVERRIDE="" cp3 "$s" plain rejoin && status=0 || status=$?
  expect "the first apply of an empty state skips the rejoin with a warning" bash -c '[ "$1" -eq 0 ] && grep -q "::warning::" "$2"' _ "$status" "${stub}/out"

  scenario; cp3 "$s" plain kms && status=0 || status=$?
  expect "the KMS check passes a KMS that answers" test "$status" -eq 0
  scenario; touch "${stub}/kms_down"; cp3 "$s" plain kms && status=0 || status=$?
  expect "the KMS check fails a KMS that does not answer" test "$status" -ne 0

  scenario; cp3 "$s" plain guard && status=0 || status=$?
  expect "the guard passes a healthy cluster" test "$status" -eq 0

  scenario; volumes luks2 luks2 >"${stub}/volumes.json"; cp3 "$s" plain status 198.51.100.13 || true
  expect "status reports LUKS2 volumes" bash -c 'grep -q "^STATE=luks2:ready$" "$1" && grep -q "^encrypted:" "$1"' _ "${stub}/out"

  scenario; cp3 "$s" plain status 198.51.100.13 || true
  expect "status reports plain volumes" bash -c 'grep -q "^STATE=none:ready$" "$1" && grep -q "^plain:" "$1"' _ "${stub}/out"
}

script="${repo}/scripts/encrypt-node.sh"
suite "$script"
[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed against the real script"; exit 1; }
echo "every check passed against the real script"

mutate() {
  local name="$1" from="$2" to="$3" mutant="${work}/mutant.sh"
  grep -qF -- "$from" "$script" || { echo "FAIL: mutant '${name}' no longer applies; update the test"; return 1; }
  python3 -c 'import sys; p,f,t,o=sys.argv[1:]; s=open(p).read(); open(o,"w").write(s.replace(f,t,1))' "$script" "$from" "$to" "$mutant"
  chmod +x "$mutant"
  quiet=1
  suite "$mutant"
  quiet=""
  if [ "$failures" -eq 0 ]; then
    echo "FAIL: mutant '${name}' survived"
    return 1
  fi
  echo "ok: mutant '${name}' caught by ${failures} check(s)"
}

survivors=0
mutate "no guard before the drain" $'  require_healthy_cluster\n  drain' '  drain' || survivors=$((survivors + 1))
mutate "no etcd leave" $'    leave_etcd\n' $'    :\n' || survivors=$((survivors + 1))
mutate "quorum after the leave unchecked" '[ "$members" -eq "$((${#cps[@]} - 1))" ] ||' 'true ||' || survivors=$((survivors + 1))
mutate "maintenance mode not recognised" '  if in_maintenance; then' '  if false; then' || survivors=$((survivors + 1))
mutate "no uncordon after a failed drain" '    kube uncordon "$NODE_NAME" >/dev/null || true' '    :' || survivors=$((survivors + 1))
mutate "rejoin accepts any volumes" '  [ "$actual" = "$(expected_encryption)" ]' '  true' || survivors=$((survivors + 1))
mutate "no KMS check" 'kms_answers || fail' 'true || fail' || survivors=$((survivors + 1))
mutate "partial volume status wiped" '*) fail "the node reports' '*) : "the node reports' || survivors=$((survivors + 1))
mutate "etcd member status unchecked" 'etcd_members_answer || fail "refusing' 'true || fail "refusing' || survivors=$((survivors + 1))
mutate "no wait for a booting server" '  wait_until "answers on the Talos API" node_answers' '  :' || survivors=$((survivors + 1))
mutate "not-Ready nodes ignored" '[ -z "$not_ready" ] || fail' 'true || fail' || survivors=$((survivors + 1))
mutate "decision on phase instead of provider" '  if [ "$providers" = "$(providers_of "$(expected_encryption)")" ]; then' '  if [ "$actual" = "$(expected_encryption)" ]; then' || survivors=$((survivors + 1))

[ "$survivors" -eq 0 ] || { echo "${survivors} mutant(s) survived"; exit 1; }
echo "every mutant was caught"
