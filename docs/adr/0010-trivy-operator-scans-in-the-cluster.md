---
status: accepted
date: 2026-10-25
---

# ADR 0010: Trivy Operator scans every running image in the cluster, with its database from Zot

## Context and problem statement

RFC 0001 section 12 names Trivy twice: in CI before signing, and as the Trivy Operator in the
cluster. The owner asked for "trivy etc": vulnerability reports for the images that run,
configuration audits, secrets baked into images, an RBAC assessment and an SBOM per image, with
metrics and reports in the homelab and an alert on new fixable CRITICAL vulnerabilities. The
nodes are small (control planes 2 vCPU and 4 GB, `unfold-app-1` 4 vCPU and 8 GB), so the
alternative was a scheduled `trivy` run instead of a resident operator.

## Facts the decision rests on

Each was checked on 2026-10-25.

* **Room.** The kubelet summary API reported `unfold-app-1` with 1.2 GB in use and 6.5 GB
  available, and requests at 34 % of its memory; each control plane had about 1.5 GB available.
* **What the operator costs.** The homelab runs Trivy Operator 0.34 against about 150 images: the
  operator peaks at about 611 MiB, its built-in Trivy server idles at about 30 MiB and holds the
  database while it serves, and scan jobs need about 256 MiB to 1 GiB each. Unfold runs about 25
  images, so one scan job at a time is enough.
* **Detection latency.** The operator scans a workload within minutes of it appearing and rescans
  when its report expires (24 hours). A nightly CronJob finds a new image up to a day later.
* **What a CronJob would need instead.** `trivy k8s` covers vulnerabilities, misconfigurations,
  secrets and RBAC, but it pulls images from the internet (Trivy's own `registry.mirrors` maps a
  host to a host and cannot add Zot's `/<registry>` path prefix), produces no per-image SBOM, and
  has no metrics: every metric and report shape would be our own code.
* **The operator against the Deny admission set.** Its generated scan Jobs mount two `emptyDir`
  volumes without `sizeLimit` (`pkg/plugins/trivy/image.go`, `jobspec.go` at v0.35.0), which
  `resource-limits` refuses, and the chart's Trivy server StatefulSet hard-codes two more. The
  chart volumes are fixed by a Flux post-renderer patch; the Job volumes need a mutation at
  admission, because no chart value reaches them. The homelab also hit upstream issue
  trivy-operator#2859 (sibling Trivy processes in one scan pod share `/tmp/trivy-<pid>` and delete
  each other's directory) and fixed it with `shareProcessNamespace`.
* **Supply chain of Trivy itself.** Trivy's March 2026 compromise (CVE-2026-33634) shipped bad
  v0.69.4 binaries and v0.69.5 and v0.69.6 images. The images used here verify against
  Aqua's release workflows with cosign: `docker.io/aquasec/trivy-operator:0.35.0` (keyless,
  `aquasecurity/trivy-operator/.github/workflows/release.yaml@refs/tags/v0.35.0`) and
  `ghcr.io/aquasecurity/trivy:0.75.0` (Sigstore bundle, cosign 3), both pinned by digest.
* **Aqua stopped publishing the chart as OCI after 0.32.1.** `ghcr.io/aquasecurity/helm-charts/trivy-operator`
  ends at 0.32.1; 0.37.0 exists only in the HTTPS chart repository (tarball sha256
  `6d23f16d…cedf69`). Flux cannot pin a digest on a `HelmRepository` chart, so the chart is pinned by
  version and every image in it by digest.

## Decision

Run Trivy Operator 0.35.0 (chart 0.37.0) in `trivy-system`, on the hub pool, in client-server mode
with the built-in Trivy server:

* Vulnerability scans with SBOMs and exposed-secret scanning, config audit and RBAC assessment.
  Infra assessment and cluster compliance stay off: both need the node collector, which needs
  host paths that Talos does not have (the homelab learned this).
* HIGH and CRITICAL only, unfixed included, one scan job at a time.
* Every pull goes through Zot: the Trivy database (`ghcr.io/aquasecurity/trivy-db`), the check
  bundle, and the images being scanned, through the operator's registry mirror map. Nothing in
  `trivy-system` reaches the internet. The Java database (about 1 GB) is not downloaded.
* A MutatingAdmissionPolicy, `trivy-scan-job-defaults`, gives the operator's scan Jobs in
  `trivy-system` a `sizeLimit` on every unbounded `emptyDir` and `shareProcessNamespace`. It is the
  cluster's first mutation and is scoped to Jobs labelled `app.kubernetes.io/managed-by:
  trivy-operator` in that one namespace. The validating policies are not relaxed.
* Metrics go to vmsingle-unfold through vmagent. Each report the operator writes is posted to a
  small Vector Deployment, which writes a compact record of it to VictoriaLogs; full reports stay
  in the cluster as CRs.

## Consequences

* About 500 MiB requested on `unfold-app-1` (operator 192 MiB, server 256 MiB, shipper 48 MiB),
  plus up to 1 GiB while a scan job runs. No volume is bought: the Trivy server keeps its database
  in an `emptyDir` and fetches it again from Zot after a restart.
* The MutatingAdmissionPolicy has no Audit mode. It touches nothing but the operator's own Jobs, and
  the admission fixtures prove both what it changes and that a Job without the operator's label
  stays refused.
* The chart version is not pinned by digest. Renovate still proposes chart bumps, and each image
  bump is a digest change reviewed with it.
* If the operator ever proves too heavy, the scheduled scan above is the fallback, at the price of
  writing the metrics ourselves.
