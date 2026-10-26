# Capacity and scale

| | |
| --- | --- |
| Status | Proposed, with [ADR 0013](../adr/0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md) |
| Date | 2026-10-26 |
| Owner | ryangr0 |
| Builds on | RFC 0001, RFC 0002 (the €280 cap, three hub nodes before the first client), RFC 0003 (inventory and cutover), ADR 0002, ADR 0004, ADR 0009, ADR 0010, ADR 0012 |
| Facts checked | 2026-10-26: this repository's `main` at 938870c (the RFC 0003 stack merged), the live cluster (`kubectl get pods`, `describe node`, the kubelet summary API), the homelab's VictoriaMetrics (7-day maxima, means and p99), hetzner.com cloud price pages |

All prices are per month, excluding VAT. Cloud servers bill hourly up to the monthly price.

## Summary

* **The control planes are full.** With honest requests they are at 96% of their allocatable memory today. The API server alone uses 850 to 1126 MiB against a 512 MiB request, and Cilium and the CSI node plugin request nothing. They stay CX23 through S3 anyway: CX cannot be bought, and three CPX32 control planes would add €90, which breaks the €280 cap at S3. They get there by carrying only etcd, the API and the recovery set, with honest requests, and a trigger that buys bigger ones when the API server grows ([ADR 0013](../adr/0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md)).
* **A system pool of one CPX32 (€35.99) arrives with the observability stack (S1).** It takes observability, KEDA, the CNPG operator, cert-manager, the cluster-autoscaler, Zot and Trivy. The control planes and the hub then keep their own jobs. At S3 it folds into the three-node hub.
* **The metal node is mandatory at S2.** Without it no `isolated` Run and no workspace can move. While the EX44 is sold out, the default is an AX42 (€97.30 plus €49 setup). The i7-8700 from the auction is too old for a host that runs other people's VMs.
* **Stage costs:** S0 €45.05, S1 €82.80, S2 €192.74, S3 €241.89 (€156.14 and €205.29 with an EX44). S4 starts at €339.19 with the first dedicated cell, above the cap. The confidential class takes it to €741.19.
* **Autoscaling:** CI (from zero, exists) and a new `runs` node group for gVisor Runs (from zero, S3). Everything else is fixed and moves only through reviewed applies, because a Robot server cannot be autoscaled and the hub holds state.

## What was measured

| Source | What it gave |
| --- | --- |
| Live cluster, kubelet summary API (metrics-server is not installed) | Working set and CPU per pod and per node, 2026-10-26 |
| Live cluster, `describe node` | Allocatable: CX23 1950m and 3.12 GiB, CX33 3950m and 7.08 GiB |
| Homelab VictoriaMetrics, `container_memory_working_set_bytes` and `container_cpu_usage_seconds_total`, 7 days | Peaks, means and p99 for the homelab equivalents: vmsingle, vlsingle, alloy, grafana, vmalert, alertmanager, LiteLLM, CNPG, KEDA, Kyverno, Trivy, Tetragon, the `ploeg` namespace |
| Homelab VictoriaMetrics, storage metrics | vmsingle: 816k active series, 12.7k rows/s, 16 GiB at 15 days. vlsingle: 112 KB/s and 173 rows/s of ingest, 6.7 GiB at 30 days. 228 pods on 6 nodes |

The homelab's grafana MCP was down during the measurement (its database pod was restarting), so the numbers come from the same VictoriaMetrics through the API server's service proxy.

**The production metrics path is still empty.** `vmsingle-unfold` in the homelab holds 0 active series, so no Unfold dashboard or alert has data. RFC 0003's R10 still stands; the kubelet summary above is the only live source.

### The control planes today

| Node | Working set | Available | API server | Requests (live) | Requests (honest) |
| --- | --- | --- | --- | --- | --- |
| unfold-cp-1 | 2809 MiB | 993 MiB | 852 MiB | 68% | 96% |
| unfold-cp-2 | 2932 MiB | 871 MiB | 1126 MiB | 74% | 96% |
| unfold-cp-3 | 2321 MiB | 1481 MiB | 928 MiB | 52% | 96% |

"Honest" counts the API server at 1 GiB and gives Cilium, cilium-envoy and the CSI node plugin the requests proposed below, with KEDA (Pending today) placed. Etcd and containerd live in the Talos system reservation, about 450 MiB per node, outside these numbers.

### Live findings

* **KEDA is Pending.** Its new ReplicaSet still selects `node.webgrip.io/pool=ci` from before ADR 0004, and no such node exists, so the rollout to the control planes is stuck. Nothing scales CI until it lands.
* **The cluster-autoscaler cannot start.** The Secret `cluster-autoscaler-hcloud` is written by the `infra` apply, which has not run since #84 merged.
* **Both CoreDNS replicas run on unfold-cp-2.** One node's loss takes cluster DNS down.
* **Six kube-system components request nothing:** cilium-agent, cilium-envoy, cilium-operator, hubble-relay, and the hcloud CSI node plugin and controller. The scheduler cannot see about 400 MiB per control plane. The CSI pods are BestEffort, so under memory pressure the kernel kills them first. Cilium survives because its priority class makes the kubelet protect it.
* **Flux asks for 450m CPU in total for controllers that idle at 1 to 17m,** on nodes with 1950m allocatable.

