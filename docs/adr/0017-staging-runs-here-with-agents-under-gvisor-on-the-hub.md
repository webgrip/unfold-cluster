---
status: accepted
date: 2026-10-28
---

# ADR 0017: Unfold staging runs here at `staging.app.unfoldhq.dev`, public through a Cloudflare Tunnel, with its agents under gVisor on the hub

## Context and problem statement

[RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md) moves Unfold and Ploeg here in one cutover, after a shadow install, with Runs under Kata on a metal node and the homelab as staging. Three of its assumptions no longer hold:

* **There is no metal node.** The EX44 and AX41 are sold out and the AX42 costs €97.30 plus €49 setup ([ADR 0009](0009-the-metal-node-is-an-ex44.md), [ADR 0013](0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md) part 4). Without one there is no Kata, so RFC 0003 step 7 cannot start.
* **The product's zone is `unfoldhq.dev`.** cert-manager already holds a DNS-01 token scoped to it, and the ops consoles live under `*.ops.unfoldhq.dev`.
* **The homelab is short of memory**, and staging there cannot prove what production here will run.

On 2026-10-28 the owner decided: "Let's deploy unfold properly. staging.app.unfoldhq.dev makes sense to me. Gvisor for the agents", and, asked to choose, picked staging here with production later, public access through a Cloudflare Tunnel, and the agents under gVisor on the hub node.

## Decision

1. **Staging runs in this cluster** as its own environment, at `staging.app.unfoldhq.dev`. Production follows later at `app.unfoldhq.dev`, in its own namespaces, from the same chart. This replaces RFC 0003's shadow install (step 5) and D10: the homelab's Unfold keeps running until production exists here, and is then removed instead of becoming staging.
2. **Agents run under gVisor (`hardened`)**, not Kata. Unfold ADR-0045 and homelab ADR-0079 allow this on nodes without hardware virtualisation. Every pod that runs model-directed code takes `runtimeClassName: gvisor`:
   * Ploeg's worker pods (`executor.runtimeClassName`), enforced by Ploeg's own `security.workerAdmission` with `runtimeClassNames: [gvisor]`;
   * Unfold's workspace pods (`workspacePodRuntimeClassName`), in a namespace labelled `ploeg.webgrip.dev/isolation-class: hardened`, so the cluster's `sandboxed-workloads` policy refuses any workspace pod without gVisor.
   The delivery verifier stays off in staging.
