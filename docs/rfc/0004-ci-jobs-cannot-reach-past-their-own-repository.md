# RFC 0004: A CI job cannot reach past its own repository

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-27 |
| Owner | ryangr0 |
| Builds on | RFC 0001, [ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md), [ADR 0011](../adr/0011-kyverno-checks-webgrip-image-signatures.md), homelab-cluster ADR-0055 |
| Facts checked | 2026-10-27: this repository's `main` 051e3a8, ci-smoke run 606 (green), Forgejo 15.0.10 and its Actions OIDC discovery document, Zot v2.1.22 as configured in `kubernetes/platform/zot/helmrelease.yaml`; the part 1 spike against Zot v2.1.22 and BuildKit v0.34.0 |

## Summary

Today one Zot user, `ci`, may create and overwrite anything under `webgrip/**`, and its password is mounted into every runner pod for every job. A job can therefore overwrite another repository's images and build cache. A poisoned cache layer is then rebuilt into the victim's next release and signed by the victim's own pipeline. Inside the pod, a Dockerfile `RUN` step shares the pod's network (`worker.network: host`) and can drive `buildkitd` on loopback.

This RFC closes those paths. Every CI job is treated as untrusted code:

1. **No standing push credential.** A job proves who it is with its Forgejo Actions OIDC token, which Zot checks itself and which covers only its own repository.
2. **Only protected refs write what others trust.** Releases and the shared build cache are written by protected refs only. Pull requests read the cache and write nothing others import. Fork pull requests get no token at all.
3. **A release is built twice.** One build uses the cache and one starts from nothing, each in its own pod. Only when the image digests match is the release tagged and signed.
4. **`buildkitd` answers only the runner.** It listens on loopback with mutual TLS and a CA that exists only for the life of the pod.

## Threat model

The attacker can run arbitrary code in one CI job: a malicious pull request, a compromised npm package, a poisoned base image, or a prompt-injected agent. They must not be able to:

| Goal | Path today | Closed by |
| --- | --- | --- |
| Overwrite another repository's image or tag | the `ci` password, `create` and `update` on `webgrip/**` | 1, 2 |
| Poison another repository's build cache | the same | 1, 2 |
| Poison their own repository's release through the cache from a branch | any job writes `:buildcache` | 2, 3 |
| Keep pushing after the job ends | the password never rotates | 1 |
| Drive `buildkitd` from a `RUN` step | unauthenticated loopback | 4 |
| Get a release signed that was not built from reviewed source | signing is not wired up yet; Kyverno is in Audit | 3, then Deny |

Out of scope: reading. Zot keeps anonymous read, because nodes pull through the NodePort and every webgrip image is digest-pinned and signed. A compromise of Forgejo, OpenBao or the Zot pod is also out of scope.

## Design

### 1. Zot checks the job's own OIDC token

Forgejo 15 issues Actions OIDC tokens (`https://forgejo.webgrip.dev/api/actions`, RS256), with the audience the job asks for. They carry `repository`, `repository_owner`, `ref`, `ref_protected` (the string `"true"` or `"false"`), `ref_type`, `event_name`, `workflow_ref` and `run_id`. Forgejo never issues one to a pull request from a fork.

