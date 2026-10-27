# Admission policies

The API server enforces the cluster's admission rules in-process as native `ValidatingAdmissionPolicy` objects (CEL). Flux reconciles them from [kubernetes/platform/admission-policies](../../kubernetes/platform/admission-policies). This is tier 2 of RFC 0001 section 3. Nothing here needs a webhook, so an outage of any admission component cannot stop the API server from checking these rules.

## The catalogue

| Policy | Refuses | Where | Action |
| --- | --- | --- | --- |
| `pinned-approved-images` | an image without `@sha256:` or outside the approved registry prefixes, in containers, init and ephemeral containers and image volumes | every namespace but `kube-system`, `flux-system` | Deny |
| `pod-security-restricted` | the PodSecurity `restricted` profile, checked separately: root, privilege escalation, capabilities beyond dropping ALL (plus `NET_BIND_SERVICE`), unconfined seccomp, other volume types, `procMount`, unsafe sysctls, unconfined AppArmor, SELinux user or role | every namespace but `kube-system` | Deny |
| `host-access` | privileged containers, `hostNetwork`, `hostPID`, `hostIPC`, `hostPath`, `hostPort`, Windows host processes | every namespace but `kube-system` | Deny |
| `sandbox-annotations` | pod annotations under `io.katacontainers.` or `dev.gvisor.` | every namespace | Deny, since the metal node brought Kata ([ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md)) |
| `sandboxed-workloads` | a sandboxed pod on the wrong RuntimeClass or with its service-account token mounted, or an unknown isolation class | pods labelled, or in a namespace labelled, `ploeg.webgrip.dev/isolation-class`, and the `ci` namespace | Deny |
| `immutable-image-references` | an image without a digest, or one naming the `latest` tag | every namespace, `kube-system` included | Deny |
| `resource-limits` | a container without cpu and memory requests, a memory limit or an ephemeral-storage limit, an `emptyDir` without `sizeLimit` | every namespace but `kube-system` | Deny |
| `service-exposure` | Services of type `NodePort`, `LoadBalancer` or `ExternalName`, and `externalIPs` | every namespace | Deny |
| `cluster-admin-bindings` | a ClusterRoleBinding or RoleBinding to `cluster-admin` for anyone but Flux's `kustomize-controller`, `helm-controller` and `flux-operator` | every namespace; the API server's own bootstrap is exempt | Deny |
| `service-account-token-secrets` | Secrets of type `kubernetes.io/service-account-token` | every namespace | Deny |
| `pod-security-floor` | a namespace whose `pod-security.kubernetes.io/enforce` label is anything but `restricted` | every namespace but `kube-system` | Deny |
| `encrypted-volumes` | a PersistentVolumeClaim on any StorageClass but the LUKS-encrypted `hcloud-luks`; `hcloud-luks-drill`, which deletes its volume, only for a CloudNativePG cluster named `*-drill` | every namespace | Deny |
| `trivy-scan-job-defaults` (MutatingAdmissionPolicy) | nothing: it sets a 2 GiB `sizeLimit` on every unbounded `emptyDir` and `shareProcessNamespace` in the Trivy Operator's scan Jobs ([vulnerability-scanning](vulnerability-scanning.md)) | Jobs labelled `app.kubernetes.io/managed-by: trivy-operator` in `trivy-system` | mutates |

The policies match Pods and the pod templates in Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs and CronJobs, so Flux's apply sees the warning before a controller creates the Pod.

`host-access`, `immutable-image-references`, `pod-security-restricted` and `resource-limits` judge an update of a workload only when its pod template changes (the `creates-or-changes-the-pod-template` match condition). A rollout ends with the deployment controller setting the old ReplicaSet's `spec.replicas` to 0, an update of a ReplicaSet made before its Deployment complied. On 2026-10-26 `resource-limits` refused exactly that, so the old pods of the Flux operator and controllers, External Secrets and kube-state-metrics kept running beside the new ones and their HelmReleases failed on `ProgressDeadlineExceeded`. Pods are judged on every create and update, so scaling an old ReplicaSet up still cannot start a pod the policies refuse. The fixtures `*-replicaset-that-predates-it.yaml` prove both directions.

### Isolation classes and RuntimeClasses

`sandboxed-workloads` reads the class from the pod's `ploeg.webgrip.dev/isolation-class` label (Ploeg ADR-0106) and from the same label on its namespace, and the stricter of the two wins. A pod cannot label itself down from its namespace's class.

| Class | RuntimeClass |
| --- | --- |
| `standard` | none required |
| `hardened` | `gvisor` |
| `isolated` | `kata` |

The `ci` namespace requires `gvisor` whatever its pods claim. Every sandboxed pod, `standard` included, sets `automountServiceAccountToken: false`. A new class, such as `confidential`, is added to the policy's `runtimeClassByIsolationClass` map together with its fixtures; until then it is refused as unknown.

