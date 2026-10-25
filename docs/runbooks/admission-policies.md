# Admission policies

The API server enforces the cluster's admission rules in-process as native `ValidatingAdmissionPolicy` objects (CEL). Flux reconciles them from [kubernetes/platform/admission-policies](../../kubernetes/platform/admission-policies). This is tier 2 of RFC 0001 section 3. Nothing here needs a webhook, so an outage of any admission component cannot stop the API server from checking these rules.

## The catalogue

| Policy | Refuses | Where | Action |
| --- | --- | --- | --- |
| `pinned-approved-images` | an image without `@sha256:` or outside the approved registry prefixes, in containers, init and ephemeral containers and image volumes | every namespace but `kube-system`, `flux-system` | Deny |
| `pod-security-restricted` | the PodSecurity `restricted` profile, checked separately: root, privilege escalation, capabilities beyond dropping ALL (plus `NET_BIND_SERVICE`), unconfined seccomp, other volume types, `procMount`, unsafe sysctls, unconfined AppArmor, SELinux user or role | every namespace but `kube-system` | Audit, Warn |
| `host-access` | privileged containers, `hostNetwork`, `hostPID`, `hostIPC`, `hostPath`, `hostPort`, Windows host processes | every namespace but `kube-system` | Audit, Warn |
| `sandbox-annotations` | pod annotations under `io.katacontainers.` or `dev.gvisor.` | every namespace | Deny, since the metal node brought Kata ([ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md)) |
| `sandboxed-workloads` | a sandboxed pod on the wrong RuntimeClass or with its service-account token mounted, or an unknown isolation class | pods labelled, or in a namespace labelled, `ploeg.webgrip.dev/isolation-class`, and the `ci` namespace | Audit, Warn |
| `immutable-image-references` | an image without a digest, or one naming the `latest` tag | every namespace | Audit, Warn |
| `resource-limits` | a container without cpu and memory requests, a memory limit or an ephemeral-storage limit, an `emptyDir` without `sizeLimit` | every namespace but `kube-system` | Audit, Warn |
| `service-exposure` | Services of type `NodePort`, `LoadBalancer` or `ExternalName`, and `externalIPs` | every namespace | Audit, Warn |
| `cluster-admin-bindings` | a ClusterRoleBinding or RoleBinding to `cluster-admin` for anyone but Flux's `kustomize-controller`, `helm-controller` and `flux-operator` | every namespace; the API server's own bootstrap is exempt | Audit, Warn |
| `service-account-token-secrets` | Secrets of type `kubernetes.io/service-account-token` | every namespace | Audit, Warn |
| `pod-security-floor` | a namespace whose `pod-security.kubernetes.io/enforce` label is anything but `restricted` | every namespace but `kube-system` | Audit, Warn |

The policies match Pods and the pod templates in Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs and CronJobs, so Flux's apply sees the warning before a controller creates the Pod.

### Isolation classes and RuntimeClasses

`sandboxed-workloads` reads the class from the pod's `ploeg.webgrip.dev/isolation-class` label (Ploeg ADR-0106) and from the same label on its namespace, and the stricter of the two wins. A pod cannot label itself down from its namespace's class.

| Class | RuntimeClass |
| --- | --- |
| `standard` | none required |
| `hardened` | `gvisor` |
| `isolated` | `kata` |

The `ci` namespace requires `gvisor` whatever its pods claim. Every sandboxed pod, `standard` included, sets `automountServiceAccountToken: false`. A new class, such as `confidential`, is added to the policy's `runtimeClassByIsolationClass` map together with its fixtures; until then it is refused as unknown.

## Rollout: Audit, Warn, then Deny

New policies bind `validationActions: ["Audit", "Warn"]`. A violation is admitted, the client gets a warning naming the policy, and the API server adds an audit annotation and counts it in `apiserver_validating_admission_policy_check_total`. A policy moves to `["Deny"]` in its own pull request once the audit shows no violation from a workload that should keep running, and that pull request fixes or exempts what the audit found.

Known violations on the day the policies landed, all `resource-limits`: the `etcd-backup` CronJob and the five Flux controllers set no ephemeral-storage limit, and their `emptyDir` volumes have no `sizeLimit`. The Flux controllers come from the operator's manifests, so their fix is a patch in the FluxInstance.

### Why there is no MutatingAdmissionPolicy yet

RFC 0001 tier 3 sets safe defaults with `MutatingAdmissionPolicy` (GA, served at `admissionregistration.k8s.io/v1` on 1.37). A mutation has no Audit mode: it changes every matching pod the moment it lands. The defaults it would set (`hostUsers: false`, seccomp, the token opt-out, the RuntimeClass) are exactly what the validating set above now reports on, so the mutating set follows once that audit is clean, with the same fixtures.

## Tests

Every policy has a directory under [tests/admission-policies](../../tests/admission-policies) named after it, with at least one `refused-*.yaml` and one `admitted-*.yaml`. [scripts/test-admission-policies.sh](../../scripts/test-admission-policies.sh) starts a throwaway etcd and kube-apiserver at the cluster's Kubernetes version on loopback, applies the policies as Flux would, and sends each fixture as a server-side dry run. A refused fixture passes when the server's answer names its policy, as a denial or a warning; an admitted one passes when the request succeeds and the policy is not named.

```sh
./scripts/test-admission-policies.sh                  # the fixtures
./scripts/test-admission-policies.sh --mutation-test  # and prove each policy is what refuses
```

The mutation test replaces every validation of one policy at a time with `true` and requires all of that policy's refused fixtures to go through. A fixture that is still refused was never testing its policy. The `admission-policies-check` workflow runs the mutation test on every pull request and push to `main` that touches the policies, the fixtures or the script.

Adding a policy: write the policy and its binding, add them to the kustomization, add the fixture directory, and run the script. It fails until the directory has both kinds of fixture.