Zot v2.1.22 validates such tokens itself ([OIDC workload identity](https://github.com/project-zot/zot/blob/v2.1.22/examples/README-OIDC-WORKLOAD-IDENTITY.md)): `http.auth.bearer.oidc` names the issuer and audience, CEL maps the claims to a user and groups, and a CEL condition on each `accessControl` policy compares the request with the claims (`req.repository`, `req.claims`). No token service and no signing key of our own are needed. The job requests a token with audience `zot` and writes a Docker config with username `oidc` and the token as password. BuildKit trades it at Zot's `/zot/auth/token`, as the Docker token protocol does, and the secret mounted into the pod goes away.

```yaml
bearer:
  realm: http://zot.zot.svc.cluster.local:5000/zot/auth/token
  service: zot.zot.svc.cluster.local:5000
  oidc:
    - issuer: https://forgejo.webgrip.dev/api/actions
      audiences: [zot]
      claimMapping:
        validations:
          - expression: claims.repository_owner == 'webgrip'
        username: "'forgejo-actions:' + claims.repository"
        groups: "['forgejo-actions']"
```

| Caller | Pull | Push (policy condition on `webgrip/**`) |
| --- | --- | --- |
| Protected ref | everything | `<repo>/release/*` create only; `<repo>/cache/*` and `<repo>/candidate/*` create and update |
| Unprotected ref or same-repository pull request | everything | `<repo>/pr/*` create and update, with retention of 7 days |
| Fork pull request (no OIDC token) | anonymous read | nothing |

`<repo>` is `req.claims.repository`, so one set of policies covers every repository. `create` without `update` makes a release tag immutable.

Zot fetches the discovery document and keys from `forgejo.webgrip.dev:443`, which its network policy has to allow.

**Spike, 2026-10-27.** Zot v2.1.22 (the pinned digest), a mock issuer that signs tokens in Forgejo's claim shape, crane and BuildKit v0.34.0. Every row of the table held: a protected ref creates a release and cannot overwrite it, writes the cache and candidates; an unprotected ref writes only `pr/`; neither reaches another repository or a name that merely starts with its own (`webgrip/unfold-cluster-evil`). Zot refused a forged signature, a wrong audience, a wrong issuer, an expired token and another organisation. BuildKit pushed through the token exchange, and BuildKit and containerd still pulled anonymously.

**What blocks it.** With a token realm advertised and policies that are partly anonymous, Zot answers an anonymous `GET /v2/` with a Bearer challenge and then refuses to mint an anonymous token ([zot#4373](https://github.com/project-zot/zot/issues/4373), open). containerd never asks `/v2/`, but go-containerregistry does, so in the spike crane's anonymous pull failed. Trivy (its database through Zot) and Kyverno (signature checks on Zot images) are such clients. Without the realm, `/v2/` stays open, but BuildKit then gets a Basic challenge and never presents the token. The htpasswd user `ci` stops working once the realm is on, because the token exchange accepts only OIDC tokens and API keys, so the switch is one cutover.

The ways through, smallest first:

1. Zot mints a token for an anonymous request that carries only the anonymous policy, the case #4373 asks for. That is an upstream change; the switch waits for it.
2. Trivy and Kyverno authenticate as well, with their Kubernetes ServiceAccount tokens as a second `bearer.oidc` issuer.
3. Jobs push with crane from an OCI layout BuildKit exports, sending the token directly (`registrytoken`). This needs no realm, but BuildKit can no longer export its cache to Zot.

### 2. The cache is written by protected refs only

- Builds import from `webgrip/<repo>/cache/main` and, in a pull request, also from the pull request's own `pr/` cache.
- Only a protected ref exports to `cache/main`. The scope table enforces this, not the workflow.
- `mode=max` stays, because only trusted refs write it.
- The reusable build workflow in `webgrip/workflows` carries these refs, so repositories do not choose them.

### 3. Releases are built twice and compared

A release workflow on a protected tag runs two jobs, each in its own fresh pod:

1. **Candidate:** builds with the cache and pushes to `candidate/<sha>`.
2. **Witness:** builds with `--no-cache` and pushes nothing. It reports the digest of each platform's image manifest.
3. **Promote:** a third job compares the two. If they match, it tags `release/<version>` from the candidate digest and signs that digest with the OpenBao Transit key `cosign-webgrip`, through an OpenBao role bound to `ref_protected=true` and to the pinned `workflow_ref` of the release workflow. If they do not match, nothing is tagged.

The comparison covers the image manifest, not the index. Provenance attestations carry timestamps and invocation details, so they differ between two builds by design.

This needs reproducible builds:

- `SOURCE_DATE_EPOCH` set from the commit time;
- `rewrite-timestamp=true` on the image exporter;
- base images pinned by digest;
- package installs from lock files, and apt from a dated snapshot.

The build workflow sets the first two. Each repository's Dockerfile has to meet the rest before its releases can be promoted. ci-smoke gets the witness build first.

Once every webgrip image in Zot is signed this way, the Kyverno policy `webgrip-image-signatures-zot` moves from Audit to Deny, following [image signatures](../runbooks/image-signatures.md#from-audit-to-deny).

### 4. Mutual TLS on `buildkitd`

- A new init container, `buildkit-tls`, runs before `buildkitd`. It uses the runner's `node` image, which is already approved and has `openssl`. It makes an ECDSA P-256 CA valid for one day that can sign only end certificates (`pathlen:0`), a server certificate for `127.0.0.1` and one client certificate, each limited to its own use (`keyUsage`, `extendedKeyUsage`).
- It writes them into two `emptyDir` volumes:
  - `buildkit-server-tls` holds the CA certificate, the server certificate and the server key, and is mounted only in `buildkitd`;
  - `buildkit-client-tls` holds the CA certificate, the client certificate and the client key, and is mounted only in the runner, outside `/work`.
- The CA key is deleted before `buildkitd` starts, and everything dies with the pod. The volumes stay on disk because files on a disk `emptyDir` are proven to reach the other containers under gVisor, and a memory `emptyDir` is not.
- `buildkitd` starts with `--tlscacert`, `--tlscert` and `--tlskey`.
- `buildctl` reads no environment variable for its TLS files, so `/opt/ci/bin/buildctl` is a wrapper that adds `--tlsdir`.
- The probes use a second listener, the image's default Unix socket inside the `buildkitd` container, as in BuildKit's own Kubernetes examples. It is in no volume, so the client key stays out of `buildkitd`.
- A `RUN` step sees neither volume nor the socket. It runs in BuildKit's process sandbox, so it does not see `buildkitd`'s processes either. Its connection fails the TLS handshake.

## Rollout

Each step is one pull request. An admission policy change lands before the workload that needs it.

1. mTLS on `buildkitd` (part 4). Done: #137, #138 (process sandbox), proven by ci-smoke run 640.
2. The spike. Done: Zot validates Forgejo tokens itself; anonymous `/v2/` under a token realm blocks the switch (part 1).
3. Zot repository layout and retention for `release/`, `candidate/`, `cache/` and `pr/`. Existing tags stay readable.
4. Zot on `bearer.oidc` with ci-smoke switched over, once one of the ways through in part 1 is in place. The `zot-push-credentials` secret, job and mount are removed in the same step.
5. The build workflow in `webgrip/workflows` with the scope rules, then each repository moved onto it.
6. Reproducible builds and the release workflow (part 3), ci-smoke first.
7. Kyverno `webgrip-image-signatures-zot` to Deny.

## Proof

Each step ships with tests that are seen to fail before they pass:

- a token for repository A pushing to `webgrip/B/...` gets 403;
- an unprotected ref pushing to `cache/main` gets 403;
- pushing an existing `release/` tag again gets 403;
- an expired token, a token with another audience and a token from another issuer get 401;
- a fork pull request gets no token, and its build still pulls;
- in ci-smoke, `RUN buildctl --addr tcp://127.0.0.1:1234 debug workers` fails, while the same command from the runner succeeds;
- the release workflow refuses to promote when the witness digest differs (forced with a Dockerfile that writes `date`).

## Costs

- **Moving parts:** Zot configuration only, one init container, one release workflow, and the reproducibility work per repository.
- **Time:** a release build takes about twice as long, because the witness starts from nothing. It runs in parallel, so wall-clock time is the slower of the two builds.
- **Availability:** Zot fetches Forgejo's signing keys; while Forgejo is unreachable, no new token can be checked, so nothing can push. Pulls are unaffected.

## Open questions

Which way through the anonymous `/v2/` challenge (part 1): wait for or contribute the anonymous token in Zot, give Trivy and Kyverno ServiceAccount identities, or push with crane.
