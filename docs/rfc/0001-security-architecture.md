# RFC 0001: Security architecture for the Unfold cluster

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-24 |
| Owner | ryangr0 |
| Builds on | Unfold ADR-0040, Ploeg ADR-0106 and ADR-0107, PRs #10 to #16 |
| Versions checked | Talos 1.14.4, Kubernetes 1.37.1, Cilium 1.20.4, Kyverno 1.19.2, Tetragon 1.7.1, CNPG 1.30.1, hcloud-csi 2.24.1, VictoriaMetrics LTS 1.148.x |

## Summary

This cluster runs code nobody reviewed: agent Runs execute model-written code against client repositories. It is designed so that no single failure gives an attacker the cluster, and every control can be checked against the live system.

Every layer follows four rules:

1. **Deny by default, allow by name.** Network, egress, images, registries, admission, RBAC and the host firewall all start closed. Each allow names its subject.
2. **Two independent controls per critical boundary**, enforced by different components. Image trust, for example, is checked by Talos when the image is pulled and by the API server when the pod is admitted.
3. **The guardrails cannot be switched off through the API they guard.** The core admission policies load from the control planes' disk, not from etcd.
4. **Nothing counts until it has been broken on purpose.** Each control ships with a mutation test that must fail when the control is removed and pass when it is present.