## Components

Each row gives one replica. "Pool" is where it runs today, then where it should run. A pool of "every node" is a DaemonSet. Volumes are hcloud volumes at €0.044 per GB, with 10 GB the smallest Hetzner sells; workspace volumes are local disk on the metal node.

| Component | Namespace | Pool now → proposed | Replicas | Request (CPU / memory) | Limit (CPU / memory) | Volume | From | Today's values | Observed | Flag |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| etcd (Talos service) | - | cp | 3 | - | - |  | S0 | outside kubelet; Talos system reservation | node working set minus pods: about 450 MiB per control plane |  |
| kube-apiserver | kube-system | cp | 3 | 250m / 1Gi | - |  | S0 | 200m / 512Mi, no limit | 850-1126 MiB, 50-126m | under-requested: uses twice its request, so the scheduler overpacks the control planes |
| kube-controller-manager | kube-system | cp | 3 | 50m / 256Mi | - |  | S0 | 50m / 256Mi | 17-109 MiB |  |
| kube-scheduler | kube-system | cp | 3 | 10m / 64Mi | - |  | S0 | 10m / 64Mi | 24-29 MiB |  |
| cilium-agent | kube-system | every node | per node | 100m / 256Mi | none / 1Gi |  | S0 | no requests, no limits | 136-174 MiB, 27-55m; homelab peak 540 MiB | no requests: invisible to the scheduler |
| cilium-envoy | kube-system | every node | per node | 10m / 32Mi | none / 128Mi |  | S0 | no requests, no limits | 13-17 MiB | no requests |
| cilium-operator | kube-system | cp | 1 | 20m / 64Mi | none / 256Mi |  | S0 | no requests, no limits | 50 MiB | no requests |
| hubble-relay | kube-system | cp → system | 1 | 10m / 32Mi | none / 128Mi |  | S0 | no requests, no limits | 14 MiB | no requests |
| tetragon | kube-system | every node | per node | 50m / 384Mi | 1 / 384Mi |  | S0 | 50m / 384Mi, limit 1 / 384Mi | 104-119 MiB here; homelab busy workers 262-285 MiB | limit 3x observed, deliberate (ADR 0012: Guaranteed memory, skipped by the Talos OOM controller); keep |
| vector | observability | every node | per node | 20m / 96Mi | none / 256Mi |  | S0 (until S1) | 20m / 96Mi, limit 512Mi | 55-69 MiB, 19-37m | limit 7x observed; replaced by the Alloy agent at S1 |
| node-exporter | observability | every node | per node | 10m / 32Mi | none / 128Mi |  | S0 | 10m / 32Mi, limit 128Mi | 4-10 MiB |  |
| hcloud-csi-node | kube-system | every cloud node | per node | 15m / 48Mi | none / 128Mi |  | S0 | no requests, no limits (3 containers) | 19-22 MiB | no requests; BestEffort, first to be OOM-killed |
| hcloud-csi-controller | kube-system | cp | 1 | 20m / 96Mi | none / 256Mi |  | S0 | no requests, no limits (5 containers) | 68 MiB | no requests; BestEffort |
| hcloud-cloud-controller-manager | kube-system | cp | 1 | 10m / 48Mi | none / 128Mi |  | S0 | 100m / 50Mi, no limit | 25 MiB, 1m | CPU request 100x use; no memory limit |
| coredns | kube-system | cp | 2 | 50m / 64Mi | none / 170Mi |  | S0 | 100m / 70Mi, limit 170Mi | 20-21 MiB, 2-3m | both replicas on unfold-cp-2: needs topology spread |
| flux-operator | flux-system | cp | 1 | 50m / 128Mi | none / 512Mi |  | S0 | 100m / 64Mi, limit 2 / 1Gi | 50-134 MiB | limit 8x observed |
| source-controller | flux-system | cp | 1 | 50m / 96Mi | none / 512Mi |  | S0 | 50m / 64Mi, limit 1 / 1Gi | 35 MiB |  |
| helm-controller | flux-system | cp | 1 | 50m / 128Mi | none / 1Gi |  | S0 | 100m / 64Mi, limit 1 / 1Gi | 20-93 MiB |  |
| kustomize-controller | flux-system | cp | 1 | 50m / 96Mi | none / 512Mi |  | S0 | 100m / 64Mi, limit 1 / 1Gi | 21-43 MiB |  |
| notification-controller | flux-system | cp | 1 | 10m / 48Mi | none / 256Mi |  | S0 | 100m / 64Mi, limit 1 / 1Gi | 25-35 MiB, 1m | Flux asks 450m CPU in total on 2-vCPU nodes while idle |
| external-secrets | external-secrets | cp | 1 | 20m / 96Mi | none / 256Mi |  | S0 | 20m / 96Mi, limit 256Mi | 30-33 MiB |  |
| external-secrets-webhook | external-secrets | cp | 2 | 10m / 48Mi | none / 128Mi |  | S0 | 10m / 48Mi, limit 128Mi | 27-28 MiB |  |
| external-secrets-cert-controller | external-secrets | cp | 1 | 10m / 48Mi | none / 128Mi |  | S0 | 10m / 48Mi, limit 128Mi | 37-60 MiB |  |
| cert-manager | cert-manager | cp → system | 1 | 10m / 64Mi | none / 256Mi |  | S0 | 10m / 64Mi, limit 256Mi | 26 MiB |  |
| cert-manager-cainjector | cert-manager | cp → system | 1 | 10m / 64Mi | none / 256Mi |  | S0 | 10m / 64Mi, limit 256Mi | 59 MiB; homelab 110 MiB |  |
| cert-manager-webhook | cert-manager | cp → system | 1 | 10m / 32Mi | none / 128Mi |  | S0 | 10m / 32Mi, limit 128Mi | 22 MiB |  |
| kyverno-admission-controller | kyverno | cp | 2 | 100m / 192Mi | none / 512Mi |  | S0 | 100m / 192Mi, limit 512Mi | 57-67 MiB; homelab 930-970 MiB with its larger policy set |  |
| cluster-autoscaler | cluster-autoscaler | cp → system | 1 | 20m / 128Mi | none / 512Mi |  | S0 | 20m / 128Mi, limit 512Mi | not running: Secret cluster-autoscaler-hcloud missing until the infra apply |  |
| etcd-backup (CronJob, 6-hourly) | etcd-backup | cp | 1 | 50m / 128Mi | none / 512Mi |  | S0 | 50m / 128Mi, limit 512Mi | short-lived |  |
| keda-operator | keda | cp → system | 1 | 50m / 192Mi | none / 512Mi |  | S0 | 50m / 128Mi, limit 1 / 512Mi | Pending live; homelab peak 211 MiB, p99 33m | request below the homelab's working set; moves off the control planes at S1 |
| keda-operator-metrics-apiserver | keda | cp → system | 1 | 20m / 96Mi | none / 256Mi |  | S0 | 50m / 128Mi, limit 1 / 512Mi | Pending live; homelab peak 74 MiB |  |
| keda-admission-webhooks | keda | cp → system | 1 | 10m / 48Mi | none / 128Mi |  | S0 | 10m / 64Mi, limit 1 / 256Mi | Pending live; homelab peak 30 MiB |  |
| cloudnative-pg operator | cnpg-system | cp → system | 1 | 50m / 192Mi | none / 512Mi |  | S0 | 25m / 128Mi, limit 512Mi | 28 MiB here; homelab peak 190 MiB, p99 182m | homelab ran it BestEffort and it was OOM-killed; request sized to the homelab peak |
| plugin-barman-cloud | cnpg-system | cp → system | 1 | 10m / 64Mi | none / 256Mi |  | S0 | 10m / 64Mi, limit 256Mi | 19 MiB |  |
| kyverno-reports-controller | kyverno | cp → system | 1 | 50m / 128Mi | none / 384Mi |  | S0 | 50m / 96Mi, limit 256Mi | 49 MiB; homelab 157-224 MiB |  |
| kube-state-metrics | observability | unfold → system | 1 | 20m / 64Mi | none / 256Mi |  | S0 | 20m / 64Mi, limit 256Mi | 21-22 MiB |  |
| vmagent | observability | unfold → system | 1 | 50m / 128Mi | none / 512Mi |  | S0 (until S1) | 50m / 128Mi, limit 512Mi | 125 MiB, 117m |  |
| zot | zot | unfold → system | 1 | 100m / 256Mi | none / 1Gi | 20 GB | S0 | 100m / 256Mi, limit 1Gi; PVC 20Gi | 76 MiB |  |
| trivy-operator | trivy-system | unfold → system | 1 | 50m / 192Mi | none / 768Mi |  | S0 | 50m / 192Mi, limit 768Mi | 160 MiB; homelab 776-858 MiB at 150 images |  |
| trivy-server | trivy-system | unfold → system | 1 | 50m / 256Mi | 1 / 1.5Gi |  | S0 | 50m / 256Mi, limit 1 / 1.5Gi | 27 MiB idle; homelab 129 MiB |  |
| trivy scan job (one at a time) | trivy-system | unfold → system | 1 | 100m / 256Mi | none / 1Gi |  | S0 | set by the operator, sizeLimit by trivy-scan-job-defaults | 256 MiB to 1 GiB |  |
| trivy-report-shipper | trivy-system | unfold → system | 1 | 10m / 48Mi | none / 256Mi |  | S0 | 10m / 48Mi, limit 256Mi | 18 MiB |  |
| gvisor-probe / kata-probe (CronJobs) | sandbox-probes | metal | 1 | 10m / 16Mi | none / 64Mi |  | S0 | 10m / 16Mi, limit 64Mi | Pending until a node with runtime.webgrip.io/kvm exists |  |
| runtime-security canary (CronJob) | runtime-security-canary | unfold → system | 1 | 10m / 16Mi | none / 64Mi |  | S0 | repo | short-lived |  |
| forgejo-runner job (runner + rootless BuildKit, gvisor) | ci | unfold → ci | 1 | 1550m / 3136Mi | none / 8Gi |  | S0 | runner 1 / 2Gi, buildkitd 500m / 1Gi, two init sidecars; limits 4Gi + 4Gi; overhead 50m / 64Mi | no run yet in production |  |
| alloy agent | observability | every node | per node | 30m / 128Mi | none / 384Mi |  | S1 | coming | homelab alloy-agent 181-381 MiB with 228 pods; 77m mean |  |
| vmsingle | observability | system | 1 | 200m / 768Mi | none / 2Gi | 20 GB | S1 | coming | homelab: 816k active series, 2.66 GiB mean, 3.98 GiB peak, 157m mean, 402m p99, 16 GiB at 15d |  |
| vlsingle | observability | system | 1 | 100m / 384Mi | none / 1Gi | 20 GB | S1 | coming | homelab: 112 KB/s ingest, 570 MiB mean, 1.34 GiB peak, 6.7 GiB at 30d |  |
| vmalert | observability | system | 1 | 20m / 64Mi | none / 192Mi |  | S1 | coming | homelab 44 MiB mean, 65 MiB peak |  |
| alertmanager | observability | system | 1 | 10m / 48Mi | none / 128Mi | 1 GB | S1 | coming | homelab 36 MiB mean, 48 MiB peak |  |
| grafana | observability | system | 1 | 50m / 256Mi | none / 512Mi |  | S1 | coming | homelab 263 MiB mean, 350 MiB peak, 46m mean |  |
| unfold workbench | ploeg | unfold | 1 | 100m / 512Mi | 1 / 1Gi | 10 GB | S2 | homelab 100m / 256Mi, limit 1 / 1Gi; PVC 4Gi (88 MiB used) | homelab peak 521 MiB (RFC 0003), 165 MiB this week; p99 211m | homelab request is half its peak |
| ploegd | ploeg | unfold | 1 | 100m / 256Mi | 100m / 256Mi |  | S2 | Guaranteed 100m / 256Mi | homelab peak 31-60 MiB |  |
| ploeg-mcp | ploeg | unfold | 1 | 10m / 32Mi | none / 128Mi |  | S2 | 10m / 32Mi, limit 128Mi | homelab peak 19 MiB |  |
| ploeg-db (CNPG postgres) | ploeg | unfold | 1 | 100m / 384Mi | none / 1Gi | 20 GB | S2 | homelab 100m / 256Mi per instance; data 2Gi, WAL 5Gi | homelab peak 269 MiB, p99 380m; database 23 MiB | homelab request below its peak |
| ploeg-db barman-cloud sidecar | ploeg | unfold | 1 | 50m / 128Mi | none / 384Mi |  | S2 | plugin default | homelab peak 215 MiB, p99 718m during backups |  |
| work-items exporter | ploeg | unfold | 1 | 10m / 32Mi | none / 64Mi |  | S2 | 10m / 32Mi | homelab peak 23 MiB |  |
| ploeg-tracker-wiring (CronJob) | ploeg | unfold | 1 | 25m / 64Mi | none / 128Mi |  | S2 | 25m / 64Mi | homelab peak 20 MiB |  |
| agent-sandbox controller | agent-sandbox | unfold | 1 | 50m / 128Mi | none / 256Mi |  | S2 | estimate | none |  |
| cloudflared | cloudflared | unfold | 2 | 20m / 64Mi | none / 128Mi |  | S2 | estimate | none |  |
| litellm | litellm | unfold | 1 | 200m / 1Gi | none / 1.5Gi |  | S2 | RFC 0003 budget | homelab 900-1044 MiB per pod, p99 337m | RFC 0003's 1.28 GiB for LiteLLM, Valkey and its database together is below LiteLLM's own working set |
| litellm valkey | litellm | unfold | 1 | 20m / 64Mi | none / 256Mi |  | S2 | estimate | none |  |
| litellm-db (CNPG postgres + barman sidecar) | litellm | unfold | 1 | 150m / 512Mi | none / 1280Mi | 20 GB | S2 | estimate | homelab ai postgres peak 323 MiB |  |
| victoriatraces | observability | system | 1 | 50m / 256Mi | none / 512Mi | 10 GB | S2 | RFC 0003 D7 B | none |  |
| package cache (per-Run egress proxy companion) | egress | system | 1 | 50m / 128Mi | none / 512Mi | 10 GB | S2 | RFC 0002 decision | none |  |
| ploeg worker (Run, kata) | ploeg | metal | 12 | 1 / 768Mi | 1 / 768Mi |  | S2 | homelab 100m / 768Mi, limit 1 / 768Mi; overhead 100m / 160Mi | none here | request 100m against a 1-CPU VM: set request = limit so scheduling matches what Kata starts (whole cores, RFC 0002) |
| unfold workspace (kata) | unfold-workspaces | metal | 1 | 500m / 1Gi | 1 / 2Gi | 8 GB | S2 | 500m / 1Gi, limit 1 / 2Gi; 8Gi PVC per workspace on the local encrypted class | homelab agent peak 520 MiB |  |
| delivery verifier (kata) | unfold-verifier | metal | 1 | 250m / 256Mi | 1 / 512Mi |  | S2 | estimate | none |  |
| ploeg-db replicas 2 and 3 | ploeg | unfold | 2 | 100m / 384Mi | none / 1Gi | 20 GB | S3 |  |  |  |
| litellm-db replicas 2 and 3 | litellm | unfold | 2 | 150m / 512Mi | none / 1280Mi | 20 GB | S3 |  |  |  |
| litellm replica 2 | litellm | unfold | 1 | 200m / 1Gi | none / 1.5Gi |  | S3 |  |  |  |
| openbao | openbao | unfold | 3 | 50m / 128Mi | none / 256Mi | 10 GB | S3 |  |  |  |
| nats | nats | unfold | 3 | 50m / 128Mi | none / 256Mi | 10 GB | S3 |  |  |  |
| ploeg worker (hardened class, gvisor) | ploeg | runs | 6 | 1 / 768Mi | 1 / 1.5Gi |  | S3 |  |  |  |

