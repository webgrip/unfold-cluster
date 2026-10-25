# RFC 0003: Moving Unfold and Ploeg from the homelab to this cluster

| | |
| --- | --- |
| Status | Proposed |
| Date | 2026-10-25 |
| Owner | ryangr0 |
| Builds on | RFC 0001 (delivery steps 8 to 15), RFC 0002, Unfold ADR-0040, ADR-0043 and ADR-0045, Ploeg ADR-0106, ADR-0107 and ADR-0154, homelab-cluster ADR-0044, ADR-0055, ADR-0070 and ADR-0071 |
| Proposes | [ADR 0005](../adr/0005-unfold-and-ploeg-move-in-one-cutover-after-the-run-gates.md), [ADR 0006](../adr/0006-production-reaches-the-homelab-from-the-hub-pool-only.md), [ADR 0007](../adr/0007-production-runs-its-own-litellm.md), [ADR 0008](../adr/0008-ploeg-and-unfold-data-move-as-encrypted-files.md), [ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md) |
| Facts checked | 2026-10-25: homelab-cluster `main` (files and live metrics), Unfold `development` 44990fe2 (chart 0.4.0-rc.114), Ploeg `development` b07f6d6, this repository's `main` 875006e and open PR #83, Hetzner price pages, the server auction feed and status page |

## Summary

Unfold and Ploeg run today in the homelab's `ploeg` namespace as one Helm release (`unfold`, with Ploeg as a subchart). This RFC moves them here and makes the homelab their staging environment, as Unfold ADR-0040 decided.

1. **What moves:** Unfold, ploegd, ploeg-mcp, the Ploeg database, the agent Runs and Unfold's workspaces.
2. **What stays home at first:** Forgejo, Vikunja, Authentik, OpenBao (still the only original of every secret), Omnigraph and the observability backend.
3. **LiteLLM moves too.** It gets its own provider keys here ([ADR 0007](../adr/0007-production-runs-its-own-litellm.md)), so client code never passes through the house and the production cluster holds no homelab master key.
4. **One cutover.** Unfold and Ploeg move in one window, after the Run security gates are on ([ADR 0005](../adr/0005-unfold-and-ploeg-move-in-one-cutover-after-the-run-gates.md)). Everything before that window installs into an empty shadow environment, so nothing has to be rolled back.
5. **Data:** about 110 MiB in total. It moves as two age-encrypted files ([ADR 0008](../adr/0008-ploeg-and-unfold-data-move-as-encrypted-files.md)). Downtime is about 30 to 60 minutes.
6. **Runs need bare metal,** and the AX41 is no longer sold. An EX44 at €60.70 a month takes its place ([ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md)).

After the move the cluster costs about **€116 a month excluding VAT** (about €140 including it), with the hub still on one node. It rises to about €188 when the hub grows to three nodes before the first client.

## Where things stand

