---
status: proposed
date: 2026-10-26
---

# ADR 0015: Production stays operable without the homelab

## Context and problem statement

The owner asked for this cluster to stand on its own feet. The
[external dependency inventory](../architecture/external-dependencies.md) lists 45 things outside the
cluster that production leans on; 23 of them are in the homelab. With the homelab down, production
keeps **running**, but nobody can rotate a secret, apply infrastructure, log in except with the
break-glass kubeconfig, receive an alert, add a node or rebuild. With the homelab compromised, the
attacker holds every production credential (OpenBao), every apply (the infra runner), a key Flux trusts
(Forgejo's instance key) and the operator login (Authentik).

That is not a thought experiment. On 2026-10-26 one value an apply should have written to the homelab
OpenBao was missing; the homelab gateway never joined the tailnet, and External Secrets, telemetry and
the CI trigger on this cluster were down together, with no alert, because the alerts also run in the
homelab.

RFC 0001 already designed several pieces of the answer (an OpenBao in the cluster with a static seal,
object storage at two providers, the infra runner moving out of the homelab) and ADR 0014 proposes
Google as the operators' identity provider. This record states the rule they serve, decides what the
RFC left open, and orders the work.

## Decision drivers

* **The rule:** production keeps running *and* stays operable (deploy, rotate, log in, alert, back up,
  reboot or add a node, rebuild) while the homelab is down.
* A homelab compromise must not be able to change production on its own.
* No SaaS in the operations path beyond the providers already trusted: Hetzner, Cloudflare, Google
  Workspace, Let's Encrypt, the public registries.
* Nothing made by hand that a rebuild cannot make again (reproducibility page).
* Money counts: two people, a cluster that costs about €49 a month today.

## Decision

Six parts. Each is proposed; the owner decisions are at the end.

### 1. Production's secrets originate in production

An OpenBao runs in this cluster, as RFC 0001 section 8 designed: integrated Raft storage on Talos user
volumes, one replica while the hub is one node and three when it has three, TLS end to end.

* **Seal.** The static seal. The seal key reaches the control planes as a Talos inline manifest, so it
  lives in the machine config on the STATE partition, which the disk KMS encrypts, and in the encrypted
  OpenTofu state. OpenBao unseals itself on every restart with no service outside the cluster.
  Transit auto-unseal from another OpenBao was weighed and rejected: it adds a runtime dependency to
  every restart, the opposite of the goal. Shamir keys were rejected because a restarted pod would wait
  for a person.
* **The homelab is a separate vault, not a replica.** OpenBao has no replication in its open-source
  edition, so a live replica is not on offer. Provider-issued production values (Hetzner, Robot,
  Cloudflare, model providers) are seeded into production's OpenBao by the owner; the homelab keeps its
  own and staging gets its own keys, as ADR 0007 already does for LiteLLM. Nothing production needs is
  read from the homelab.
* **Backups.** A CronJob takes a Raft snapshot every 6 hours, encrypts it with age to a recipient whose
  identity is only in the offline seed, and writes it with a write-only key to the object storage of
  part 4. A weekly drill restores it into a throwaway OpenBao and reads a canary.
* **The rebuild path.** OpenBao cannot hold the values that build the cluster it runs in. The few values
  an apply needs before OpenBao exists (state keys and passphrase, the Hetzner and Robot tokens, the
  Talos bundle, the disk master keys) are kept as one age-encrypted file, `production-seed.age`,
  encrypted to the owner's YubiKey with an offline copy. `scripts/openbao-kv.sh` gains a read-only file
  backend for it, so a plan and apply run from a laptop when neither the homelab nor the cluster is
  there. A rebuild is then: apply from the seed, restore the newest OpenBao snapshot, and let External
  Secrets bring back everything else.
* **CI reads production's OpenBao** with its Forgejo OIDC token, through a JWT mount that trusts
  Forgejo's published keys. Forgejo stays able to mint those tokens; that is inherent while Forgejo
  runs the workflow, and the role keeps today's bindings (repository, `main`, event, actor) and the
  plan digest.

### 2. Git stays on Forgejo; deploys and applies get paths that skip the homelab

* **Source.** Forgejo stays the source of truth (Unfold ADR-0040). Flux keeps reading the GitHub mirror,
  which keeps working while the homelab is down.
* **Deploy without Forgejo.** An owner-signed commit pushed to the mirror under a temporary ruleset
  bypass deploys; the [break-glass runbook](../runbooks/break-glass.md#the-homelab-is-down) has the
  steps.
* **Deploy without GitHub.** A second GitRepository reads Forgejo with the same signature check and
  applies nothing on its own; it proves the fallback works and shows when the mirror falls behind.
  Break-glass points `flux-system` at Forgejo for one fetch.
* **Apply.** A second runner pool with the `unfold-infra` label runs in this cluster, on trusted nodes
  (the control planes or ADR 0013's system pool, never the CI or metal pools), registered on this
  repository only. The homelab pool keeps the same label and stays the rebuild path. Forgejo hands the
  job to whichever pool asks first; the workflow's `concurrency` group still keeps one writer on the
  state. With the cluster's runner reaching the APIs privately, `ADMIN_CIDRS` no longer needs the
  homelab's address. When Forgejo itself is down, the laptop apply of part 1 is the path.
* CI for other repositories stays on Forgejo and is accepted as down while the homelab is down.

### 3. Operators sign in without the homelab

ADR 0014 as proposed: Kubernetes, Headscale and this cluster's Grafana trust Google Workspace directly.
The admin kubeconfig stays break-glass, age-encrypted to a YubiKey.

### 4. Backups land outside the homelab and outside this Hetzner project

RFC 0001's object storage layout, with one change: the Hetzner buckets live in a **separate Hetzner
project**, so the cluster project's API tokens and a disk image of anything in it reach none of them.

| Data | Primary | Second copy |
| --- | --- | --- |
| etcd snapshots, OpenBao snapshots, CNPG backups | Hetzner Object Storage, Nuremberg, separate project | OVHcloud with a 30-day compliance lock |
| OpenTofu state | OVHcloud | Scaleway |

The clusters hold write-only keys; the accounts that can delete or unlock live with the owner, outside
every cluster, OpenBao and CI (homelab ADR-0081's rule). garage-fsn1 leaves this cluster's backup path.
Restore checks move into the cluster as CronJobs, so they run and alert while the homelab is down.

### 5. The disk KMS stops being a single point of failure

Every encrypted node asks the KMS on `unfold-headscale` for its key at every boot (ADR 0003). One more
KMS removes the single point:

* `kms-server` on a CX23 in a **separate Hetzner project** (the same project as the backup buckets),
  with its own master key, minted like the first one.
* Each node's STATE and EPHEMERAL get a second LUKS key slot sealed by it. Talos adds a slot without a
  wipe, so the rollout is one reviewed plan per node and two reboots.
* Its name lives in a DNS zone **not on Cloudflare** (a zone at Hetzner's free DNS), so a Cloudflare
  outage or a stolen webgrip.dev DNS token cannot stop a reboot or capture the seal of a new node.
* The apply publishes both KMS names itself, with a token scoped to the zone, instead of the homelab
  CronJob that publishes `headscale.webgrip.dev` today.
* Both master keys are in the offline seed. A certificate-expiry alert watches both endpoints.

It also changes ADR 0003's worst case: imaging one KMS server needs that project's token, and slot 1's
key never sits in the cluster's project.

Headscale itself stays single. Once parts 1, 3 and the in-cluster alerting are done, the tailnet
carries only admin convenience and optional telemetry copies to the homelab, and admins have the
public `ADMIN_CIDRS` path when it is down.

### 6. Alerts reach a person without the homelab

The in-cluster Alertmanager (being built) keeps ntfy as its first receiver and gets a second one for
critical alerts outside the homelab: email through Google Workspace's SMTP relay, already a trusted
provider. The dead-man's switch stays outside the cluster and outside the homelab and must notify by
the same email path, not through the homelab's ntfy.

## Cost and order

Each step is its own set of pull requests and can stop after any step. Prices exclude VAT.

| Step | What | €/month added |
| --- | --- | --- |
| 1 | This inventory and its drift check, the break-glass runbook, the two missing seed values, the warm Forgejo source | 0,00 |
| 2 | In-cluster alerting (in flight) with the email receiver; the dead-man's switch on email | 0,00 |
| 3 | Operators on Google (ADR 0014) | 0,00 |
| 4 | Talos discovery off, Hetzner NTP added, the installer pinned by digest (in flight) and mirrored | 0,00 |
| 5 | The second KMS in a separate project, its name off Cloudflare, both keys in the seed | 5,99 |
| 6 | Object storage at Hetzner (separate project) and OVHcloud, state on OVHcloud and Scaleway; garage-fsn1 leaves the path | 10,29 at start, about 17,39 at steady state |
| 7 | Production OpenBao with the static seal, its snapshots and drill; External Secrets switches store; the gateway's 8200 retires | 0,00 |
| 8 | The `unfold-infra` runner pool in the cluster; `ADMIN_CIDRS` shrinks | 0,00 |
| 9 | `production-seed.age` and the laptop apply | 0,00 |
| 10 | The boot images in the Talos image cache; Zot keeps every pinned digest and mirrors `code.forgejo.org` | 1,00 |
| | **Total** | **17,28 at start (20,91 with VAT), about 24,38 at steady state** |

Step 7 needs step 6 for its snapshots; steps 8 and 9 need step 7. The OpenBao replicas fit the
hub and system-pool memory the capacity page already plans; they add no node.

## Consequences

Good:

* With the homelab down, every capability in the rule works: deploys (signed push), rotation
  (production OpenBao), applies (the cluster's runner, or the laptop), login (Google), alerts (email),
  backups and their checks (two providers, in-cluster drills), reboots (two KMS servers), rebuild (seed
  plus snapshot).
* A homelab compromise no longer reads production secrets, runs applies with Hetzner tokens, or issues
  operator sessions. What remains is Forgejo: its instance key (owner decision D6) and its OIDC tokens
  for the infra workflow.
* About €17 a month, under the price of one more CX33 hub node.

Bad, accepted:

* A second secret store to run, back up and drill, and a split seeding routine: production values are
  put into production's OpenBao, over the tailnet.
* The seed file is a second copy of the most sensitive values, held by the owner. The YubiKey and the
  offline copy are its controls.
* Three more providers in the backup path (Hetzner Object Storage, OVHcloud, Scaleway) and one more
  small server to patch.
* CI for every other repository still stops with the homelab.

## Confirmation

A **homelab-off drill**, run before this record is accepted and then every quarter: the homelab gateway
scaled to zero and Forgejo, Authentik and ntfy unreachable from this cluster, then, each with its
evidence:

1. A secret is rotated in production's OpenBao and reaches its pod.
2. A person signs in with `kubectl` through Google, and Grafana opens.
3. A test alert arrives by email, and the dead-man's switch fires when the Watchdog is silenced.
4. An etcd and an OpenBao snapshot are written to both providers and their restore checks pass in the
   cluster.
5. One node reboots while the first KMS is stopped and unlocks through the second.
6. A laptop plan from `production-seed.age` shows no changes.
7. An owner-signed commit pushed to the GitHub mirror is applied by Flux.

`scripts/check-external-dependencies.sh` fails any pull request that adds an external host without a row
in the inventory, and its test proves it fails on each kind of host and passes on the repository as it is.

## Owner decisions

* **D1.** Production OpenBao in the cluster with the static seal (recommended), or keep the homelab
  OpenBao as the only original and accept that rotation and rebuilds stop with the homelab.
* **D2.** Buy the second KMS server, a CX23 in a separate Hetzner project at €5,99 a month
  (recommended), or accept that every reboot depends on one server.
* **D3.** Object storage at Hetzner (separate project) and OVHcloud, about €10 a month at start
  (recommended), now rather than at RFC 0001 step 3's later date; and whether that project sits in a
  separate Hetzner account.
* **D4.** The second alert receiver: email through Google Workspace's SMTP relay (recommended), or a
  self-hosted ntfy on the second KMS server.
* **D5.** Run the `unfold-infra` runner pool in this cluster, which puts the Hetzner tokens and the state
  passphrase on its control planes or system pool during a run (recommended; the cluster's own Hetzner
  token is already there), or keep applies homelab-only.
* **D6.** Keep trusting Forgejo's instance key (the 2026-10-25 decision), or trust only owner-held
  signing keys, which closes the last homelab-to-production write path at the cost of merging with a
  local signed merge.
* **D7.** Keep `production-seed.age` encrypted to a YubiKey with an offline copy (recommended), which
  makes a rebuild without the homelab possible and a rebuild always a deliberate act of the owner.
