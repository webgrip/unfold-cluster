#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: plan-digest.sh [--normalized] < plan.txt

Reads a plan as tofu show -no-color prints it and prints its digest, the
SHA-256 the infra workflow's apply gate compares. With --normalized it prints
the text the digest is taken over instead.

The digest leaves out two kinds of line, and only inside the blocks of
terraform_data.control_plane_tailnet_key, worker_tailnet_key and
homelab_gateway_tailnet_key: the input line, whose value is only ever shown as
(sensitive value) or null, and the count of hidden unchanged attributes. Whether a
plan-only run could read a key the apply run mints decides only whether those
lines appear. Every other line, the action and triggers of those resources
included, is in the digest."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
  --normalized) mode=normalized ;;
  "") mode=digest ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

normalized() {
  awk '
    /^  # terraform_data\.(control_plane|worker|homelab_gateway)_tailnet_key(\["[^"]*"\])? / { in_key_block = 1 }
    in_key_block && /^    }$/ { in_key_block = 0 }
    in_key_block && /^ +[-+~] input += (\(sensitive value\)|null)( -> (\(sensitive value\)|null))?$/ { next }
    in_key_block && /^ +# \([0-9]+ unchanged attributes? hidden\)$/ { next }
    { print }
  '
}

if [ "$mode" = normalized ]; then
  normalized
else
  normalized | sha256sum | cut -d' ' -f1
fi
