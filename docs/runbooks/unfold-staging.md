# Unfold staging

Unfold staging runs in this cluster at `https://staging-app.unfoldhq.dev`, public through a Cloudflare Tunnel, with its agents under gVisor on the hub node. The decision and its accepted risks are [ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md). Everything is in `kubernetes/apps/unfold-staging/`.

## What runs where

| Namespace | What | Placement |
| --- | --- | --- |
| `unfold-staging` | The `unfold` HelmRelease (`oci://ghcr.io/unfold-hq/charts/unfold`, pinned by digest; it pins `ghcr.io/unfold-hq/unfold`, `ghcr.io/unfold-hq/unfold-agent` and the Ploeg chart it was tested with by digest, [image signatures](image-signatures.md#keyless-unfold-hq-releases)): the Unfold workbench and ploegd, with Ploeg's executor off; `ploeg-db` (CNPG, one instance, database `app`, owner `ploeg`); `authentik-relay` | hub (`node.webgrip.io/pool=unfold`) |
| `unfold-staging-workspaces` | Unfold's agent workspaces, one pod each, `runtimeClassName: gvisor`; labelled `ploeg.webgrip.dev/isolation-class: hardened`, so `sandboxed-workloads` refuses any pod without gVisor and with a mounted token | hub, through the `gvisor` RuntimeClass |
| `litellm-staging` | LiteLLM (`ghcr.io/berriai/litellm-non_root`, app-template chart) with staging's own provider keys and budgets; `litellm-db` (CNPG) | hub |
| `unfold-staging-edge` | `cloudflared`, two replicas, the tunnel connector | hub |

Flux applies them in this order: `unfold-staging-namespaces`, then `unfold-staging-ploeg-db` and `litellm-staging-db` (after `plugin-barman-cloud`), `unfold-staging-workspaces`, `litellm-staging`, `unfold-staging` and `unfold-staging-edge` (after `external-secrets-stores`). The databases have no backup: the backup component waits for the object storage bucket ([postgres databases](postgres-databases.md#backups-built-off-until-the-bucket-exists)).

A `LimitRange` in `unfold-staging` and in `unfold-staging-workspaces` gives every container without one an ephemeral-storage limit, because Unfold creates workspace pods without one and `resource-limits` refuses those.

### Substitutions

The `unfold-staging` Flux Kustomization sets these variables in `kubernetes/apps/unfold-staging/ks.yaml`:

| Variable | Value | Used for |
| --- | --- | --- |
| `UNFOLD_STAGING_HOSTNAME` | `staging-app.unfoldhq.dev` | Unfold's `baseUrl` and the ClickUp webhook ploegd looks for |
| `UNFOLD_STAGING_CLICKUP_WORKSPACE_ID` | `'"1500520000009653"'` | the ClickUp Workspace whose webhooks ploegd checks |
| `UNFOLD_STAGING_CLICKUP_LIST_ID` | `'"1500520000176822"'`, the List *Staging fixture* (Unfold › Engineering) | Unfold's task source and ploegd's board |
| `UNFOLD_STAGING_CLICKUP_AGENT` | `ryan+unfold-agent@webgrip.nl`, the Ploeg bot | the only assignee that dispatches, and the `staging` Team's tracker user |

The ids keep their double quotes inside the single quotes (`'"123"'`). Flux substitutes into YAML text, and a bare `123` would reach Unfold and ploegd as a number.

## How a release reaches staging

Every `unfold-v0.x.y-rc.N` release the `unfold-hq/unfold` release train publishes reaches staging through Flux, without a pull request or a person. The owner decided this on 2026-11-17 ("flux overal", the same way the homelab follows them); production stays a manual bump (Unfold ADR-0040). Who can now change staging is in [identity-and-access](../architecture/identity-and-access.md#2026-11-17-flux-follows-unfold-release-candidates-to-staging), and the decision in [ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md#history).

1. The release workflow pushes the chart `ghcr.io/unfold-hq/charts/unfold:0.x.y-rc.N` and signs it keyless with cosign. The chart pins the Unfold image, the agent image and the Ploeg chart by digest, so the chart version is the whole release.
2. Every 3 minutes, source-controller lists the chart's tags anonymously (`kubernetes/apps/unfold-staging/unfold/ocirepository.yaml`). `ref.semver` picks the highest version, and `ref.semverFilter` admits only `0.x.y-rc.N`: a per-architecture tag such as `0.4.0-rc.136-amd64`, a stable `0.x.y` or a `1.x` never becomes staging's release.
3. Before it stores the chart, source-controller verifies its signature: the certificate must come from GitHub Actions (`token.actions.githubusercontent.com`) for `unfold-hq/unfold`'s `on_release_published.yml` at a tag `unfold-v0.x.y-rc.N`. An unsigned chart or one signed by anything else leaves the OCIRepository not Ready on `VerificationError`, staging stays on the release it runs, and `UnfoldFluxReconcileFailing` fires after 15 minutes.
4. A new chart revision makes the HelmRelease upgrade (`timeout: 15m`), then run the chart's Helm tests (`test.enable`; the chart has none yet, see [staging rollouts](staging-rollouts.md#smoke-test)). An upgrade or test that fails, for example on a Secret the release needs and `unfold/secrets.yaml` does not yet hold, is retried three times and rolled back to the previous release (`upgrade.remediation`); `UnfoldStagingRolloutLagging` and `UnfoldFluxReconcileFailing` fire.

[Staging rollouts](staging-rollouts.md) says which ntfy messages tell you it went well and how to check a rollout by hand.

Nothing renders a candidate with staging's values before it is installed: a release that needs a value staging does not give it, renames one or changes its type fails at step 4 and is rolled back. Read the release notes, then change `helmrelease.yaml` in a pull request; Flux upgrades again on merge.

- **Hold staging on a release, or skip a bad one:** exclude it in the range, `semver: ">=0.0.0-0 <1.0.0-0, !=0.4.0-rc.137"`, in a pull request. The next candidate is picked up as usual.
- **Stop following candidates:** replace `ref.semver` and `ref.semverFilter` with `ref.tag` and `ref.digest` of the release to keep (the `ref` of the OCIRepository is the pin; keep `verify`).
- **Pick up a candidate at once:** `flux -n unfold-staging reconcile source oci unfold`.

## Secrets the owner seeds

Every value lives in the homelab OpenBao; External Secrets reads it through `openbao-homelab`. Seed them from a homelab-cluster checkout with `just secret-set <path> <key>`: it logs in to OpenBao if needed, asks for the value without echoing it, keeps the other keys at the path and leaves nothing in shell history.

```sh
just secret-set unfold-main/staging/litellm fireworks-api-key
just secret-set unfold-main/staging/litellm hetzner-inference-api-key
```

Or `mise run wellhead -- seed litellm-staging/litellm-secret`,
which also checks the Fireworks key against its API before writing ([External Secrets](external-secrets.md#every-externalsecret-says-where-its-value-comes-from)).

| Key | Value |
| --- | --- |
| `fireworks-api-key`, `hetzner-inference-api-key` | staging keys from each provider, with a monthly cap |

`unfold-main/staging/forgejo` (`builder-token`, `reader-token`) is pushed by the homelab: its provisioner Jobs mint the `agent-builder` and `agent-reviewer` tokens and the PushSecrets `unfold-staging-agent-builder-token` and `unfold-staging-agent-reviewer-token` (homelab-cluster `kubernetes/apps/forgejo/forgejo-actions-secrets/app/`) copy them there. They are the homelab's own tokens, so they can write every repository the `agents` team can; ploegd does not start without them, even with the executor off.

The tunnel token is written by the `infra` apply that declares the tunnel, not by hand; until it exists `cloudflared` does not start. OpenBao's role `unfold-main-external-secrets` must allow `secret/unfold-main/staging/*`; it already allows `secret/unfold-main/*`.

Generated in the cluster, never in OpenBao (External Secrets `Password` generators, `refreshInterval: "0"`): `litellm-generated` in `litellm-staging` (`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`; the executor reads the master key from there through the `litellm-staging` SecretStore, whose service account may get that one Secret and nothing else, and for which External Secrets may mint a token through `external-secrets-litellm-master-reader-token`), and `unfold-credentials` (`PLOEG_OPERATOR_UNFOLD_TOKEN`, the token Unfold presents to ploegd, and `UNFOLD_ADMIN_PASSWORD`, the first administrator's password, unused while local sign-in is off). Reading it takes the break-glass kubeconfig, because `unfold-admins` may not read Secrets ([kubernetes-login](kubernetes-login.md#who-may-do-what)): `kubectl -n unfold-staging get secret unfold-credentials -o jsonpath='{.data.UNFOLD_ADMIN_PASSWORD}' | base64 -d`. People sign in through Authentik instead ([Sign-in](#sign-in)). The store key that encrypts Unfold's stored links and credentials is the file the workbench writes next to its database on the encrypted `unfold-data` volume.

## Sign-in

Until the identity broker of Unfold's ADR-0058 runs, people sign in to staging with the homelab Authentik, as on production Unfold. The client is `unfold-staging`, public with PKCE, made by the homelab access plane (homelab-cluster `kubernetes/apps/security/access-plane/tofu/broker/applications.tf`) and open to the `unfold-admin` capability. Unfold's `config.auth.oidc` in `kubernetes/apps/unfold-staging/unfold/helmrelease.yaml` makes `unfold-app-admins` an admin. There is no client secret.

Authentik answers on the homelab LAN only, so the sign-in works from a browser on the LAN or the tailnet, after Cloudflare Access. The workbench makes its code and refresh-token exchanges through `authentik-relay`, an Envoy CONNECT proxy that forwards `authentik.webgrip.dev:443` and nothing else to the homelab gateway's 443, the same path [the ops consoles](ops-consoles.md#how-the-logins-reach-authentik) take through their own relay. Local sign-in is off (`auth.localLogin: false`) since 2026-11-17, after the owner signed in through Authentik; only `unfold-app-admins` can sign in at all, so that sign-in was an admin's. Unfold offers only Homelab login, refuses `POST /api/login` and creates no administrator from `UNFOLD_ADMIN_PASSWORD`. Off the LAN and the tailnet nobody can sign in to staging until the broker runs. To get a password sign-in back, set `auth.localLogin: true` in a pull request.

## ClickUp

Staging's board is the ClickUp List [Staging fixture](https://app.clickup.com/1500520000009653/v/l/li/1500520000176822) in the Unfold space, under Engineering. It holds test work for `webgrip/ploeg-bench-world` only. Never point staging at a List another ploegd watches: both would dispatch the same task ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md#r1-double-dispatch)). It replaced the homelab Vikunja project *Fixture · Ploeg Staging* on 2026-11-18, so staging no longer depends on the homelab for its work.

Unfold reads the List as its task source and hands a task to Ploeg by assigning the bot member. ploegd dispatches on that assignment only (`trackers.clickup.agents`), so a person assigning themselves starts nothing. It moves the task to `in progress` when a Shift opens, `in review` when a pull request waits, `needs you` when a person must decide and `done` when the work is finished; `backlog` and `ready` stay a person's. A ClickUp Work Item's branch is `agent/CU-<task id>`.

Both reach `api.clickup.com` directly over HTTPS by name ([Network](#network)); nothing goes through the homelab.

### Setting it up

Staging acts as the Ploeg bot that also works the homelab's Lists, the member *Unfold* (`ryan+unfold-agent@webgrip.nl`, `UNFOLD_STAGING_CLICKUP_AGENT`). Its token reaches every List the bot is on; only *Staging fixture* dispatches on staging. Everything below happens in this repository and this cluster.

1. **The token**, once. Seed the bot's personal API token from this repository:

   ```sh
   mise run wellhead -- seed unfold-staging/clickup-bot
   ```

   wellhead asks for it without echoing, checks it against `GET /api/v2/user` and writes it to `secret/unfold-main/staging/clickup` (`api-token`). `clickup-bot` gives it to Unfold (`UNFOLD_TASK_CLICKUP_TOKEN`), ploegd (`PLOEG_CLICKUP_TOKEN`) and the webhook job.
2. **The webhook** needs nothing. The CronJob `clickup-webhook` (`unfold/clickup-webhook/`) runs every 10 minutes with the bot's token. When the Secret `clickup-webhook` names no webhook ClickUp still has, it deletes the bot's other webhooks to the same endpoint, registers a new one on the List, stores the secret ClickUp returns in that Secret (`PLOEG_CLICKUP_SECRET`, `webhook-id`) and restarts ploegd so it reads it. A webhook ClickUp suspended after failed deliveries is reactivated. The secret never leaves the cluster, so a rebuilt cluster registers a new webhook by itself. ploegd does not start before the job's first run has written the Secret.
3. **Check.** `kubectl -n unfold-staging logs job/<latest clickup-webhook job>` says which webhook it keeps or registered. ploegd checks the webhook at start and hourly and reports the count under `clickupWebhooks` in `/readyz`: `kubectl get --raw /api/v1/namespaces/unfold-staging/services/ploeg:8080/proxy/readyz`. Then assign the bot on a task in the List: the task moves to `in progress` and its Work Item appears in Unfold.

Once Ploeg registers ClickUp webhooks itself ([the Ploeg ticket](https://app.clickup.com/t/1ampw4tmy1p)), the job goes.

## Network

Every namespace starts from the cluster's default deny ([egress by name](egress-by-name.md)). The policies are in each directory's `networkpolicy.yaml` or `cloudflared.yaml`.

| From | To | Port | Why |
| --- | --- | --- | --- |
| `cloudflared` | Cloudflare's tunnel edge (`*.v2.argotunnel.com`), `api.cloudflare.com` | 7844 UDP and TCP, 443 | the tunnel |
| `cloudflared` | Unfold | 4080 | every path but `/webhooks/` |
| `cloudflared` | ploegd | 8080, **`POST /webhooks/.*` only** (Cilium's L7 rule) | tracker and forge webhooks |
| Unfold | ploegd 8080, LiteLLM 4000, the Kubernetes API, `authentik-relay` 3128, `forgejo.webgrip.dev` 443, `api.clickup.com` 443 | | the workbench creates workspace pods, reads the repositories and the board, and signs people in |
| ploegd | `ploeg-db` 5432, LiteLLM 4000, `forgejo.webgrip.dev` 443, `api.clickup.com` 443 | | the chart's own NetworkPolicy plus `ploegd` |
| `authentik-relay` | `unfold-gateway.webgrip.dev` | 443 | the homelab gateway, `tag:hub` only on the tailnet; it forwards `authentik.webgrip.dev` |
| `clickup-webhook` job | the Kubernetes API, `api.clickup.com` 443 | | registers staging's ClickUp webhook and stores its secret |
| LiteLLM | `litellm-db` 5432, `api.fireworks.ai` 443, `inference.hetzner.com` 443 | | models |
| a workspace | Unfold 4080, LiteLLM 4000, `forgejo.webgrip.dev` 443 | | nothing else |

The workspace namespace is left out of the cluster's `default-dns`; its own policy answers only names under `cluster.local` and `forgejo.webgrip.dev`, so an agent cannot carry data out in DNS lookups. `unfold-staging` still has `default-dns`, which matters once Ploeg's workers run there (below).

Ploeg's chart renders its own default-deny NetworkPolicies, which profile P1 requires. Its forge and tracker peers point at a label no pod carries (`ploeg.webgrip.dev/egress: cilium-fqdn`), so the chart never opens `0.0.0.0/0`; the Cilium policies add Forgejo and ClickUp by name.

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
  kubectl -n unfold-staging-workspaces run probe --image=ghcr.io/unfold-hq/unfold-agent:0.4.0-rc.132@sha256:7c8bb8f4028a0648b8c8805546736939044aa8a1a484b760c29c6fedb4a88b24 --dry-run=server
  ```

* A running workspace reports gVisor's kernel: `kubectl -n unfold-staging-workspaces exec <pod> -- dmesg | head -1` starts with "Starting gVisor".
* From outside: `https://staging-app.unfoldhq.dev/` asks for Cloudflare Access; `curl -X POST https://staging-app.unfoldhq.dev/webhooks/tracker/clickup` answers 401; a port scan of the nodes' public addresses finds nothing open.
* ploegd migrated its database (`kubectl -n unfold-staging logs deploy/ploeg | grep -i migrat`), Unfold answers `/healthz`, and a LiteLLM call is metered against a staging key's budget.

## Not wired yet

* Unfold reads no logs or metrics: the cluster's own VictoriaMetrics and VictoriaLogs (ADR 0016) admit no reader from `unfold-staging` yet.
* LiteLLM reads its configuration once at start. A change to `litellm-config.yaml` needs `kubectl -n litellm-staging rollout restart deploy/litellm`, or a pod template change in the same commit.
* Whether Unfold sets `automountServiceAccountToken: false` on workspace pods is unverified; `sandboxed-workloads` refuses the pod if it does not, and the first workspace shows it.
