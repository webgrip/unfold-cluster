---
status: accepted
date: 2026-10-25
---

# ADR 0011: Kyverno, and nothing else of it, checks the cosign signature of webgrip images at admission

## Context and problem statement

Every pod outside `kube-system` and `flux-system` already has to name a digest-pinned image from an
approved prefix (`pinned-approved-images`, a native ValidatingAdmissionPolicy in Deny). A digest
says which bytes run, not who built them. RFC 0001 wants images we build to carry a cosign
signature checked at admission. The estate signs with one key: the OpenBao Transit key
`cosign-webgrip` (ECDSA P-256, `--tlog-upload=false`), used by Forgejo's release jobs for Harbor's
`webgrip` project and for `ghcr.io/webgrip/*`. A ValidatingAdmissionPolicy cannot fetch a
signature from a registry, so a webhook is needed. Four were weighed.

## Facts the decision rests on

Each was checked on 2026-10-25.

* **The key and the images.** `ghcr.io/webgrip/unfold:0.4.0-rc.114`
  (`sha256:139d0a0f…`, the Unfold application that is to run here) verifies with
  `cosign verify --key cosign-webgrip.pub --insecure-ignore-tlog`; its `linux/amd64` child manifest
  (`sha256:39e39f6b…`) carries no signature of its own. The public key is the one the homelab's
  `cosign-pubkey-publish` CronJob mirrors from Transit; the Transit key has one version.
* **Kyverno 1.19.2** (chart 3.9.2, 2026-10-21) is the version RFC 0001 already names for this
  cluster (it fixed 24 advisories). Its `ImageValidatingPolicy` takes a static cosign key,
  `insecureIgnoreTlog`, `validationActions` Audit, Warn and Deny like a ValidatingAdmissionPolicy,
  and records each result as `kyverno_image_validating_policy_results_total`. The Kyverno CLI runs
  the same verification engine, so the policy can be tested without a cluster.
* **Kyverno's footprint with only the admission controller and the reports controller.** About
  480 MiB requested for two admission replicas and one reports controller, on the control planes. The background and
  cleanup controllers and the generation of ValidatingAdmissionPolicies are off, so Kyverno does
  not duplicate the native policies.
* **Sigstore policy-controller** is lighter (one webhook) but opts in per namespace with a label,
  and its non-enforcing mode (`mode: warn`) only warns the client: there is no report to read an
  audit from. RFC 0001 already plans Kyverno for generating and deleting policies, so
  policy-controller would be a second webhook to retire later.
* **Ratify with Gatekeeper** needs both components and a Rego or CEL constraint layer that
  overlaps the native policies; it is the heaviest of the four.
* **Connaisseur** (v3.13.1, 2026-10-16, monthly releases) supports static cosign keys and a
  detection mode, and is about as light as policy-controller. It does only signatures, so it too
  would sit beside the Kyverno that RFC 0001 plans, as a second webhook with its own
  configuration format.
* **Release pace.** policy-controller's last release is v0.15.1 (2026-03-26).

## Decision

Install Kyverno 1.19.2 with only its admission controller (two replicas on the control planes, a
PodDisruptionBudget) and its reports controller, and give it two ImageValidatingPolicies:

* `webgrip-image-signatures`: `ghcr.io/webgrip/*`, `forgejo.webgrip.dev/webgrip/*` and
  `harbor.webgrip.dev/webgrip/*`, over HTTPS.
* `webgrip-image-signatures-zot`: `zot.zot.svc.cluster.local:5000/webgrip/*`, what CI pushes, over
  plain HTTP inside the cluster.

Both require a cosign signature from `cosign-webgrip` on every matching image in containers,
init containers and ephemeral containers, with `required: true` and the same check in a CEL
validation, so either gate alone refuses. Both start in Audit and Warn with `failurePolicy:
Ignore`. Third-party images stay as they are: digest-pinned under `pinned-approved-images`.

## Consequences

* Kyverno reads signatures from ghcr.io and forgejo.webgrip.dev directly (its egress names exactly
  those) and from Zot. Harbor is LAN-only, so a Harbor image cannot be verified from here; it is
  refused anyway, because Harbor is not an approved prefix.
* What CI pushes to Zot is unsigned: a CI job is untrusted and holds no signing key (runbook
  `ci-runners.md`). Those images are reported until a trusted job signs them.
* The public key is in git, like Flux's trusted signers. A rotation of the Transit key is a pull
  request that adds the new key next to the old one ([image-signatures](../runbooks/image-signatures.md#when-the-signing-key-rotates)).
* Moving to Deny is its own pull request, with the conditions in
  [image-signatures](../runbooks/image-signatures.md#from-audit-to-deny).
