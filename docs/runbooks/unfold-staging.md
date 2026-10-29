# Unfold staging

Unfold staging runs in this cluster at `https://staging-app.unfoldhq.dev`, public through a Cloudflare Tunnel, with its agents under gVisor on the hub node. The decision and its accepted risks are [ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md). Everything is in `kubernetes/apps/unfold-staging/`.

## What runs where

| Namespace | What | Placement |
| --- | --- | --- |
| `unfold-staging` | The `unfold` HelmRelease (`oci://ghcr.io/webgrip/charts/unfold`, pinned by digest): the Unfold workbench and ploegd, with Ploeg's executor off; `ploeg-db` (CNPG, one instance, database `app`, owner `ploeg`); `vikunja-relay` | hub (`node.webgrip.io/pool=unfold`) |
| `unfold-staging-workspaces` | Unfold's agent workspaces, one pod each, `runtimeClassName: gvisor`; labelled `ploeg.webgrip.dev/isolation-class: hardened`, so `sandboxed-workloads` refuses any pod without gVisor and with a mounted token | hub, through the `gvisor` RuntimeClass |
| `litellm-staging` | LiteLLM (`ghcr.io/berriai/litellm-non_root`, app-template chart) with staging's own provider keys and budgets; `litellm-db` (CNPG) | hub |
| `unfold-staging-edge` | `cloudflared`, two replicas, the tunnel connector | hub |

