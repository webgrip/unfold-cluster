---
status: proposed
date: 2026-10-26
---

# ADR 0013: The control planes stay small, a system pool carries the platform, and the hub grows before the control planes do

## Context and problem statement

The owner asked for the cluster to be designed for resources: right-sized, with its architecture decided for scale. [Capacity and scale](../architecture/capacity-and-scale.md) has the measurements, the per-component sizes and the stage costs. This record takes the five decisions in it:

1. whether the control planes grow;
2. whether a dedicated system pool comes now, and on which server;
3. whether observability runs on it;
4. when the metal node becomes mandatory;
5. how the cluster-autoscaler extends to Runs.

## Facts

Checked on 2026-10-26 unless stated.

* **The control planes are CX23**: 2 vCPU, 3.12 GiB allocatable. On the kubelet summary they use 2.3 to 2.9 GiB of 3.7 GiB, with 0.87 to 1.48 GiB available. The API server uses 852 to 1126 MiB against a request of 512 MiB. With honest requests (API server at 1 GiB, Cilium and the CSI node plugin given requests, KEDA placed), each control plane is at 96% of allocatable memory. CPU requests stay under 40%.
* **What sits on them beyond etcd and the API:** Flux, Cilium's operator, the cloud controller, the CSI controller, CoreDNS, External Secrets, cert-manager, Kyverno, the CNPG operator and plugin, KEDA (ADR 0004, Pending today), the cluster-autoscaler (ADR 0004), Tetragon at 384 MiB per node (ADR 0012), Vector and node-exporter.
* **The homelab's API server peaks at 4.46 GiB** with 228 pods and many controllers. This cluster's grows with objects and watches: Trivy reports, Kyverno reports, KEDA ScaledJobs creating a Job per Run.
* **CX is sold out.** A lost CX23 cannot be replaced with a CX23; the nearest shape is CPX22 (2 vCPU, 4 GB) at €19.99. Bigger control planes are CPX32 (4 vCPU, 8 GB) at €35.99 or CCX13 (2 dedicated vCPU, 8 GB) at €43.49: three of either add €90 or €112.50 a month.
* **The cap is €280 a month through the first client** (RFC 0002). S3 with three hub nodes costs €241.89; with CPX32 control planes it would cost €331.89.
* **CPX32, CPX42, CPX52 and CCX are in stock**; CPX42 and CPX52 in nbg1 and hel1. The EX44 and AX41 are sold out on the website. The AX42 is €97.30 plus €49 setup through the Robot API; the auction's cheapest 64 GB machine is an i7-8700 at €81.70.
* **Observability measured in the homelab** (7-day maxima): vmsingle 3.98 GiB at 816k series, vlsingle 1.34 GiB, Grafana 350 MiB, the Alloy agent 181 to 381 MiB per node, vmalert 65 MiB, Alertmanager 48 MiB. Scaled to this cluster, the stack requests about 1.6 GiB and is limited at about 4.1 GiB.
* **Runs need hardware virtualisation** for Kata (ADR 0001, ADR 0002). Hetzner Cloud does not expose it. Unfold ADR-0045 allows `hardened` Runs under gVisor on cloud VMs; Ploeg's bronze and copper teams and Unfold's workspaces use `kata`.

## Considered options

### 1. Control planes

* **A. Grow them now** to CPX32: +€90, S3 over the cap.
* **B. Keep CX23 and keep adding to them:** the scheduler already overpacks them because the API server's request is half its use.
* **C. Keep CX23 and strip them** to etcd, the API and the recovery set, with honest requests, and grow them only on a measured trigger.

### 2. A system pool now

* **A. No system pool;** the platform keeps sharing the hub. At S2 the hub needs 4 GiB for Unfold, Ploeg and LiteLLM, and the platform needs 4.4 GiB: they do not fit together on a CX33.
* **B. A system node at S1, on CPX32** (€35.99): the cheapest in-stock server with room for observability, Zot and Trivy together (4.4 to 4.8 GiB requested).
* **C. A system node on CPX22** (€19.99): 3.2 GiB allocatable, too small.
* **D. A system node on CCX13** (€43.49): dedicated CPU the platform does not need; the fallback if CPX32 is out of stock.

### 3. Observability's place

* **A. On the system node.**
* **B. On the hub.** A hub incident then blinds the tools that would show it, and the hub has no room at S2.
* **C. On the control planes.** No room.

### 4. When the metal node is mandatory

* **A. Now,** idle until the gates: about €97 a month for nothing.
* **B. When RFC 0003 steps 1 to 4 are merged,** because gates G2 and G7 can only be proven on it, and the cutover (S2) cannot happen without it.
* **C. Never: `hardened` Runs only, on cloud.** Gives up Kata for writing Runs and workspaces.

### 5. Autoscaling Runs

* **A. A `runs` node group of CPX42 from zero**, for `hardened` Runs only, beside `ci`.
* **B. Runs in the `ci` group.** CI jobs and Runs would share nodes and trust levels.
* **C. Autoscale the metal node.** The cluster-autoscaler's Hetzner provider handles cloud servers only, and Robot orders take hours and carry setup fees.

## Decision

