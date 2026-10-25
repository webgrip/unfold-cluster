---
status: accepted
date: 2026-10-25
---

# ADR 0004: CI runs on the hub worker, and overflows to an autoscaled CPX42

## Context and problem statement

ADR 0002 put CI on the metal node and on "any cloud CI node that comes back". Neither exists today:
the metal node is being made inactive, and Hetzner Cloud has no CX type to place in any location.
In stock are CPX42 (8 shared vCPU, 16 GB, 320 GB) in Nuremberg at €0,1122 an hour, capped at
€69,99 a month, and the dedicated CCX23 and CCX33 everywhere. A node that runs all month for CI
that runs a few hours a week is mostly paid for idling.

The owner asked for two things: normal CI must run without waiting for a cold node, and extra
capacity may come and go with the queue (option 5).

## Decision

* **Baseline on the hub worker.** `unfold-app-1` (CX33, 4 vCPU, 8 GB) carries the gVisor capability
  label `runtime.webgrip.io/gvisor=true` through `var.worker_pools` and gets the same gVisor systrap
  config as every gVisor node (user namespaces allowed, `oci-seccomp`). The runner ScaledJob alone
  tolerates the `unfold` pool taint and prefers that node. The `gvisor` RuntimeClass still tolerates
  only `ci` and `metal`, so no other sandboxed pod lands on the hub.
* **The cap on the hub is the requests.** A runner pod requests 1.55 CPU and 3 GiB with gVisor's
  overhead. On 2026-10-25 the hub had 3,95 CPU and 7,08 GiB allocatable, with 0,3 CPU and 0,57 GiB
  requested by Zot, vmagent and the DaemonSets: two runners fit, a third does not on CPU alone. The
  PriorityClass `ci-runner` (-5, `preemptionPolicy: Never`) lets every pod at the default priority
  preempt a runner, so Unfold's own workloads are never starved by CI; as they arrive, the hub's
  share of CI falls to one job, then none, and all CI overflows.
* **Overflow on an autoscaled CPX42.** The Kubernetes cluster-autoscaler with the Hetzner provider
  owns one node group, `ci`: CPX42 in `nbg1`, minimum 0, maximum 1 (both in the HelmRelease). A
  Pending runner that fits the `ci` template makes it create one server; the node is removed about
  ten minutes after its last job (`scale-down-unneeded-time`, `scale-down-delay-after-add`).
* **The new node boots its whole config from user data.** OpenTofu renders a Talos worker config
  for each pool in `autoscaled_worker_pools`: the common patches (registry mirrors, node IP subnet,
  install image), the worker host firewall, log shipping, the pool's labels and taint, gVisor, and
  the Hetzner server name as hostname. It carries no tailnet key: a CI node needs only the private
  network, and an operator reaches its Talos API through a control plane
  (`talosctl -e 10.64.0.11 -n 10.64.2.x`), whose apid proxies over the private network. It carries no
  disk-encryption config: the disk KMS admits fixed addresses, and an autoscaled node's address is
  unknown before it exists; the node holds only CI scratch space and its disk is destroyed with it.
* **Autoscaled servers live in their own subnet,** `10.64.2.0/24`, so they never hold an address the
  static plan in `10.64.0.0/24` reserves.
* **Its own token.** The autoscaler's Hetzner token is a fourth token (`unfold-autoscaler`), written by
  the apply to `cluster-autoscaler/cluster-autoscaler-hcloud` with the rendered config, through the
  existing `write-cluster-secrets` path. It can be revoked alone. It shares the project's API budget
  with every other token.
* **It touches only what it created.** The provider counts and deletes only servers labelled
  `hcloud/node-group=ci`, which no OpenTofu server carries (a tofu test holds this), and every
  OpenTofu server keeps Hetzner's delete protection, which the API enforces against any token.
* **KEDA and the autoscaler run on the control planes,** in the recovery set, so they run with no
  worker at all. KEDA's operator reaches the homelab job count on tailnet port 9150, which the
  Headscale policy now grants `tag:cp` instead of `tag:node`.

## Consequences

* Cost, at realistic use: the baseline costs nothing extra. Each overflow episode bills its started
  hours, about job time plus 15 minutes (boot and the idle wait). Twenty one-hour overflows a month
  is about €2,24 to €4,49; an overflow every working day of two hours is about €5 to €7. A node that
  never leaves costs at most €69,99 a month; the homelab alert `HetznerAutoscaledServerRunningLong`
  fires after four hours, at about €0,45.
* CI shares a kernel boundary per pod (gVisor's Sentry) with Zot and, later, Unfold on the hub. This
  is temporary: it ends when the Unfold application needs the hub, or when the metal node takes CI.
* A cold overflow node takes about three to five minutes before the third job starts.
* Any `gvisor` pod that cannot be placed and does not select `runtime.webgrip.io/kvm` makes the
  autoscaler buy a CPX42, because the RuntimeClass tolerates the `ci` taint. Today only runners do.
* The worker config, and with it the cluster's join token, is Hetzner user data, readable from the
  metadata service on the node. The cluster-wide default deny keeps every pod outside `kube-system`
  and `flux-system` from reaching `169.254.169.254`; the CSI node plugin is allowed it, and the
  host-network DaemonSets (Cilium, Vector, node-exporter) can reach it, as on every node.
* The autoscaler image (v1.36.1) is one minor version behind Kubernetes 1.37 until 1.37 is released.
  The chart comes from an HTTP Helm repository, so Flux pins its version, not a digest; the image is
  pinned by digest.