3. **They run on the hub node, `unfold-app-1`**, beside Unfold, ploegd and their databases. The `gvisor` RuntimeClass gains a toleration for `node.webgrip.io/pool=unfold`, because neither chart lets worker or workspace pods carry their own tolerations; the RuntimeClass's `runtime.webgrip.io/gvisor` node selector keeps them on nodes with runsc. This reverses ADR 0013 part 5's "the `gvisor` RuntimeClass stops tolerating pool taints" until both charts accept tolerations.
4. **Public access is a Cloudflare Tunnel, declared in OpenTofu** (RFC 0003 section 3), with two changes for staging:
   * **One hostname.** `cloudflared` routes by path: `/webhooks/*` to ploegd, everything else to Unfold. No ploeg-mcp host in staging.
   * **No Gateway in between.** `cloudflared` reaches the two Services directly, over the pod network Cilium already encrypts with WireGuard. The Cilium Gateway in ClusterIP mode is still an unproven spike, and the ops Gateway holds port 443 on the control planes in host-network mode.
   * Cloudflare Access (one-time PIN to the owner's address) stands in front of every path except `/webhooks/*`; Unfold's own sign-in is the second control. Webhooks are checked by ploegd's HMAC.
5. **Staging owns its dependencies here**: its own LiteLLM with staging provider keys and budgets (as [ADR 0007](0007-production-runs-its-own-litellm.md) does for production), and its own CNPG databases, `ploeg-db` and `litellm-db`, from the cluster template.
6. **Staging watches its own board only.** A new Vikunja project, *Ploeg Staging*, and the fixture repository `webgrip/ploeg-bench-world`. It never names a board the homelab's ploegd watches, so nothing is dispatched twice (RFC 0003 R1).
7. **Names.** Everything below is the contract the manifests, the infrastructure and the secrets are built against.

| Thing | Name |
| --- | --- |
| Flux path | `kubernetes/apps/unfold-staging/` |
| Release namespace (Unfold, ploegd, Ploeg workers, `ploeg-db`) | `unfold-staging` |
| Workspace namespace | `unfold-staging-workspaces` |
| LiteLLM and `litellm-db` | `litellm-staging` |
| Tunnel connector | `cloudflared` in `unfold-staging-edge` |
| Tunnel | `unfold-staging`, ingress `staging.app.unfoldhq.dev` |
| OpenBao | `secret/unfold-main/staging/<component>` |
| Chart | `oci://ghcr.io/webgrip/charts/unfold`, pinned by digest |

## Consequences

* Good, because staging can exist this week, on the hub that is already paid for, with no metal order.
* Good, because staging proves on this cluster what production will run: the chart from GHCR, Zot, the admission policies, External Secrets, CNPG and the tunnel.
* Good, because gVisor runs on any node, so Runs can later move to an autoscaled `runs` pool (ADR 0013 part 5) without changing runtime.
* Bad, because **model-directed code shares a host kernel with `ploeg-db`, the LiteLLM master key and Unfold's store key, behind one sandbox**. RFC 0001 asks for two controls per boundary and RFC 0003 D12 rejected the same arrangement for CI. The owner accepts this for staging only, where the data is fixture data and the keys are staging keys with small budgets. Production does not inherit it: before production, Runs move off the hub (a `runs` pool or a metal node).
* Bad, because a sandbox escape lands on a `tag:hub` node, which may open the homelab gateway's port 443 ([ADR 0006](0006-production-reaches-the-homelab-from-the-hub-pool-only.md)). Staging's egress policies allow that path only to the relay pods, but a node-level escape is past them.
* Bad, because Tetragon cannot see inside a gVisor sandbox ([ADR 0012](0012-runtime-detection-with-tetragon-alone.md)); it sees only the sandbox's host process.
* Bad, because `staging.app.unfoldhq.dev` is two levels below the zone. Cloudflare's free Universal SSL covers only the apex and first-level names, so the edge needs Advanced Certificate Manager (about €9.50 a month) before the name serves TLS. Renaming to a first-level name such as `staging-app.unfoldhq.dev` removes that cost; the name is one variable in `infra/` and one in the Flux substitutions.
* Bad, because Ploeg's worker image (`agent-runner`) is published only to the homelab's Harbor. The executor stays off until it is published to GHCR or pushed into Zot's `webgrip/` namespace.
* Neutral: RFC 0003 D3, D5, D10 and D12 are superseded for staging by this record; for production they stay open.

## Confirmation

* `kubectl -n unfold-staging-workspaces run probe --image=… ` without `runtimeClassName: gvisor` is refused by `sandboxed-workloads`; a Ploeg worker without it is refused by Ploeg's `agent-security` policy.
* A workspace pod reports gVisor's kernel (`dmesg` starts with "Starting gVisor").
* From outside: `https://staging.app.unfoldhq.dev/` asks for Access; an unsigned `POST /webhooks/tracker/vikunja` gets 401; a port scan of every node's public address finds nothing open.
* ploegd migrates its empty database, Unfold answers `/healthz`, and a LiteLLM call is metered against a staging key's budget.

## History

* 2026-10-28: The owner renamed the host to `staging-app.unfoldhq.dev`, one level below the zone,
  so Cloudflare's free Universal SSL covers it and Advanced Certificate Manager is not needed.
  Wherever this record says `staging.app.unfoldhq.dev`, read `staging-app.unfoldhq.dev`; production
  stays `app.unfoldhq.dev`. The `unfold_staging_hostname` variable refuses a deeper name.
