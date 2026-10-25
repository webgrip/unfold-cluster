---
status: accepted
date: 2026-10-25
---

# ADR 0001: The metal node runs our own Kata 4.3.1 build, installed from rescue

## Context and problem statement

`unfold-metal-1`, a Hetzner AX41 in FSN1, runs agent Runs of the `isolated` class under Kata
Containers and CI under gVisor. It needs a Talos image with the extensions `amd-ucode`, `gvisor`,
`tailscale` and Kata, and a way from an empty Robot server to a Talos node that no person drives.

Two facts constrain the choice:

* Sidero's Image Factory serves only official extensions. The official `siderolabs/kata-containers`
  for Talos 1.14.4 is Kata **3.32.0** (`ghcr.io/siderolabs/extensions:v1.14.4`, checked 2026-10-25),
  the last 3.x release. Upstream Kata is at 4.3.1.
* Robot's webservice can arm the rescue system and reset a server, but it cannot mount an ISO:
  that needs a KVM console requested from Hetzner support.

## Decision

1. **Kata 4.3.1 from our own extension**, `webgrip/talos-kata-extension`, not Sidero's 3.32. Its
   containerd handler is `kata`, so the `kata` RuntimeClass does not change. The extension's
   configuration is the hardened one: empty pod and container annotation lists, no hypervisor
   annotations, guest seccomp on, no debug console, no nested virtualisation. Sandbox runtime
   configuration comes only from the node.
2. **One image for the node, built by imager** in that repository's release pipeline: the official
   extensions in [talos/schematics/metal.yaml](../../talos/schematics/metal.yaml) plus our Kata
   extension, as an installer image and a `metal-amd64.raw.zst` disk image.
3. **Published where the node can reach it.** Harbor is reachable only on the homelab LAN, so the
   pipeline also publishes to the `webgrip` organisation's packages on `forgejo.webgrip.dev`: the
   installer to its container registry, the disk image as a generic package. Both are pinned in
   [talos/metal-image.yaml](../../talos/metal-image.yaml), the installer by digest and the disk
   image by sha256. OpenTofu refuses an installer whose tag does not start with the Talos version
   in `talos/talenv.yaml`.
4. **Installed from the rescue system with `dd`.** `scripts/robot.sh install` arms the rescue
   system with a one-time SSH key, resets the server, checks the rescue host key against the one
   Robot announced, downloads the disk image, checks its sha256, wipes the NVMe disks and writes the
   image to `nvme0n1`. Talos then boots into maintenance mode and OpenTofu applies the machine
   config over apid, exactly as it does for the cloud nodes booted from a snapshot.
5. **Never over a running Talos.** The install refuses when the server answers as a configured
   Talos, or when the rescue system finds Talos partitions, unless `install_generation` was raised
   in a reviewed change. The install resource is replaced only by a new server number or a raised
   generation, never by a new image pin; upgrades go through the installer image.
6. **No upstream contribution.** The build stays ours.

## Considered options

| Option | For | Against |
| --- | --- | --- |
| Official `siderolabs/kata-containers` through Image Factory | No pipeline to keep; Sidero rebuilds it for every Talos release | Kata 3.32.0, a branch that gets no more releases; its configuration is not ours, so every node would carry an override of it |
| **Our 4.3.1 extension, baked in with imager (chosen)** | Current Kata; the hardened configuration is part of the image and asserted at build time; the same image installs and upgrades | We rebuild for every Talos patch and Kata release (Renovate tracks both); first boot of this build is on this node |
| Self-hosted Image Factory | Schematic ids again for custom extensions | A service to run and secure for one node |
| Boot the Talos ISO | Talos's documented bare-metal path | Robot cannot mount an ISO through its API; a person would book a KVM console |
| `installimage` | Hetzner's own tool | Installs Linux distributions, not Talos |

## Consequences

* Ordering, wiring and installing the node need no person once the Robot webservice user is
  seeded (`docs/runbooks/metal-node.md`).
* While `talos/metal-image.yaml` holds empty values, an apply orders the server and puts it on the
  vSwitch behind its firewall, and installs nothing.
* A Talos upgrade of the metal node needs a new release of `talos-kata-extension` for that Talos
  version first, then a new pin.
* If our Kata build misbehaves, removing the `runtime.webgrip.io/kata` label keeps new Kata pods off
  the node; the installer of the previous release is the rollback.

## Confirmation

* `infra/tests/metal.tftest.hcl` and `scripts/test-robot.sh` cover the pins, the guards and the
  install steps against a stubbed Robot.
* After the first install, the `diagnose` mode of the `infra` workflow shows
  `kata-containers 4.3.1-webgrip.1` in `talosctl get extensions`, the handler file with empty
  annotation lists, and a Kata probe whose guest kernel differs from the host's.
