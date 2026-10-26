---
description: "Land an admission policy change before the workload it admits"
applyTo: "kubernetes/**"
---

# Admission policies

- Merge an admission policy change before the workload that needs it, never in one commit: Flux dry-runs the workload against the policy already in the cluster and the root Kustomization deadlocks. Why and how to recover: [admission policies](docs/runbooks/admission-policies.md#a-policy-change-lands-before-its-workload).