| Part | State on 2026-10-25 |
| --- | --- |
| This cluster | Three CX23 control planes, the CX33 hub worker `unfold-app-1` and the CX23 `unfold-headscale` |
| What is running | Cilium with WireGuard, Flux deploying signed commits only, admission policies in Deny (#78), egress flow evidence ahead of default deny (#79), disk encryption through the KMS (#82), Zot, OIDC login, and External Secrets reading the homelab OpenBao through the homelab gateway |
| CI pool | `unfold-ci-1` (CX43) is declared at `node_count = 0`, because Hetzner has no CX to place |
| Metal node | None. Robot no longer sells the AX41-NVMe: plan run 201 failed on it. Open PR #83 sets `metal_servers = {}` and adds an adopt mode and an auction mode |
| Open PR #84 | Runs CI on the hub worker `unfold-app-1` under gVisor (two runners at most, priority -5 so the hub's own pods preempt them), overflows to a CPX42 that the cluster-autoscaler adds from zero, and moves KEDA to the control planes. It claims ADR 0004, so this RFC's ADRs start at 0005 |
| Being built by other streams | RFC 0001 step 10 (cert-manager, encrypted volumes, CNPG); runtime security (Tetragon); supply-chain signature checks. This RFC depends on their outcomes, not on their pull request numbers |
| The homelab | Everything Unfold and Ploeg need, in namespace `ploeg` (`kubernetes/apps/ploeg/` in homelab-cluster). It already feeds this cluster OpenBao reads, metrics and logs, and the CI queue length, through the `unfold-gateway` tailnet gateway |

## 1. Inventory

### What moves

Requests and limits are the values the homelab deploys: the chart defaults unless the homelab's `helmrelease.yaml` overrides them. "Peak" is the highest working set seen over the last 7 days.

| Component | In the homelab today | State and data | Depends on | Here |
| --- | --- | --- | --- | --- |
| Unfold workbench | Deployment, 1 replica, `Recreate` (one SQLite writer). Requests 100m / 256Mi, limits 1 CPU / 1Gi. Peak 521 MiB | SQLite and the store key file on PVC `unfold-data` (4Gi Longhorn, 88 MiB used). The key file decrypts every stored link and credential | ploegd API; LiteLLM; Forgejo; Vikunja (task sources); Authentik OIDC; reads of VictoriaLogs, VictoriaMetrics and traces; OTLP | hub pool, encrypted hcloud volume |
| ploegd | Deployment, 1 replica, Guaranteed 100m / 256Mi. Peak 60 MiB | None in the pod. Everything is in `ploeg-db` | `ploeg-db`; LiteLLM (it holds the master key and mints a key per Run); Forgejo API and webhooks; Vikunja API and webhooks; Omnigraph; Authentik JWKS for token exchange | hub pool |
| ploeg-mcp | 10m / 32Mi, limit 128Mi | None | ploegd; Authentik clients `ploeg-mcp` and `ploeg-mcp-confirm` | hub pool |
| `ploeg-db` (CNPG) | 2 instances, 100m / 256Mi each, 2Gi data and 5Gi WAL, PostgreSQL 18. Managed roles `ploeg_scaler` and `grafana_ro`. Backups through barman-cloud to the off-site Garage. A DR replica, `cnpg-disaster-recovery`, keeps running | The `app` database, **23 MiB** | CNPG operator, the barman-cloud plugin, object storage | hub pool. One instance at first, three when the hub has three nodes |
| Ploeg workers | One KEDA ScaledJob per team (bronze, silver, copper, pewter), `maxReplicaCount` 1 each. bronze and copper use the sandbox executor on `kata`. Requests 100m / 768Mi, limits 1 CPU / 768Mi | Ephemeral: an 8Gi `ci-shared` emptyDir per Run | ploegd; LiteLLM with a per-Run key; Forgejo git; OTLP | metal node, `kata` |
| agent-sandbox controller and Ploeg's sandbox launcher | The agent-sandbox Kustomization; launcher pods per sandbox team | None | Kubernetes API | controller on the hub pool, sandboxes on the metal node |
| Unfold workspaces | Namespace `unfold-workspaces`, `kata`. Requests 500m / 1Gi, limits 1 CPU / 2Gi. At most 1 concurrent session | An 8Gi PVC per workspace, kept 7 days | Unfold, LiteLLM, Forgejo | metal node. Needs a local encrypted StorageClass, because hcloud volumes cannot attach to a Robot server |
| Delivery verifier | Namespace `unfold-verifier`, `kata` | None | Unfold | metal node |
| Work-items exporter | postgres-exporter, 10m / 32Mi | None | `ploeg-db` | hub pool |
| `ploeg-tracker-wiring` | CronJob every 15 minutes, 25m / 64Mi | None | Vikunja API through its in-cluster Service | hub pool, reaching Vikunja through the gateway |
| Probes | `kata-clusterip-probe`, `runc-clusterip-probe`, `worker-egress-probe` | None | | ported as this cluster's proofs (step 7) |
| CNPG drills | `cnpg-restore-test` (weekly) and `cnpg-disaster-recovery-check` (hourly) | None | | replaced by RFC 0001's weekly restore drill into a throwaway cluster |

**Not moving: `claude-runner`,** the pewter team's runner on an Anthropic subscription session. Ploeg's P1 support profile refuses it (ADR-0154), so it stays with homelab staging ([D8](#d8-the-pewter-team-and-claude-runner)).

### What stays home, how this cluster reaches it, and what that trusts

| Service | Why it stays | How this cluster reaches it | What that trusts |
| --- | --- | --- | --- |
| Forgejo | Unfold ADR-0040 accepts it as a dependency: it holds the repositories and their CI. It is already public through the homelab's Cloudflare Tunnel (`forgejo.webgrip.dev`) | **API and git over HTTPS** at its public name: from the hub, and from Runs through the egress gateway's FQDN allowlist. **Webhooks** reach this cluster's public webhook endpoint, signed with HMAC | Repository text steers Runs, as it does today. The bot users stay the same, but each cluster gets **its own token** for them (no new bot accounts) |
| Vikunja | It is the tracker. Its route is internal only (`envoy-internal`) | **API** through a new homelab-gateway port, for the hub pool only ([ADR 0006](../adr/0006-production-reaches-the-homelab-from-the-hub-pool-only.md)). **Webhooks** reach the public webhook endpoint with HMAC | The hub can write the board with Ploeg's bot token. A webhook can only make ploegd re-read the tracker: ploegd acts on the API's answer, never on the webhook's body |
| Authentik | It is the identity provider. Only the `unfold-kubernetes` discovery and JWKS are public | **Browsers** use it over the LAN or the tailnet. **Unfold's and ploegd's server-side calls** (token, JWKS) go through the gateway's port 443, which `tag:headscale` already uses | An Authentik outage blocks new logins to Unfold. The owner accepted the same for Headscale |
| OpenBao | It is the only original of every secret (homelab ADR-0055) | External Secrets, `secret/unfold-main/*`, through the gateway, as today | Every production credential lives in the house. This was already true for the infrastructure (RFC 0001, "A compromised homelab") |
| Omnigraph | It is the knowledge graph | Off at cutover. Later through the gateway, with tokens that only this cluster holds ([D9](#d9-omnigraph)) | The graph's writers can steer Runs |
| Observability backend | The cluster has no in-cluster stack yet (RFC 0001 step 8 sends everything home) | Writes as today. **Unfold's reads** of logs, metrics and traces need read paths on the gateway, filtered to `cluster=unfold` ([D7](#d7-unfolds-reads-of-logs-and-metrics)) | The homelab sees all telemetry, as today |
| Harbor | Not used here. Images come from GHCR through Zot | | |
| LiteLLM | Moves ([ADR 0007](../adr/0007-production-runs-its-own-litellm.md)) | | |

### Trust, against RFC 0001's homelab-to-production risks

RFC 0001's threat model already records that **a compromised homelab can reach production**:

* The homelab OpenBao holds every production credential.
* The infra runner reads the Hetzner tokens.
* Flux trusts Forgejo's instance key for merges (README, owner decision 2026-10-25).

The move adds **one new write path from the homelab into production: webhooks.** Each one is HMAC-checked, and none carries authority, because ploegd re-reads the source of truth.

The bigger change runs the other way. The move adds paths **from production into the homelab**: Vikunja's API, Authentik's token endpoint and, later, Omnigraph. Those are paths a **Run that escapes to its node** could try.

The tailnet policy today lets every `tag:node` device open the gateway's OpenBao port 8200, and the CI and metal nodes join as `tag:node`. Once `secret/unfold-main/*` holds the application's tokens, that is one control (the OpenBao role's subject binding) between a Run escape and those tokens. RFC 0001 asks for two.

[ADR 0006](../adr/0006-production-reaches-the-homelab-from-the-hub-pool-only.md) splits the tags:

| Tag | Nodes | May open |
| --- | --- | --- |
| `tag:hub` | the hub pool | the gateway's ports |
| `tag:runs` | the metal node | the log and metrics write port only |
| `tag:ci` | the CI nodes | the log and metrics write port, and the queue-length port |

This keeps RFC 0001's rule of two controls per boundary on the house side.

## 2. Capacity

### The hub pool (`unfold-app-1`, CX33: 4 vCPU, 8 GB)

Talos and the kubelet reserve some of the node, which leaves about 3.7 CPU and 7.0 GiB allocatable. That is an estimate. The production metrics path returned no data when this was written, so check `kubectl describe node unfold-app-1` before step 5.

| Workload | CPU request | Memory request | Memory limit | Source |
| --- | --- | --- | --- | --- |
| Already on the node: Zot, Cilium agent, Vector, node-exporter, CSI node plugin | ~0.36 | ~0.94 GiB | | this repository |
| Coming with runtime security: Tetragon | 0.10 | 0.25 GiB | | RFC 0001 §9 |
| Unfold workbench (request raised to its observed peak) | 0.10 | 0.50 GiB | 1 GiB | homelab, live peak |
| ploegd, ploeg-mcp, exporter, tracker-wiring | 0.15 | 0.38 GiB | 0.6 GiB | homelab |
| `ploeg-db`, 1 instance, plus the barman sidecar | 0.11 | 0.63 GiB | 1 GiB | homelab |
| agent-sandbox controller | 0.05 | 0.13 GiB | 0.25 GiB | estimate |
| cloudflared, 2 replicas | 0.04 | 0.13 GiB | 0.25 GiB | estimate |
| CNPG operator (or on the control planes, as step 10 decides) | 0.10 | 0.25 GiB | 0.5 GiB | homelab: the operator once ran out of memory there on less |
| LiteLLM, its Valkey, its database and the database's sidecar ([ADR 0007](../adr/0007-production-runs-its-own-litellm.md)) | 0.17 | 1.28 GiB | 3 GiB | homelab |
| **Total** | **~1.2 of 3.7** | **~4.5 of 7.0 GiB** | ~6.6 GiB, before Zot and the agents | |

It fits, at about 65% of memory requested, with no failover. Three things do not fit on top of it:

* PR #84's CI baseline: two gVisor runners at 1.55 CPU and 3 GiB each. Their priority lets Unfold preempt them, but untrusted CI code would still share a node with `ploeg-db`, the LiteLLM master key and Unfold's store key ([D12](#d12-ci-on-the-hub-after-the-move));
* an in-cluster VMSingle, VLSingle and VictoriaTraces (about 1.5 GiB), and
* the three replicas each that RFC 0001 asks of Postgres, OpenBao and NATS.

The last two wait for the hub to grow, which RFC 0002 put "before anyone else depends on it" ([D4](#d4-hub-size-at-cutover)).

### The metal node (Runs and workspaces)

On a 64 GB machine, the kubelet reservation of ADR 0002 (1.5 CPU, 3 GiB) leaves about 60 GiB.

| Pod | Request | VM or limit | Kata overhead | Per pod, scheduled |
| --- | --- | --- | --- | --- |
| Ploeg worker | 100m / 768Mi | 1 CPU / 768Mi | 100m / 160Mi | 0.2 CPU / 0.9 GiB |
| Unfold workspace | 500m / 1Gi | 1 CPU / 2Gi | 100m / 160Mi | 0.6 CPU / 1.2 GiB |
| CI job (runner and rootless BuildKit, gVisor), up to 3 | 1.5 CPU / 3 GiB | | 50m / 64Mi | 1.55 CPU / 3.1 GiB |

Today's concurrency is 4 workers and 1 workspace. That is about 1.4 CPU and 4.8 GiB, or about 5.5 CPU and 6 GiB at their limits.

**Kata sizes each VM by the pod's limits,** so CPU at the limits is the number that matters:

* An EX44 (20 threads) runs about **12 concurrent Runs** beside three CI jobs.
* Without the CI jobs it runs about 16.

So CI belongs on the on-demand CPX42 once that exists, and the metal node stays a Run node ([D3](#d3-the-metal-node)).

### Node plan and cost

Live on 2026-10-25:

* **CX:** every CX and CAX plan is marked "not available", and Hetzner's status page has carried "Limited availability of cloud instances" since 2026-06-26. Existing CX servers keep their old prices.
* **CPX and CCX:** these are in stock at the prices from 15 June: CPX32 €35.99, CPX42 €69.99 (€0.1122 an hour), CCX23 €86.49.
* **AX41-NVMe:** no longer sold.
* **EX44:** €59.00 with no setup fee, in FSN1 and HEL1.
* **AX42:** €99.00 plus €49.00 setup.
* **Server auction:** the cheapest 64 GB machine is €71 plus €1.70 for IPv4 (an i7-6700 with 2 × 512 GB NVMe).
* **Dedicated IPv4:** €1.70.

| Item | Now | After the move | Before the first client |
| --- | --- | --- | --- |
| 3 × CX23 control planes | €17.97 | €17.97 | €17.97 |
| `unfold-app-1` CX33 (hub) | €8.99 | €8.99 | €8.99 |
| 2 more hub nodes, CPX32, unless CX returns | | | €71.98 |
| `unfold-headscale` CX23 | €5.99 | €5.99 | €5.99 |
| Metal node EX44 with IPv4 ([ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md)) | | €60.70 | €60.70 |
| CI node CPX42 on demand, about 100 hours a month | | ~€11.22 | ~€11.22 |
| Object storage, Hetzner and OVHcloud (RFC 0001) | | ~€10.00 | ~€10.00 |
| hcloud volumes (Unfold data and LiteLLM, about 20 GB) | | ~€0.88 | ~€0.88 |
| **Total excluding VAT** | **€32.95** | **~€115.75** | **~€187.73** |
| Including 21% VAT | €39.87 | ~€140.06 | ~€227.15 |

The total stays under ADR-0040's €185 cap after the move. It also stays under the €280 cap that RFC 0002 set before the first client.

* Models are capped separately, at €100 a month, through LiteLLM's budgets.
* The CI node is billed hourly, so it is the only line that moves with use. 100 hours is a cautious guess; PR #84 expects €2.24 to €7.00 a month. Always on, it would cost €69.99.
* In the homelab, the move frees about 0.5 CPU and 3.5 GiB of requests on worker nodes whose memory is nearly full. It saves no power, because the nodes stay on.

## 3. Public access

RFC 0001 step 11.

```
forge / tracker / browser ──► Cloudflare edge (TLS, WAF, Access) ──► cloudflared ×2 (hub)
                                                                         │ HTTPS, internal CA
                                                                         ▼
                                                    Cilium Gateway (ClusterIP Service only)
                                                    ├─ UI host: Unfold :4080, ploeg-mcp :8090
                                                    └─ webhook host: ploegd /webhooks/* only
```

| Concern | Design |
| --- | --- |
| Tunnel | A Cloudflare Tunnel declared in OpenTofu in `infra/`, its public hostnames included. The apply writes the connector token to OpenBao `secret/unfold-main/cloudflare/tunnel`, and External Secrets delivers it. Two `cloudflared` replicas run on the hub pool with a PodDisruptionBudget. Their only egress is Cloudflare's tunnel endpoints, by FQDN. The owner seeds one Cloudflare API token, with tunnel edit and DNS edit on the zone, at `secret/cloudflare/unfold-tunnel`. Nothing is clicked in the dashboard |
| Gateway | Cilium's Gateway API in namespace `gateway`. Its Service is `ClusterIP` (`CiliumGatewayClassConfig`), so neither a Hetzner load balancer nor a node port exists. The admission policy `service-exposure` already refuses both elsewhere. Spike: confirm the class parameter on Cilium 1.20 |
| Hostnames | First-level names under `webgrip.dev`, so Cloudflare's Universal SSL covers them: `unfold`, `unfold-hooks` and `mcp-ploeg`. The CNAMEs point at the tunnel and are declared in homelab-cluster's `cloudflare-dns`, the same way `headscale` is. This cluster holds no DNS token ([D5](#d5-hostnames-and-dns-authority)) |
| The homelab's LAN DNS | The homelab's k8s-gateway answers every hostname that a homelab HTTPRoute declares, so LAN clients would keep landing on staging. The cutover removes the homelab's `unfold` and `mcp-ploeg` routes, and staging gets `unfold-staging` |
| TLS | Cloudflare terminates at the edge. `cloudflared` connects to the Gateway over HTTPS with a certificate from cert-manager's internal CA (step 10), and checks it with `originRequest.caPool` and `originServerName`. DNSSEC and a CAA record that allows only Let's Encrypt and Cloudflare's CAs (RFC 0001 §5) |
| Auth on the UI host | A Cloudflare Access application allows the owner's identity, and Unfold's own Authentik OIDC applies behind it, so two independent controls stand in front of the UI. MCP clients send an Access service token ([D6](#d6-owner-facing-endpoints)) |
| Auth on the webhook host | No Access, because forges cannot answer it. The Gateway routes only `POST /webhooks/*` to ploegd, and everything else gets a 404. ploegd checks each forge's and the tracker's HMAC. A Cloudflare rate limit applies, and the origin accepts connections from the tunnel only |
| Later | `unfoldhq.dev` for the read-only demo, and the GitHub and GitLab webhooks (ADR-0040). The same tunnel serves them, under their own hostnames and routes |

## 4. Data migration

| Dataset | Size | Method | Notes |
| --- | --- | --- | --- |
| `ploeg-db` database `app` | 23 MiB | `pg_dump -Fc` from the frozen homelab primary, then `pg_restore` into a fresh CNPG cluster here ([ADR 0008](../adr/0008-ploeg-and-unfold-data-move-as-encrypted-files.md)) | Both sides run PostgreSQL 18. The managed roles are declared again here, not dumped |
| Unfold data directory | 88 MiB | `sqlite3 .backup` plus the store key file, as one tarball, restored by an init Job before Unfold starts | The store key **must** come with the data, or no stored credential can be decrypted |
| LiteLLM | | Not migrated. Production starts with an empty LiteLLM: its own keys, budgets and spend log | Per-Run keys live 4 hours. None survives a cutover anyway |
| Generated secrets | | Generated again here: the worker signing key, the worker bootstrap registry, the webhook secrets, the operator and MCP tokens, the confirmation key and the scaler password | A new webhook secret means the tracker and forge webhooks are wired again. Step 8 includes that |
| Provided secrets | | The same bot users, with **new tokens** for this cluster, at `secret/unfold-main/...`, written by homelab provisioners or handed to the owner as `bao kv put` commands | Forgejo `agent-builder` and `agent-reviewer`, Vikunja `bot-ploeg`, the Unfold reports bot, and the Authentik client secrets of the production clients |

### The transfer

* **Encryption.** Each file is encrypted with age, to a recipient whose identity only this cluster's migration Job can read.
* **Upload.** A homelab Job writes each file to a short-lived bucket `unfold-migration` on this cluster's object storage (step 3 of RFC 0001). It uses a key that may write and nothing else.
* **Download.** A production Job reads the files with a key that may read and nothing else.
* **Deletion.** Bucket and keys are deleted after the soak.
* **No new port.** No database port crosses the tailnet.

### Verification

Each check runs on the frozen source and on the target, and the two outputs must be equal:

* **Row counts:** per table.
* **Table checksums:** `md5(string_agg(t::text, '' ORDER BY t::text))` per table.
* **Sequences:** `last_value` of every sequence.
* **Schema:** Ploeg's applied migration versions.
* **SQLite:** `PRAGMA integrity_check` must return `ok`. The tarball's sha256 must match before upload and after download, and the per-table counts must match.
* **Functional check:**
  * one stored Unfold link decrypts and opens;
  * the newest `agent_runs` row in production equals the newest at the source.

A script under `scripts/` prints the comparison and exits non-zero on any difference. Its mutation test runs one row short, and must also pass on an identical copy.

### Window and rehearsal

* **Rehearsal.** The full sequence runs twice into the shadow environment of step 5 before the real window, and the shadow database is dropped after each run. A rehearsal measures the window and leaves the source untouched.
* **The real window.**
  1. Stop intake: set the homelab executor's teams to 0 and stop ploegd's tracker polling.
  2. Wait for running Runs to finish, or cancel the stragglers after 30 minutes.
  3. Scale the homelab's ploegd and Unfold to 0.
  4. Dump, transfer, restore and verify.
  5. Start production with the real board projects.
  6. Wire the webhooks again.
  7. Check that one real ticket is dispatched and opens a pull request.
* **Downtime.** About 30 to 60 minutes of no dispatching. Tickets that arrive meanwhile wait on the board, and production picks them up when it starts.

### Rollback

| Until | Rollback |
| --- | --- |
| Step 8 starts | Nothing to undo: production ran only in shadow |
| The webhooks are re-pointed | Scale the homelab's ploegd and Unfold back up. The source is untouched |
| The end of the 14-day soak | Freeze production, then run the same transfer in reverse, so that work done in production is kept. The homelab's `ploeg-db` stays hibernated and backed up for those 14 days |
| After the soak | The homelab database becomes staging's, on the fixture boards. Rolling back after that is a new migration |

## 5. Order of steps

Each step is a pull request with its own proof, then a reviewed `infra` apply wherever `infra/` changes. Steps 1 to 4 can run in parallel. **No agent Run executes here before every gate in step 7 is green.**

| # | Pull request | Apply | Proof |
| --- | --- | --- | --- |
| 0 | This RFC and ADRs 0005 to 0009 (docs only) | none | The owner's decisions below, recorded in each ADR |
| 1 | Prerequisites from the other streams: cert-manager with the internal CA, an encrypted hcloud StorageClass and an encrypted local StorageClass on the metal node, the CNPG operator with the barman-cloud plugin, and object storage at both providers (RFC 0001 steps 3 and 10) | yes | A throwaway CNPG cluster backs up, is restored into a second throwaway cluster, and its canary row is found. A PVC on another class is refused |
| 2 | The metal node: adopt or order the EX44 through PR #83's modes, Kata 4.3.1 and gVisor on KVM, `kvm_intel` ([ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md)) | yes, with a plan whose price line reads €60.70 or less | ADR-0040's check: a `kata` pod reports a guest kernel different from the host's. The disk report shows LUKS2 with the KMS key slot |
| 3 | Tailnet tags `tag:hub`, `tag:runs` and `tag:ci`, and the gateway's new ports for Vikunja's API and Authentik ([ADR 0006](../adr/0006-production-reaches-the-homelab-from-the-hub-pool-only.md)), in this repository and in homelab-cluster | yes (Headscale policy) | From a hub pod: Vikunja and Authentik answer. From the metal node and a CI pod: 8200 and the new ports are refused, and 8427 is accepted. The policy test pins each case |
| 4 | Supply chain: `ghcr.io/webgrip/unfold`, `ghcr.io/webgrip/unfold-agent`, `ghcr.io/ploeg-hq/` and the CNPG Postgres image on `allowedPrefixes`, synced through Zot, with signatures checked at pull and at admission | no | The admission test admits each digest-pinned image, and refuses the same image by tag and an unsigned image |
| 5 | **Shadow hub:** CI's hub preference and `unfold` toleration removed ([D12](#d12-ci-on-the-hub-after-the-move)); namespace `ploeg` and an empty `ploeg-db`; LiteLLM with its own database and provider keys ([ADR 0007](../adr/0007-production-runs-its-own-litellm.md)); the `unfold` release with `ploeg.executor.enabled: false` and only the Ploeg Test board; the secrets at `secret/unfold-main/...` | no | ploegd migrates the empty database. Unfold answers its health check. An OIDC login works over the tailnet. A LiteLLM call is metered against its key's budget. **This is also ADR-0040's public install proof:** the release installs from published artifacts with this cluster's values only |
| 6 | Public access: Tunnel, Gateway, routes and Access (section 3) | yes (Tunnel in OpenTofu) | From outside: the UI host asks for Access. On the webhook host, an unsigned POST gets 401, a correctly signed test POST gets 2xx, and any other path gets 404. A port scan of every node's public address finds nothing open |
| 7 | **Run gates, then the executor on the fixture boards only** (Ploeg Test and Ploeg Bench) | as needed | Every gate below green, and one Bench Run completes under `kata` |
| 8 | **Cutover** (section 4): the homelab config loses the real board projects, and this cluster's config gains them, in two commits merged within the window | no | The comparison script prints no difference. A real ticket is dispatched and opens a pull request. The homelab's ploegd is at 0 replicas |
| 9 | The homelab becomes staging: `unfold-staging` hostname, fixture boards, `claude-runner` kept there ([D8](#d8-the-pewter-team-and-claude-runner)) | no | The homelab's Unfold lists only fixture projects. No production project id appears in the homelab's values (a check in homelab CI) |
| 10 | After 14 days: delete the migration bucket and keys, archive the homelab's old `ploeg-db` backups, and close the temporary paths | no | The bucket is gone. The weekly restore drill of production's `ploeg-db` passes |

### The gates before untrusted Runs (step 7)

Each gate needs its mutation test (RFC 0001 rule 4): it must refuse when the control is removed and admit when it is present.

| Gate | Control | Proof |
| --- | --- | --- |
| G1 | Admission in Deny for `sandboxed-workloads`, `sandbox-annotations`, the pod-security policies and the image policy (#78, done) | The existing tests, plus a Ploeg worker and a workspace pod rendered from the real chart values |
| G2 | Runs land only on the metal node under `kata`. The isolation-class label must match the runtime class. Ploeg's `security.workerAdmission` is on with `runtimeClassNames: [kata]`. `automountServiceAccountToken: false` and `hostUsers: false` | A worker without `kata`, with a wrong label, or with a token mounted is refused. A correct one is admitted |
| G3 | Egress default-deny for `ploeg`, `unfold-workspaces` and `unfold-verifier`. Run egress leaves only through the egress gateway, with a fixed source address and FQDN rules: the forge, LiteLLM and ploegd (homelab ADR-0071, RFC 0001 §4) | `worker-egress-probe` ported: the allowed list answers. The database, Unfold, ploeg-mcp, Vikunja, the gateway's addresses, the cloud subnet, Hetzner metadata and `example.com` are refused |
| G4 | Tetragon's Run policies enforcing through BPF LSM: credential-file reads, `setns` and `unshare`, module and BPF loads, exec from `/tmp`. Events leave the cluster within seconds | Each forbidden action in a test pod is killed and its event shows up in the homelab's VictoriaLogs |
| G5 | Run nodes have no route to the homelab: `tag:runs` (step 3) | Part of step 3's proof |
| G6 | Credentials stay out of the Run's pod. LiteLLM `keyIsolation: proxy`, with per-Run keys of 4 hours and a budget. The forge token is held by the proxy. A quarantine label denies all egress | A Run's environment and filesystem hold no forge token and no master key. A quarantined pod reaches nothing |
| G7 | The metal node's disks are encrypted with the KMS key (#82) and its host firewall is closed | The `diagnose` disk report, and a port scan |
| G8 | KEDA holds no read-all credential on an untrusted node: the scaler's role reads one counting view only ([R6](#r6-the-keda-scaler-credential)) | `SELECT` on any other table as `ploeg_scaler` fails |
| G9 | Ploeg's attack drill (ADR-0126) and a planted-sabotage Run against this cluster (RFC 0001, qualification item 5) | The drill's report shows every attack refused or caught |

## 6. Risks and open owner decisions

### Decisions

#### D1. The cutover's shape

* A. **One cutover:** the hub and the Runs move together, after the gates.
* B. The hub first, with the homelab running Runs as a cell. This needs Ploeg's `ploeg-cell` chart (ADR-0107), which does not exist yet.
* C. The hub first with no Runs. Agent work stops until the gates are green.

**Recommendation: A** ([ADR 0005](../adr/0005-unfold-and-ploeg-move-in-one-cutover-after-the-run-gates.md)). B is the long-term shape, but it waits on an unbuilt chart. C stops the owner's work for weeks.

#### D2. LiteLLM

* A. **Its own instance here,** with production provider keys and budgets.
* B. The homelab's LiteLLM through the gateway. ploegd would then hold the homelab master key, and every prompt carrying client code would pass through the house.
* C. Provider keys straight in ploegd. That skips the metering homelab ADR-0044 requires.

**Recommendation: A** ([ADR 0007](../adr/0007-production-runs-its-own-litellm.md)). The cost is about 1.3 GiB of hub memory and one more provider key per provider. Self-hosted models that only the homelab serves stay out of production until a route is decided.

#### D3. The metal node

* A. **An EX44:** €59.00 plus €1.70 for IPv4, no setup fee, 64 GB, an Intel i5-13500 with 20 threads and VT-x. It fits the €65 ceiling already in `infra/`.
* B. An auction i7-6700 with 64 GB: €72.70, over the ceiling, an old CPU, no ECC.
* C. An AX42: €99.00 plus €49.00 setup, ECC memory, an AMD CPU (SEV-capable, which keeps RFC 0002 phase 0 the same).
* D. No metal: Runs under gVisor on a CPX42 as `hardened`. Unfold ADR-0045 allows this on cloud VMs, but it gives up Kata for writing Runs.

**Recommendation: A** ([ADR 0009](../adr/0009-the-metal-node-is-an-ex44.md)). Re-check stock on the day of ordering.

#### D4. Hub size at cutover

* A. **Keep the one CX33** and grow to three before the first client, as RFC 0002 decided.
* B. Three hub nodes now: two CPX32s, +€71.98 a month.

**Recommendation: A.** The owner is the only user. Unfold is a single writer with `Recreate` anyway. WAL archiving bounds data loss to minutes. The node's loss is an outage of hours, while a new CX33 or CPX32 is created by an apply.

#### D5. Hostnames and DNS authority

* A. **First-level names under `webgrip.dev`,** declared in homelab-cluster's `cloudflare-dns`. This cluster holds no DNS token.
* B. A subzone owned by this cluster's external-dns (RFC 0001 §5). Cloudflare gives a subzone its own zone only on paid plans, so the token would cover all of `webgrip.dev`.
* C. Names under `unfoldhq.dev`, the product's zone, with a token scoped to that zone.

**Recommendation: A** for the owner's production. Use C for the demo and for agencies when they come.

#### D6. Owner-facing endpoints

* A. **Public, behind Cloudflare Access and then Unfold's OIDC.** MCP clients use Access service tokens.
* B. Tailnet only, through a Gateway in host-network mode on the hub node, with the host firewall admitting only the tailnet. This needs a certificate that a browser trusts, so it needs a DNS-01 token in this cluster, which brings back D5's problem.

**Recommendation: A.** The tunnel exists anyway for the webhooks, two independent checks stand in front of the UI, and it works from a phone without the tailnet.

#### D7. Unfold's reads of logs and metrics

* A. **Read paths on the homelab gateway's vmauth,** forced to `cluster=unfold` with `extra_filters`, for the hub only.
* B. An in-cluster VMSingle, VLSingle and VictoriaTraces first. This needs D4 B.

**Recommendation: A** at cutover, and B once the hub grows. Until then, an outage of the house hides Run logs from the UI. Runs keep working.

#### D8. The pewter team and `claude-runner`

* A. **Stays on homelab staging,** outside production.
* B. Retired.
* C. Moved under `supportProfile: unsupported`.

**Recommendation: A.** C undoes the P1 profile in the one place where untrusted code runs.

#### D9. Omnigraph

* A. **Off in production at cutover,** then reached through the gateway with tokens that only this cluster holds.
* B. Through the gateway from day one.

**Recommendation: A.** It keeps the first window small.

#### D10. The homelab after the move

* A. **Staging, on the fixture boards only,** under the `unfold-staging` hostname. A homelab CI check refuses any production project id in its values.
* B. Remove Unfold and Ploeg from the homelab.

**Recommendation: A.** ADR-0040 makes the homelab staging, and the check closes R1.

#### D11. How the data moves

* A. **Two age-encrypted files** through a short-lived bucket.
* B. CNPG's `import` bootstrap. It is declarative, but it needs a temporary database port across the tailnet.

**Recommendation: A** ([ADR 0008](../adr/0008-ploeg-and-unfold-data-move-as-encrypted-files.md)).

#### D12. CI on the hub after the move

PR #84 puts the CI baseline on `unfold-app-1`. That is sound while the hub holds nothing but Zot. RFC 0001 says CI does not belong next to the production hub.

* A. **CI leaves the hub before step 5.** The baseline moves to the metal node under gVisor on KVM, as ADR 0002 allows, and overflow stays on the autoscaled CPX42.
* B. CI stays on the hub, preemptible, under gVisor. Untrusted build code then shares a kernel host with the database and the LiteLLM master key, behind one sandbox.
* C. One CPX42 always on as the CI baseline: +€69.99 a month.

**Recommendation: A.** Step 5 then also drops the hub preference and the `unfold` toleration from the runner ScaledJob. On the metal node, CI shares a host with Runs, which ADR 0002 already accepted, and holds no production secret.

### Risks

#### R1. Double dispatch

Two ploegds watching the same boards would run every ticket twice and spend twice. Mitigations:

* Step 8 removes the projects from the homelab and adds them here within one window.
* The homelab is at 0 replicas before production starts.
* D10's check stops them coming back.

#### R2. A Run escape reaches the house

The tailnet policy today lets every `tag:node` device open OpenBao's port. [ADR 0006](../adr/0006-production-reaches-the-homelab-from-the-hub-pool-only.md) and gate G5 close this before any Run moves.

#### R3. One hub node, one metal node

There is no failover for either. If the metal node is lost, Runs wait and are never run below their floor (Ploeg ADR-0106). If the hub node is lost, Unfold and ploegd are down until a new node is created. It is accepted until D4 B.

#### R4. Metal stock

The AX41 vanished between ADR-0040 and its order. EX44 stock can vanish the same way, so PR #83's auction mode with a price ceiling is the fallback (D3 B or C).

#### R5. The store key

If the store key file is lost, every stored link and credential is lost too. Mitigations:

* The tarball carries the whole data directory.
* Verification decrypts one stored link.
* The homelab copy is kept for 14 days.

#### R6. The KEDA scaler credential

Ploeg's PostgreSQL scaler gives KEDA the password of `ploeg_scaler`, which has `pg_read_all_data` in the homelab. ADR 0002 runs KEDA where CI runs, which would put a read-everything credential on an untrusted node. PR #84 moves KEDA to the control planes, which removes the untrusted node, but KEDA still holds the credential. The fix is that the scaler's role gets `SELECT` on one counting view only (gate G8).

#### R7. The homelab is in the intake path

A homelab outage stops intake, logins and CI (ADR-0040 accepts this). While it lasts, production keeps serving and reconciling, and in-flight Runs finish.

#### R8. Image and policy gaps found late

The chart may render something the admission policies refuse. That shows up only when the real values are rendered, so step 5 renders the real chart values against the policies in CI before any apply.

#### R9. The workspace volumes

hcloud volumes cannot attach to a Robot server, so workspaces need step 1's encrypted local StorageClass on the metal node. Until it exists, workspaces stay on staging.

#### R10. The production metrics path was empty when this was written

The live numbers for the hub node come from manifests, not measurements. Before step 5, check the node's allocatable resources and the scrape targets in VictoriaMetrics.

## Decisions

None yet. The owner decides D1 to D12, and each recommendation accepted here moves its ADR from `proposed` to `accepted`.
