# Unfold staging

Unfold staging runs in this cluster at `https://staging-app.unfoldhq.dev`, public through a Cloudflare Tunnel, with its agents under gVisor on the hub node. The decision and its accepted risks are [ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md). Everything is in `kubernetes/apps/unfold-staging/`.

## What runs where

| Namespace | What | Placement |
| --- | --- | --- |
| `unfold-staging` | The `unfold` HelmRelease (`oci://ghcr.io/unfold-hq/charts/unfold`, pinned by digest; it pins `ghcr.io/unfold-hq/unfold`, `ghcr.io/unfold-hq/unfold-agent` and the Ploeg chart it was tested with by digest, [image signatures](image-signatures.md#keyless-unfold-hq-releases)): the Unfold workbench and ploegd, with Ploeg's executor off; `ploeg-db` (CNPG, one instance, database `app`, owner `ploeg`); `authentik-relay` | hub (`node.webgrip.io/pool=unfold`) |
| `unfold-staging-workspaces` | Unfold's agent workspaces, one pod each, `runtimeClassName: gvisor`; labelled `ploeg.webgrip.dev/isolation-class: hardened`, so `sandboxed-workloads` refuses any pod without gVisor and with a mounted token | hub, through the `gvisor` RuntimeClass |
| `unfold-staging-workers` | Ploeg's worker CronJobs (`executor.namespace`), `runtimeClassName: gvisor`, labelled `ploeg.webgrip.dev/isolation-class: hardened` | hub, through the `gvisor` RuntimeClass |
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
- **Unstick a release whose rollback failed too.** When an upgrade fails and the rollback to the previous release fails as well, for example because the same pull request removed a Secret the old release needs, helm-controller keeps retrying that rollback and never the upgrade, even after the cause is gone. Operators may not patch the HelmRelease, so set a new value in both `reconcile.fluxcd.io/requestedAt` and `reconcile.fluxcd.io/forceAt` on it in `helmrelease.yaml`, in a pull request: Flux then runs the upgrade once more. On 2026-11-18 the move to ClickUp needed this, because its Secrets were seeded after the merge that removed Vikunja's.

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

### What is connected to what

| | Value |
| --- | --- |
| ClickUp Workspace | WebGrip, `1500520000009653` |
| List | Unfold › Engineering › [Staging fixture](https://app.clickup.com/1500520000009653/v/l/li/1500520000176822) (`1500520000176822`), test work for `webgrip/ploeg-bench-world` only |
| Bot | the Workspace member *Unfold*, `ryan+unfold-agent@webgrip.nl` (user `105726150`, `UNFOLD_STAGING_CLICKUP_AGENT` in `ks.yaml`) |
| The bot's token, original | homelab OpenBao `secret/clickup/ploeg`, field `api_token`, written by `just clickup-token` in homelab-cluster |
| The bot's token, staging's copy | the same OpenBao, `secret/unfold-main/staging/clickup`, field `api-token` |
| Read by | ExternalSecret `clickup-bot` in `unfold-staging` on this cluster, for Unfold (`UNFOLD_TASK_CLICKUP_TOKEN`), ploegd (`PLOEG_CLICKUP_TOKEN`) and the webhook job |
| Webhook | `https://staging-app.unfoldhq.dev/webhooks/tracker/clickup`, on the List only, registered and kept by the CronJob `clickup-webhook` in `unfold-staging` |

The same bot works two environments, each on its own Lists:

| Environment | Cluster | Lists its ploegd dispatches from |
| --- | --- | --- |
| Homelab Unfold and Ploeg | homelab-cluster | Unfold › Agency integrations, Agency pilot, Hosted billing |
| Unfold staging | this cluster | Unfold › Engineering › Staging fixture |
| Production | not built yet | |

A task assigned to the bot starts work only in the environment whose Lists hold it, so never add *Staging fixture* to the homelab's routing or a homelab List here: both would dispatch the same task ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md#r1-double-dispatch)). The bot's token can still write every List the bot is a member of, the homelab's included; a staging bot of its own can follow once Ploeg registers ClickUp webhooks itself ([the Ploeg ticket](https://app.clickup.com/t/1ampw4tmy1p)).

The List replaced the homelab Vikunja project *Fixture · Ploeg Staging* on 2026-11-18.

### How work flows

Unfold reads the List as its task source and hands a task to Ploeg by assigning the bot. ploegd dispatches on that assignment only (`trackers.clickup.agents`), so a person assigning themselves starts nothing. It moves the task to `in progress` when a Shift opens, `in review` when a pull request waits, `needs you` when a person must decide and `done` when the work is finished; `backlog` and `ready` stay a person's. A ClickUp Work Item's branch is `agent/CU-<task id>`. Both reach `api.clickup.com` directly over HTTPS by name ([Network](#network)).

### Setting it up

Once per cluster, or after the bot's token changed. Everything else is automatic.

**Before you start.** Tailscale is connected and `tailscale ping 100.64.0.6` answers `pong`: the homelab gateway, which carries OpenBao on 8200 to this repository's tools. Turn off OpenVPN Connect or any other VPN on a Mac: it keeps Tailscale from reaching its relay, and Tailscale then shows connected but answers no ping ([Headscale browser login](headscale-browser-login.md)). Authentik is public ([homelab ADR-0092](https://forgejo.webgrip.dev/webgrip/homelab-cluster/src/branch/main/docs/techdocs/docs/adr/adr-0092-authentik-sign-in-is-public-through-the-tunnel.md)), so no VPN to the homelab LAN is needed.

From a checkout of this repository, on `main`:

```sh
BAO_ADDR=http://unfold-gateway.webgrip.dev:8200 bao login -method=oidc
```

Signs you in to the homelab OpenBao through Authentik (Google, then your security key) and caches the token in `~/.vault-token`. Now `bao` and wellhead may read and write `secret/unfold-main/*`.

```sh
BAO_ADDR=http://unfold-gateway.webgrip.dev:8200 bao kv get -field=api_token secret/clickup/ploeg | pbcopy
```

Copies the bot's token from the homelab's path to the clipboard without printing it.

```sh
mise run wellhead -- seed unfold-staging/clickup-bot
```

Shows where the value comes from, asks for it without echo (paste, Enter), checks it against ClickUp's `GET /api/v2/user`, writes it to `secret/unfold-main/staging/clickup` (`api-token`) and makes External Secrets sync `clickup-bot` at once. It signs in to this cluster through kubelogin, which may open the browser once more. Clear the clipboard afterwards.

**What you have then.** The Secret `clickup-bot` exists in `unfold-staging`. Within 10 minutes the CronJob `clickup-webhook` registers the webhook on the List, stores the secret ClickUp returns in the Secret `clickup-webhook` and restarts ploegd, which then starts with the token and the webhook secret. Staging takes work from *Staging fixture*.

**The webhook** needs nothing after that. Every 10 minutes the job checks it: when the Secret `clickup-webhook` names no webhook ClickUp still has, it deletes the bot's other webhooks to the same endpoint, registers a new one and restarts ploegd; a webhook ClickUp suspended after failed deliveries is reactivated. The secret never leaves the cluster, so a rebuilt cluster registers a new webhook by itself.

**Check.**

* `kubectl -n unfold-staging get externalsecret clickup-bot` is `SecretSynced`.
* `kubectl -n unfold-staging logs job/<latest clickup-webhook job>` names the webhook it registered or keeps.
* `kubectl get --raw /api/v1/namespaces/unfold-staging/services/ploeg:8080/proxy/readyz` counts the webhook under `clickupWebhooks`.
* Assign the bot on a task in *Staging fixture*: the task moves to `in progress` and its Work Item appears in Unfold.

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

The executor (`ploeg.executor`) is type `cronjob`, so each Team's Roles poll for work every two minutes and KEDA plays no part; team `staging` with a builder and a reviewer on `webgrip/ploeg-bench-world`, branch `staging/smoke`; `runtimeClassName: gvisor`, both credential proxies, and `security.workerAdmission` admitting only `gvisor`.

The workers render into their own namespace, `unfold-staging-workers` (`executor.namespace`), labelled `ploeg.webgrip.dev/isolation-class: hardened`, so `sandboxed-workloads` refuses a worker without gVisor or with a mounted token. ploegd and its Secrets stay in `unfold-staging`. The Flux Kustomization `unfold-staging-workers` (`kubernetes/apps/unfold-staging/workers/`) gives the namespace what its pods read:

| Secret | From |
| --- | --- |
| `agent-builder-token`, `agent-reader-token` | OpenBao `unfold-main/staging/forgejo`, like their copies in `unfold-staging` |
| `ploeg-worker-bootstrap` (`staging--builder`, `staging--reviewer`) | the `registry.json` of `unfold-staging`'s `ploeg-worker-bootstrap`, read through the SecretStore `unfold-staging` as `ploeg-bootstrap-reader`, which may get that one Secret |

The chart's worker NetworkPolicy reaches ploegd, staging's LiteLLM and DNS; the CiliumNetworkPolicy `ploeg-worker` there adds Forgejo by name. The chart's DNS rule has no name filter, so the workers' lookups are not narrowed the way the workspaces' are; that needs an option in Ploeg's chart.

A post-renderer on the HelmRelease gives each worker CronJob's `worker-bin` volume a 256Mi `sizeLimit`, which `resource-limits` demands and Ploeg's chart does not set; its `test` step fails the release if the chart moves that volume.

Ploeg finds pull request merges by itself every 10 minutes, so staging needs no Forgejo webhook.

The executor is off again since 2026-11-18. Its first worker pods were admitted and pulled `ghcr.io/ploeg-hq/agent-runner` (Ploeg ADR-0200), but every worker stopped after two minutes with `no harness launcher connected to /run/ploeg/launcher/launcher.sock`: under gVisor the Unix socket the harness container creates in the shared `harness-launcher` volume does not reach the worker container, so no Run could start. Ploeg is moving that connection from the socket to TCP on the pod's loopback, which works under gVisor, Kata and runc alike; once a Ploeg release carries it, turn the executor on again with that release's agent image by digest in `executor.runnerImage`. The admission policy `pinned-approved-images` already admits the image.

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
