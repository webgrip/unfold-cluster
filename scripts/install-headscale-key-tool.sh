#!/usr/bin/env bash
set -euo pipefail

readonly usage="usage: install-headscale-key-tool.sh [ADMIN_SSH_TARGET]

Installs infra/templates/unfold-tailnet-key.sh and its sudoers rule on the
running unfold-headscale, as the admin user over SSH (default
admin@headscale.webgrip.dev). cloud-init installs both on a new server; a
server created before the program had its install and policy modes runs this
once, after which every change to the program, the Headscale policy and the
gateway key arrives through the infra apply. Running it again changes nothing."

case "${1:-}" in
  -h | --help) echo "$usage"; exit 0 ;;
esac

target="${1:-admin@headscale.webgrip.dev}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
tool="${repo}/infra/templates/unfold-tailnet-key.sh"
sudoers="${repo}/infra/templates/unfold-tailnet-key.sudoers"

sh -n "$tool"

ssh "$target" 'set -eu
  candidate=/usr/local/sbin/unfold-tailnet-key.candidate
  sudo install -m 0755 -o root -g root /dev/stdin "$candidate"
  sudo sh -n "$candidate"
  sudo mv "$candidate" /usr/local/sbin/unfold-tailnet-key' <"$tool"

ssh "$target" 'set -eu
  candidate=/etc/sudoers.d/unfold-tailnet-key.candidate
  sudo install -m 0440 -o root -g root /dev/stdin "$candidate"
  sudo visudo -cf "$candidate" >/dev/null
  sudo mv "$candidate" /etc/sudoers.d/unfold-tailnet-key' <"$sudoers"

echo "unfold-tailnet-key and its sudoers rule are installed on ${target#*@}"
