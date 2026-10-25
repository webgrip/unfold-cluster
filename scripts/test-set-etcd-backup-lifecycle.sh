#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

readonly usage="usage: test-set-etcd-backup-lifecycle.sh

Runs scripts/set-etcd-backup-lifecycle.sh against a stubbed curl playing
Garage's S3 API, and checks the request it signs, that the secret key never
reaches the command line, and that a rule Garage does not keep fails the run."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/scripts/set-etcd-backup-lifecycle.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_DIR}/argv"
method=GET out="" body="" url="" config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    -H) echo "$2" >>"${STUB_DIR}/headers"; shift 2 ;;
    --aws-sigv4) echo "$2" >>"${STUB_DIR}/sigv4"; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
cp "$config" "${STUB_DIR}/config"
echo "${method} ${url}" >>"${STUB_DIR}/calls"
if [ "$method" = PUT ]; then
  if [ -n "${GARAGE_DROPS_RULE:-}" ]; then : >"${STUB_DIR}/stored"; else cp "$body" "${STUB_DIR}/stored"; fi
  : >"$out"; printf 200
else
  if [ -n "${GARAGE_REFUSES_READ:-}" ]; then : >"$out"; printf 403; exit 0; fi
  cp "${STUB_DIR}/stored" "$out"; printf 200
fi
STUB
chmod +x "${work}/bin/curl"

export STUB_DIR="$work" PATH="${work}/bin:${PATH}"
export S3_ENDPOINT="https://s3.invalid" S3_REGION="garage" AWS_ACCESS_KEY_ID="GKwritekey" AWS_SECRET_ACCESS_KEY="write-secret-value"
failures=0
expect() {
  local title="$1"
  shift
  if "$@"; then echo "ok: ${title}"; else echo "FAIL: ${title}"; failures=$((failures + 1)); fi
}

"$tool" >"${work}/out"
expect "the rule goes to the etcd bucket as a signed PUT" grep -qx 'PUT https://s3.invalid/unfold-cluster-etcd?lifecycle' "${work}/calls"
expect "it is signed for Garage's region" grep -qx 'aws:amz:garage:s3' "${work}/sigv4"
expect "Garage gets the Content-MD5 of the exact rule" grep -qx "Content-MD5: x5m78lVHFb7HpVhZLg5xzg==" "${work}/headers"
expect "snapshots under unfold-main/ expire after 30 days" bash -c 'grep -q "<Prefix>unfold-main/</Prefix>" "$1" && grep -q "<Days>30</Days>" "$1" && grep -q "<Status>Enabled</Status>" "$1"' _ "${work}/stored"
expect "the secret key never reaches the command line" bash -c '! grep -q write-secret-value "$1" && grep -q write-secret-value "$2"' _ "${work}/argv" "${work}/config"
expect "the rule is read back" grep -q 'put and read back' "${work}/out"

GARAGE_REFUSES_READ=1 "$tool" >"${work}/out"
expect "a key that may not read the rule back still succeeds" grep -q 'may not read it back' "${work}/out"

expect "a rule Garage does not keep fails the run" bash -c 'GARAGE_DROPS_RULE=1 "$1" >/dev/null 2>&1; [ "$?" -ne 0 ]' _ "$tool"
expect "a missing key fails before anything is sent" bash -c 'AWS_SECRET_ACCESS_KEY= "$1" >/dev/null 2>&1; [ "$?" -ne 0 ]' _ "$tool"

[ "$failures" -eq 0 ] || { echo "${failures} check(s) failed"; exit 1; }
echo "every check passed"