## Granted exceptions

Every exception is written into the policy that grants it, names one workload or one namespace, and grants only the specific relaxation listed. A pod is matched to its workload through its controlling owner reference, so a `node-exporter` DaemonSet in any other namespace gets nothing. Each grant has fixtures that prove it admits exactly this and refuses the next step past it.

| Policy | Granted to | What is granted | Why |
| --- | --- | --- | --- |
| `host-access` | DaemonSet `observability/node-exporter` | `hostNetwork`, `hostPID`, hostPort 9100, read-only hostPath `/`, `/proc`, `/sys` | node metrics come from the host's own `/proc`, `/sys` and network stack |
| `host-access` | DaemonSet `observability/vector` | `hostNetwork`, hostPort 9598, read-only hostPath `/var/log`, writable hostPath `/var/lib/vector` | it tails the pod and audit logs on each node and keeps its read checkpoints across restarts |
| `pod-security-restricted` | DaemonSet `observability/node-exporter` | hostPath volumes (the paths above) | as above |
| `pod-security-restricted` | DaemonSet `observability/vector` | hostPath volumes, running as root | the logs under `/var/log` on a Talos node belong to root |
| `pod-security-restricted` | container `buildkitd` of a `gvisor` pod in `ci`, image `docker.io/moby/buildkit:*-rootless@sha256:*` | `allowPrivilegeEscalation`, the default capability set (it may still add nothing) | rootless BuildKit maps its user namespace through the setuid `newuidmap`; gVisor is the boundary |
| `pod-security-floor` | namespace `observability` | PodSecurity `enforce: privileged` | PodSecurity cannot exempt one workload, so the namespace allows what the two DaemonSets need and `host-access` and `pod-security-restricted` hold every other pod there to `restricted` |
| `pod-security-floor` | namespace `ci` | PodSecurity `enforce: baseline` | rootless BuildKit, as above; `pod-security-restricted` holds every other container in `ci` to `restricted` |
| `resource-limits` | pods labelled `cnpg.io/cluster` (CloudNativePG instances and jobs), volume `plugins` only, disk-backed | an `emptyDir` without `sizeLimit` | the barman-cloud plugin injects it to hold its unix socket and gives it no size; the containers' ephemeral-storage limits still bound it. A memory-backed `plugins` volume, or the name on any other pod, is refused |
| `encrypted-volumes` | PVC `zot/zot-data` | StorageClass `hcloud-volumes` (unencrypted) | it was bound before `hcloud-luks` existed and a StorageClass cannot be changed on a bound claim; it holds only mirrored public images. Moving it to `hcloud-luks` removes the grant |
| `service-exposure` | Service `zot/zot`, nodePort 30500 only | type `NodePort` | the nodes' containerd pulls through Zot on `127.0.0.1:30500` ([talos-registry-mirrors](talos-registry-mirrors.md)) |
| `service-exposure` | Service `ops-gateway/cilium-gateway-ops`, only while the Gateway `ops` owns it | type `NodePort`, any port | Cilium creates a host-network Gateway's Service as a NodePort with a port it picks; the consoles are served by Envoy on the host network, not through that port ([ops-consoles](ops-consoles.md)) |

Adding a grant means adding it to the policy's grant map, adding an admitted fixture for it and a refused fixture for the nearest thing it must not allow, and adding a row here.

## A policy change lands before its workload

The root Flux Kustomization (`kubernetes/clusters/main/kustomization.yaml`) applies `admission-policies` and the workloads in one server-side apply. Its dry-run judges every workload against the policy already in the cluster, not the one in the same commit. A workload that only the new policy admits (a new image prefix in `pinned-approved-images`, a grant in `host-access` or `pod-security-restricted`) fails the dry-run, the whole apply stops, the new policy is never applied, and every retry fails the same way. The Kustomization `flux-system` then reports `False` with `dry-run failed (Forbidden)` and a `ValidatingAdmissionPolicy` name; children with their own Flux Kustomization keep reconciling.

So a policy change merges first, and the workload merges once `flux-system` reports `Applied revision` for it.

When the deadlock has happened: check that the policy in Git admits the workload (`granted: []` in the message means the cluster still has the old grant map), then apply the policies from Git once as Flux would, and let the next reconcile carry on:

```sh
kubectl apply --server-side --field-manager=kustomize-controller -k kubernetes/platform/admission-policies
```

The observability merge of 2026-10-26 deadlocked this way on `alloy-logs`.

## Rollout: Audit, Warn, then Deny

