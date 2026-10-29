# RFC 0005: Take CI load off the homelab

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-28 |
| Owner | ryangr0 |
| Builds on | [ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md), [ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md), [ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md), [RFC 0004](0004-ci-jobs-cannot-reach-past-their-own-repository.md), homelab-cluster runbook `forgejo-runner` |
| Facts checked | 2026-10-28: homelab VictoriaMetrics and VictoriaLogs (7 days), the homelab `forgejo` namespace live, homelab-cluster `main` ee99f396, this repository's `main` 6571e13, ci-smoke run 693 (green) |

## Summary

The homelab is slow and out of memory, and CI is the largest load it can shed. This cluster already runs `unfold-ci` jobs under gVisor, two at a time on the hub worker at no extra cost and more on an autoscaled CPX42. Today only `ci-smoke` uses it.

This RFC moves webgrip CI here one repository at a time, starting with this repository's own checks, and caps the homelab's runners once the overflow has somewhere to go. Jobs reach the internet through a per-host allowlist: each moved workflow adds the hosts it needs, each in its own rule with its reason.

Moving CI here buys capacity, not resilience. Forgejo runs in the homelab, so no job is handed out while the homelab is down, wherever the runners are ([ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md), part 2).

## The homelab today

| Node | Size | CPU busy, 7-day mean | CPU pressure, 7-day mean | IO pressure, 7-day mean |
| --- | --- | --- | --- | --- |
| worker-1 | 4 cores, 23 GiB | 76% | 49% | 13% |
| fringe-workstation | 8 cores, 15 GiB | 46% | 10% | 27% |
| worker-2 | 8 cores, 15 GiB | 43% | 16% | 3% |

Pressure is the share of time work waited for the resource (`node_pressure_*_waiting_seconds_total`).

- The worker pool is full on memory requests. On 2026-10-28 three `docker` runners sat `Pending` with `Insufficient memory` on two nodes and `Insufficient cpu` on the third.
- CI (`forgejo-runner*` and `forgejo-dind`) used 1.06 cores on average, 2.9 at the 90th percentile and about 5 in a burst, of 9.6 cores in use across the cluster.
- A larger CPU request per runner was tried on 2026-10-24 and reverted: the pool had no CPU requests left to promise, so two runners scheduled and eight waited (homelab-cluster d415ed68, a396dc8e). Tuning the homelab runners does not create room; moving jobs does.

Runner pods per repository over the same week, counted from runner logs that name the repository (a pod that names two repositories counts for both):

| Repository | Runner pods |
| --- | --- |
| homelab-cluster | 1,995 |
| unfold | 1,428 |
| infrastructure | 732 |
| unfold-cluster | 511 |
| twente.dev | 463 |
| every other repository | under 300 each |

The first four make three quarters of the load.

## Design

### 1. A toolchain runner beside `unfold-ci`

Of this repository's twelve `docker` jobs, nine run in `container: harbor.webgrip.dev/webgrip/infra-runner`, one in a `node` image and two in the homelab runner's own toolchain. `unfold-ci` runs steps in host mode, in the runner's own container, and has no Docker daemon to start a job container.

A second ScaledJob, label `unfold-check`, uses the homelab's pattern for its `unfold-infra` pool: the main container is the `infra-runner` image, an init container copies `forgejo-runner` in, and steps run in host mode inside the toolchain. It keeps everything else from `forgejo-runner`: gVisor, an ephemeral runner per pod, the same egress policy, PriorityClass `ci-runner`, and its own count from the homelab's `forgejo-runner-queue`, which needs `unfold-check` added to the labels it answers.

`infra-runner` is published to Harbor only, which this cluster cannot pull from. The `infrastructure` release copies it, signature and attestations included, to `forgejo.webgrip.dev/webgrip/infra-runner` and checks the copy serves the same digest anonymously. Forgejo's registry and not GHCR: infrastructure ADR 0004 removed GHCR publishing, and its `GHCR_TOKEN` is a GitHub token handed to two repositories only, while the Forgejo copy needs only `WEBGRIP_CI_TOKEN`, which already copies Unfold's images there. Kyverno already covers `forgejo.webgrip.dev/webgrip/*`; `pinned-approved-images` gains the one prefix.

### 2. This repository's checks move first

The eight workflows with `runs-on: docker` change to `runs-on: unfold-check`, drop `container:`, and name `actions/checkout` by its full `https://forgejo.webgrip.dev/actions/checkout` URL, because a bare name resolves against the homelab's in-cluster Forgejo address. The scripts fetch from `github.com` and its release CDN, `dl.k8s.io` and `helm.cilium.io`; the first run on the new label confirms the list. Each host gets its own rule in [the runner policy](../../kubernetes/platform/ci-runners/app/networkpolicy.yaml) naming the workflow that needs it. Only this repository runs here at this step, so the shared Zot credential of RFC 0004 is not yet a cross-repository risk.

### 3. RFC 0004 part 1 before a second repository

Before any other repository uses these runners, Zot checks each job's Forgejo OIDC token and the shared `ci` password goes away. Until then one repository's job could overwrite another's images and build cache.

### 4. Other repositories, in order of load

`unfold`, `infrastructure`, then the heaviest `homelab-cluster` jobs. Each changes `runs-on` in its own workflows, after a run on the new label shows the hosts it needs. Reusable workflows in `webgrip/workflows` are not the starting point: these repositories define their heavy jobs inline.

### 5. Cap the homelab once the overflow exists

When the moved repositories account for most of the load, homelab-cluster lowers `maxReplicaCount` for the `docker` runners from 8 to 4, so a Renovate wave stops crowding Vikunja, Ploeg and the rest on worker-1.

## Rejected

| Option | Why not |
| --- | --- |
| A larger CPU request on the homelab runners | Tried and reverted; it moves the queue into `Pending`, it does not add capacity. |
| Giving these runners the `docker` label | Both clusters race for every job; jobs that need Docker, a job container or open egress fail here. |
| Open HTTPS egress for CI jobs | Removes the main reason a job is safer here: it could carry data to any host. |
| An in-cluster mirror for every package source first | The strongest lock, but weeks before any load moves. Worth revisiting once the allowlist grows. |

## Costs

The two hub slots cost nothing extra. Bursts run on a CPX42 at €0,1122 an hour, removed about ten minutes after its last job; [ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md) puts a daily two-hour overflow at about €5 to €7 a month.

## Proof

- Each moved workflow is green on its new label, and its run log shows the node it ran on.
- After step 2 and after each repository in step 4, the homelab's runner pods per week, `Pending` runner minutes and worker-1 CPU pressure are compared with the table above.
- The egress policy keeps its mutation test: a job that resolves a host outside the allowlist fails.

## Open questions

1. Do the `unfold` jobs need hosts beyond the npm registry and GitHub, and can a `pnpm` store live in Zot or on the CI node?