1. **Control planes: option C.**
   * They carry etcd, the API server, controller manager and scheduler, and the recovery set: Flux, cilium-operator, the cloud controller, the CSI controller, CoreDNS, External Secrets, the Kyverno admission controller, metrics-server (20m / 64Mi, so `kubectl top` and the HorizontalPodAutoscaler work with no worker) and the etcd backup. Nothing else tolerates their taint.
   * The API server's request becomes 1 GiB in the Talos machine config. Cilium, cilium-envoy, cilium-operator, hubble-relay and the CSI pods get requests. Flux's controllers drop their idle CPU requests.
   * **Trigger to grow,** to three CPX32 one node at a time: any of the API server above 1.5 GiB working set at p95 over 7 days, a control plane under 15% available memory for 30 minutes, etcd's database above 1 GiB, or etcd WAL fsync p99 above 25 ms for an hour. If it fires before the first client, it is an owner decision to exceed the cap or delay S3.
   * A lost control plane is replaced with a CPX22 while CX is sold out (`control_plane_server_type` per node, +€14).
2. **System pool: option B, at S1, one CPX32.**
   * It lives in fsn1, beside the hub: Hetzner volumes cannot move between locations, and the observability volumes must be able to fold into the hub at S3.
   * Pool `system`, label and taint `node.webgrip.io/pool=system`, tailnet tag `tag:system` with ports 8427 and 9150: KEDA reads the CI job count on 9150 from wherever it runs, so the pool it moves to needs that port; it never gets OpenBao (8200).
   * It takes KEDA, the cluster-autoscaler, the CNPG operator and its plugin, cert-manager, Zot, Trivy, the Kyverno reports controller, kube-state-metrics, hubble-relay and the package cache.
   * KEDA and the autoscaler leave the control planes. ADR 0004 put them there so they run with no worker at all; the system node is always on, and neither is needed to recover the cluster. KEDA's scaler credential (RFC 0003 R6) moves off the nodes that run etcd.
   * At S3 the pool folds into the three-node hub: `node_count = 0`, and the workloads' affinity (`system` preferred, `unfold` allowed) moves them with no manifest change. A separate system node at S3 would leave €2.12 under the cap.
3. **Observability: option A.** The Alloy agent replaces Vector and vmagent in the same change, so each node runs one agent. vmsingle (20 GB, 30 days), vlsingle (20 GB, 18 GiB cap), VictoriaTraces (10 GB, from S2), vmalert, Alertmanager and Grafana (no volume, dashboards as code) run on the system node.
4. **Metal: option B.** Order it when RFC 0003 steps 1 to 4 are merged. Buy an EX44 at €60.70 if the stock watcher fires before then; otherwise an AX42 at €97.30 plus €49 setup, raising `max_monthly_eur` to €101 and `max_setup_eur` to €49 in a reviewed change (ADR 0009's fallback). Not the auction i7-8700: an eighth-generation Intel host for other people's VMs needs SMT off against L1TF and MDS, which leaves 6 cores for €81.70.
5. **Runs autoscaling: option A, from S3.** Group `runs`, CPX42 in nbg1, 0 to 2, its own pool, label `isolation.webgrip.io/class=hardened`, taint and address block. The `gvisor` RuntimeClass stops tolerating pool taints; each workload tolerates its own pool. Run pods carry `safe-to-evict: "false"`. A priority expander falls back to hel1 once the pool validation admits it.

PriorityClasses, disruption budgets and spread follow [Capacity and scale](../architecture/capacity-and-scale.md#priority-classes): five new classes (`platform-critical`, `hub-critical`, `platform-background`, `run-isolated`, `run-hardened`) and a global default `standard` at 0.

## Consequences

* Good, because the cap holds through S3 (€241.89, or €205.29 with an EX44) with €38 to spare, and every stage has a measured trigger to the next.
* Good, because the control planes stop being the place where new platform components land by default; adding one now needs a line in this record.
* Good, because the scheduler sees what the control planes really carry, so a new pod is refused instead of starving etcd.
* Bad, because the control planes stay at about 86% of their allocatable memory even after S1. The trigger above is the safety, and it needs a working metrics path: today the homelab's `vmsingle-unfold` holds no series.
* Bad, because the system node is a single point of failure from S1 to S3 for observability, KEDA (so new Runs and CI scaling) and Zot. That is the same exposure the single hub already has under RFC 0003 D4; both end at S3.
* Bad, because ADR 0004's "KEDA and the autoscaler run with no worker at all" no longer holds. ADR 0004 gets a history line when this record is accepted.
* Bad, because S4 cannot stay under the cap: each dedicated cell adds €97.30.
* Neutral: a new tailnet tag, `tag:system`, joins ADR 0006's table with 8427 and 9150.

## Confirmation

* `kubectl describe node` on each control plane shows memory requests at or below 90% of allocatable after S1, with the API server's request at 1 GiB.
* No pod outside the recovery set list above runs on a control plane: a CI check renders `kubernetes/` and fails on any workload that tolerates `node-role.kubernetes.io/control-plane` and is not on the list, and passes on the list itself.
* The admission tests refuse a CI pod that tolerates `runs`, and a Run pod without `safe-to-evict: "false"` on the `runs` pool; they admit the correct ones.
* An `infra` plan for S1 shows one CPX32 at €35.99 and no change to the control planes.
* A Pending hardened Run creates exactly one CPX42 labelled `hcloud/node-group=runs`, which is deleted about ten minutes after the Run ends.
