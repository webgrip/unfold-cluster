# CI runners: Forgejo jobs on the hub worker, with overflow on an autoscaled node

A job with `runs-on: unfold-ci` in any repository of the `webgrip` organisation runs on this cluster
inside gVisor and builds container images with a rootless BuildKit that lives and dies with the job.
Up to two jobs at a time run on the hub worker `unfold-app-1` (CX33), which always exists, so a job
never waits for a cold node. A third concurrent job is Pending until the cluster-autoscaler adds a
CPX42 to the `ci` pool, and that node goes away about ten minutes after its last job
([ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md),
[ci-autoscaler](ci-autoscaler.md)). RFC 0001 calls CI jobs untrusted: they run Renovate updates,
agent pull requests and anyone's branch. Everything below follows from that.

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| KEDA | namespace `keda`, Flux Kustomization `keda`, on the control planes | Every 15 s reads `GET http://unfold-gateway.webgrip.dev:9150/waiting-jobs/unfold-ci` (a `metrics-api` trigger, value `waiting`) and starts one Job per waiting CI job. Nothing runs when nothing waits. |
| ScaledJob `forgejo-runner` | namespace `ci`, Flux Kustomization `ci-runners` | At most 6 job pods at once, RuntimeClass `gvisor`, which places them on a node labelled `runtime.webgrip.io/gvisor=true`. The pods also tolerate the `unfold` pool taint and prefer the hub worker (weight 100) over a `ci` node (weight 50). Their requests (1.55 CPU and 3 GiB with gVisor's overhead) let two fit beside the hub's own pods and not a third. PriorityClass `ci-runner` (-5, never preempts) lets any Unfold pod at the default priority preempt a runner on the hub, and `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` keeps the autoscaler from moving a running job. |
| Job pod | `unfold-app-1`, or an autoscaled `ci-<hex>` node | `register` (init): registers an ephemeral runner. `buildctl` (init): copies the BuildKit client. `buildkitd` (sidecar): rootless BuildKit. `runner`: `forgejo-runner one-job`, steps run here. |
| Runner registration token | OpenBao `secret/unfold-main/ci/forgejo-runner`, key `registration-token` | Minted by the homelab's `unfold-ci-runner-provisioner` CronJob. Delivered as Secret `ci/forgejo-runner-registration`, mounted into the `register` init container only. |
| Job count | homelab `forgejo/forgejo-runner-queue`, behind the homelab gateway's tailnet port 9150 | Answers `{"label":"unfold-ci","waiting":N}`: the `webgrip` jobs in status `waiting` whose `runs-on` is `unfold-ci`. It reads Forgejo with the homelab KEDA scaler's existing token, which never leaves the homelab. Any other label is a 404, any other method a 501, and an unreadable queue a 502, never a zero. |

The registration token comes through the ClusterSecretStore `openbao-homelab` (runbook
[external-secrets](external-secrets.md)). Nobody creates or copies it.

## Why KEDA reads a number and not Forgejo

Forgejo 15.0 serves the job queue at three levels, and each needs more than KEDA should hold
(`routers/api/v1/api.go` at v15.0.10): the org's `/orgs/{org}/actions/runners/jobs` needs an
org owner (`reqOrgOwnership`), a repository's `/repos/{owner}/{repo}/actions/runners/jobs`
needs the repository's owner, which for an org repository is again an org owner
(`reqOwner`, access mode owner), and `/admin/actions/runners/jobs` needs a site admin. There
is no read-only or label-limited permission for it, no job-queued webhook (only
`action_run_success`, `action_run_failure` and `action_run_recover`), and no autoscaler of
its own. The homelab already has a site-admin scaler token for its own runners, so the
homelab counts the queue with it and publishes only the number. A CI job, this cluster or a
leaked Unfold secret can learn how many `unfold-ci` jobs wait, and nothing else.

A fixed pool of idle runners would need no count at all, and on a CX43 that is billed per
month it costs no money. It costs capacity and traffic instead: three idle job pods hold 4.5
vCPU and 9 GiB of requests on the node, every idle runner polls Forgejo's `FetchTask` about
every two seconds over the internet, around 130,000 requests a day for three, and a burst
beyond three waits. Restarting a pod after its one job also needs a controller, which is
what KEDA is. The count costs one small pod in the homelab and one request every 15 s.

## Why each pod registers its own ephemeral runner

The homelab's runners share one persistent runner identity across every pod. In host mode a job's
steps run in the runner's own container and can read that identity, and a runner identity can claim
any label: a hostile pull request could keep the token and pick up other repositories' jobs, secrets
included. Forgejo's answer is the ephemeral runner, which receives at most one job and is then
removed by Forgejo itself. So each pod registers a fresh ephemeral runner in an init container,
which is the only container that mounts the registration token. The runner container gets the
ephemeral runner's file and nothing else; after the one job, its token is worthless.

The registration token is the `webgrip` org's, the narrowest scope that serves every repository
of the org: Forgejo 15.0 has registration tokens for the instance, an owner or one repository
(`ActionRunnerToken` holds an owner id, a repository id and nothing else), none limited to a
label, and the API has no way to reset one. A token per repository would need a ScaledJob per
repository. What keeps it narrow is where it lives: only the `register` init container mounts it.

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
description. KEDA's operator reaches `unfold-gateway.webgrip.dev:9150` and the API server, and nothing on
the internet.

Talos's host firewall (runbook `host-firewall.md`) filters only inbound connections to node
addresses. Job pods open connections outward and receive nothing, and the API server reaches the
KEDA and External Secrets webhooks over the pod network, so no host rule is needed for any of this.

The homelab sends exactly these requests straight to Forgejo, past the Anubis bot check, because a
challenge page there would stall every runner outside the homelab: `POST` to
`/api/actions/runner.v1.RunnerService/*` and `/api/actions/ping.v1.PingService/*`, `GET` of a job's
OIDC token (`/api/actions/_apis/pipelines/workflows/<run>/idtoken`) and of the issuer metadata
under `/api/actions/.well-known/`, and the artifact API under
`/api/actions_pipeline/_apis/pipelines/workflows/<run>/artifacts` with the methods Forgejo serves
there. Any other request under those prefixes meets Anubis.

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

The baseline and the overflow each have their own proof, in [ci-autoscaler](ci-autoscaler.md#proving-it-after-the-apply):
one `ci-smoke` run lands on `unfold-app-1` with no new server, and three at once make the third
land on a new `ci-<hex>` node under gVisor, which is gone again about ten minutes later.

## When it does not start

| Symptom | Look at |
| --- | --- |
| Job waits, no pod | `kubectl -n ci describe scaledjob forgejo-runner` and `kubectl -n keda logs deploy/keda-operator` for the `metrics-api` call. A connection error is the tailnet path (the gateway pod, the `unfold-gateway` DNS record, the Headscale policy's port 9150); a 502 is the homelab endpoint failing to read Forgejo: `kubectl -n forgejo logs deploy/forgejo-runner-queue` in the homelab. |
| Pod stuck `ContainerCreating` | `forgejo-runner-registration` Secret missing: the ExternalSecret, then the store. |
| Push answers 401 | `kubectl -n ci get secret zot-push-credentials`; if missing, the Zot Job's log says `skipped ci` until the RoleBinding exists and `ci` is in its `CONSUMER_NAMESPACES`. |
| `register` fails | Its log. A refused token means the org's registration token was reset; the next provisioner run publishes the new one within 30 minutes, ESO within the hour. |
| `buildkitd` never ready | Its log; see the gVisor notes above. |
| Third job Pending, no new node | [ci-autoscaler](ci-autoscaler.md#when-no-node-comes): the autoscaler's log names why the `ci` group did not grow. |
| Pods pile up waiting | Each waits at most 90 minutes (`activeDeadlineSeconds`), and KEDA starts a new one only for a job no pod is serving yet (`accurate`, with pods counted as pending until a job's workspace exists). |