### Why the proposed values

* **Requests follow the observed working set.** Where the homelab ran a heavier load, the request sits between this cluster's use and the homelab's peak. The CNPG operator and LiteLLM get the homelab peak, because both have run out of memory there.
* **Limits stay at two to four times the request.** Burst room for compaction, scans and renders, but not the eight times Flux and Vector have today. Pods without a CPU limit keep none: a CPU limit only throttles, and these are trusted workloads. Kata Runs are the exception, because Kata sizes the VM from the limit.
* **Run requests equal their limits.** A Ploeg worker asks 100m and gets a 1-CPU VM. Setting the request to 1 CPU makes the scheduler count what Kata starts, and gives RFC 0002's whole cores a Guaranteed pod, which the static CPU manager can pin later.
* **Tetragon stays at 384 MiB requested and limited,** three times what it uses here. ADR 0012 chose that on purpose: the Talos OOM controller skips a pod with `memory.max`. It is the largest fixed cost per control plane, so it is the first lever if they run short: a second DaemonSet at 256 MiB for the control planes saves 128 MiB on each.
* **One node agent, not two.** The Alloy agent replaces Vector and vmagent in the same change. Running Alloy beside Vector adds 128 MiB to each control plane, which they do not have.
* **The database volumes are 10 GB of data and 10 GB of WAL,** although `ploeg-db` holds 23 MiB: 10 GB is the smallest hcloud volume. A separate WAL volume costs €0.44 per instance and keeps a full WAL from filling the data disk, the homelab's 2026-07-17 failure.

