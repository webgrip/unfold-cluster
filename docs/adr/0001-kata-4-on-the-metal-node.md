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
   containerd handler is `kata`, so the `kata` RuntimeClass does not change. The extension carries
   our hardened configuration; it is documented and asserted in the private extension repository,
   not here. Sandbox runtime configuration comes only from the node.
2. **One image for the node, built by imager** in that repository's release pipeline: the official
   extensions in [talos/schematics/metal.yaml](../../talos/schematics/metal.yaml) plus our Kata
   extension, as an installer image and a `metal-amd64.raw.zst` disk image.
3. **Published privately, where the node can reach it.** Harbor is reachable only on the homelab
   LAN, so the release publishes both images to the private Forgejo organisation `webgrip-talos`
   on `forgejo.webgrip.dev`: the installer as a container image, the disk image as an OCI artifact.
   Nothing there is readable anonymously; the release refuses to publish otherwise and fails when
   an anonymous pull succeeds. The images contain our hardening, so they are never public.
   A release happens only when a version bump is merged in the extension repository.
4. **One read-only pull credential, minted by API.** homelab-cluster's
   `unfold-metal-image-provisioner` keeps the organisation private, lets the existing `webgrip-ci`
   bot publish to it, and mints a `webgrip-ci` token with the single scope `read:package` into
   OpenBao `unfold-cluster/metal-image-pull`. Forgejo 15 cannot narrow a token to one package or
   one organisation: its scopes are per category, and its repository-limited tokens do not cover
   packages. So the token can list and download every package `webgrip-ci` can see (the public
   ones anywhere, and `webgrip-talos`), and nothing else: no writes, no code, issues, user or
   organisation data. The `infra` apply reads it for the node's `RegistryAuthConfig`, which
   upgrades pull the installer with, and for the install, which downloads the disk image on the
   runner. Renovate reads the same token to find new releases.
5. **Pinned by Renovate.** [talos/metal-image.yaml](../../talos/metal-image.yaml) holds both
   references by tag and digest; Renovate opens the pull request that moves them, grouped, and
   `scripts/check-metal-image.sh` checks it in CI: one release, the private registry, a tag for the
   Talos version in `talos/talenv.yaml`. All-zero digests are the placeholder before the first
   release, and install nothing.
6. **Installed from the rescue system with `dd`.** `scripts/robot.sh install` downloads the disk
   image on the runner with the pull token and checks the manifest and layer digests, then arms
   the rescue system with a one-time SSH key, resets the server, checks the rescue host key against
   the one Robot announced, copies the image in, checks it again, wipes the NVMe disks and writes
   it to `nvme0n1`. The pull token never reaches the server. Talos then boots into maintenance mode and OpenTofu applies the machine
   config over apid, exactly as it does for the cloud nodes booted from a snapshot.
7. **Never over a running Talos.** The install refuses when the server answers as a configured
   Talos, or when the rescue system finds Talos partitions, unless `install_generation` was raised
   in a reviewed change. The install resource is replaced only by a new server number or a raised
   generation, never by a new image pin; upgrades go through the installer image.
8. **No upstream contribution.** The build stays ours.

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
* A Talos upgrade of the metal node needs a release of `talos-kata-extension` for that Talos
  version first; Renovate then offers it here.
* The pull token is also a key to the other packages `webgrip-ci` can read; it sits in the
  node's machine config, which is already secret.
* If our Kata build misbehaves, removing the `runtime.webgrip.io/kata` label keeps new Kata pods off
  the node; the installer of the previous release is the rollback.

## Confirmation

* `infra/tests/metal.tftest.hcl`, `scripts/test-robot.sh` and `scripts/test-check-metal-image.sh`
  cover the pins, the pull credential, the guards and the install steps against a stubbed Robot
  and registry.
* After the first install, the `diagnose` mode of the `infra` workflow shows
  `kata-containers 4.3.1-webgrip.1` among the node's extensions and a Kata probe whose guest
  kernel differs from the host's.
* An anonymous request for either image answers 401 or 404; the release job proves it on every
  publish.
