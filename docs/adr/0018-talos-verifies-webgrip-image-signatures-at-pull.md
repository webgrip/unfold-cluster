---
status: accepted
date: 2026-11-01
---

# ADR 0018: Talos verifies webgrip image signatures when a node pulls them, and Kyverno leaves after it

## Context and problem statement

[ADR 0011](0011-kyverno-checks-webgrip-image-signatures.md) has Kyverno check the cosign signature
of webgrip images at admission, in Audit and Warn, with `failurePolicy: Ignore`: it reports an
unsigned image and lets it start. That check costs the control planes, which ran at 97 to 103% of
their memory on 2026-11-01 ([ADR 0013](0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md)),
more than anything else that could leave them: Kyverno's CRDs are 2.8 MB of the 7.6 MB of CRD
schema every API server holds (37%), its admission controller about 180 MiB, and its webhook sits
in every pod's admission. RFC 0001 already plans a second check at pull, by Talos (delivery step 9).
The question is whether that check can carry the whole job, so Kyverno can go.

## Facts the decision rests on

Checked on 2026-11-01, on a throwaway single-node Talos 1.14.4 (Kubernetes 1.37.1) in QEMU, with
the `ImageVerificationConfig` this record adds:

* **A static key works, without a transparency log.** A `publicKey` rule whose `certificate` holds
  the PEM public key of the OpenBao Transit key `cosign-webgrip` (not a certificate) verifies
  `ghcr.io/webgrip/unfold@sha256:c7836272…`, the image Unfold staging runs, which was signed with
  `--tlog-upload=false`.
* **It refuses.** Its unsigned `linux/amd64` child manifest (`sha256:570a3bd3…`) and the unsigned
  `forgejo.webgrip.dev/webgrip/infra-runner` are refused at pull: `talosctl image pull` returns
  `image verification failed: no valid signature found`, and a pod gets `ErrImagePull` with the
  event `failed to verify image`. An image no rule matches (`registry.k8s.io/pause`) pulls as before.
* **It works through Zot.** With a Zot v2.1.22 configured like `kubernetes/platform/zot` as the
  `ghcr.io` mirror, the signed image pulls and the unsigned one is refused, both with
  `skipFallback: true` (Zot answered the signature tags) and with Zot stopped and `skipFallback:
  false` as in production (the node fell back to ghcr.io and still verified).
* **First match wins.** A `skip` rule for one repository placed before the patterns lets that
  repository through and nothing else.
* **No reboot.** Changing the `ImageVerificationConfig` applied without a reboot.
* **What runs here.** From kube-state-metrics over 14 days, the only webgrip image that ran is
  `ghcr.io/webgrip/unfold`, signed. `forgejo.webgrip.dev/webgrip/infra-runner`, which the check
  jobs use, is not signed.
* **Limits.** Talos checks when it pulls; an image already on the node is not checked again. It
  has no audit mode: a matching rule either verifies or refuses. It does not check attestations
  (SBOM, provenance).

## Decision

Every node (control planes, workers, autoscaled pools, the metal node) carries one
`ImageVerificationConfig` (`infra/image-verification.tf`), with the public key in
`infra/keys/cosign-webgrip.pub`:

1. `skip` for each webgrip repository that is not signed yet, by its exact name:
   `forgejo.webgrip.dev/webgrip/infra-runner`.
2. `publicKey` for `ghcr.io/webgrip/*`, `ghcr.io/webgrip/*/*`, `forgejo.webgrip.dev/webgrip/*` and
   `forgejo.webgrip.dev/webgrip/*/*`.

Images that match no rule pull as before; `pinned-approved-images` still limits them to digest-pinned
approved prefixes. Zot's `webgrip/` path, which CI pushes unsigned, is not matched, as under
ADR 0011 where it was reported only.

The alert `UnfoldWebgripImageNotPulled` replaces Kyverno's report: a webgrip image that stays in
`ErrImagePull` or `ImagePullBackOff` for 10 minutes.

Kyverno is removed in a later pull request, once this check is applied to every node and has run
for a week without refusing an image that should run. That pull request supersedes ADR 0011.

## Consequences

* Good, because the check enforces where ADR 0011 only reported, and does so in each node's
  container runtime: no webhook, no CRD, nothing on the control planes, and nothing that can be
  down while pods start.
* Good, because removing Kyverno afterwards frees 2.8 MB of CRD schema in every API server and
  about 180 MiB of pods on the control planes.
* Bad, because an unsigned webgrip image now fails to start instead of being reported. A release
  that skips signing breaks its own rollout; the alert names it.
* Bad, because `infra-runner` is let through unsigned until its release job signs it; then its
  `skip` rule goes.
* Bad, because RFC 0001's later Kyverno jobs (attestation checks at admission, generating and
  deleting policies) have no home here; each needs its own decision when it is due.
* Bad, because each rule holds one key and the first matching rule wins, so Talos cannot trust an
  old and a new key side by side: a rotation of `cosign-webgrip` first signs every webgrip digest
  in use with the new key too, then replaces `infra/keys/cosign-webgrip.pub` in an `infra` apply.

## Confirmation

* `infra/tests/image_verification.tftest.hcl`: every node type's machine config carries the
  document, the four patterns verify against `infra/keys/cosign-webgrip.pub`, and every `skip` rule
  names one repository without a wildcard and comes before the verifying rules.
* After the apply, on each node: `talosctl -n <node> get mc -o yaml | grep -A3 ImageVerificationConfig`.
* `talosctl -n <worker> image pull --namespace cri ghcr.io/webgrip/unfold@sha256:570a3bd3b4aa734063ac65f5159057116e42612e186d3bf1a89fef14307d016a`
  is refused with `image verification failed`.