New policies bind `validationActions: ["Audit", "Warn"]`. A violation is admitted, the client gets a warning naming the policy, and the API server adds an audit annotation and counts it in `apiserver_validating_admission_policy_check_total`. A policy moves to `["Deny"]` in its own pull request once the audit shows no violation from a workload that should keep running, and that pull request fixes or exempts what the audit found.

Known violations on the day the policies landed, all `resource-limits`: the `etcd-backup` CronJob and the five Flux controllers set no ephemeral-storage limit, and their `emptyDir` volumes have no `sizeLimit`. The Flux controllers come from the operator's manifests, so their fix is a patch in the FluxInstance.

### Moving to Deny (2026-10-25)

Every policy denies; `immutable-image-references` followed in `kube-system` once Talos ran the control plane and CoreDNS by digest ([kubernetes-upgrades](kubernetes-upgrades.md)). The evidence before the switch:

- `apiserver_validating_admission_policy_check_total` on each API server counted violations of `resource-limits`, `host-access`, `pod-security-restricted`, `pod-security-floor`, `immutable-image-references` and `cluster-admin-bindings`, and none of the others.
- A server-side dry run of every live Deployment, StatefulSet, DaemonSet, CronJob, Job, Pod, Service, Namespace and `cluster-admin` binding named the violators: every workload outside `kube-system` lacked an ephemeral-storage limit (Flux, External Secrets, KEDA, Zot and its credentials Job, kube-state-metrics, vmagent, node-exporter, Vector, etcd-backup); node-exporter and Vector use the host; `observability` lowers PodSecurity; Zot is a NodePort; the Talos images in `kube-system` carry no digest. The `cluster-admin` binding to `system:masters` is the API server's own, which the policy exempts by user.

The violators were fixed in their manifests, the rest became the grants above, and the same replay was run against the Deny set on a throwaway API server: every rendered workload of `kubernetes/` (HelmRelease charts templated with their values, the FluxInstance patches applied to the live controllers, the CI runner's pod and Job) and every live object is admitted without a word, except the live objects the fix replaces and the `kube-system` images.

A Deny policy also refuses an UPDATE of an object that already violates it. Flux replaces each fixed workload in the same reconcile that lands the policies, so this matters only for a HelmRelease whose upgrade fails: its old pods keep running, but a replacement pod is refused until the release goes through. On a rebuild, Talos installs the Flux operator from its chart without the `emptyDir` size the HelmRelease adds as a post-renderer; the operator's pod is compliant once its HelmRelease first reconciles.

### Why there is no defaulting MutatingAdmissionPolicy yet

The one MutatingAdmissionPolicy, `trivy-scan-job-defaults`, sets nothing a workload chooses: it bounds the scratch volumes of Jobs the Trivy Operator generates, which no chart value reaches ([ADR 0010](../adr/0010-trivy-operator-scans-in-the-cluster.md)). Its fixtures are under `resource-limits`: the operator's Job is admitted only because of it, and the same Job without the operator's label stays refused.

RFC 0001 tier 3 sets safe defaults with `MutatingAdmissionPolicy` (GA, served at `admissionregistration.k8s.io/v1` on 1.37). A mutation has no Audit mode: it changes every matching pod the moment it lands. The defaults it would set (`hostUsers: false`, seccomp, the token opt-out, the RuntimeClass) are exactly what the validating set above now reports on, so the mutating set follows once that audit is clean, with the same fixtures.

## Tests

Every policy has a directory under [tests/admission-policies](../../tests/admission-policies) named after it, with at least one `refused-*.yaml` and one `admitted-*.yaml`. [scripts/test-admission-policies.sh](../../scripts/test-admission-policies.sh) starts a throwaway etcd and kube-apiserver at the cluster's Kubernetes version on loopback, applies the policies as Flux would, and sends each fixture as a server-side dry run. A refused fixture passes when the server's answer names its policy, as a denial or a warning; an admitted one passes when the request succeeds and the policy is not named.

```sh
./scripts/test-admission-policies.sh                  # the fixtures
./scripts/test-admission-policies.sh --mutation-test  # and prove each policy is what refuses
```

While one policy's fixtures run, every other binding is switched to `Warn` on the throwaway server, so a fixture refused by a neighbouring policy cannot pass for the one under test. The output says whether each refused fixture was `denied` or `warned`. Fixtures go in as server-side apply dry runs, so a fixture naming an existing object, such as the `ci` namespace, is checked as the UPDATE Flux sends.

The mutation test replaces every validation of one policy at a time with `true` and requires all of that policy's refused fixtures to go through. A fixture that is still refused was never testing its policy. The `admission-policies-check` workflow runs the mutation test on every pull request and push to `main` that touches the policies, the fixtures or the script.

Adding a policy: write the policy and its binding, add them to the kustomization, add the fixture directory, and run the script. It fails until the directory has both kinds of fixture.
