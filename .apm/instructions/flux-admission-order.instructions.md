---
description: "Land an admission policy change before the workload it admits, so the root Flux Kustomization does not deadlock"
applyTo: "kubernetes/**"
---

# Admission policies and the workloads they admit

- Never change an admission policy and a workload that needs that change in the same commit or pull request. The root Flux Kustomization applies `kubernetes/platform/admission-policies` and the workloads in one server-side apply, and its dry-run judges every workload against the policy already in the cluster. A workload the old policy refuses fails the dry-run, the new policy is never applied, and the root Kustomization stays `False` on every retry.
- Merge the policy change first, wait until the root Kustomization `flux-system` reports `Applied revision` for it, then merge the workload. This holds for new image prefixes in `pinned-approved-images.yaml`, grants in `host-access.yaml` and `pod-security-restricted.yaml`, and every other policy that names a workload.
- When the root Kustomization is stuck on `dry-run failed (Forbidden)` from a ValidatingAdmissionPolicy, compare the in-cluster policy with Git before changing the workload: the policy in Git may already admit it.