No cluster is perfectly secure. [Residual risks](#residual-risks) lists what this design does not stop, so each can be accepted or bought down knowingly.

## Threat model

| Actor | Goal | Primary controls |
| --- | --- | --- |
| A malicious or confused agent Run | Escape the pod, steal credentials, reach other tenants, exfiltrate code, sabotage a change | Kata micro-VM on the AX41, user namespaces, Tetragon LSM enforcement, FQDN-only egress through the egress gateway, credentials held outside the pod; judge models that watch every action and can hold the Run; a sampled audit ([agent oversight](#agent-oversight-infrastructure)) |
| An internet attacker | Reach any service or node | No public ingress ports: Cloudflare Tunnel only. Hetzner and Talos firewalls closed. API and Talos API reachable on the tailnet only |
| A compromised supply chain | Run a poisoned image or chart | Digest pins, signature checks at pull (Talos) and at admission (Kyverno), registry allowlist in CEL, in-cluster mirror that only serves signed or re-signed images |
| A stolen credential | Use a kubeconfig, a Hetzner token or a forge token | Short-lived OIDC sign-in, break-glass credentials kept offline with an alert on use, one token per job with delete protection (#14), signed commits only (#10) |
| A compromised homelab | Push to production | Production pulls from the GitHub mirror and deploys only signed commits. The apply job runs only on its own runner (#15), and later in production itself |
| The host provider | Read disks or snapshots | LUKS2 on every Talos partition and every volume, keys never stored on the same disk |
| An insider with cluster admin | Delete evidence | Audit logs leave the cluster within seconds; the off-cluster copy is outside the cluster admin's reach |

## Layer by layer

Every row below has a state: **built** (merged or in an open PR), **design** (this RFC), or **spike** (needs a proof before we commit).

### 1. Nodes: Talos

| Control | How | State |
| --- | --- | --- |
| Immutable OS, no SSH, no shell | Talos defaults | built |
| Kernel hardening | KSPP flags and sysctls, `module.sig_enforce=1`, signed kexec only (Talos defaults) | built |
| Workload isolation | `SecurityProfileConfig` with `workloadIsolation: true`: kubelet, containerd and pods run in their own PID and mount namespace | design |
| Host firewall | `NetworkDefaultActionConfig` `ingress: block`, plus one `NetworkRuleConfig` per port and source subnet. Control planes accept 6443 and 50000 from the tailnet only; 2379–2380 from control planes only; etcd HTTP 2383 from the metrics scraper only; 10250 and 50001 from the cluster subnet; WireGuard 51871/udp and VXLAN 8472/udp from nodes. Talos owns host filtering; Cilium's host firewall stays off so the two never fight over the nftables chain | design |
| Cloud firewall | Hetzner Cloud Firewall in front, mirroring the Talos rules | built |
| Disk encryption, cloud nodes | `VolumeConfig` STATE and EPHEMERAL with LUKS2 `aes-xts-plain64`, `blockSize: 4096`, and the `no_read_workqueue` and `no_write_workqueue` options (see [disk encryption cost](#disk-encryption-cost)). Key slot 0 is `kms` against a KMS server on its own small VM, reachable only on the private network. Hetzner Cloud has no TPM, so `nodeID` (no real protection) and `static` (stored in clear text for STATE) are not used. Discards stay off | decided 2026-10-24; KMS server is a spike |
| Disk encryption, AX41 | SecureBoot with our own keys, enrolled once over the KVM console. Slot 0 is `tpm` bound to the signed PCR 11 policy; slot 1 is `kms` as recovery for a BIOS update or CMOS reset. Same cipher options as the cloud nodes, plus `allowDiscards` on the local NVMe, where TRIM keeps write performance and wear healthy | design |
| Talos API | Reached over the tailnet only. Day-to-day `talosconfig` is `os:reader`; `os:admin` is issued for one day from the break-glass bundle when needed | design |
| Image signature at pull | `ImageVerificationConfig` ends in `image: "*"` `deny: true`. Allowed: Sidero images (keyless, Sidero's GitHub identity), our images (our public key), the mirror's re-signed images (the mirror's key). Applies to system images and every pod image | design |
| Bootstrap without registries | `ImageCacheConfig` bakes the bootstrap images into the Talos snapshot, so a node boots and joins without reaching any registry | design |
| User namespaces | `SysctlConfig` raises `user.max_user_namespaces`; admission requires `hostUsers: false` (section 3) | design |
| SELinux enforcing | Permissive by default and labelled experimental; Cilium under enforcing is unproven. Enforcing only takes effect on a fresh install, so the cluster is installed enforcing from its first apply and qualified before production moves onto it ([qualification](#qualification-before-production)) | decided 2026-10-24 |
| Kata Containers version | The Talos extension pins Kata 3.32, the last 3.x release (June 2026). Upstream is at 4.3.1, and a plain version bump breaks the extension because 4.x moved its Go runtime configs and confidential images. We contribute the bump to siderolabs/extensions and, until it merges, build our own extension and installer with Talos's `imager` (base `installer-base:v1.14.4`), signed with our key and mirrored. That also removes the dependence on Sidero's Image Factory for these nodes. Renovate tracks Kata releases | decided 2026-10-24 |

### 2. Control plane and etcd

| Control | How | State |
| --- | --- | --- |
| Floating API address on the private network | Talos Hetzner VIP | built (#8) |
| etcd transport | mTLS between peers and clients, TLS 1.3 minimum (Talos 1.14 default), ports closed to everything except control planes | design (firewall) |
| etcd at rest | Talos `secretbox` encryption for Secrets, extended through `KubeEtcdEncryptionConfig` to every resource that may hold a credential. KMS v2 with OpenBao Transit is rejected for now: OpenBao runs inside the cluster it would have to unlock, and Talos 1.14's API server document cannot mount a plugin socket | design |
| etcd backups | Encrypted snapshots every 6 hours, write-only key, daily restore into a throwaway etcd | built (#16) |
| etcd health | Alerts on DB size against quota, leader changes, fsync latency, member count | design |
| Authentication | `KubeAuthenticationConfig`: anonymous access only to `/livez`, `/readyz` and `/healthz`; one JWT issuer, Google. CEL `claimValidationRules` require `email_verified` and the webgrip.nl hosted domain. `claimMappings` turn Google groups into Kubernetes groups. No static tokens, no client-certificate users except break-glass | design |
| Authorization | Node and RBAC only. No webhook authorizer, so no extra component sits in the path of every request | design |
| RBAC | No standing `cluster-admin` for people. Flux reconciles each tenant through a per-namespace service account (`--default-service-account`, `--no-cross-namespace-refs`). Nobody is granted `pods/exec`, `pods/attach` or `pods/portforward` outside the break-glass group | design |
| Break-glass | The admin kubeconfig and an `os:admin` talosconfig, age-encrypted in the password manager with an offline copy. Any audit event from the admin certificate pages the owner | design |
| Service-account tokens | Bound, audience-scoped, node-bound tokens (Kubernetes defaults). Legacy token Secrets are refused in admission | design |
| Audit | `KubeAuditPolicyConfig`. Secrets, ConfigMaps and TokenReviews at `Metadata`, never bodies. RBAC, admission policies, network policies, CRDs, exec, attach and port-forward at `RequestResponse`. Health and watch noise dropped. Shipped off the node within seconds (section 9) | design |

### 3. Admission: CEL first, one webhook where CEL cannot reach

The rules live in four tiers, from hardest to remove to easiest:

1. **Static manifests on disk.** `ManifestBasedAdmissionControlConfig` is beta and on by default in 1.37. The API server loads ValidatingAdmissionPolicies from a directory on the control plane at start-up. Those policies survive etcd loss and cannot be deleted through the API. Tier 1 holds the guardrails that protect the guardrails:
   - Nobody but Flux's service account may change admission policies, their bindings, cluster-wide network policies, PodSecurity labels or the `kube-system` RBAC.
   - Privileged pods, host namespaces and hostPath are refused everywhere except a named list of system pods.

   Getting these files onto the disk through Talos machine config is still to be proven, so tier 1 is a **spike**.
2. **ValidatingAdmissionPolicy (CEL)**, reconciled by Flux. It extends the image policy already in #11:

   | Policy | Rule |
   | --- | --- |
   | Images | Digest-pinned, from the in-cluster mirror only. Covers containers, initContainers, ephemeralContainers and image volumes, because image volumes otherwise slip past container-only checks |
   | Isolation class | A namespace labelled with an isolation class must run the matching `runtimeClassName`: `kata` for isolated, `gvisor` for hardened (Ploeg ADR-0106) |
   | User namespaces | `hostUsers: false` is required. PodSecurity restricted relaxes `runAsNonRoot` when it is set, so non-root is enforced separately |
   | Pod hardening | `automountServiceAccountToken` false unless the pod is labelled to need it. `seccompProfile` RuntimeDefault or Localhost. Requests and memory limits required. `emptyDir.sizeLimit` and an ephemeral-storage limit required |
   | Services | No NodePort, no LoadBalancer outside the gateway namespace, no `externalIPs`, no ExternalName |
   | Storage | A PVC must use an encrypted StorageClass. Only namespaces on an allowlist may create PVCs |
   | Routes | HTTPRoute hostnames must fall under the namespace's allowed subdomain |
   | RBAC | No wildcard verbs or resources in tenant Roles. No binding to `cluster-admin`, `admin` or `edit` from a tenant namespace. No `escalate`, `bind` or `impersonate` |
   | Secrets | No `kubernetes.io/service-account-token` Secrets |
   | Namespaces | The PodSecurity `enforce` label cannot be lowered from `restricted` |
3. **MutatingAdmissionPolicy (CEL)**, GA in 1.36. It sets the safe defaults so manifests stay short and the validating rules rarely fire: seccomp RuntimeDefault, `hostUsers: false`, `automountServiceAccountToken: false`, and the runtime class from the namespace label.
4. **Kyverno**, the authoring layer and the one webhook. It runs at version 1.19.2 or later, which fixed 24 advisories, nine of them critical. Three admission replicas run on the control planes with a PodDisruptionBudget, and two reports-controller replicas. It does two jobs:
   - **It authors the best-practice catalogue in CEL.** Kyverno's CEL `ValidatingPolicy` and `MutatingPolicy` generate native ValidatingAdmissionPolicies and MutatingAdmissionPolicies (`autogen`). The rules are written once, with Kyverno's tests and reports, and the API server enforces them in-process. A Kyverno outage does not stop admission.
     - The catalogue covers pod security beyond PodSecurity, requests and limits, probes, labels, no `latest` tags, PodDisruptionBudgets for replicated workloads, and no default service account.
     - The tier 2 and tier 3 rules above live here.
   - **It does what CEL in the API server cannot:**
     - `ImageValidatingPolicy` checks cosign signatures and in-toto attestations (SBOM, provenance, vulnerability scan) at admission, as a second check behind Talos's check at pull time. It uses `failurePolicy: Fail`, except for `kube-system` and Kyverno's own namespace.
     - `GeneratingPolicy` gives every new namespace its default-deny network policy, ResourceQuota and LimitRange.
     - `DeletingPolicy` removes expired Run namespaces.

Every policy rolls out in `Audit`, then `Warn`, then `Deny`. A policy reaches `Deny` only after the mutation test: a manifest that breaks the rule is refused, a manifest that follows it is admitted, and both run in CI against a kind cluster on the same Kubernetes version.

### 4. Networking

| Control | How | State |
| --- | --- | --- |
| CNI | Cilium 1.20.4 (1.20.3 is affected by a Go CVE patched on 23 October), VXLAN, kube-proxy replacement | built, version bump due |
| Encryption in transit | WireGuard with node encryption and ingress strict mode. Control-plane host traffic is left out by Cilium's default (encrypting it can lock workers out); it stays on the private network and is TLS anyway | built (#12), strict mode design |
| Default deny | Every namespace, including `kube-system` and `flux-system`, each with an explicit allowlist. Today those two are excluded; they join in audit mode first | built (#11), widening design |
| Egress | No `world` rules. Every egress rule names FQDNs through Cilium's DNS proxy (`rules: dns`). The backup job's `world:443` becomes `s3-offsite.webgrip.dev` | design |
| Agent Run egress | Through an egress gateway on the AX41 with a fixed source address, so forges and model gateways can allowlist it. Open-source Cilium has no failover for it; one gateway per cell is accepted | design |
| Public ingress | None on the nodes. `cloudflared` (two replicas, remotely managed tunnel) forwards to Cilium's Gateway API. The webhook endpoint verifies each forge's HMAC signature | design |
| Admin endpoints | Tailnet only (#13). Cloudflare Access only where a browser needs to reach it from outside | design |
| Mutual authentication | Cilium's SPIFFE mutual auth is deprecated in 1.20 and removed in 1.21, so it is not used. Service-to-service mTLS comes later from pod certificates (GA in 1.37) or ztunnel | rejected |
| Flow evidence | Hubble relay plus flow export (dropped flows and all egress) to VictoriaLogs | design |
| Multi-cluster room | ClusterMesh needs a unique cluster ID, non-overlapping pod CIDRs and settings fixed at install. Allocate them now: [address plan](#address-plan) | design |

### 5. DNS

| Control | How | State |
| --- | --- | --- |
| Public zone | Cloudflare with DNSSEC on. CAA allows only Let's Encrypt, with an `iodef` reporting address. Certificate Transparency monitoring on | design |
| Per-cell subzone | Each cluster owns a subzone (`<cell>.unfold.webgrip.dev`). external-dns runs with `--policy upsert-only`, `--txt-owner-id <cluster>`, a domain filter on its subzone, and a token scoped to DNS edit on one zone | design |
| Resolver | Talos `ResolverConfig` with host DNS on and upstreams over DNS-over-TLS (new in 1.14). CoreDNS forwards to the host. If the egress gateway's masquerading breaks that forward (a known Talos and Cilium issue), CoreDNS forwards over `tls://` itself | design |
| DNS visibility | Every pod query passes Cilium's DNS proxy and lands in Hubble, which is what the FQDN egress rules need anyway | design |
| Time | NTP servers by IP address, so DNS-over-TLS certificate checks do not depend on DNS | design |
| Scale | NodeLocal DNSCache through Cilium Local Redirect Policy once query volume warrants it | later |

### 6. Images and supply chain

```
Renovate (digest pins) ─► Zot mirror in the cluster ─► Talos pull check ─► Kyverno admission check ─► pod
                              │ only signed upstreams,
                              │ unsigned ones re-signed
                              │ after a vulnerability scan
```

| Control | How | State |
| --- | --- | --- |
| Digest pins everywhere | Renovate with digest updates (#9); admission refuses tags | built |
| Registry allowlist | CEL policy (#11). Narrows to the mirror once the mirror runs | built, narrowing design |
| In-cluster mirror | Zot with on-demand sync. It keeps digests, syncs cosign signatures and referrers, and serves only signed images. An upstream image without a signature is mirrored only after a CI job scans it and signs it with the mirror key. Talos `RegistryMirrorConfig` sends every registry to Zot with `skipFallback`, so no node pulls from the internet. Spegel is rejected: on Talos it needs a privileged namespace and a containerd patch | design |
| Our images | Built in Forgejo CI, signed with cosign through OpenBao Transit (the key never leaves OpenBao), with SBOM and provenance attestations | partly built in the homelab |
| Signature checks | Twice: Talos at pull, Kyverno at admission (section 3) | design |
| Credential re-checks | Kubelet `imagePullCredentialsVerificationPolicy: AlwaysVerify`, so a cached private image is not handed to a pod that lacks the pull credential | design |

### 7. Storage and PVCs

Hetzner volumes have no snapshots and no encryption at rest that Hetzner documents. A volume attaches to one server at a time, up to 16 per server. So durability comes from the applications and confidentiality from LUKS.

| Control | How | State |
| --- | --- | --- |
| Default StorageClass | `hcloud-luks`: hcloud-csi LUKS through a node-publish Secret holding `encryption-passphrase`, synced from OpenBao by External Secrets. `reclaimPolicy: Retain`. The unencrypted class is not offered, and admission refuses PVCs on any other class | design (built: Retain) |
| Databases | CloudNativePG 1.30 with `plugin-barman-cloud` (the in-tree backup path is removed in 1.31). Continuous WAL archiving and a daily base backup. Single instance while there is one Unfold node; a replica on a control plane is the step before hub HA | design |
| Backup targets | Object storage at two providers ([object storage](#object-storage)). Garage is not used for this cluster: it has no object lock or versioning, encrypts only with SSE-C, which barman-cloud cannot send, and filled up once | proposed |
| Other state | Not allowed by default. A workload that needs a PVC outside CNPG brings its own backup and restore test. Velero's file-system backup needs a privileged node agent, so it is not installed | design |
| Run scratch space | The AX41's EPHEMERAL partition is LUKS, TPM-bound, wiped on reinstall. Every Run pod has ephemeral-storage and `emptyDir` size limits | design |
| Restore drills | etcd daily (#16); CNPG weekly into a throwaway cluster, with an alert on failure | etcd built, CNPG design |
| Database disk | CNPG starts on hcloud LUKS volumes, which Hetzner replicates three times. A benchmark gate (fio with `--fsync=1` and an etcd-style WAL test) runs on an encrypted and a plain volume before the first database goes live; if fsync p99 misses the target, the primary moves to encrypted local NVMe and relies on its replica and WAL archive for durability | design |

### 8. Secrets

| Control | How | State |
| --- | --- | --- |
| Store | OpenBao in the cluster with the static seal (VIK-1768). The seal key reaches the control planes through a Talos inline manifest, never through git | design |
| Delivery | External Secrets syncs from OpenBao. Pods read Secrets they are bound to and nothing else | design |
| Bootstrap secrets | Hetzner tokens, tailnet key, backup keys: OpenTofu variables into encrypted state, delivered as Talos inline manifests (#14, #16) | built |
| Dynamic credentials | OpenBao's database engine issues short-lived Postgres users to Unfold and ploegd, instead of static passwords | later |
| Agent Run credentials | Never in the Run's pod for `hardened` and above. The egress gateway swaps placeholders for real credentials (Ploeg ADR-0106) | design |

### 9. Runtime security

| Control | How | State |
| --- | --- | --- |
| Untrusted code | Kata micro-VMs on the AX41 for `isolated`, gVisor on cloud nodes for `hardened` | design |
| Detection and enforcement | Tetragon 1.7.1. The Talos kernel lacks `BPF_KPROBE_OVERRIDE`, so enforcement uses BPF LSM hooks, which Talos builds in. Policies: <ul><li>kill a process that writes to `/proc/sys`, loads a kernel module, or calls `ptrace` or `mount` from a workload</li><li>record every exec and outbound connection from Run pods</li><li>kill shells in pods outside the debug namespace</li></ul> Talos 1.14 no longer forces the lockdown mode that blocked BPF loading; `tetra probe` on a real node confirms it before any enforcing policy | spike |
| Seccomp | RuntimeDefault by default (Talos kubelet default and section 3). A Localhost profile for the agent harness once its syscalls are known | design |

### 10. Observability

The cluster watches itself; nothing about production alerting passes through the house.

| Signal | Source | Alert |
| --- | --- | --- |
| Audit events | API server audit files, read by a vlagent DaemonSet on control planes only (read-only hostPath, its own narrow admission exception) | Break-glass use, RBAC or admission policy change outside Flux, exec into any pod, Secret read by a person |
| Node logs | Talos `machine.logging` and `KmsgLogConfig` to vlagent | Service restarts, kernel BPF or LSM denials |
| Network | Hubble flow export | Dropped egress from Run pods, new external destinations |
| Runtime | Tetragon events | Any enforcement kill |
| Admission | `apiserver_validating_admission_policy_check_total` and Kyverno metrics | Denials in production namespaces, policies stuck in Audit |
| Images | Talos image verification denials | Any denial |
| Backups | Restore check result and snapshot age (#16) | A failed or missing restore check |
| Platform | Flux, etcd, certificate expiry, volume usage, spend against the €185 cap | The usual SLO alerts |

The stack:

- **Storage:** VMSingle on the VictoriaMetrics LTS line (1.148.x; 1.154.0 can run out of memory), and VLSingle.
- **Collectors:** vlagent and vmagent.
- **Alerting:** vmalert and VMAlertmanager, sending to a self-hosted ntfy on the off-site box. uptime-kuma there is the dead-man's switch.
- **Tamper-evidence:** audit and Tetragon events are also forwarded off the cluster within seconds, so a cluster administrator cannot erase them afterwards. Garage has no object lock, so true write-once retention needs a different target. Owner decision.

### 11. In-cluster TLS and workload identity

WireGuard encrypts pod traffic between nodes, so a reader on Hetzner's network sees nothing. It does not prove *which workload* is calling. That second property comes from TLS with client certificates, on the services where it matters most.

| Control | How | State |
| --- | --- | --- |
| Transport | Cilium WireGuard with node encryption. Traffic between pods on the same node and control-plane host traffic stay outside it; both remain inside one machine or on the private network, and every control-plane protocol is TLS 1.3 | built (#12) |
| Internal CA | cert-manager with an intermediate CA issued by OpenBao PKI (offline root). trust-manager distributes the CA bundle; approver-policy replaces the default approver, so a namespace can only request names it owns. Per-pod keys through cert-manager's CSI driver stay on the node and never enter etcd | design |
| PostgreSQL | CNPG serves TLS 1.3 only, but its default `pg_hba` still accepts plain connections. The rules are replaced with `hostssl` entries using certificate authentication and a final `host all all all reject`. Clients connect with `sslmode=verify-full` | design |
| OpenBao | TLS end to end, never terminated in front of it. Certificate rotation triggers a reload | design |
| NATS | TLS on client and route ports, client certificates required, and JWT accounts per publisher: a Run's pod has no credential for its own event subject | design |
| Everything else | TLS where the application supports it, verified against the internal CA. VictoriaMetrics' mTLS is an Enterprise feature, so vmauth fronts it | design |
| Mesh | Not now. Cilium's ztunnel mTLS is beta and today replaces WireGuard and breaks L4 policies. Istio ambient is GA but needs CNI chaining and gives up eBPF masquerading. Pod certificates are GA in 1.37 but no maintained signer exists yet, cert-manager included. Re-evaluate when ztunnel leaves beta, a signer ships, or per-request L7 authorization becomes a requirement | rejected for now |

### 12. Further hardening

| Measure | Value | Cost |
| --- | --- | --- |
| Kubescape operator | Continuous posture checks against CIS, NSA and MITRE, RBAC risk, image scans | A few hundred MiB |
| Sidero's CIS mapping for Talos 1.14 | Evidence of record; kube-bench expects kubeadm paths and reports false positives on Talos | Free |
| gitleaks in CI and pre-commit on every repository, one history scan | No secret reaches git | Free |
| RBAC review in CI (`rbac-tool`, `kubectl-who-can`) | Every role change shows who gains what | Free |
| Cloudflare WAF, rate limits and Access in front of every public route; the origin accepts only the tunnel | Admin pages never face the internet unauthenticated | Free tier |
| NTS for time sync, set explicitly in `TimeSyncConfig` | Certificate and token expiry checks cannot be skewed by a forged time server; servers learned from DHCP never use NTS | Free |
| Incident runbooks: node compromise, OpenBao rotation, mass credential rotation, etcd key rotation; a yearly tabletop exercise | The first bad day follows a script | A few days |
| Forensics: Tetragon and audit events off the cluster, `talosctl support` bundles, volume snapshots; container checkpoints treated as secrets | Evidence survives the incident | Free |
| OWASP ZAP baseline in CI against public routes; an external pentest once real users depend on it | Outside view | Free; a pentest €3,000–10,000 |
| Trivy: not installed. Its March 2026 supply-chain compromise (CVE-2026-33634) is the reason; if it is ever used, pin it by digest | Avoids a known-bad dependency path | Free |

### Disk encryption cost

- **The cipher is not the cost.** On AMD CPUs with AES-NI, aes-xts runs at well over a gigabyte per second per core.
- **The cost is dm-crypt's work queues**, which queue each write up to four times. Cloudflare measured default dm-crypt at about 7 times slower than the raw device on a RAM disk. Turning the queues off (`no_read_workqueue`, `no_write_workqueue`) roughly doubled throughput.
- **On Hetzner Cloud volumes the network is the bottleneck.** Their latency dwarfs the encryption, so encryption costs close to nothing there.
- **On local NVMe, expect 5 to 15% less throughput** and microseconds more per write, with the queues off.
- **etcd is sensitive to fsync latency, not throughput**, and its target is a WAL fsync p99 under 10 ms. The control planes' etcd lives on their local disk, and `etcd_disk_wal_fsync_duration_seconds` p99 is alerted on from the first day.

## Platform components

Every component below is reconciled by Flux from this repository, pinned by digest, and placed on the control planes when it belongs to the recovery set: the components needed to change the cluster when everything else is down.

| Area | Component | Role |
| --- | --- | --- |
| Bootstrap (Talos inline manifests) | Cilium, hcloud CCM, Flux operator and instance | Network and GitOps before anything else exists |
| Network | Cilium with Hubble and Gateway API; cloudflared; external-dns | Encrypted, default-deny networking; the only public way in; DNS records |
| Certificates | cert-manager, trust-manager | Gateway and internal certificates; CA bundles; later the signer for pod certificates (GA in 1.37) |
| Secrets | OpenBao, External Secrets, Reloader | Secret store with the static seal; delivery into Secrets; restarts on rotation |
| Policy | Kyverno (admission and reports), native VAP and MAP | Section 3 |
| Runtime security | Tetragon | Section 9, and the agent oversight below |
| Images | Zot | Section 6 |
| Storage | hcloud-csi, CloudNativePG with plugin-barman-cloud | Section 7 |
| Observability | VictoriaMetrics operator: VMSingle, VLSingle, VictoriaTraces, vmagent, vlagent, vmalert, VMAlertmanager; kube-state-metrics, node-exporter; Grafana; OpenCost | Section 10; VictoriaTraces holds each Run's harness traces (Ploeg ADR-0113) |
| Off-site | ntfy, uptime-kuma | Alerts and the dead-man's switch, outside the cluster |
| Agent plane | ploegd and ploeg-worker, Unfold, LiteLLM, KEDA, NATS JetStream, RuntimeClasses `kata` and `gvisor`, agent-sandbox (spike) | The workloads this cluster exists for, and their oversight |
| Scaling | cluster-autoscaler with the Hetzner provider | Node pools below |

## Agent oversight infrastructure

Agents are watched in five layers, designed in Ploeg's [run oversight and execution backends dossier](https://github.com/ploeg-hq/ploeg/pull/243): guards that refuse an action inline, a Watch that judges every action within seconds, a sampled Audit, and a person. This cluster provides the parts that sit outside Ploeg.

| Part | In this cluster | Why here |
| --- | --- | --- |
| Kernel guard and evidence | Tetragon `TracingPolicyNamespaced` on Run pods. It kills processes and fails their system calls (through BPF LSM hooks, which the Talos kernel supports) on credential-file reads, `setns` and `unshare`, module and BPF loads, execution from `/tmp`, and connections outside the allowlist. It also exports exec, file and connect events with pod labels | The Run cannot forge or suppress kernel events |
| Network evidence | Hubble flow export for Run pods, allowed and dropped | The same reason |
| Event stream | NATS JetStream, one subject per Run, which the Run's own pod cannot publish to | The Watch reads every source from one ordered stream |
| Model gateway guards | LiteLLM's Tool Permission guardrail; Prompt Guard 2 scoring tool results for injection; outbound secret patterns | Refusals happen before the model or the tool acts |
| Judge models | Stage 1 (gpt-oss-safeguard or Granite Guardian) and stage 2 (a frontier model from a different family than the agent), both reached through LiteLLM | Every judge call is metered and budgeted like a Run's |
| Holding a Run | Blocking the Run's LiteLLM key, and a Cilium policy that denies all egress for pods labelled for quarantine | The fastest stop available without killing the evidence |

## Node pools and scaling

Hetzner Cloud offers no nested virtualization, and Hetzner dedicated servers are billed monthly with a setup fee. Each isolation class therefore scales differently (Ploeg ADR-0106, and section 5 of the dossier).

| Pool | Machines | Runs | Scales by |
| --- | --- | --- | --- |
| Control planes | 3 × CPX22 | The recovery set | By hand |
| `unfold` | CPX32 | ploegd, Unfold, databases | By hand; a second node with hub HA |
| `gvisor` | CPX VMs | `standard` and `hardened` Runs, under gVisor's systrap, which needs no `/dev/kvm` | cluster-autoscaler from zero. Each pool is one server type; the Talos worker config is its cloud-init, the Talos snapshot its image |
| `kata` | AX41 now; Hetzner auction servers later | `isolated` Runs under Kata with Cloud Hypervisor; CI under Kata until it moves to its own cell ([CI](#ci)) | A person orders a server when `isolated` Runs have waited too long for a week; the alert carries the evidence |
| Burst cells | Hourly bare metal (Scaleway Elastic Metal) | `isolated` Runs at peak | OpenTofu creates and destroys a small Talos cell that pulls work from the hub (Ploeg ADR-0107) |
| `confidential` | None on Hetzner | `confidential` Runs | A confidential-VM cloud cell, or our own EPYC hardware, when a client needs it |

Warm Run pods per pool keep Kata and gVisor starts close to a second; agent-sandbox's warm pools are the candidate (spike). The Talos Kata extension ships Kata 3.32 while upstream is at 4.3.1, which is a risk to watch.

## Address plan

ClusterMesh fixes these at install and requires them to be unique, so they are allocated now even though only one cluster exists.

| Cluster | Cluster ID | Nodes | Pods | Services |
| --- | --- | --- | --- | --- |
| homelab (staging hub) | 1 | 10.0.0.0/24 | 10.42.0.0/16 | 10.43.0.0/16 |
| unfold-main (production hub) | 2 | 10.64.0.0/16 | 10.65.0.0/16 | 10.66.0.0/16 |
| later cells | 3 and up | 10.(64+4n).0.0/16 | 10.(65+4n).0.0/16 | 10.(66+4n).0.0/16 |

`clustermesh.maxConnectedClusters` stays at 255. Today `infra/talos.tf` uses the Talos defaults, pods on 10.244.0.0/16 and services on 10.96.0.0/12. Moving them to this plan is part of delivery step 2. It has to happen before the first apply: Kubernetes cannot change a cluster's pod or service range in place.

## Object storage

| Use | Primary | Second copy (outside Hetzner and Falkenstein) | Why |
| --- | --- | --- | --- |
| etcd snapshots (age-encrypted) | Hetzner Object Storage, Nuremberg | OVHcloud | Already encrypted; Nuremberg puts the backup on another site at the same price |
| CNPG backups | Hetzner Object Storage, Nuremberg | OVHcloud multi-zone with SSE (`AES256`), copied by a scheduled job | barman-cloud writes to one store and cannot send SSE-C; OVH accepts its `AES256` header |
| Security evidence (audit, Tetragon, Hubble) | Hetzner Object Storage with object lock in compliance mode, 365 days | OVHcloud with object lock in compliance mode | Two providers make it tamper-evident even against a lost or closed account. The cluster holds write-only keys |
| OpenTofu state | OVHcloud | Scaleway | Hetzner rejects conditional writes on versioned buckets, which OpenTofu's lock needs |
| Zot storage, later file backups | Hetzner Object Storage | OVHcloud | In-region for fast restores |

The cost is about €10 a month at the start, rising to about €17 a month at steady state, excluding VAT:

| Provider | Start | Steady state |
| --- | --- | --- |
| Hetzner Object Storage | €6.49 | €6.49 (up to 1 TB storage and 1 TB egress) |
| OVHcloud multi-zone | about €3.30 | about €10.40 |

Neither provider charges for requests or egress at this scale.

Hetzner bills objects under 64 KB as 64 KB, so evidence is shipped in batches. Self-hosting is rejected for evidence: write-once storage on disks the cluster's administrator controls is not tamper-proof against that administrator. MinIO's community edition is archived. SeaweedFS is the most complete self-hosted option, if one is ever needed.

The backups built in #16 move from the off-site Garage to this layout before the first apply.

## CI

CI jobs run code from every repository: Renovate updates, agent pull requests, and anyone's branch. They need container builds, and the trusted ones push and sign images. They do not belong next to the production hub.

| Option | Separation | Cost |
| --- | --- | --- |
| A. A `ci` node pool in this cluster: its own bare-metal node, Kata only, tainted, its own namespace and network policy | Separate kernel and node; shared control plane, API and cluster-wide policy | Within the €185 cap if it shares the AX41 with Runs, as decided on 2026-10-18 |
| B. A separate CI cell: a single-node Talos cluster on its own bare-metal server, with Forgejo runners pulling jobs as they do today | Nothing shared with production: a CI escape reaches no production credential, API or node | One more server, about €57 to €68 a month, which takes the plan past the cap |

Recommendation: B is the target and A is the start. Runners pull their jobs, so moving them from A to B only re-points them; nothing else changes.

Three rules apply in both:
- Signing happens in a separate trusted job that reaches OpenBao Transit through Forgejo's OIDC, never on the runner that executed untrusted build steps.
- The infra workflow keeps its own repository-scoped runner (#15) on trusted nodes, never on the CI pool.
- A CI cell needs no high availability. It holds no state; a lost node means jobs retry.

## Qualification before production

The cluster is not production until it has passed these checks. Until then it is the test bed, so no separate throwaway cluster is needed. If one is wanted for a riskier change, the same OpenTofu can create a cloud-only copy for an afternoon; it costs a few euros, because cloud servers are billed by the hour.

1. SELinux enforcing on every node, with Cilium, hcloud-csi, Kata, gVisor, Tetragon and every platform component running. A component that fails gets a written fix or its node goes back to permissive through a reinstall, and that exception is recorded.
2. Disk benchmarks on encrypted volumes and local disks, against the etcd and Postgres targets.
3. Every admission policy's mutation test, and every network policy's allowed and denied probe.
4. A restore of etcd and of a CNPG database from the off-site copies.
5. Ploeg's attack drill (ADR-0126) against the cluster, and a planted-sabotage Run through the oversight layers.

## Room to scale, per layer

| Layer | Today | Next step, and its trigger |
| --- | --- | --- |
| Nodes | 3 CPX22, 1 CPX32, 1 AX41 | Second AX41 when Runs queue; larger control planes when etcd latency alerts |
| Admission | CEL policies plus one Kyverno webhook | The same policy set ships as a versioned Flux OCI bundle, so every cell runs identical policy |
| Network | One cluster | ClusterMesh between cells using the address plan; ztunnel when it leaves beta |
| DNS | One subzone | One subzone per cell, each with its own external-dns owner |
| Images | Zot in one cluster | Zot per cell syncing from the hub's Zot, so cells never reach the internet for images |
| Storage | Single-instance CNPG | Replicas when a second Unfold node exists; synchronous replication when the hub goes HA |
| Secrets | OpenBao in one cluster | OpenBao performance replicas per cell, or zero-secret cells (ADR-0107) |
| Observability | VMSingle and VLSingle | VMCluster and VLCluster with cell and tenant labels, when one node's disk or memory runs out |
| Tenancy | Namespaces | A cell per paying tenant (blueprint, "Signal: client") |

## Residual risks

| Risk | Why it remains | What would reduce it |
| --- | --- | --- |
| Hetzner can read memory on its own hosts | Cloud servers offer no TPM, SecureBoot or confidential computing | Confidential VMs with SEV-SNP when an EU provider offers them at this price |
| The KMS server has no client authentication | Sidero's reference server authorises by node UUID alone | Network isolation now; our own KMS server backed by OpenBao Transit later |
| Control-plane host traffic is not WireGuard-encrypted | Cilium excludes control planes from node encryption by default | Private network plus TLS on every control-plane protocol |
| Backups depend on two object-storage providers | Both are rented; neither is ours | Restore drills from each copy; a third copy only if a provider fails a drill |
| The homelab CI shares a privileged Docker daemon | The infra runner's pods share nodes with other repositories' jobs | Move the infra runner into the AX41's Kata pool |
| SELinux enforcing is experimental on Talos | Upstream labels it experimental; components may need fixes | Qualification before production; recorded exceptions only |
| We carry our own Kata build until upstream catches up | Our pipeline rebuilds the extension and installer for every Talos patch and Kata release | The upstream contribution; Renovate tracking both |
| Talos and its Image Factory belong to one vendor | Sidero was acquired in September 2026 | Mirrored installer digests (VIK-2144), recipes in git |

## Delivery

Each step is one pull request with its mutation test, stacked like #10 to #16.

1. Version bumps: Cilium 1.20.4, hcloud-csi 2.24.1, CCM 1.39.2.
2. Address plan and Cilium cluster ID; disk encryption with the KMS VM; SELinux enforcing in the node image; Talos host firewall, workload isolation, user-namespace sysctl, kubelet credential re-checks, NTS.
3. Object storage at both providers; the etcd backups of #16 and the OpenTofu state move onto it.
4. The Kata 4 extension and installer pipeline, and the upstream contribution.
5. Authentication through Google OIDC with CEL claim rules; audit policy; break-glass alerting.
6. CEL policy set (tier 2) and mutating defaults (tier 3), in Audit.
7. FQDN-only egress; `kube-system` and `flux-system` into default deny, in audit mode.
8. Observability stack with the alerts above, and ntfy on the off-site box.
9. Zot mirror, Talos registry mirrors and `ImageVerificationConfig`, then Kyverno image policies.
10. Encrypted StorageClass, OpenBao, External Secrets, cert-manager on OpenBao PKI, CNPG with the barman-cloud plugin and certificate-only `pg_hba`.
11. Cloudflare Tunnel, Gateway API, external-dns, DNSSEC and CAA.
12. Agent plane: RuntimeClasses, the `gvisor` pool with cluster-autoscaler, NATS JetStream, Tetragon Run policies, LiteLLM guardrails, then Ploeg's Watch in shadow mode.
13. CI pool or cell, Kubescape, gitleaks and RBAC review in CI.
14. Spikes, in parallel: the KMS server, static admission manifests, Tetragon LSM enforcement, agent-sandbox warm pools.
15. Qualification before production, then policies from Audit to Deny, one at a time, each after its mutation test.

## Decisions

Decided on 2026-10-24:

- Kyverno authors the best-practice catalogue in CEL and is the one admission webhook (section 3).
- Cloud and bare-metal disks are encrypted with keys from a KMS server on its own VM.
- SELinux enforcing is tested on this cluster before it becomes production.
- `isolated` capacity grows both ways: Hetzner servers ordered by a person, and hourly bare-metal burst cells.
- We stay on current Kata: an upstream contribution, and our own build until it lands.

Open:

1. **Object storage:** Hetzner Object Storage plus OVHcloud, as [proposed](#object-storage).
2. **CI:** start with option A and move to B, or go to B straight away and raise the cap by about €60 a month.
