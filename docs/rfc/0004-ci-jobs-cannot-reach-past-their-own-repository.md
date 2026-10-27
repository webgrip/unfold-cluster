# RFC 0004: A CI job cannot reach past its own repository

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-27 |
| Owner | ryangr0 |
| Builds on | RFC 0001, [ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md), [ADR 0011](../adr/0011-kyverno-checks-webgrip-image-signatures.md), homelab-cluster ADR-0055 |
| Facts checked | 2026-10-27: this repository's `main` 051e3a8, ci-smoke run 606 (green), Forgejo 15.0.10 and its Actions OIDC discovery document, Zot v2.1.22 as configured in `kubernetes/platform/zot/helmrelease.yaml` |

## Summary

Today one Zot user, `ci`, may create and overwrite anything under `webgrip/**`, and its password is mounted into every runner pod for every job. A job can therefore overwrite another repository's images and build cache. A poisoned cache layer is then rebuilt into the victim's next release and signed by the victim's own pipeline. Inside the pod, a Dockerfile `RUN` step shares the pod's network (`worker.network: host`) and can drive `buildkitd` on loopback.

This RFC closes those paths. Every CI job is treated as untrusted code:

1. **No standing push credential.** A job proves who it is with its Forgejo Actions OIDC token and receives a Zot token that lasts minutes and covers only its own repository.
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

### 1. Short-lived, repository-scoped Zot tokens

Forgejo 15 issues Actions OIDC tokens (`https://forgejo.webgrip.dev/api/actions`, RS256). They carry `repository`, `ref`, `ref_protected`, `ref_type`, `event_name`, `workflow_ref` and `run_id`. Forgejo never issues one to a pull request from a fork. The `openbao-read` composite action in `webgrip/workflows` already exchanges these tokens.

Zot switches from htpasswd to bearer authentication (the Docker registry token protocol): `http.auth.bearer` names a realm, a service and the certificate whose key signs the tokens. A small in-cluster token service, `zot-token`, is that realm:

1. The job requests an OIDC token with audience `zot` and writes a Docker config with the username `oidc` and the JWT as the password. The secret mounted into the pod goes away.
2. BuildKit receives a 401 from Zot, asks the realm for the scopes it needs and presents those credentials.
3. `zot-token` verifies the JWT against Forgejo's JWKS: issuer, audience, expiry and `repository_owner == webgrip`. It then grants only the scopes the claims allow (table below) and signs a token that expires after 10 minutes.

| Caller | Pull | Push |
| --- | --- | --- |
| Protected ref, push or tag event | everything | `webgrip/<repo>/release/*` create only, `webgrip/<repo>/cache/main` create and update, `webgrip/<repo>/candidate/*` create |
| Unprotected ref or same-repository pull request | everything | `webgrip/<repo>/pr/*` create and update, with retention of 7 days |
| Fork pull request (no OIDC token) | anonymous read | nothing |

`create` without `update` makes a release tag immutable: once a tag is pushed, nobody overwrites it. Zot's `accessControl` stays as a second gate, but with no named users: bearer scopes decide who may push.

The signing key for the tokens lives in OpenBao and reaches `zot-token` through External Secrets, under its own policy. Zot reads only the public certificate.

**Spike first.** OpenBao's identity tokens (`identity/oidc/token/<role>`) sign templated JWTs with a key OpenBao rotates. If Zot accepts such a token as a bearer token, OpenBao could be the realm and `zot-token` would not be needed. Two unknowns decide it: whether Zot accepts the `access` claim in the shape an OpenBao template can produce, and whether CI pods can reach OpenBao in the homelab. Today their network policy allows only Forgejo and Zot. If either answer is no, `zot-token` is built: about 200 lines, one Deployment, its own network policy.

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
- A `RUN` step sees neither volume nor the socket, and with `--oci-worker-no-process-sandbox` it can see `buildkitd`'s processes but not read their files through `/proc/<pid>/root`. Its connection fails the TLS handshake. It can still signal those processes, which ends only its own job.

## Rollout

Each step is one pull request. An admission policy change lands before the workload that needs it.

1. mTLS on `buildkitd` (part 4). It needs nothing else.
2. The spike: OpenBao identity tokens as Zot bearer tokens, yes or no.
3. Zot repository layout and retention for `release/`, `candidate/`, `cache/` and `pr/`. Existing tags stay readable.
4. `zot-token`, or the OpenBao realm, and Zot on bearer authentication with ci-smoke switched over. The `zot-push-credentials` secret, job and mount are removed in the same step.
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

- **Moving parts:** one service (`zot-token`, unless the spike removes it), one init container, one release workflow, and the reproducibility work per repository.
- **Time:** a release build takes about twice as long, because the witness starts from nothing. It runs in parallel, so wall-clock time is the slower of the two builds.
- **Availability:** if `zot-token` is down, nothing can push. It runs two replicas on the system pool, and pulls are unaffected.

## Open questions

None for the owner. The spike in step 2 decides between OpenBao and `zot-token`.
