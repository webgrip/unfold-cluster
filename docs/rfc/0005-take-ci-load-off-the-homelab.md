# RFC 0005: Take CI load off the homelab

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-28 |
| Amended | 2026-11-12: a dedicated CI node, toolchain runners for shared workflows, a monthly ceiling |
| Owner | ryangr0 |
| Builds on | [ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md), [ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md), [ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md), [ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md), [RFC 0004](0004-ci-jobs-cannot-reach-past-their-own-repository.md) |

## Summary

The homelab has run out of room, and CI is the largest load it can shed. This cluster already runs CI jobs under gVisor: two at a time on the hub worker at no extra cost, and more on an autoscaled CPX42.

This RFC moves CI here one repository at a time, adds a metal node for CI alone, and caps the homelab's runners once the jobs have somewhere to go. Jobs reach the internet through a per-host allowlist: each moved workflow adds the hosts it needs, each in its own rule with its reason.

Moving CI here buys capacity, not resilience. Forgejo runs in the homelab, so no job is handed out while the homelab is down, wherever the runners are ([ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md), part 2).

## Why the homelab cannot keep up

- Its CI runs on older hardware, behind a Docker daemon whose disk writes are throttled to protect shared storage.
- Its worker pool is full on resource requests, so new runners wait in `Pending`.
- A larger request per runner was tried and reverted: the pool had nothing left to promise, so fewer runners scheduled.

Tuning the homelab runners does not create room; moving jobs does.

## Design

### 1. Toolchain runners beside `unfold-ci`

`unfold-ci` runs steps in host mode, in the runner's own container, and has no Docker daemon to start a job container. Jobs written for a job container therefore get a runner whose main container is their toolchain image.

Each toolchain image gets its own ScaledJob and label, on the pattern of `unfold-check` ([runbook](../runbooks/ci-runners.md)): an init container copies `forgejo-runner` in, and steps run in host mode inside the toolchain. It keeps everything else from `forgejo-runner`: gVisor, an ephemeral runner per pod, the same egress policy, PriorityClass `ci-runner`, and its count from the homelab's runner queue, which answers for each new label.

This cluster pulls only from registries Kyverno allows. A toolchain image is copied to `forgejo.webgrip.dev/webgrip/*` with its signature and attestations, and the copy is checked to serve the same digest. Renovate moves the image in the workflows and in the ScaledJob together; a new major version gets a new label, so an old pin never lands on a new toolchain.

Jobs that call `docker build` use BuildKit through `BUILDKIT_HOST`, as `unfold-ci` does. Jobs that need `docker run` or service containers stay on the homelab until they are rewritten.

### 2. This repository's checks move first

Its workflows change `runs-on: docker` to `runs-on: unfold-check`, drop `container:`, and name `actions/checkout` by its full `https://forgejo.webgrip.dev/actions/checkout` URL, because a bare name resolves against Forgejo's in-cluster address. Each host a job needs gets its own rule in [the runner policy](../../kubernetes/platform/ci-runners/app/networkpolicy.yaml), naming the workflow that needs it. Only this repository runs here at this step, so the shared Zot credential of RFC 0004 is not yet a cross-repository risk.

### 3. RFC 0004 part 1 before a second repository

Before any other repository uses these runners, Zot checks each job's Forgejo OIDC token and the shared `ci` password goes away. Until then one repository's job could overwrite another's images and build cache.

### 4. Other repositories, in order of load

The heaviest repositories move first, each after a run on the new label shows the hosts it needs. Where a repository defines its heavy jobs inline, it changes its own `runs-on`. Where they live in shared reusable workflows, those workflows get a `runs-on` input that defaults to `docker` and run without `container:` when it is not `docker`.

### 5. A dedicated CI node

The hub's two slots and one autoscaled CPX42 do not carry the whole load.

- **CI gets its own metal node,** an EX44 declared in `metal_servers` beside `unfold-metal-1`, under the same ceiling as [ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md). It carries the `ci` pool label and taint and `runtime.webgrip.io/gvisor=true`, and runs gVisor on the `kvm` platform, which is faster than `systrap` on cloud nodes. It runs no Kata and no agent Runs, so ADR 0009's aim to keep CI off the Run node holds.
- **The runners prefer it,** then the hub, then the autoscaled CPX42, which stays as overflow with a maximum of one.
- **Caches stay on the node.** BuildKit state and package caches live on its NVMe, so a job there starts warm. The CPX42 still starts cold.
- **Its disks are encrypted like `unfold-metal-1`'s,** from the first install.

### 6. Cap the homelab once the jobs have moved

When the moved repositories carry most of the load, the homelab lowers the maximum of its `docker` runners, so a Renovate wave stops crowding its other workloads.

## Rejected

| Option | Why not |
| --- | --- |
| A larger CPU request on the homelab runners | Tried and reverted; it moves the queue into `Pending`, it does not add capacity. |
| Giving these runners the `docker` label | Both clusters race for every job; jobs that need Docker, a job container or open egress fail here. |
| Docker inside gVisor, or a privileged Docker daemon on the CI node | The first is unproven with rootless BuildKit and `oci-seccomp`; the second gives a job a path to the node on the production cluster. |
| Only a larger autoscaled pool | Every job starts cold and each new node takes three to five minutes, while CI runs most of the day. |
| Self-hosted runners for public GitHub repositories | GitHub's hosted runners are free for public repositories, and a self-hosted runner there runs fork pull request code on this cluster. |
| Open HTTPS egress for CI jobs | Removes the main reason a job is safer here: it could carry data to any host. |
| An in-cluster mirror for every package source first | The strongest lock, but weeks before any load moves. Worth revisiting once the allowlist grows. |

## Costs

The two hub slots cost nothing extra. Bursts run on a CPX42 at €0,1122 an hour, removed about ten minutes after its last job; [ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md) puts a daily two-hour overflow at about €5 to €7 a month.

The dedicated node costs €60,70 a month with IPv4, at the price ADR 0009 checked. CI here has a ceiling of €75 a month excluding VAT: the node plus about 120 CPX42 hours. The alert `HetznerAutoscaledServerRunningLong` catches an overflow node that does not leave.

## Proof

- Each moved workflow is green on its new label, and its run log shows the node it ran on.
- After each moved repository, the homelab's runner pods per week, `Pending` runner minutes and CPU pressure are compared with the week before.
- The egress policy keeps its mutation test: a job that resolves a host outside the allowlist fails.

## Open questions

1. Which hosts beyond the package registries and GitHub do the moved jobs need, and can package stores live in Zot or on the CI node?
2. Is the EX44 in stock when it is ordered, or does `auction` mode pick another server under the ceiling?
