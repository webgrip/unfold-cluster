# CI runners: Forgejo jobs on the CI pool

A job with `runs-on: unfold-ci` in any repository of the `webgrip` organisation runs on this cluster's
CI node (`unfold-ci-1`, CX43, 8 vCPU, 16 GB), inside gVisor, and builds container images with a
rootless BuildKit that lives and dies with the job. RFC 0001 calls CI jobs untrusted: they run
Renovate updates, agent pull requests and anyone's branch. Everything below follows from that.

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| KEDA | namespace `keda`, Flux Kustomization `keda` | Polls `GET /api/v1/orgs/webgrip/actions/runners/jobs?labels=unfold-ci` every 15 s and starts one Job per waiting CI job. Nothing runs when nothing waits. |
| ScaledJob `forgejo-runner` | namespace `ci`, Flux Kustomization `ci-runners` | At most 3 job pods at once, on the CI node only (`node.webgrip.io/pool=ci`, its taint tolerated), RuntimeClass `gvisor`. |
| Job pod | CI node | `register` (init): registers an ephemeral runner. `buildctl` (init): copies the BuildKit client. `buildkitd` (sidecar): rootless BuildKit. `runner`: `forgejo-runner one-job`, steps run here. |
| Runner registration token | OpenBao `secret/unfold-main/ci/forgejo-runner`, key `registration-token` | Minted by the homelab's `unfold-ci-runner-provisioner` CronJob. Delivered as Secret `ci/forgejo-runner-registration`, mounted into the `register` init container only. |
| KEDA scaler token | same path, key `scaler-token` | A `read:organization` token of the homelab bot `unfold-ci-scaler`, an owner of `webgrip` (Forgejo lets only owners read the org's job queue). Delivered as Secret `keda/forgejo-unfold-ci-scaler`, used through the ClusterTriggerAuthentication `forgejo-unfold-ci`. It never enters `ci`. |

Both tokens come through the ClusterSecretStore `openbao-homelab` (runbook
[external-secrets](external-secrets.md)). Nobody creates or copies either of them.

## Why each pod registers its own ephemeral runner

The homelab's runners share one persistent runner identity across every pod. In host mode a job's
steps run in the runner's own container and can read that identity, and a runner identity can claim
any label: a hostile pull request could keep the token and pick up other repositories' jobs, secrets
included. Forgejo's answer is the ephemeral runner, which receives at most one job and is then
removed by Forgejo itself. So each pod registers a fresh ephemeral runner in an init container,
which is the only container that mounts the registration token. The runner container gets the
ephemeral runner's file and nothing else; after the one job, its token is worthless.

A pod that dies before it gets a job leaves an offline ephemeral runner behind; Forgejo keeps those
until someone removes them. The homelab provisioner removes offline `unfold-ci-*` ephemeral runners
once they are older than its previous run (a high-water mark of runner ids, kept beside the tokens),
so a runner that is still registering is never touched.

## Why BuildKit runs in the job pod, under gVisor

A shared BuildKit daemon, as in the homelab, would run every job's Dockerfile `RUN` steps in one
process tree with one cache: one hostile build could poison another's layers. Here every job gets its
own rootless `buildkitd` as a native sidecar, in the same gVisor sandbox as the steps, and it is gone
when the job ends. Layers are shared only through the registry cache in Zot, which a trusted job
never reads from a branch's tag.

What that costs, and what to check:

- Rootless BuildKit maps a range of user ids with `newuidmap`, which is setuid, so the `buildkitd`
  container needs `allowPrivilegeEscalation: true` and the default capability set. That is why `ci`
  enforces Pod Security `baseline` instead of the cluster's `restricted`. Inside gVisor the
  escalation only reaches gVisor's own kernel. The `pod-security-restricted` admission policy will
  report this container; it needs a recorded exception for container `buildkitd` in `ci` with
  RuntimeClass `gvisor` before that policy moves to Deny.
- `--oci-worker-no-process-sandbox` lets build steps see `buildkitd`'s processes. The pod holds one
  job, so there is nobody else to see.
- runsc ignores the pod's seccomp profile unless the node runs it with `--oci-seccomp`. If the CI
  node ever enables that flag, rootless BuildKit's `unshare` calls are refused and the startup probe
  fails; the fix is a Localhost seccomp profile for `buildkitd`, not Unconfined.
- The snapshotter is left to BuildKit's own detection. The smoke workflow prints which one it chose
  (`buildctl debug workers --verbose`); `native` works everywhere but copies every layer.

If rootless BuildKit cannot run under gVisor on the node at all, the fallback is a rootless
`buildkitd` Deployment on the CI node outside gVisor, one per concurrent job. That puts Dockerfile
`RUN` steps on the host kernel behind only a user namespace, so it is the second choice.

## Images and the registry

- Pushes and the layer cache go to Zot under `webgrip/ci/<repository>`, over plain HTTP inside the
  cluster: `zot.zot.svc.cluster.local:5000/webgrip/ci/<repository>:<tag>`, cache at `:buildcache`.
- Pushing needs Zot's `ci` user. `ci` opts in to Zot's credential copy with the RoleBinding
  `zot-push-credentials` (runbook `zot-registry.md`); Zot's Job then keeps the Secret
  `ci/zot-push-credentials` current, and the runner container mounts its `.dockerconfigjson` as
  `$DOCKER_CONFIG/config.json`, which `buildctl` hands to BuildKit for each push. The volume is
  optional, so a job still starts and pulls without it; only a push then fails with 401.
- That credential may write any tag under `webgrip/**`, and every job here can read it. A CI push is
  therefore untrusted until a separate trusted job signs it (RFC 0001, CI rules); production admits
  signed images only. Narrowing it to `webgrip/ci/**` is a change to Zot's access control.
- Base images are pulled through Zot's mirrors. `buildkitd.toml` sends `docker.io`, `ghcr.io`,
  `quay.io` and `registry.k8s.io` to `zot.zot.svc.cluster.local:5000/<registry>`, the layout Zot's
  sync uses. No registry on the internet is reachable from a job pod.

## Network

A job pod reaches `forgejo.webgrip.dev:443` (its task, the checkout, the actions it uses) and Zot on
5000, and nothing else. A pipeline that needs another host, such as a package registry, adds its own
egress rule to `kubernetes/platform/ci-runners/app/networkpolicy.yaml` with the reason in the rule's
description. KEDA's operator reaches `forgejo.webgrip.dev:443` and the API server.

Talos's host firewall (runbook `host-firewall.md`) filters only inbound connections to node
addresses. Job pods open connections outward and receive nothing, and the API server reaches the
KEDA and External Secrets webhooks over the pod network, so no host rule is needed for any of this.

The homelab routes `/api/actions` and `/api/actions_pipeline` straight to Forgejo, past the Anubis
bot check, like `/api/v1`: those are the runner protocol and the artifact API, and a challenge page
there would stall every runner outside the homelab.

## Writing a workflow for `unfold-ci`

- `runs-on: unfold-ci`. Steps run in `node:24` (Debian bookworm) as uid 1000 with `node`, `git`,
  `curl` and `buildctl`; `BUILDKIT_HOST` already points at the job's own BuildKit. There is no
  Docker daemon; build with `buildctl`.
- Name actions by full URL: `uses: https://forgejo.webgrip.dev/actions/checkout@<sha> # vX.Y.Z`.
  A bare `actions/checkout@...` resolves against the homelab's in-cluster Forgejo address, which this
  cluster cannot reach.
- `actions/cache` finds no cache server and continues without one.
- No secret a trusted job holds (signing, deploy keys) belongs in a job that runs here.

## Proving it end to end

After the Zot (#52), CI node (#50), External Secrets (#58) and CI runner pull requests are merged, and the homelab
link to OpenBao is up:

1. `kubectl --kubeconfig ~/.kube/unfold.yaml -n ci get externalsecret` shows
   `forgejo-runner-registration` `SecretSynced`, and `-n keda get externalsecret` shows
   `forgejo-unfold-ci-scaler` the same.
2. `kubectl --kubeconfig ~/.kube/unfold.yaml get scaledjob -n ci forgejo-runner` shows `READY True`
   and `ACTIVE False`.
3. In Forgejo, open `webgrip/unfold-cluster`, Actions, `ci-smoke`, Run workflow on `main`.
4. Within about 30 s, `kubectl --kubeconfig ~/.kube/unfold.yaml -n ci get pods -o wide` shows one
   pod on `unfold-ci-1`; its `register` log says the runner registered, and the pod turns `Ready`
   once the job starts.
5. The run is green. Its log shows gVisor in `dmesg` or `/proc/version`, the BuildKit worker and its
   snapshotter, `CACHED` steps in the rebuild, and the commit's tag in Zot.
6. Afterwards the pod is `Completed`, the runner list of `webgrip` (Settings, Actions, Runners) no
   longer shows `unfold-ci-<pod>`, and `ACTIVE` is back to `False`.

## When it does not start

| Symptom | Look at |
| --- | --- |
| Job waits, no pod | `kubectl -n keda logs deploy/keda-operator` for the scaler's Forgejo calls; `kubectl -n ci describe scaledjob forgejo-runner`. A 403 means the scaler bot is no longer an owner of `webgrip`. |
| Pod stuck `ContainerCreating` | `forgejo-runner-registration` Secret missing: the ExternalSecret, then the store. |
| Push answers 401 | `kubectl -n ci get secret zot-push-credentials`; if missing, the Zot Job's log says `skipped ci` until the RoleBinding exists and `ci` is in its `CONSUMER_NAMESPACES`. |
| `register` fails | Its log. A refused token means the org's registration token was reset; the next provisioner run publishes the new one within 30 minutes, ESO within the hour. |
| `buildkitd` never ready | Its log; see the gVisor notes above. |
| Pods pile up waiting | Each waits at most 90 minutes (`activeDeadlineSeconds`), and KEDA starts a new one only for a job no pod is serving yet (`accurate`, with pods counted as pending until a job's workspace exists). |