### What each pool carries

Requested memory against allocatable memory, from the table. CronJobs count as if they were running.

| Stage | Control planes, each | System | Hub | Metal (without Runs) |
| --- | --- | --- | --- | --- |
| S0 | 2.99 of 3.12 GiB (96%) | | 5.08 of 7.08 GiB, one CI job included | |
| S1 | 2.69 of 3.12 GiB (86%) | 4.42 of ~7.0 GiB (63%) | 0.86 of 7.08 GiB, plus up to two CI jobs | |
| S2 | 2.69 of 3.12 GiB (86%) | 4.80 of ~7.0 GiB (69%) | 4.05 of 7.08 GiB (57%) | 0.83 of ~60 GiB |
| S3 | 2.69 of 3.12 GiB (86%) | folded into the hub | 13.20 of ~21 GiB over three nodes (63%) | 0.83 of ~60 GiB |

CPU requests stay below 40% everywhere except the metal node, which is sized by Runs.

At S3, losing one CPX32 leaves 14 GiB for 13.2 GiB of requests. It fits only because the lowest priority classes (Grafana, Trivy, the reports controller) give way first.

## Node pools

| Pool | Server | Nodes | Label and taint | Tailnet tag | Carries |
| --- | --- | --- | --- | --- | --- |
| `cp` | CX23 (CPX22 replaces a lost one while CX is sold out) | 3, fixed | `node-role.kubernetes.io/control-plane:NoSchedule` (Talos) | `tag:cp` | etcd, the API server, controller manager and scheduler; the recovery set: Flux, cilium-operator, the cloud controller, the CSI controller, CoreDNS, External Secrets, the Kyverno admission controller; the etcd backup |
| `system` | CPX32, 4 vCPU and 8 GB, fsn1 | 1, fixed, S1 to S2 | `node.webgrip.io/pool=system`, taint `system:NoSchedule` | `tag:system`: 8427, and 9150 for KEDA | observability (Alloy gateway, vmsingle, vlsingle, VictoriaTraces, vmalert, Alertmanager, Grafana, kube-state-metrics), KEDA, the CNPG operator and barman plugin, cert-manager, the cluster-autoscaler, Zot, Trivy, the Kyverno reports controller, hubble-relay, the package cache |
| `unfold` (hub) | CX33, then + 2 × CPX32 | 1 through S2, 3 from S3 | `node.webgrip.io/pool=unfold`, taint `unfold:NoSchedule` | `tag:hub` | Unfold, ploegd, ploeg-mcp, the agent-sandbox controller, cloudflared, LiteLLM and Valkey, `ploeg-db`, `litellm-db`; from S3 OpenBao and NATS, and the system pool's workloads |
| `ci` | CPX42, nbg1 | 0 to 1, autoscaled | `node.webgrip.io/pool=ci`, `runtime.webgrip.io/gvisor=true`, taint `ci:NoSchedule` | none (private network only, ADR 0004) | CI jobs under `gvisor` |
| `runs` | CPX42, nbg1 | 0 to 2, autoscaled, from S3 | `node.webgrip.io/pool=runs`, `runtime.webgrip.io/gvisor=true`, `isolation.webgrip.io/class=hardened`, taint `runs:NoSchedule` | none | `hardened` Runs under `gvisor` |
| `metal` | AX42 (EX44 when in stock) | 1, fixed, from S2; ordered through Robot | `node.webgrip.io/pool=metal`, `runtime.webgrip.io/{kata,gvisor,kvm}=true`, taint `metal:NoSchedule` | `tag:runs`: 8427 only | `isolated` Runs, workspaces and the verifier under `kata`; the CI baseline under `gvisor` as preemptible filler (RFC 0003 D12 A) |

