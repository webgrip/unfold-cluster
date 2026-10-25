---
status: accepted
date: 2026-10-25
---

# ADR 0003: Disk keys come from a KMS on unfold-headscale, for cloud and metal nodes alike

## Context and problem statement

RFC 0001 decided that every node's Talos STATE and EPHEMERAL volumes are LUKS2, with keys that
never sit on the disk they open. PR #54 rendered that config and left it off, because no key
source existed. Talos 1.14 offers four key sources: `static`, `nodeID`, `kms` and `tpm`. This
record picks one per node class and says what it protects.

Two node classes exist:

* **Cloud servers** (three CX23 control planes, the CX33 `unfold-app-1`, later the CX43 CI node).
  Hetzner Cloud has no virtual TPM and no SecureBoot.
* **The AX41** (`unfold-metal-1`, being built in PR #75): a Ryzen with a firmware TPM, installed
  by writing a disk image from Hetzner's rescue system and reinstalled the same way when
  `install_generation` is raised.

## Facts the decision rests on

Each was checked on 2026-10-25.

* **The reference KMS authorises nobody.** `siderolabs/kms-client` (`cmd/kms-server`, tag v0.2.0,
  commit 296bf9a) seals with AES-256-GCM under one master key for every node. `Unseal` never
  checks the node UUID it is sent; it only logs it. Anyone who can reach the port with the sealed
  blob from a LUKS2 header gets the passphrase back. The firewall in front of it is the whole of
  its access control. RFC 0001's "authorises by node UUID" overstated it.
* **The reference KMS ships as a container image only.** v0.2.0 has no release binary; the image
  is `ghcr.io/siderolabs/kms-server:v0.2.0@sha256:db6ee3a7…`. The last binary release is v0.1.0
  from 2023.
* **Talos needs the KMS before it has its config.** STATE is unlocked before the machine config
  is read, so the KMS must be reachable on the network the platform provides and must present a
  certificate from a public CA (Talos 1.14 disk-encryption docs). The tailnet is no help: the
  Tailscale extension starts after EPHEMERAL is open. On the AX41 the vSwitch VLAN is part of the
  machine config, so only its public DHCP address exists at that point.
* **The Talos provider configures a node in maintenance mode.** `talos_machine_configuration_apply`
  tries an insecure connection first and falls back to certificates (provider v0.12.0,
  `talosClientOp`). So a wiped node can take its encrypted config from the same resource.
* **Talos can add a key slot to a LUKS2 volume without a wipe.** It syncs the configured key list
  with the volume (rotation: add the new slot, apply, reboot; remove the old one, apply, reboot).
  A wipe is needed only to go from plain to encrypted.
* **TPM sealing on the AX41 needs hands.** The AX41 has a firmware TPM, but switching the board
  to UEFI, turning the TPM on and enrolling SecureBoot keys needs a KVM console that Hetzner
  support lends for one to three hours. Talos's default TPM policy binds PCR 7, the SecureBoot
  state; `pcrs: []` binds only the signed PCR 11 policy, which software in Hetzner's rescue
  system can reproduce by extending PCR 11 itself, so it is worth little without SecureBoot.
  With our own keys enrolled in custom mode, Hetzner's network-booted rescue system is not
  signed by them; whether it still boots is unproven, and PR #75's install and reinstall path
  depends on it. Moving a running Talos node from GRUB to a SecureBoot UKI needs a reinstall.

## Threat model

| Who | What they hold | What a key source must do |
| --- | --- | --- |
| Whoever ends up with a decommissioned cloud volume or AX41 NVMe | the disk, nothing else | keep the key off the disk |
| Whoever obtains a disk image or snapshot, without a Hetzner token (a leaked image, a support case, a backup copy) | the image | keep the key away from wherever the image is read |
| A thief of a cluster Hetzner token (`unfold-tofu`, `unfold-cluster`, `unfold-vip`) | every server of the project: snapshots, rescue mode, firewalls | make reading a disk noisy at least |
| A thief of the Robot webservice user | the AX41: rescue mode, reset, firewall | the same |
| Hetzner staff | the hosts, their memory and disks | accepted in RFC 0001; disk encryption does not answer a host operator |

The token thief is the hard case for every network KMS. With a token one can boot any node into
rescue mode (delete and rebuild protection do not stop it), read the LUKS2 header there and ask the
KMS from the node's own public address, which the firewall must allow. That costs the attacker a
node outage that the cluster alerts on. What differs between KMS placements is whether a **silent**
path exists as well: imaging the KMS server's disk, which needs no reboot, and then reading
snapshots of the nodes offline.

## Options

| Option | Cost | Protects against | Fails against | Boot dependency |
| --- | --- | --- | --- | --- |
| `static` | free | nothing for STATE: the passphrase is stored in META beside it | everyone | none |
| `nodeID` | free | a loose disk without its server's UUID | anyone with the token: rescue mode reads the UUID | none |
| `tpm` (AX41 only) | free, plus a KVM session and a SecureBoot image | the AX41's loose disk, a Robot thief, rescue mode | nothing in this table except Hetzner staff | none: the key never leaves the board |
| `kms` on a CX23 in a second Hetzner project | about €4,49 a month with its IPv4 (Hetzner list price after the April 2026 adjustment; check before ordering), and CX capacity was short on 2026-10-25 | loose disks, leaked images, a token thief's silent path (that project's token is not the cluster's) | a token thief who accepts a node outage | that VM must be up when a node reboots |
| `kms` on `unfold-headscale` | free | loose disks, leaked images | a token thief, silently: the same token images the Headscale server and its master key | Headscale's VM, already needed by the tailnet |
| `kms` in the homelab over the tailnet | free | everything above, Hetzner staff at rest included | nothing more | **impossible**: the tailnet starts after EPHEMERAL is open; over the public internet it would make every node reboot depend on the homelab, which the cluster is designed to survive without |

## Decision

* **Cloud nodes: `kms`, slot 0, served by `kms-server` on `unfold-headscale`** at
  `https://headscale.webgrip.dev:4050`, with Headscale's own Let's Encrypt certificate. The
  Hetzner firewall `unfold-disk-kms` opens port 4050 only to the nodes' public IPv4 addresses
  and to `ADMIN_CIDRS` (the runners, for the pre-flight check and the diagnose run). Built now.
* **The AX41: the same `kms` key in slot 0 from its first install**, so it never needs a wipe for
  encryption, with `allowDiscards` on its local NVMe as RFC 0001 planned. A `tpm` slot is a
  later, separate decision: it needs one KVM session, a SecureBoot image signed with our keys, a
  reinstall through `install_generation`, and proof that Hetzner's rescue still boots. Adding
  that slot needs no wipe of the encrypted volumes.
* **The master key is minted, never typed.** `scripts/disk-kms-key.sh` reads it from OpenBao
  `secret/unfold-cluster/disk-kms` (`master_key`) and, on an apply run that finds none, writes 32
  random bytes there first; CI's OpenBao policy may create that secret but not update it. OpenBao holds the only original (homelab ADR-0055); the encrypted
  state and the Headscale server's cloud-init hold copies. A rebuild from an empty state reads the
  same key, so every encrypted disk still opens.
* **The separate-project KMS is proposed, not built.** It costs money, and it changes the token
  thief's best attack from silent to noisy rather than closing it. Moving there later changes
  `disk_encryption_kms_endpoint` and copies the same master key; nodes then take the new endpoint
  as a new key slot, with two reboots each and no wipe.

## Consequences

* A node reboot needs `unfold-headscale` up. A running node never asks again. Headscale was already
  the tailnet's single coordination server; its daily unattended upgrade may reboot it at 04:30,
  for about a minute, and a node rebooting then waits and retries.
* `unfold-headscale` now carries a key that opens every disk of the cluster. A token that can image
  it can read every node disk offline. RFC 0001's residual-risk row says so.
* The KMS is replaced with the server (`headscale_generation` 4). The image is pinned by digest
  with a `# renovate:` line; like Headscale itself it only changes with the next generation.
* Encrypting a running cloud node is a wipe and rejoin, one node per reviewed plan
  ([docs/disk-encryption.md](../disk-encryption.md)).

## Confirmation

* `infra/tests/disk_encryption.tftest.hcl` pins the key source, the endpoint, the cipher options
  per node class, the firewall sources, the cloud-init and the refusal of an apply without a key;
  each assertion was broken once and seen to fail.
* `scripts/test-disk-kms-key.sh` proves a stored key is never replaced and a plan never mints.
* The diagnose run prints, per node, whether STATE and EPHEMERAL are LUKS2, and whether the KMS
  answers TLS with a certificate that verifies.
