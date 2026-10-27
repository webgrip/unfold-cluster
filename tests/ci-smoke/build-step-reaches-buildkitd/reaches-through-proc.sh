#!/bin/sh
set -u
for root in /proc/[0-9]*/root; do
  if head -c 1 "$root/run/buildkit/server/key.pem" >/dev/null 2>&1; then
    echo "a build step read the server key through $root" >&2
    exit 1
  fi
  socket="$root/run/user/1000/buildkit/buildkitd.sock"
  if [ -S "$socket" ] && buildctl --addr "unix://$socket" debug workers >/dev/null 2>&1; then
    echo "a build step drove buildkitd through $socket" >&2
    exit 1
  fi
done
