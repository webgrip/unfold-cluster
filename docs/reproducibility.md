# Reproducibility: rebuilding the estate from git and OpenBao

The goal: from an empty Hetzner project, the whole Unfold estate comes back from two git repositories and the values in the homelab OpenBao, with the `infra` workflow's buttons as the only action. Nobody runs a command or clicks a setting except to put a provider-issued value into OpenBao once. The running estate must equal what such a rebuild gives, so nothing on it may exist only because someone made it by hand.

This page is the inventory behind that claim, the minimal seed list, the rebuild procedure, and how each part is proven. The [bootstrap checklist](bootstrap-checklist.md) is the first-time procedure; this page is what keeps it true afterwards. (The estate lives in Hetzner's EU regions and the owner is in the Netherlands, which is why the provider and the off-site Garage are where they are; nothing below depends on that.)

## Where everything lives

| Holder | What | Changed by |
| --- | --- | --- |
| git, `webgrip/unfold-cluster` | every Hetzner resource, the Talos machine configs, the Headscale server and its program, policy and settings, the seed Talos installs, everything Flux runs, the trusted signers, the workflows and the drill | a merged pull request |
| git, `webgrip/homelab-cluster` | the OpenBao roles and policies (`kubernetes/apps/security/openbao/bootstrap/`), the `unfold-infra` runner, the variables bridge, the Forgejo repository settings and branch protection (`repo-config`), the homelab gateway, the DNS records of `headscale` and `unfold-gateway`, the Authentik OIDC client, the Unfold alert rules | a commit on `main` |
| OpenBao, provided once | the Hetzner tokens, the Garage keys, the state passphrase, the age key, `ADMIN_CIDRS`, `ADMIN_SSH_PUBLIC_KEY` | the owner, `just secret-set` |
| OpenBao, written by the apply | the Talos secrets bundle, the Headscale address, the homelab gateway's tailnet key | every `infra` apply |
| made by the apply, nowhere else | the Talos snapshot, the tailnet pre-auth keys, the Headscale server's SSH keys, the cluster's certificates (from the escrowed secrets), the Zot push credentials | the run that needs them |

## Inventory

Every piece of state the estate depends on, how it came to exist, and what happens to it in a rebuild. "Yes" in the third column means a rebuild produces it without anyone acting.

| Item | Created today by | Reproducible | Fix |
| --- | --- | --- | --- |
| Hetzner project | the owner, in the Console | no: Hetzner has no API to create one | seed, once per project (A1) |
| Hetzner API tokens (`unfold-tofu`, `unfold-cluster`, `unfold-vip`) | the owner, in the Console | no: tokens are issued only in the Console | seed into OpenBao (A2); everything after reads them per run |
| Network, subnet, firewalls, placement group, SSH key, servers | OpenTofu | yes | |
| Talos snapshot | `scripts/build-talos-snapshot.sh` in the apply run | yes: built when no snapshot carries the pinned labels | |
| Talos secrets (cluster CAs, service-account key, etcd CA) | OpenTofu, in the encrypted state; formerly also a manual export to the password manager | **now yes** | every apply escrows the bundle to `secret/unfold-cluster/talos-secrets`; an apply into an empty state imports it (`talos_secrets_import_file`), so the cluster keeps its identity. The homelab OpenBao's `jwt-unfold-main` key and `access/unfold-oidc.kubeconfig.yaml` stay valid |
| etcd bootstrap of a cluster rebuilt with a surviving state | nothing: `talos_machine_bootstrap` is a no-op on update | **now yes** | the bootstrap is replaced when the Cloud Network is new (`replace_triggered_by = [hcloud_network.cluster.id]`), and each machine config apply when its server is new |
| Headscale server | OpenTofu with cloud-init | yes | |
| Headscale database: nodes, preauth keys | Headscale, on the server's disk | **now yes, by re-joining, not by restore** | a new server mints new keys in the same apply; every node and the gateway log in again on their own (below) |
| Headscale policy | cloud-init, then `policy set` pushed by the apply | yes | |
| `unfold-tailnet-key` and its sudoers rule on the live server | cloud-init of 2026-10-24, an older version | **was no**: needed `install-headscale-key-tool.sh` by hand | `headscale_generation` 3 replaces the server in one apply; the script is deleted ([below](#the-live-headscale-server)) |
| Delete protection blocking a Headscale replacement | Hetzner refuses; the provider does not lift it | **now yes** | `scripts/lift-headscale-protection.sh` lifts it between the digest check and the apply, only when the reviewed plan deletes `unfold-headscale` |
| Admin devices on the tailnet | the owner, `tailscale up` and `headscale nodes register` | no: a person's device | re-register after a Headscale rebuild; Headscale OIDC through Authentik would make it a browser login (open) |
| DNS `headscale.webgrip.dev` | a DNSEndpoint in homelab git with the IP typed in | **was no** in a new project, whose primary IP differs | the apply writes the IP to `secret/unfold/headscale-address`; the homelab CronJob `network/unfold-headscale-address` publishes it; cloud-init waits for the name to resolve before Headscale asks Let's Encrypt |
| DNS `unfold-gateway.webgrip.dev` | homelab CronJob from the gateway's tailnet state | yes | |
| Homelab gateway's tailnet identity | the gateway, from the key the apply hands it | **now yes** | the old instruction to delete its state Secret after a Headscale rebuild is gone: `TS_AUTH_ONCE` logs it in with the new key, and its ExternalSecret refreshes every 5 minutes |
| GitHub mirror `webgrip/unfold-cluster` and its ruleset `main: no rollback` | hand: `forgejo-sync.sh mirror` and the GitHub UI (ruleset 25791226, 2026-10-24) | **no** | open: a provisioner like homelab's `glide-distribution-bootstrap` (SSH deploy key instead of an expiring token) plus the ruleset in the repo-config model, once the `webgrip` GitHub App exists. Not part of a Hetzner rebuild: GitHub keeps it |
| Forgejo repository settings and branch protection | homelab `repo-config` (tofu-controller) | yes | |
| Forgejo instance signing key (trusted signer) | homelab, from OpenBao through External Secrets | yes | |
| Trusted signers | git, `kubernetes/clusters/main/flux-system/trusted-signers/` | yes | |
| Values in OpenBao | the owner, `bao kv put` / `just secret-set` | provided values: no; written values: yes | see the seed list |
| Forgejo Actions variables | homelab CronJob `forgejo-actions-secrets` from `secret/unfold-cluster/vars` | yes | |
| `unfold-infra` runner | homelab git | yes | |
| OpenBao JWT mount `jwt-unfold-main`, roles, policies | homelab `config.sh` from git | yes, with a fixed service-account key, which the escrow now keeps | |
| OpenBao role `ci-unfold-cluster` and policy | homelab git | yes | extended for the escrow, the address and the drill token |
| Authentik OIDC client for the Kubernetes login | homelab access-plane model | yes | |
| Garage buckets and keys (`unfold-cluster-tfstate`, `unfold-cluster-etcd`) | the owner, on `garage-fsn1` | no: a hand-run box without a controller | seed, once; RFC 0001 moves them to providers with an API |
| etcd bucket lifecycle rule (30 days) | the owner, an S3 call on `garage-fsn1` | **now yes** | every apply puts it (`scripts/set-etcd-backup-lifecycle.sh`) |
| Secrets `kube-system/hcloud`, `etcd-backup/etcd-backup` | Talos seed, then OpenTofu | yes | |
| Zot push credentials | an in-cluster Job | yes (a new value per cluster; only in-cluster consumers) | |
| Cilium, Flux, cloud controller, CSI, policies, workloads | Talos seed, then Flux | yes | |
| etcd contents | etcd, backed up every 6 hours | from the backup only | restoring a snapshot is a separate runbook; everything Flux and External Secrets own comes back without it |

## Minimal seed list

What a person still puts into OpenBao, once, from a homelab-cluster checkout. Everything else is generated, declared or written by the apply.

| OpenBao path | Keys | Issued by |
| --- | --- | --- |
| `secret/hetzner/unfold-tofu` | `HCLOUD_TOKEN` | Hetzner Console |
| `secret/hetzner/unfold-cluster` | `HCLOUD_TOKEN_CLUSTER` | Hetzner Console |
| `secret/hetzner/unfold-vip` | `HCLOUD_TOKEN_VIP` | Hetzner Console |
| `secret/unfold-cluster/tofu-state` | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY`, `STATE_PASSPHRASE` | Garage; the passphrase is generated once |
| `secret/unfold-cluster/etcd-backup` | the write and read key pairs, `ETCD_BACKUP_AGE_IDENTITY` | Garage; `age-keygen` once |
| `secret/unfold-cluster/vars` | `STATE_BUCKET`, `STATE_ENDPOINT`, `STATE_REGION`, `ADMIN_CIDRS`, `ADMIN_SSH_PUBLIC_KEY`, `ETCD_BACKUP_AGE_RECIPIENT`, `ETCD_BACKUP_CHECK`, `REBUILD_DRILL` | the owner |
| `secret/hetzner/unfold-drill` | `HCLOUD_TOKEN` | Hetzner Console, the drill project (only for the drill) |

A rebuild into a new Hetzner project needs only the three Hetzner tokens of that project replaced; the rest stays.

## Rebuild procedure

**The Hetzner project is gone, the state is not** (the state lives on the off-site Garage, not in Hetzner Cloud):

1. Seed the new project's three tokens at the same paths (`just secret-set hetzner/unfold-tofu HCLOUD_TOKEN`, and the cluster and VIP ones).
2. Actions → `infra` → Run workflow, `plan-only`. Read the plan: everything is created again; `talos_machine_bootstrap.cluster` is replaced because the network is new; the Talos secrets are kept.
3. Run `apply` with that digest, and once more with the digest the run prints (the snapshot is built in the first one).

Inside that apply: the snapshot is built, the network and servers are created, the new Headscale address goes to OpenBao and from there into DNS within minutes, Headscale waits for its name, gets its certificate, mints keys, the nodes join, etcd is bootstrapped on the new control planes, Talos seeds Flux, and Flux brings back everything under `kubernetes/`. The gateway's new key reaches the homelab through OpenBao, and its state follows by itself.

**The state is lost as well:** the same steps. The run sees no Talos secrets in the state, reads the escrowed bundle from OpenBao and imports it, so the plan shows `talos_machine_secrets.cluster` imported rather than created. Hetzner resources that still exist under a lost state collide by name; the rebuild assumes an empty project.

**Only Headscale:** raise `headscale_generation` in a pull request, merge, apply. One apply; see the next section.

## Headscale survives a rebuild

Headscale keeps no backup. Backing up its SQLite database and keys would need a credential on the server and a restore step before the first boot; instead a new server simply becomes the coordination server of the same nodes:

1. The tailnet keys follow the server. `terraform_data.control_plane_tailnet_key` and `terraform_data.worker_tailnet_key` carry `hcloud_server.headscale.id` in `triggers_replace`. A new server has a new id, so the same apply asks the new server for a new reusable `tag:cp` key and a new single-use key per worker, and writes them into each node's `ExtensionServiceConfig` (`TS_AUTHKEY`). While the same server runs, nothing changes: the timer's renewed `tag:cp` key never reaches a running node.
2. Talos restarts the extension when its config changes. `ExtensionServiceController` (Talos 1.14, `internal/app/machined/pkg/controllers/runtime/extension_service.go`) watches each `ExtensionServiceConfigStatus` and restarts `ext-tailscale` when its spec version changes, without a reboot; the restarted service reads the new environment.
3. The node logs in again on its own. The extension runs Tailscale's `containerboot` with `TS_AUTH_ONCE=true`. Its state on `/var/lib/tailscale` still holds the old node key, which the new Headscale does not know, so `tailscaled` reports `NeedsLogin`; `containerboot` answers `NeedsLogin` with `tailscale up --authkey=$TS_AUTHKEY` (`cmd/containerboot/main.go`, the `authLoop`), the key the apply just wrote. A node whose server disappears while it runs exits (`tailscaled left running state`) and goes through the same login when restarted.
4. The homelab gateway does the same. Its key is minted per server too (`triggers_replace` includes the server id), written to OpenBao, refreshed into its Secret within 5 minutes, and Reloader restarts the pod; `containerboot` with `TS_AUTH_ONCE` and its Kubernetes state Secret logs in with the new key. The `unfold-gateway` DNS record follows the new tailnet address from that state.
5. The policy comes from cloud-init and the apply, the users from the program, the DNS name from the published address.

What is lost: the admin devices' registrations and the nodes' `100.64.x` addresses, which nothing depends on (the host firewall allows the whole tailnet prefix; the gateway's name is republished).

### The live Headscale server

The server created on 2026-10-25 runs the program and sudoers rule of 2026-10-24, which refuse the apply's `install`, `policy` and `gateway` steps. Three ways out were weighed:

| Option | Avoids a command by hand | Live equals a fresh rebuild | Verdict |
| --- | --- | --- | --- |
| Run `install-headscale-key-tool.sh` once (the #61 bridge) | no | yes, for the program and sudoers rule | rejected: a hand step, and the rebuild path stays unexercised |
| A CI-held admin credential minted by OpenTofu | no: a running server cannot be given a new SSH key without a hand step or a reboot into rescue mode, and the credential would be root on the server for every apply run | yes | rejected |
| Replace the server through the apply (`headscale_generation` 3) | yes | yes, by construction | **chosen** |

The replacement costs a tailnet outage of 10 to 25 minutes inside one apply (Kubernetes, Flux and the workloads keep running; External Secrets and the metrics and logs to the homelab pause) and one re-registration of each admin device. It is also the first real run of the rebuild path. `install-headscale-key-tool.sh` is deleted; the owner must not run it.

## The rebuild drill

`.forgejo/workflows/rebuild-drill.yml` proves the procedure against real infrastructure, in a separate Hetzner project, then deletes everything:

1. `rebuild-drill.sh guard` refuses unless the drill project is empty, then marks it with a free placement group `rebuild-drill-marker`. Production is never empty, so a production token seeded at the drill path by mistake stops here.
2. The state lives only on the runner, encrypted with a passphrase made for the run. The run builds the snapshot and applies from nothing, with `headscale-drill.webgrip.dev` as the Headscale name (published from `drill_ipv4`).
3. `rebuild-drill.sh verify` checks what stage D of the bootstrap checklist checks by hand: five nodes Ready in their pools, three etcd members, Flux Ready on a verified commit and owning its own seed, Cilium, the cloud controller and CSI driver Ready under Flux, the two Secrets written by OpenTofu.
4. `rebuild-drill.sh tailnet` waits until Headscale lists every node online.
5. It raises `headscale_generation`, plans, lifts the protection through `lift-headscale-protection.sh` and applies: Headscale is replaced under the running cluster. `tailnet` must then see every node online on the new server, and `verify` passes again.
6. Always, also after a failure: `teardown` deletes everything in the marked project (servers, volumes the CSI driver made, IPs, network, firewalls, SSH key, snapshot, the marker) and fails unless the project is empty; the drill's DNS record is cleared.

The drill uses fresh Talos secrets on purpose: a drill cluster with production's CAs and service-account key could mint tokens production and the homelab OpenBao trust. So External Secrets, the CI runners and the observability path cannot authenticate in the drill and are not checked; they come back unchanged in a production rebuild because the escrow keeps the identity. The etcd backup gets a dummy key, so the drill never writes into the production bucket.

**Cost per run.** About 2 billed hours of three CX23, one CX33, one CX43 and two CX23 for Headscale (before and after the replacement), plus the snapshot build's CX23: roughly €0.20 excluding VAT, €0.25 including, with snapshot and volume storage for those hours adding cents. A run that dies before its teardown and is left for a day costs about €2.30 including VAT; `teardown-only` ends it. It shares nothing with production's API budget (a separate project) but occupies the `unfold-infra` runner for about 90 minutes, so applies wait. Let's Encrypt issues at most 5 certificates a week for one name, so at most 5 drills a week.

**Shipped disabled.** The job runs only when the variable `REBUILD_DRILL` is `enabled`. To run it, the owner:

1. In the [Hetzner Console](https://console.hetzner.com), creates a Cloud project `unfold-drill` (nothing else in it) and in it **Security → API tokens → Generate API token**, Read & Write.
2. From a homelab-cluster checkout: `just secret-set hetzner/unfold-drill HCLOUD_TOKEN` and paste the token.
3. `just secret-set unfold-cluster/vars REBUILD_DRILL` and type `enabled`; the bridge copies it within the hour.
4. Actions → `rebuild-drill` → Run workflow on `main`, mode `drill`. A run that stopped before its teardown: run again with `teardown-only`.

To switch it off again, set `REBUILD_DRILL` to `disabled` the same way.

## Proof

| Claim | Proven by |
| --- | --- |
| A new Headscale makes every tailnet key new; a running one never changes a node | `infra/tests/rebuild.tftest.hcl`, `every_tailnet_key_is_minted_again_by_a_new_headscale` and `a_node_logs_in_with_its_key_only_when_headscale_refuses_its_identity`; the drill's step 5 on real servers |
| The live server is replaced once, by generation 3 | `the_live_server_is_replaced_once_to_match_a_fresh_rebuild` |
| Only a planned deletion of `unfold-headscale` lifts protection, never a control plane or a worker | `scripts/test-lift-headscale-protection.sh` |
| The escrowed bundle restores the same CAs, keys and secrets | `scripts/test-talos-secrets-escrow.sh`: generates secrets, escrows, imports into an empty state, compares every field |
| OpenBao writes keep other properties, skip unchanged values, refuse wrong kinds and never print values | `scripts/test-openbao-kv.sh` |
| The lifecycle rule is the exact one, signed for Garage, the secret key never on the command line | `scripts/test-set-etcd-backup-lifecycle.sh` |
| The drill never starts in a non-empty project and never deletes in an unmarked one | `scripts/test-rebuild-drill.sh` |
| `nodes list` prints names and online state, never a key | `scripts/test-tailnet-key-tool.sh` |
| A new network bootstraps etcd once; adding the trigger to a live state does not | OpenTofu's `replace_triggered_by` on an attribute: a plan on an existing state with the trigger added shows no change, an in-place update of the referenced resource triggers nothing, its replacement replaces the dependent (checked against OpenTofu 1.13.2 while writing this) |

Each test above was mutation-tested when written: breaking what it checks (the server id dropped from the key triggers, `TS_AUTH_ONCE=false`, the DNS gate removed, generation left at 2, the address not tied to the IP, the bundle made non-sensitive, a service-account key swapped in the bundle, any server unprotected, the live-name check removed, the guard or marker check removed, the expiry days changed, raw node JSON printed) made it fail, and the unchanged code passes. All run in `infra-check` on every pull request that touches them.

## Still open

- **The GitHub mirror** and its ruleset are hand-made (inventory above). A Hetzner rebuild does not touch them.
- **Admin devices** register again after a Headscale rebuild; Headscale OIDC through Authentik would turn that into a browser login.
- **The Garage buckets and keys** are made by hand on `garage-fsn1`; moving them to providers with an API (RFC 0001) makes them declarable.
- **etcd contents** come back only from a snapshot restore, which is its own runbook.
