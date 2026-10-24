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
| A malicious or confused agent Run | Escape the pod, steal credentials, reach other tenants, exfiltrate code | Kata micro-VM on the AX41, user namespaces, Tetragon LSM enforcement, FQDN-only egress through the egress gateway, credentials held outside the pod |
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
| Disk encryption, cloud nodes | `VolumeConfig` STATE and EPHEMERAL with LUKS2 `aes-xts-plain64`. Key slot 0 is `kms` against a KMS server on its own small VM, reachable only on the private network. Hetzner Cloud has no TPM, so `nodeID` (no real protection) and `static` (stored in clear text for STATE) are not used | spike |
| Disk encryption, AX41 | SecureBoot with our own keys, enrolled once over the KVM console. Slot 0 is `tpm` bound to the signed PCR 11 policy; slot 1 is `kms` as recovery for a BIOS update or CMOS reset | design |
| Talos API | Reached over the tailnet only. Day-to-day `talosconfig` is `os:reader`; `os:admin` is issued for one day from the break-glass bundle when needed | design |
| Image signature at pull | `ImageVerificationConfig` ends in `image: "*"` `deny: true`. Allowed: Sidero images (keyless, Sidero's GitHub identity), our images (our public key), the mirror's re-signed images (the mirror's key). Applies to system images and every pod image | design |
| Bootstrap without registries | `ImageCacheConfig` bakes the bootstrap images into the Talos snapshot, so a node boots and joins without reaching any registry | design |
| User namespaces | `SysctlConfig` raises `user.max_user_namespaces`; admission requires `hostUsers: false` (section 3) | design |
| SELinux enforcing | Permissive by default and labelled experimental; Cilium under enforcing is unproven. Test on a throwaway cluster before committing | spike |

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
4. **Kyverno ImageValidatingPolicy**, the one webhook. VAP cannot verify signatures. Kyverno checks cosign signatures and in-toto attestations (SBOM, provenance, vulnerability scan) at admission, which is a second check behind Talos's check at pull time.
   - Version 1.19.2 or later: that release fixed 24 advisories, nine of them critical.
   - Three replicas on the control planes, with a PodDisruptionBudget.
   - `failurePolicy: Fail`, except for `kube-system` and Kyverno's own namespace.
   - Only the admission controller runs. No background, cleanup or reports controllers.

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
| Backup encryption | barman-cloud supports only AWS-style server-side encryption, and Garage encrypts nothing at rest without SSE-C. Choose between LUKS under the off-site Garage's data disk and a bucket at a provider with encryption at rest. Owner decision | decision |
| Other state | Not allowed by default. A workload that needs a PVC outside CNPG brings its own backup and restore test. Velero's file-system backup needs a privileged node agent, so it is not installed | design |
| Run scratch space | The AX41's EPHEMERAL partition is LUKS, TPM-bound, wiped on reinstall. Every Run pod has ephemeral-storage and `emptyDir` size limits | design |
| Restore drills | etcd daily (#16); CNPG weekly into a throwaway cluster, with an alert on failure | etcd built, CNPG design |

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

## Address plan

ClusterMesh fixes these at install and requires them to be unique, so they are allocated now even though only one cluster exists.

| Cluster | Cluster ID | Nodes | Pods | Services |
| --- | --- | --- | --- | --- |
| homelab (staging hub) | 1 | 10.0.0.0/24 | 10.42.0.0/16 | 10.43.0.0/16 |
| unfold-main (production hub) | 2 | 10.64.0.0/16 | 10.65.0.0/16 | 10.66.0.0/16 |
| later cells | 3 and up | 10.(64+4n).0.0/16 | 10.(65+4n).0.0/16 | 10.(66+4n).0.0/16 |

`clustermesh.maxConnectedClusters` stays at 255. Today `infra/talos.tf` uses the Talos defaults, pods on 10.244.0.0/16 and services on 10.96.0.0/12. Moving them to this plan is part of delivery step 2. It has to happen before the first apply: Kubernetes cannot change a cluster's pod or service range in place.

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
| Backups and evidence sit in the same region and lack object lock | The off-site Garage is in Falkenstein and has no write-once mode | A second copy outside Hetzner; a target with object lock |
| The homelab CI shares a privileged Docker daemon | The infra runner's pods share nodes with other repositories' jobs | Move the infra runner into the AX41's Kata pool |
| SELinux is permissive | Enforcing is experimental on Talos and unproven with Cilium | The SELinux spike |
| Talos and its Image Factory belong to one vendor | Sidero was acquired in September 2026 | Mirrored installer digests (VIK-2144), recipes in git |

## Delivery

Each step is one pull request with its mutation test, stacked like #10 to #16.

1. Version bumps: Cilium 1.20.4, hcloud-csi 2.24.1, CCM 1.39.2.
2. Address plan and Cilium cluster ID; Talos host firewall, workload isolation, user-namespace sysctl, kubelet credential re-checks.
3. Authentication through Google OIDC with CEL claim rules; audit policy; break-glass alerting.
4. CEL policy set (tier 2) and mutating defaults (tier 3), in Audit.
5. FQDN-only egress; `kube-system` and `flux-system` into default deny, in audit mode.
6. Observability stack with the alerts above, and ntfy on the off-site box.
7. Zot mirror, Talos registry mirrors and `ImageVerificationConfig`, then Kyverno image policies.
8. Encrypted StorageClass, OpenBao, External Secrets, CNPG with the barman-cloud plugin.
9. Cloudflare Tunnel, Gateway API, external-dns, DNSSEC and CAA.
10. Spikes, in parallel: KMS disk encryption, static admission manifests, Tetragon LSM enforcement, SELinux enforcing.
11. Policies from Audit to Deny, one at a time, each after its mutation test.

## Decisions for the owner

1. **KMS VM for disk encryption** on the cloud nodes: one CX-class VM on the private network, about €4 a month, or accept unencrypted cloud disks.
2. **Where database backups and audit evidence live:** the off-site Garage with LUKS under it, or a second provider with encryption at rest and object lock.
3. **Kyverno as the one admission webhook** for signatures and attestations, or rely on Talos's pull-time check alone and keep the API path webhook-free.
4. **SELinux enforcing:** run the spike now, or after the cluster is live.