Flux applies them in this order: `unfold-staging-namespaces`, then `unfold-staging-ploeg-db` and `litellm-staging-db` (after `plugin-barman-cloud`), `unfold-staging-workspaces`, `litellm-staging`, `unfold-staging` and `unfold-staging-edge` (after `external-secrets-stores`). The databases have no backup: the backup component waits for the object storage bucket ([postgres databases](postgres-databases.md#backups-built-off-until-the-bucket-exists)).

A `LimitRange` in `unfold-staging` and in `unfold-staging-workspaces` gives every container without one an ephemeral-storage limit, because Unfold creates workspace pods without one and `resource-limits` refuses those.

### Substitutions

The `unfold-staging` Flux Kustomization sets two variables in `kubernetes/apps/unfold-staging/ks.yaml`:

| Variable | Value | Used for |
| --- | --- | --- |
| `UNFOLD_STAGING_HOSTNAME` | `staging-app.unfoldhq.dev` | Unfold's `baseUrl` |
| `UNFOLD_STAGING_VIKUNJA_PROJECT_ID` | `'"154"'`, *Fixture · Ploeg Staging (unfold-cluster)* | the Vikunja project id of Unfold's task source |

The project id keeps its double quotes inside the single quotes (`'"123"'`). Flux substitutes into YAML text, and a bare `123` would reach Unfold as a number. ploegd finds the same project by its name, *Ploeg Staging*.

## Secrets the owner seeds

Every value lives in the homelab OpenBao; External Secrets reads it through `openbao-homelab`. Seed them from a homelab-cluster checkout with `just secret-set <path> <key>`: it logs in to OpenBao if needed, asks for the value without echoing it, keeps the other keys at the path and leaves nothing in shell history.

```sh
just secret-set unfold-main/staging/litellm fireworks-api-key
just secret-set unfold-main/staging/litellm hetzner-inference-api-key
just secret-set unfold-main/staging/forgejo builder-token
just secret-set unfold-main/staging/forgejo reader-token
```

| Key | Value |
| --- | --- |
| `fireworks-api-key`, `hetzner-inference-api-key` | staging keys from each provider, with a monthly cap |
| `builder-token` | a new Forgejo token of `agent-builder` with write on `webgrip/ploeg-bench-world` only; ploegd does not start without it, even with the executor off |
| `reader-token` | a new Forgejo token of `agent-reviewer` with read on `webgrip/ploeg-bench-world` only |

The tunnel token is written by the `infra` apply that declares the tunnel, not by hand; until it exists `cloudflared` does not start. OpenBao's role `unfold-main-external-secrets` must allow `secret/unfold-main/staging/*`; it already allows `secret/unfold-main/*`.

Generated in the cluster, never in OpenBao (External Secrets `Password` generators, `refreshInterval: "0"`): `litellm-generated` in `litellm-staging` (`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`; the executor reads the master key from there through the `litellm-staging` SecretStore, whose service account may get that one Secret and nothing else), and `unfold-credentials` (`PLOEG_OPERATOR_UNFOLD_TOKEN`, the token Unfold presents to ploegd, and `UNFOLD_ADMIN_PASSWORD`, the first administrator's password). Read the password once with `kubectl -n unfold-staging get secret unfold-credentials -o jsonpath='{.data.UNFOLD_ADMIN_PASSWORD}' | base64 -d`. The store key that encrypts Unfold's stored links and credentials is the file the workbench writes next to its database on the encrypted `unfold-data` volume.

## Vikunja

1. The project is *Fixture · Ploeg Staging (unfold-cluster)*, id 154. Never point staging at a board the homelab's ploegd watches: both would dispatch the same ticket ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md#r1-double-dispatch)).
2. Give `bot-ploeg` access to it and put a token in `secret/unfold-main/staging/vikunja` (above).
3. Its id is `UNFOLD_STAGING_VIKUNJA_PROJECT_ID` in `ks.yaml`, written as `'"154"'`.
4. The homelab's `unfold-staging-board-wiring` CronJob (homelab-cluster `kubernetes/apps/vikunja/vikunja/app/`) shares the project with `bot-ploeg` and registers the webhook `https://staging-app.unfoldhq.dev/webhooks/tracker/vikunja` with `webhook-secret`, which it generates and pushes to OpenBao itself. For now `api-token` is a copy of `bot-ploeg`'s homelab token, so it can write every board that bot is on; a separate staging bot is the follow-up.

ploegd and the workbench reach Vikunja's API through `vikunja-relay`, an Envoy CONNECT proxy that forwards `vikunja.webgrip.dev:443` and nothing else to the homelab gateway's 443, the same path [the ops consoles](ops-consoles.md#how-the-logins-reach-authentik) use for Authentik. Both pods send `HTTPS_PROXY` to it and keep Forgejo and the cluster's own names in `NO_PROXY`. Before relying on it, check from the relay's side that the homelab gateway routes `vikunja.webgrip.dev` like it routes Authentik: `kubectl -n unfold-staging logs deploy/vikunja-relay` shows nothing on success, and ploegd's log names the tracker error otherwise.

## Network

Every namespace starts from the cluster's default deny ([egress by name](egress-by-name.md)). The policies are in each directory's `networkpolicy.yaml` or `cloudflared.yaml`.

| From | To | Port | Why |
| --- | --- | --- | --- |
| `cloudflared` | Cloudflare's tunnel edge (`*.v2.argotunnel.com`), `api.cloudflare.com` | 7844 UDP and TCP, 443 | the tunnel |
| `cloudflared` | Unfold | 4080 | every path but `/webhooks/` |
| `cloudflared` | ploegd | 8080, **`POST /webhooks/.*` only** (Cilium's L7 rule) | tracker and forge webhooks |
| Unfold | ploegd 8080, LiteLLM 4000, the Kubernetes API, `vikunja-relay` 3128, `forgejo.webgrip.dev` 443 | | the workbench creates workspace pods and reads the repositories |
| ploegd | `ploeg-db` 5432, LiteLLM 4000, `vikunja-relay` 3128, `forgejo.webgrip.dev` 443 | | the chart's own NetworkPolicy plus `ploegd` |
| `vikunja-relay` | `unfold-gateway.webgrip.dev` | 443 | the homelab gateway, `tag:hub` only on the tailnet |
| LiteLLM | `litellm-db` 5432, `api.fireworks.ai` 443, `inference.hetzner.com` 443 | | models |
| a workspace | Unfold 4080, LiteLLM 4000, `forgejo.webgrip.dev` 443 | | nothing else |

The workspace namespace is left out of the cluster's `default-dns`; its own policy answers only names under `cluster.local` and `forgejo.webgrip.dev`, so an agent cannot carry data out in DNS lookups. `unfold-staging` still has `default-dns`, which matters once Ploeg's workers run there (below).

Ploeg's chart renders its own default-deny NetworkPolicies, which profile P1 requires. Its forge peer points at a label no pod carries (`ploeg.webgrip.dev/egress: cilium-fqdn`), so the chart never opens `0.0.0.0/0`; the Cilium policies add Forgejo by name.

## Turning Ploeg's executor on

The executor is configured for gVisor in the HelmRelease (`ploeg.executor`: team `staging`, a builder and a reviewer on `webgrip/ploeg-bench-world`, `runtimeClassName: gvisor`, both credential proxies, `security.workerAdmission` admitting only `gvisor`) and switched off. Before `executor.enabled: true`:

1. **The agent image.** `agent-runner` exists only on the homelab's Harbor. Publish it to `ghcr.io/webgrip/agent-runner` (or push it into Zot's `webgrip/` namespace) and set the digest in `executor.runnerImage`; the value there now is the Harbor digest and only a guess.
2. **The worker's unbounded `emptyDir`.** Ploeg chart 0.2.0-rc.81 renders `worker-bin` with no `sizeLimit`, which `resource-limits` refuses. A post-renderer on the HelmRelease sets it to 256Mi; its `test` step fails the release if a chart moves that volume, so drop the patch once Ploeg's chart sets a limit itself.
3. **The forge webhook.** The executor's secrets in `unfold/executor/` are applied already, because Ploeg's chart hands ploegd every one of them whether the executor is on or not. `ploeg-forge-webhook` is generated in the cluster; add a Forgejo webhook on `webgrip/ploeg-bench-world` to `https://staging-app.unfoldhq.dev/webhooks/forge/forgejo` with its `PLOEG_FORGEJO_SECRET`.
4. **KEDA.** The ScaledJob's scaler connects to `ploeg-db` as `ploeg_scaler` from the `keda` namespace: add the managed role (with `SELECT` on Ploeg's counting view only, RFC 0003 gate G8) and a client label rule for KEDA on `ploeg-db`'s policy.
5. **DNS for workers.** Workers share `unfold-staging` with ploegd, so `default-dns` answers them any name. Move them to their own namespace or accept it for staging.

## Checks

From [ADR 0017's confirmation](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md#confirmation):

* A pod in `unfold-staging-workspaces` without `runtimeClassName: gvisor` is refused by `sandboxed-workloads`:

  ```sh
  kubectl -n unfold-staging-workspaces run probe --image=ghcr.io/webgrip/unfold-agent:0.4.0-rc.119@sha256:e11d267c96f9120e6dad657ee1b4a4fd555fd57e0a357cff327f33254ce8f6a2 --dry-run=server
  ```

* A running workspace reports gVisor's kernel: `kubectl -n unfold-staging-workspaces exec <pod> -- dmesg | head -1` starts with "Starting gVisor".
* From outside: `https://staging-app.unfoldhq.dev/` asks for Cloudflare Access; `curl -X POST https://staging-app.unfoldhq.dev/webhooks/tracker/vikunja` answers 401; a port scan of the nodes' public addresses finds nothing open.
* ploegd migrated its database (`kubectl -n unfold-staging logs deploy/ploeg | grep -i migrat`), Unfold answers `/healthz`, and a LiteLLM call is metered against a staging key's budget.

## Not wired yet

* Unfold reads no logs or metrics: the cluster's own VictoriaMetrics and VictoriaLogs (ADR 0016) admit no reader from `unfold-staging` yet.
* LiteLLM reads its configuration once at start. A change to `litellm-config.yaml` needs `kubectl -n litellm-staging rollout restart deploy/litellm`, or a pod template change in the same commit.
* Whether Unfold sets `automountServiceAccountToken: false` on workspace pods is unverified; `sandboxed-workloads` refuses the pod if it does not, and the first workspace shows it.
