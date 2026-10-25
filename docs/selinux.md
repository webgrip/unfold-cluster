# SELinux on the Talos nodes

RFC 0001 decided to run SELinux enforcing, installed from the first apply and qualified before production. This page records what stands in the way on Talos 1.14, what is done now, and what turns it on.

## Where the nodes are

Every node runs SELinux in **permissive** mode. The kernel command line, read on `unfold-cp-1` on 2026-10-25, carries `selinux=1` and no `enforcing=1`. Pods are labelled `system_u:system_r:pod_t:s0`. In permissive mode the policy is loaded and every denial is logged to `auditd`, but nothing is blocked.

The cluster was installed permissive, so the RFC's "installed enforcing from its first apply" did not happen.

## What blocks enforcing today

| Blocker | Source | What it means here |
| --- | --- | --- |
| "Extensions currently do not support enforcing mode" | Talos 1.14 SELinux documentation; in v1.14.4 `services/extension.go` starts every extension with an empty SELinux label, and the policy has no domain for extensions | Every node runs `siderolabs/tailscale`, the owner's way into the cluster and the control planes' subnet route. `siderolabs/gvisor` is the CI sandbox, and `siderolabs/qemu-guest-agent` runs too. Enforcing would break the tailnet first |
| "Enforcing mode should only be enabled on new installs" | Talos 1.14 SELinux documentation | The running nodes cannot be switched by an upgrade. Each would be reinstalled from an enforcing snapshot, a rebuild of the server |
| "Enforcing mode has only been tested with the Flannel CNI" | Talos 1.14 SELinux documentation | Cilium (BPF, bpffs and cgroup mounts from a privileged `pod_t` pod) is unproven. So is hcloud-csi, which mounts volumes Talos cannot label |

A variable that switches the snapshot to an enforcing schematic would only be a trap while the first blocker stands. Flipping it would boot new nodes without a working tailnet. So this change adds no switch. It adds the evidence-gathering below and the exact steps for when the blocker falls.

## What is done now: collecting the denials

Permissive mode is the qualification tool. It logs every access enforcing would deny. The `infra` workflow's `diagnose` run now prints, for every node, the SELinux state (`talosctl get securitystate`) and the last 100 lines of the `auditd` log, where the `avc: denied` lines are. Those lines list, per component, what would break: Cilium, hcloud-csi, the extensions, Flux. That list is the qualification report RFC 0001 asks for, gathered without risk.

## Turning it on, when the blockers fall

The trigger is a Talos release whose notes say extensions support enforcing. Talos bumps already wait for approval on the Renovate dashboard; read the SELinux section of the release notes before approving.

1. **Qualify on a copy.** RFC 0001 allows a cloud-only copy of this cluster for an afternoon, a few euros because cloud servers bill by the hour; it needs the owner's go-ahead. Build it from an enforcing snapshot. Run Cilium, hcloud-csi, gVisor, Tailscale, Flux and every platform component, and read `auditd` until it is clean. Each component that fails gets a written fix, or its node stays permissive as a recorded exception.
2. **Add the schematic.** Add `talos/schematics/cloud.yaml` with `customization.extraKernelArgs: [enforcing=1]`, keeping the extensions. On 2026-10-25 the Image Factory gave that schematic, with today's three extensions, the id `e8c7381b0c75dff926812b0006311b92d61b630137c8c6a2d6b86ddea3d65962`. Put the new id in `talos_cloud_schematic`. The apply run builds the labelled snapshot.
3. **New nodes boot it.** Servers ignore image changes, so only servers created afterwards start enforcing.
4. **Existing nodes are rebuilt**, one at a time, with the same one-node-per-run discipline as the disk encryption rollout ([disk-encryption.md](disk-encryption.md)): drain, leave etcd, rebuild the server from the new snapshot, rejoin, wait for three healthy etcd members. Doing both together saves a round of rebuilds: an encrypted reinstall from an enforcing snapshot is one pass per node.
5. **Verify** with `talosctl get securitystate` on every node: `enabled, enforcing`.

A node that needs no extension (a future hub worker without Tailscale, for example) could run enforcing sooner. Every node the cluster has today needs Tailscale.
