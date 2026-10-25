#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: set-etcd-backup-lifecycle.sh

Puts the etcd backup bucket's S3 lifecycle rule: snapshots under the
CronJob's prefix expire after a fixed number of days. Garage sets lifecycle
rules only through the S3 API, signed by a key that may write to the bucket,
so every infra apply sends the rule again; a rule changed or removed by hand
is back after the next apply. Then reads it back where the key may read it.

Environment: S3_ENDPOINT (e.g. https://s3-offsite.webgrip.dev), S3_REGION
(Garage's s3_region), AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (the etcd
write key). Optional: BUCKET (default unfold-cluster-etcd), PREFIX (default
unfold-main/), EXPIRE_DAYS (default 30)."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  "") ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

fail() {
  echo "::error::set-etcd-backup-lifecycle: $*" >&2
  exit 1
}

for name in S3_ENDPOINT S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [ -n "${!name:-}" ] || fail "$name is empty"
done
for tool in curl md5sum base64 mktemp; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done

bucket="${BUCKET:-unfold-cluster-etcd}"
prefix="${PREFIX:-unfold-main/}"
days="${EXPIRE_DAYS:-30}"
[[ "$days" =~ ^[1-9][0-9]*$ ]] || fail "EXPIRE_DAYS must be a whole number of days"
[[ "$prefix" =~ ^[a-z0-9-]+/$ ]] || fail "PREFIX must be one path segment ending in /"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077

printf '<LifecycleConfiguration><Rule><ID>expire-after-%s-days</ID><Status>Enabled</Status><Filter><Prefix>%s</Prefix></Filter><Expiration><Days>%s</Days></Expiration></Rule></LifecycleConfiguration>' \
  "$days" "$prefix" "$days" >"${workdir}/lifecycle.xml"
md5_escaped="$(md5sum "${workdir}/lifecycle.xml" | cut -d' ' -f1 | sed 's/../\\x&/g')"
md5="$(printf '%b' "$md5_escaped" | base64)"
printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >"${workdir}/curl.conf"
url="${S3_ENDPOINT%/}/${bucket}?lifecycle"

code="$(curl -sS --config "${workdir}/curl.conf" --aws-sigv4 "aws:amz:${S3_REGION}:s3" \
  -o "${workdir}/put.out" -w '%{http_code}' -X PUT \
  -H "Content-MD5: ${md5}" -H 'Content-Type: application/xml' \
  --data-binary @"${workdir}/lifecycle.xml" "$url" || true)"
case "$code" in
  200 | 204) ;;
  *) fail "PUT ${bucket}?lifecycle answered HTTP ${code}: $(head -c 300 "${workdir}/put.out" | tr '\n' ' ')" ;;
esac

code="$(curl -sS --config "${workdir}/curl.conf" --aws-sigv4 "aws:amz:${S3_REGION}:s3" \
  -o "${workdir}/get.out" -w '%{http_code}' "$url" || true)"
case "$code" in
  200)
    if ! grep -q "<Prefix>${prefix}</Prefix>" "${workdir}/get.out" || ! grep -q "<Days>${days}</Days>" "${workdir}/get.out" \
      || ! grep -q '<Status>Enabled</Status>' "${workdir}/get.out"; then
      fail "${bucket} answers a lifecycle rule other than the one just put: $(head -c 300 "${workdir}/get.out" | tr '\n' ' ')"
    fi
    echo "${bucket}: objects under ${prefix} expire after ${days} days (put and read back)"
    ;;
  403) echo "${bucket}: objects under ${prefix} expire after ${days} days (put; this write-only key may not read it back)" ;;
  *) fail "GET ${bucket}?lifecycle answered HTTP ${code}" ;;
esac