`unfold-headscale` (CX23) is outside the cluster and outside these pools.

### Placement rules

1. **Every workload names its pool twice:** a toleration for the pool's taint, and a required node affinity on `node.webgrip.io/pool`. A toleration alone lets a pod land anywhere untainted; an affinity alone is refused by the taint.
2. **The recovery set** keeps `nodeSelector: node-role.kubernetes.io/control-plane: ""` and the control-plane toleration. Nothing else tolerates that taint. A new control-plane resident needs a line in ADR 0013's list, because each one is memory taken from etcd's node.
3. **System workloads** use required affinity `node.webgrip.io/pool In [system, unfold]`, preferred affinity for `system`, and tolerate both taints. While the system node exists they run there. At S3, `worker_pools.system.node_count = 0` and they move to the hub with no manifest change.
4. **Runtime classes do not tolerate pool taints.** Today `gvisor` tolerates `ci` and `metal`, which is how a stray gVisor pod can buy a CPX42 (ADR 0004's consequence). With a `runs` pool, the same toleration would let a CI job land on a Run node. The tolerations move into the workloads: the CI ScaledJob tolerates `ci` and `metal`, Ploeg's hardened executor tolerates `runs`, and the RuntimeClass keeps only its `nodeSelector`.
5. **Run pods carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`,** so the autoscaler never drains a `runs` node in the middle of a Run. CI pods carry the same.
6. **No hcloud volume on the metal node.** Robot servers cannot attach them; workspaces use the local encrypted StorageClass (RFC 0003 R9).

### Priority classes

| Class | Value | Preemption | Who |
| --- | --- | --- | --- |
| `system-node-critical` | built in | yes | Cilium, Tetragon, the CSI node plugin, the Alloy agent |
| `system-cluster-critical` | built in | yes | the recovery set |
| `platform-critical` | 100000 | yes | KEDA, the CNPG operator, cert-manager, the cluster-autoscaler, Zot, vmsingle, vlsingle, vmalert, Alertmanager |
| `hub-critical` | 50000 | yes | `ploeg-db`, `litellm-db`, ploegd, Unfold, LiteLLM, Valkey, cloudflared, OpenBao, NATS |
| `platform-background` | 10000 | yes | Grafana, Trivy, the report shipper, the reports controller, kube-state-metrics, VictoriaTraces, the package cache |
| `standard` (global default) | 0 | yes | anything unnamed |
| `run-isolated` | 1000 | yes, against CI only in practice | Ploeg workers, workspaces, the verifier on the metal node |
| `run-hardened` | 1000 | Never | hardened Runs on the `runs` pool |
| `ci-runner` | -5 | Never | CI jobs (exists; above the autoscaler's -10 cutoff) |

The classes live in `kubernetes/platform/priority-classes`. Tetragon is the exception to the table: ADR 0012 gives it no PriorityClass on purpose, so it never preempts a pod, and `UnfoldTetragonNotOnEveryNode` reports a node it cannot reach. The Alloy agent runs as `system-node-critical` so a full node still takes its log shipper; without logs, Tetragon's events are lost. Grafana sits below the databases: if the hub runs short at S3, dashboards go before data.

### Disruption budgets and spread

| Workload | Replicas | Budget | Spread |
| --- | --- | --- | --- |
| CoreDNS | 2 | `maxUnavailable: 1` | `topologySpreadConstraints` on `kubernetes.io/hostname`, `maxSkew: 1`, `DoNotSchedule` across the control planes |
| Kyverno admission controller | 2 | `minAvailable: 1` (exists) | the same |
| External Secrets webhook | 2 | `minAvailable: 1` | the same |
| cloudflared | 2 | `minAvailable: 1` | hostname spread over the hub from S3 |
| `ploeg-db`, `litellm-db` | 1, then 3 at S3 | CNPG's own PDB (`enablePDB: true` from S3; off at one instance, where it would block every drain) | CNPG pod anti-affinity (on in the template), `required` from S3 |
| LiteLLM | 1, then 2 at S3 | `minAvailable: 1` from S3 | hostname spread |
| OpenBao, NATS | 3 from S3 | `maxUnavailable: 1` | hostname spread, `DoNotSchedule` |
| Single replicas (Flux, the operators, vmsingle, vlsingle, Unfold) | 1 | none | none; a `minAvailable: 1` budget on one replica blocks every node drain |

Unfold keeps one replica and `Recreate` even at S3: it has one SQLite writer. Three hub nodes shorten its outage to a reschedule, but do not remove it.

## Scale stages

| Stage | Nodes | €/month | With an EX44 | Under €280 |
| --- | --- | --- | --- | --- |
| S0, today after the merges | 3 × CX23, 1 × CX33, Headscale, CI 0–1 | 45.05 | | yes |
| S1, observability added | + 1 × CPX32 system | 82.80 | | yes |
| S2, Unfold and Ploeg moved in | + 1 × AX42 metal, object storage | 192.74 (+ €49 setup once) | 156.14 | yes |
| S3, first paying client | hub to 3 nodes (+ 1 × CPX32; the system node joins the hub), `runs` 0–2 | 241.89 | 205.29 | yes, €38.11 left |
| S4, hub and cells | + €97.30 per dedicated cell; confidential + €402 | 339.19 from the first cell | 302.59 | no |

### S0: today's stack after the merges

| Line | € |
| --- | --- |
| 3 × CX23 control planes | 17.97 |
| CX33 hub `unfold-app-1` | 8.99 |
| CX23 `unfold-headscale` | 5.99 |
| CI overflow, CPX42 about 100 hours at €0.1122 | 11.22 |
| Zot volume, 20 GB | 0.88 |
| **Total** | **45.05** |

Autoscales: the `ci` group, 0 to 1. Fixed: everything else. Still to do at S0, at no cost: an `infra` apply so the autoscaler starts, KEDA's rollout unstuck, CoreDNS spread, requests on the kube-system components, the API server request raised in the Talos machine config.

**Move on** when the observability stack is ready to merge, or earlier if any control plane stays under 15% available memory (about 550 MiB) for 30 minutes.

### S1: observability added

| Line | € |
| --- | --- |
| S0 nodes | 32.95 |
| CPX32 system node | 35.99 |
| CI overflow | 11.22 |
| Volumes: Zot 20, vmsingle 20, vlsingle 20 GB | 2.64 |
| **Total** | **82.80** |

The same pull request moves KEDA, the CNPG operator, cert-manager, the cluster-autoscaler, Zot, Trivy, kube-state-metrics and the reports controller to the system pool, and swaps Vector and vmagent for the Alloy agent. That frees about 300 MiB of requests on each control plane, and the hub has room for two CI jobs again.

vmsingle is sized for 100 to 150 thousand active series at 30 days, about a sixth of the homelab's 816 thousand. vlsingle is sized for about a third of the homelab's log volume, capped with `retention.maxDiskSpaceUsageBytes` at 18 GiB on its 20 GB volume, as the homelab does.

Autoscales: `ci`. Fixed: the system node.

**Move on** when RFC 0003's gates G1 to G9 are green and the metal node passes ADR-0040's Kata check. Order the metal node when RFC 0003 steps 1 to 4 are merged, because gates G2 and G7 can only be proven on it.

### S2: Unfold and Ploeg moved in

| Line | € |
| --- | --- |
| S1 nodes | 68.94 |
| AX42 metal node (Robot API quote; €49 setup once) | 97.30 |
| CI overflow | 11.22 |
| Object storage, Hetzner and OVHcloud (RFC 0001) | 10.00 |
| Volumes: + Unfold 10, `ploeg-db` 20, `litellm-db` 20, VictoriaTraces 10 GB | 5.28 |
| **Total** | **192.74** |

With an EX44 it is €156.14. RFC 0003 put this stage at €115.75: the difference is the system node (€35.99), the AX42 in place of the EX44 (€36.60), and volumes at Hetzner's 10 GB minimum. Against ADR-0040's old €185 cap, S2 with an AX42 is €7.74 over; against RFC 0002's €280 it is well under.

The metal node at request equals limit holds about 12 concurrent Runs on an AX42 (16 threads, 14.5 CPU after the kubelet reservation), 16 on an EX44. Today's load, 4 workers and 1 workspace, uses about 5.3 CPU, which leaves room for two CI jobs (3.1 CPU) as filler. A Run preempts a CI job; the job is retried.

Autoscales: `ci`, and the Ploeg ScaledJobs within the metal node. Fixed: hub, system and metal.

**Move on** when a first client contract is signed (RFC 0002: three hub nodes before anyone else depends on the hub), or when hub memory requests pass 75% of allocatable, or its working set passes 80% for 24 hours, or the hub node is lost once.

### S3: first paying client, HA hub

| Line | € |
| --- | --- |
| 3 × CX23 control planes | 17.97 |
| Hub: CX33 + 2 × CPX32 (one is the former system node) | 80.97 |
| AX42 metal | 97.30 |
| Headscale | 5.99 |
| CI overflow | 11.22 |
| Object storage at steady state (RFC 0001) | 17.00 |
| Volumes: + two replicas each of `ploeg-db` and `litellm-db`, three of OpenBao and NATS, 260 GB in all | 11.44 |
| **Total** | **241.89** |

Keeping a separate system node here costs €277.88, €2.12 under the cap: one month of heavy CI breaks it. So the system pool folds into the hub, which at three nodes is its own failure domain. The `runs` group is declared at 0 to 2 and costs nothing until hardened Runs are switched on; each node-hour is €0.1122.

If the control planes have to grow at this stage (ADR 0013's trigger), S3 becomes €331.89, over the cap. That is why the control planes are kept lean rather than grown early.

Autoscales: `ci` 0–1, `runs` 0–2. Fixed: the control planes, the three hub nodes, the metal node.

**Move on** when a client needs its own isolation boundary or the confidential class, or the shared metal node runs short: `kata` Runs Pending for more than 10 minutes on three days in a week, the sum of Kata VM CPU limits above 80% of the node's allocatable at p95 over 7 days, or a Run queue wait above 15 minutes at p95.

### S4: hub and cells

RFC 0002 and Ploeg ADR-0107: the hub stays here; Runs execute in cells that pull from it.

| Line | € |
| --- | --- |
| S3 | 241.89 |
| Each dedicated `isolated` cell: one AX42 running single-node Talos (control plane and worker on one box), its own Hetzner project, €49 setup | 97.30 each |
| Confidential phase 1: AX162, SNP, SMT off, €304 setup | 319.00 |
| Confidential phase 2: key broker in an IONOS confidential VM | about 83.00 |
| CI cell of its own (RFC 0001 option B), when CI trust levels split | about 57 to 97 |

| Example | €/month |
| --- | --- |
| First dedicated cell | 339.19 |
| One dedicated cell plus the confidential class (phases 1 and 2) | 741.19 |

**S4 exceeds the €280 cap from its first cell.** Each cell is a cost floor of about €100 a month that belongs in the price of the tier that asks for it.

A cell is a separate cluster, not a node pool: a tenant escape then reaches no shared API, etcd or cluster-wide policy. Cells live in a second Hetzner project, which gives them their own 3600-request API budget and keeps this project's tokens out of reach.

At S4 the hub grows on its own triggers: hub requests above 70% over three nodes means CPX42 hub nodes (+€34 each), and vmsingle above 300 thousand active series or 1.5 GiB working set means a CPX32 observability node of its own again.

## Autoscaling

| Group | Server | Range | Grows on | Shrinks after | Guard |
| --- | --- | --- | --- | --- | --- |
| `ci` | CPX42, nbg1 | 0–1 (S0–S3), 0–2 (S4) | a Pending CI pod that fits the template | 10 minutes idle | `HetznerAutoscaledServerRunningLong` at 4 hours |
| `runs` | CPX42, nbg1 | 0–2 from S3 | a Pending hardened Run | 10 minutes idle, never mid-Run | the same alert per group; the Ploeg team's `maxReplicaCount` bounds demand |

Extending the cluster-autoscaler to `runs`:

1. `worker_pools.runs` with `node_count = 0`, its own address block (`first_host = 41`), labels and taint as in the pool table; `autoscaled_worker_pools = ["ci", "runs"]`. Nodes boot from user data like CI nodes, in `10.64.2.0/24`, without a tailnet key.
2. A second entry in the HelmRelease's `autoscalingGroups`: `runs`, `cpx42`, `nbg1`, min 0, max 2. The provider counts and deletes only servers labelled `hcloud/node-group=runs`.
3. The `gvisor` RuntimeClass loses its pool tolerations (placement rule 4); the CI ScaledJob and Ploeg's hardened executor each carry their own.
4. `expander: priority` with a ConfigMap that ranks `runs-nbg1` and `ci-nbg1` above `-hel1` fallbacks, so a stock-out in Nuremberg falls through to Helsinki. Helsinki is in the same `eu-central` network zone, but the `worker_pools` validation admits only `fsn1` and `nbg1`; it has to be widened first.
5. A tofu test, like the CI one, proves no OpenTofu server carries `hcloud/node-group=runs`.

**What does not autoscale, and why.** The metal node is a Robot server: ordering takes hours to days and carries a setup fee, so it grows through `metal_servers` in a reviewed apply on S3's metal triggers. The hub holds databases with volumes pinned to their node's location; it grows by a reviewed `node_count`. The control planes are etcd members.

## Open

* The live API server and etcd numbers have no history: the metrics path to the homelab is empty. The ADR 0013 triggers need it working, or the in-cluster vmsingle of S1.
* CPX32 stock is from RFC 0003's check on 2026-10-25. Re-check on the day; CCX13 (2 dedicated vCPU, 8 GB, €43.49) is the fallback for the system node.
* The AX42 price is the Robot API quote of 2026-10-25. The plan's price line confirms it, with or without the IPv4 address.
* Estimates without a measurement: the agent-sandbox controller, cloudflared, Valkey, the delivery verifier, the package cache, VictoriaTraces, OpenBao and NATS. Each gets a measured value after its first week.
