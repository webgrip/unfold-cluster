---
status: accepted
date: 2026-10-25
---

# ADR 0002: CI runs under gVisor on the metal node, agent Runs under Kata

## Context and problem statement

RFC 0001 option A put CI on the AX41 under Kata. Since June 2026 Hetzner Cloud has had no CX43 to
place, so the cloud CI pool is at `node_count = 0` and CI has no node. The AX41 is ordered now and
can take CI as well as agent Runs. The admission policy `sandboxed-workloads` already requires
`gvisor` for the `ci` namespace and for `hardened`, and `kata` for `isolated`.

## Decision

* **CI keeps the `gvisor` RuntimeClass** and runs on the metal node and on any cloud CI node that
  comes back. The RuntimeClass selects the capability label `runtime.webgrip.io/gvisor=true` and
  tolerates the `ci` and `metal` pool taints; no pool name is in it. The ScaledJob prefers nodes
  labelled `runtime.webgrip.io/kvm=true` and otherwise takes any gVisor node.
* **The platform is the node's choice.** Every gVisor node gets its own `runsc` configuration,
  `/etc/unfold-sandbox/runsc.toml`, through a containerd customization: `platform = "kvm"` on the
  metal node (`gvisor_platform`, with `systrap` as the fallback), `systrap` on cloud nodes, which
  have no `/dev/kvm`. Both set `oci-seccomp`, so a pod's seccomp profile also applies inside the
  sandbox (`gvisor_oci_seccomp`). gVisor needs user namespaces, which Talos turns off by default, so
  the same patch sets `user.max_user_namespaces`.
* **Agent Runs of the `isolated` class run under the `kata` RuntimeClass**, which only the metal
  node offers (`runtime.webgrip.io/kata=true`, `metal` taint tolerated).
* **KEDA runs where CI runs**: required affinity to the `ci` or `metal` pool.
* **The annotation guard denies.** `sandbox-annotations` moves from Audit and Warn to Deny before
  the first Kata pod exists: no pod may carry `io.katacontainers.*` or `dev.gvisor.*` annotations.

## Consequences

* CI shares a kernel boundary per pod (gVisor's Sentry) but a node with agent Runs. The node is
  the AX41's 6 cores and 64 GB; the kubelet reserves 1.5 CPU and 3 GiB for the system and the
  sandboxes' VMMs, and the RuntimeClasses carry their per-pod overhead (gVisor 50m and 64 MiB, Kata
  100m and 160 MiB).
* Rootless BuildKit under gVisor with `oci-seccomp` is proven only by `ci-smoke`. If a build needs a
  syscall the RuntimeDefault profile blocks, `gvisor_oci_seccomp = false` is the rollback.
* RFC 0001's option B, a CI cell of its own, stays the next step.
