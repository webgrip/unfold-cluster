# Image signatures: Talos and Kyverno check webgrip images

Every image we build must carry a cosign signature from the estate's signing key before it runs on
Unfold. Unfold's releases from GitHub (`ghcr.io/unfold-hq/*`) carry a keyless signature from their
release workflow instead. The native admission policies cannot read a registry, so Kyverno does
this one job. Why Kyverno and not policy-controller, Ratify or Connaisseur: [ADR 0011](../adr/0011-kyverno-checks-webgrip-image-signatures.md).
Everything is in `kubernetes/platform/kyverno`, reconciled by the Flux Kustomizations `kyverno`
(the chart) and `kyverno-policies` (the policies, after the chart's CRDs exist).

## Talos refuses unsigned webgrip images at pull

Every node carries an `ImageVerificationConfig` ([ADR 0018](../adr/0018-talos-verifies-webgrip-image-signatures-at-pull.md),
`infra/image-verification.tf`, applied by the `infra` workflow). When a node pulls an image, Talos
takes the first rule that matches its registry and repository:

| Rule | Images | Effect |
| --- | --- | --- |
| `publicKey` | `ghcr.io/webgrip/*`, `forgejo.webgrip.dev/webgrip/*`, and one path level deeper | pulled only with a valid signature from `infra/keys/cosign-webgrip.pub` |

Anything else, `ghcr.io/unfold-hq/*` included, pulls as before. Talos checks only when it pulls: an
image already on the node is not checked again. There is no audit mode.

A refused image leaves the pod in `ErrImagePull`, with the event `failed to verify image`; after 10
minutes the homelab alert `UnfoldWebgripImageNotPulled` fires. To check by hand from a device on
the tailnet:

```sh
talosctl -n <node> image pull --namespace cri <image>@<digest>
cosign verify --key infra/keys/cosign-webgrip.pub --insecure-ignore-tlog <image>@<digest>
```

An unsigned release is fixed by signing it in its release job, never by a `skip` rule. A `skip`
rule names one repository exactly and sits before the patterns; the infra tests refuse a wildcard.

Kyverno still runs the admission check below until it is removed (ADR 0018).

## What Kyverno checks

| Policy | Images | Registry access |
| --- | --- | --- |
| `webgrip-image-signatures` | `ghcr.io/webgrip/*`, `forgejo.webgrip.dev/webgrip/*`, `harbor.webgrip.dev/webgrip/*` | HTTPS from the admission controller |
| `webgrip-image-signatures-zot` | `zot.zot.svc.cluster.local:5000/webgrip/*` (what CI pushes) | plain HTTP inside the cluster |
| `unfold-hq-image-signatures` | `ghcr.io/unfold-hq/*` (`unfold`, `unfold-agent`) | HTTPS from the admission controller, plus Sigstore's TUF root and Rekor |

For the two webgrip policies, a matching image in a container, init container or ephemeral
container needs a cosign signature, on its digest, that verifies with the public half of the
OpenBao Transit key `cosign-webgrip`. Those signatures are made without a transparency log entry,
so these two policies skip the transparency log. They accept both cosign signature formats: the
legacy `.sig` tag and cosign 3's Sigstore bundle.
Two gates refuse an unsigned image, each on its own: `required: true` (every matching image must
be verified) and the CEL validation that calls `verifyImageSignatures`.

Images from anyone else are not checked here: they stay digest-pinned and limited to the approved
prefixes by `pinned-approved-images`. Harbor is reachable only on the homelab LAN, so a Harbor
image cannot be verified from Unfold; `pinned-approved-images` refuses Harbor anyway.

### Keyless unfold-hq releases

Unfold is released from [github.com/unfold-hq/unfold](https://github.com/unfold-hq/unfold) to
`ghcr.io/unfold-hq/unfold`, `ghcr.io/unfold-hq/unfold-agent` and the chart
`oci://ghcr.io/unfold-hq/charts/unfold`, signed keyless with GitHub Actions OIDC. A matching image
needs a cosign signature, on its digest, whose Fulcio certificate names:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject (regexp) | `^https://github\.com/unfold-hq/unfold/\.github/workflows/on_release_published\.yml@refs/tags/unfold-v0\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$` |
| Transparency log | Rekor, `https://rekor.sigstore.dev` |

Only a release tag `unfold-v0.x.y` or `unfold-v0.x.y-rc.n` of that one workflow qualifies: a build
from a branch, a fork or another workflow fails. Kyverno takes Sigstore's trusted root (Fulcio and
log keys) from `tuf-repo-cdn.sigstore.dev`, which its network policy allows by name together with
`rekor.sigstore.dev`. The chart is not checked here: Kyverno sees pods, not the chart Flux pulls.
Nothing in the cluster runs from `ghcr.io/unfold-hq` yet; Flux moves to it after the first release
from GitHub. `pinned-approved-images` does not list those prefixes yet either, and refuses them.
To check a release by hand:

```sh
cosign verify ghcr.io/unfold-hq/unfold@<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/unfold-hq/unfold/\.github/workflows/on_release_published\.yml@refs/tags/unfold-v0\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
```

When the release workflow's file name or tag format changes, the subject in
`unfold-hq-image-signatures.yaml` changes with it, in a pull request merged before the first release
signed the new way.

## Audit now

All three policies run with `validationActions: [Audit, Warn]` and `failurePolicy: Ignore`. An
unsigned webgrip or unfold-hq image is admitted, and:

- the client that applied it gets a warning naming the policy (Flux shows it in its events);
- Kyverno's admission controller logs the refusal it did not enforce, with the pod's namespace and
  name: `kubectl -n kyverno logs deploy/kyverno-admission-controller | grep -E '(webgrip|unfold-hq)-image-signatures'`
  (no PolicyReport: the reports controller is off since 2026-10-26, ADR 0013);
- `kyverno_image_validating_policy_results_total{result="fail"}` goes up, and the homelab alert
  `UnfoldUnsignedWebgripImage` fires.

If Kyverno is down, pods start unchecked (`failurePolicy: Ignore`), and
`UnfoldSignatureWebhookAbsent` fires.

## From Audit to Deny

In one pull request, once all of these hold:

1. A trusted job signs what CI pushes to Zot `webgrip/**` (or nothing runs from Zot's `webgrip/`
   path), and every webgrip image that runs here passes: no `fail` result in
   `kyverno_image_validating_policy_results_total` for 7 days.
2. Kyverno runs three admission replicas on the control planes (RFC 0001), with the
   PodDisruptionBudget.
3. The pull request changes `validationActions` to `[Deny]` and `failurePolicy` to `Fail`, and
   adds `kube-system`, `flux-system` and `kyverno` to the webhook's excluded namespaces if they are
   not already excluded (they are, in `config.webhooks`).
4. `./scripts/test-image-signatures.sh --mutation-test` passes, and a server-side dry run of a pod
   with the unsigned fixture image against the live cluster is refused.

## When the signing key rotates

The homelab rotates `cosign-webgrip` by adding a Transit key version
(homelab runbook `cosign-transit-key-rotation.md`). The public key here is in git, like Flux's
trusted signers, twice while Kyverno runs: in `infra/keys/cosign-webgrip.pub` for Talos and in the
Kyverno policies. Talos takes the first matching rule and each rule holds one key, so it cannot
trust two keys for one pattern: sign every webgrip digest that runs or may be rolled back to with
the new key as well (cosign keeps both signatures), then replace the key in
`infra/keys/cosign-webgrip.pub` and run an `infra` apply. Before old signatures stop being trusted:

1. Read the new public key: `kubectl -n security get configmap cosign-webgrip-pub -o jsonpath='{.data.cosign\.pub}'`
   on the homelab (it lists every trusted version, newest first).
2. Add it as a second attestor in both policies (`attestors`, and `[attestors.webgrip, attestors.<new>]`
   in the validation), keep the old one until every running image is re-signed, then remove it.

## Tests

`./scripts/test-image-signatures.sh --mutation-test` runs the policies through the Kyverno CLI
(the admission controller's verification engine), and `supply-chain-check` runs it on every pull
request that touches the policies:

- against ghcr.io with the real key: the signed `ghcr.io/webgrip/unfold` index passes; its unsigned
  `linux/amd64` manifest fails as a container, as an init container and next to a signed one; a
  third-party image is not judged; the signed image fails once the policy trusts another key;
- keyless, against ghcr.io: no unfold-hq image exists yet, so a copy of
  `unfold-hq-image-signatures` that matches `ghcr.io/ploeg-hq/*` and trusts ploeg-hq/ploeg's
  release workflow admits a keyless-signed `ploegd` release by digest and refuses it by tag; the
  policy as written refuses that image, because another workflow signed it;
- against a throwaway registry on loopback with throwaway keys, for the Zot policy over HTTP: signed
  passes, unsigned and signed-with-another-key fail, both for cosign 3's Sigstore bundle (an OCI
  referrer, signed with a signing config that has no transparency log) and for the legacy `.sig` tag
  the estate's signing jobs write;
- mutation: with both gates removed every refused case passes, the keyless one included, and with
  either gate removed alone the other still refuses.

## SBOM and provenance from CI

Rootless BuildKit in the CI job attaches an SPDX SBOM (generated by
`docker/buildkit-syft-scanner`, pulled through Zot) and SLSA provenance v1 to the image index it
pushes (`--opt attest:sbom=...`, `--opt attest:provenance=mode=max`). The `ci-smoke` workflow does
this and reads both attestations back from Zot. They are unsigned in-toto statements inside the
index; a trusted signing job can sign them as cosign attestations together with the image.
