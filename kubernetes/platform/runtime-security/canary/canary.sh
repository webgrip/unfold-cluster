#!/bin/sh
set -eu

sleep 20

cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
echo "must fire: read the service account token with cat"

cat /etc/hostname >/dev/null
echo "must not fire: read /etc/hostname with cat"

nc -z -w 3 192.0.2.10 3333 || true
echo "must fire: connect to 192.0.2.10:3333, a documentation address on a mining-pool port"

nc -z -w 3 10.66.0.10 53 || true
echo "must not fire: connect to the cluster DNS Service on 53"
