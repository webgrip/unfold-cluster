#!/usr/bin/env bash
set -euo pipefail

readonly encrypted_snapshot="${1:?usage: verify-etcd-snapshot.sh <snapshot.snap.age>}"
readonly age_identity_file="${AGE_IDENTITY_FILE:?AGE_IDENTITY_FILE must point at the age private key}"
readonly required_keys="${REQUIRED_KEYS:-/registry/namespaces/kube-system /registry/namespaces/flux-system}"
readonly corrupt_on_purpose="${CORRUPT_ON_PURPOSE:-false}"

workdir="$(mktemp -d)"
etcd_pid=""

stop_etcd_and_clean_up() {
  if [ -n "$etcd_pid" ]; then
    kill "$etcd_pid" 2>/dev/null || true
    wait "$etcd_pid" 2>/dev/null || true
  fi
  rm -rf "$workdir"
}
trap stop_etcd_and_clean_up EXIT

fail() {
  echo "::error::$*" >&2
  exit 1
}

decrypt_snapshot() {
  age --decrypt --identity "$age_identity_file" --output "$workdir/snapshot.db" "$encrypted_snapshot" \
    || fail "cannot decrypt $encrypted_snapshot with the restore key"
}

flip_bytes_in_the_middle() {
  local size
  size="$(stat -c %s "$workdir/snapshot.db")"
  printf '\xde\xad\xbe\xef\xde\xad\xbe\xef' \
    | dd of="$workdir/snapshot.db" bs=1 seek=$((size / 2)) conv=notrunc status=none
  echo "corrupted the decrypted snapshot on purpose; every check after this must fail"
}

report_snapshot_status() {
  local status
  status="$(etcdutl snapshot status "$workdir/snapshot.db" --write-out=json)" \
    || fail "etcdutl cannot read the snapshot"
  echo "snapshot status: $status"
  local total_keys
  total_keys="$(printf '%s' "$status" | sed -n 's/.*"totalKey":\([0-9]*\).*/\1/p')"
  [ "${total_keys:-0}" -gt 0 ] || fail "the snapshot holds no keys"
}

restore_into_a_fresh_data_dir() {
  etcdutl snapshot restore "$workdir/snapshot.db" \
    --data-dir "$workdir/restored" \
    --name restore-check \
    --initial-cluster restore-check=http://127.0.0.1:12380 \
    --initial-advertise-peer-urls http://127.0.0.1:12380 \
    >"$workdir/restore.log" 2>&1 \
    || { cat "$workdir/restore.log" >&2; fail "etcdutl snapshot restore failed: the snapshot is damaged"; }
}

start_etcd_on_the_restored_data() {
  etcd --name restore-check \
    --data-dir "$workdir/restored" \
    --listen-client-urls http://127.0.0.1:12379 \
    --advertise-client-urls http://127.0.0.1:12379 \
    --listen-peer-urls http://127.0.0.1:12380 \
    --initial-advertise-peer-urls http://127.0.0.1:12380 \
    --initial-cluster restore-check=http://127.0.0.1:12380 \
    >"$workdir/etcd.log" 2>&1 &
  etcd_pid=$!
  local attempt
  for attempt in $(seq 1 30); do
    if etcdctl --endpoints=http://127.0.0.1:12379 endpoint health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  cat "$workdir/etcd.log" >&2
  fail "etcd did not become healthy on the restored data after ${attempt}s"
}

require_cluster_keys() {
  local key
  for key in $required_keys; do
    [ "$(etcdctl --endpoints=http://127.0.0.1:12379 get "$key" --keys-only --print-value-only=false | head -n 1)" = "$key" ] \
      || fail "the restored etcd has no $key"
    echo "found $key"
  done
  local registry_keys
  registry_keys="$(etcdctl --endpoints=http://127.0.0.1:12379 get /registry/ --prefix --keys-only | grep -c '^/registry/' || true)"
  echo "restored etcd serves $registry_keys Kubernetes objects"
}

decrypt_snapshot
if [ "$corrupt_on_purpose" = "true" ]; then
  flip_bytes_in_the_middle
fi
report_snapshot_status
restore_into_a_fresh_data_dir
start_etcd_on_the_restored_data
require_cluster_keys
echo "restore check passed for $(basename "$encrypted_snapshot")"
