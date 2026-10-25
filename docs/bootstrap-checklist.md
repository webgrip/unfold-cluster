# Bootstrap checklist

The owner's ordered list for taking this repository from nothing to a running, GitOps-managed cluster. Work top to bottom and tick each box. The [README](../README.md#from-nothing-to-gitops) explains the design; this page is only the steps.

Four stages. Nothing happens by hand between the applies any more: the `infra` apply run builds the Talos snapshot, Headscale makes its own users and pre-auth keys, and OpenTofu reads those keys from the Headscale server over SSH.

| Stage | What happens | Roughly |
| --- | --- | --- |
| [A](#a-hetzner-project-and-tokens) | Hetzner project and API tokens | 15 minutes |
| [B](#b-keys-buckets-and-openbao) | Keys, buckets, and every value the workflows need, put into OpenBao | 45 minutes |
| [C](#c-the-apply) | One apply: snapshot, network, firewalls, Headscale, tailnet keys, the cluster | 30 minutes |
| [D](#d-verification) | Prove it works | 1 hour, plus up to 6 hours waiting for the first backup |

Coming from the state of 2026-10-24, with only `unfold-headscale` created: follow [From the first apply's state](#from-the-first-applys-state) instead of C.

Words used below:

* **OpenBao**: the homelab's secret store. Every value the workflows need is put there by the owner, at a fixed path, and nowhere else by hand.
* **Credentials are read per run**: a workflow job on `main` proves who it is with its Forgejo OIDC token and reads the credentials straight from OpenBao (role `ci-unfold-cluster`, homelab-cluster ADR-0061). They are never Forgejo secrets, so a pull request or a workflow added on a branch cannot read them, and a new value counts from the next run.
* **The bridge**: the homelab CronJob `forgejo-actions-secrets` (namespace `forgejo`, hourly at minute 23). It copies only `secret/unfold-cluster/vars` onto this repository, as Forgejo Actions **variables** (readable plain text). So a variable put into OpenBao reaches the workflows within the hour. To start it at once from a homelab shell: `kubectl -n forgejo create job --from=cronjob/forgejo-actions-secrets forgejo-actions-secrets-now`. Nobody types secrets into Forgejo's settings pages; this is the estate's secret model (homelab-cluster ADR-0055).
* **Password manager**: the owner's own vault, with an offline copy (paper or an encrypted USB stick in a drawer). OpenBao runs in the homelab, so anything that cannot be made again, the state passphrase, the age key and the Talos secrets bundle, also goes here, so a lost homelab does not lose the cluster.
* **Apply**: a run of the `infra` workflow (Actions → `infra` → **Run workflow** on `main`, choose `apply` in the dropdown, and paste into `plan_digest` the `plan digest` printed by the run whose plan you read). Pushes only plan; nothing at Hetzner changes until a run with `apply` whose own plan has the digest you gave. When the plans differ, the run stops and prints its digest: read that run's plan and dispatch again with it. The [infra workflow runbook](runbooks/infra-workflow.md#when-the-apply-runs-digest-differs-from-the-run-you-read) lists when that is expected: the first snapshot build, and an apply that mints a tailnet key.

## What is made by hand, and why

Almost everything is created by OpenTofu or Flux. These few things cannot be, and are made once by hand:

| Item | Why it cannot be code |
| --- | --- |
| The Hetzner Cloud project | Hetzner's API works inside a project; it has no call to create one. |
| The three Hetzner API tokens | Tokens are created only in the Hetzner Console; the API cannot mint tokens. Their values then go into OpenBao like every other secret. |
| The Garage buckets and keys | The off-site Garage is a hand-run box outside both clusters, with no declarative controller. |
| The values in OpenBao | Tokens, bucket keys, the state passphrase and the age key are provided values: someone has to create them where they are issued and put them in OpenBao once (homelab-cluster ADR-0055). The bridge carries them from there. |

No longer by hand:

| Item | Now |
| --- | --- |
| The Cloudflare record for `headscale.webgrip.dev` | The apply writes the Headscale primary IP to OpenBao `secret/unfold/headscale-address`; the homelab CronJob `network/unfold-headscale-address` publishes it through external-dns, DNS only. A new project's new IP needs no commit. |
| The Headscale users and pre-auth keys | cloud-init creates the users `nodes` and the admin user; `unfold-tailnet-key` on the server makes the control planes' reusable `tag:cp` key, renews it by timer, and makes a single-use `tag:node` key for each new worker. OpenTofu reads them over SSH during the apply. |
| The homelab gateway's tailnet key and the Headscale policy | cloud-init installs the policy; the apply pushes later policy changes, mints a single-use `tag:homelab-gateway` key and writes it to OpenBao `secret/unfold/tailnet-homelab-gateway` ([observability](observability.md)). A rebuilt Headscale gets a new key the same way; the gateway's old identity is refused and it logs in with the new key on its own (`TS_AUTH_ONCE`). |
| The Talos secrets escrow | Every apply writes the bundle to OpenBao `secret/unfold-cluster/talos-secrets`; an apply into an empty state imports it, so a rebuild keeps the cluster's CAs and service-account key (and with them the homelab OpenBao's trust and `access/unfold-oidc.kubeconfig.yaml`). |
| The etcd bucket's 30-day expiry rule | Every apply puts it with the etcd write key (`scripts/set-etcd-backup-lifecycle.sh`). |
| Registering a person's device, and the Headscale OIDC client | Browser login through Authentik with a passkey ([runbook](runbooks/headscale-browser-login.md)). The client secret is generated in the homelab and read from OpenBao `secret/authentik/unfold-headscale-oidc` by the apply, which pushes it to the server with the configuration. |
| Replacing `unfold-headscale` | Raise `headscale_generation`; the apply lifts the delete protection of exactly that server because the reviewed plan deletes it, and every node re-joins with a fresh key in the same run. |
| The Talos snapshot | The apply run builds it with `scripts/build-talos-snapshot.sh` when no snapshot carries the labels of the pinned Talos version and schematic; OpenTofu finds it by those labels. |

## A. Hetzner project and tokens

- [ ] **A1. Create the project.** In the [Hetzner Console](https://console.hetzner.com), create a Cloud project named `unfold-cluster`. Use nothing else in this project: a token can reach everything in its project, so a separate project is the boundary.
- [ ] **A2. Create three API tokens.** In the project: **Security → API tokens → Generate API token**. Hetzner tokens have only two levels, Read or Read & Write, and always cover the whole project. All three need **Read & Write**:

  | Token name in Hetzner | Used by | Why it needs write | OpenBao path and key |
  | --- | --- | --- | --- |
  | `unfold-ci` | OpenTofu in the `infra` workflow | creates and changes every server, network and firewall | `secret/hetzner/unfold-tofu` `HCLOUD_TOKEN` |
  | `unfold-cluster` | Hetzner's cloud controller and CSI driver in `kube-system` | sets node addresses and load balancers, creates and attaches volumes | `secret/hetzner/unfold-cluster` `HCLOUD_TOKEN_CLUSTER` |
  | `unfold-vip` | the control planes | moves the API address `10.64.0.10` between them | `secret/hetzner/unfold-vip` `HCLOUD_TOKEN_VIP` |

  Hetzner shows a token once, so put each into OpenBao straight away. From a homelab-cluster checkout:

  ```sh
  mise exec -- just bao-login
  export BAO_ADDR=<the address bao-login printed>
  read -r -s -p 'unfold-ci token: ' v; echo; bao kv put secret/hetzner/unfold-tofu HCLOUD_TOKEN="$v"
  read -r -s -p 'unfold-cluster token: ' v; echo; bao kv put secret/hetzner/unfold-cluster HCLOUD_TOKEN_CLUSTER="$v"
  read -r -s -p 'unfold-vip token: ' v; echo; bao kv put secret/hetzner/unfold-vip HCLOUD_TOKEN_VIP="$v"
  unset v
  ```

  `read -s` keeps the value off the screen and out of shell history. Run `bao` as `mise exec -- bao` if it is not on the path.

  Three tokens instead of one means each can be revoked alone: a leaked machine config exposes only `unfold-vip`. Rotate all three every six months: generate the new token, `bao kv put` it at the same path, run an apply (the cluster and VIP tokens reach the nodes only through an apply), then delete the old token in Hetzner.

Every server, the network and the Headscale address carry Hetzner's delete protection, so even a stolen token cannot remove them in one call.

## B. Keys, buckets and OpenBao

### B1. State passphrase

OpenTofu's state holds the Talos secrets, so it is encrypted with a passphrase.

- [ ] Generate it: `openssl rand -base64 48`
- [ ] Password manager entry `unfold-cluster state passphrase`, with the offline copy. It goes into OpenBao in B4.

Without it, the state and the Talos secrets cannot be read again, by anyone.

### B2. Backup encryption key (age)

etcd snapshots are encrypted with [age](https://age-encryption.org) before they leave the cluster. The cluster gets only the public half, so a compromised cluster cannot read its own backups.

- [ ] `mise exec age -- age-keygen -o etcd-backup.age` (or plain `age-keygen` if age is installed)
- [ ] The line `# public key: age1…` holds the recipient, the value for `ETCD_BACKUP_AGE_RECIPIENT`.
- [ ] The whole file, all three lines, goes into the password manager (entry `unfold-cluster etcd backup age key`) and the offline copy. It goes into OpenBao in B4 as `ETCD_BACKUP_AGE_IDENTITY`; keep the file until then.

### B3. Garage buckets and keys

> **Check first.** RFC 0001 ([object storage](rfc/0001-security-architecture.md#object-storage), decided 2026-10-24) moves the OpenTofu state to OVHcloud and the etcd snapshots to Hetzner Object Storage, "before the first apply". The code today still points both at the off-site Garage. Do this section only if the first apply goes ahead on Garage; otherwise the buckets are made at those providers and `STATE_ENDPOINT`, `STATE_REGION` and the etcd-backup CronJob's endpoint change with them.

Run these on the off-site Garage host, `garage-fsn1` behind `s3-offsite.webgrip.dev` (Garage v2.1, see the homelab's `garage-offsite` runbook). The owner runs them; agents may not touch that box.

```sh
ssh root@116.202.53.185
set -a; . /etc/garage/env; set +a
grep '^s3_region' /etc/garage/garage.toml

garage bucket create unfold-cluster-tfstate
garage bucket create unfold-cluster-etcd

garage key create unfold-cluster-tfstate-rw
garage key create unfold-cluster-etcd-write
garage key create unfold-cluster-etcd-read

garage bucket allow --read --write unfold-cluster-tfstate --key unfold-cluster-tfstate-rw
garage bucket allow --write unfold-cluster-etcd --key unfold-cluster-etcd-write
garage bucket allow --read unfold-cluster-etcd --key unfold-cluster-etcd-read

garage bucket info unfold-cluster-tfstate
garage bucket info unfold-cluster-etcd
```

The second line loads the CLI's secret into this shell without printing it. The `grep` shows the S3 region Garage signs with; it should say `garage`, the value `STATE_REGION` gets in B4. If it says something else, use that value for `STATE_REGION` and in the lifecycle commands.

Each `garage key create` prints a **Key ID** (starts with `GK`) and a **Secret key**. `garage key info --show-secret <key name>` prints them again later. The two `bucket info` calls must list exactly these grants and nothing more:

| Bucket | Key | Read | Write | Holder | Becomes |
| --- | --- | --- | --- | --- | --- |
| `unfold-cluster-tfstate` | `unfold-cluster-tfstate-rw` | yes | yes | OpenTofu in CI | `STATE_S3_ACCESS_KEY` = Key ID, `STATE_S3_SECRET_KEY` = Secret key |
| `unfold-cluster-etcd` | `unfold-cluster-etcd-write` | no | yes | the cluster's backup CronJob | `ETCD_BACKUP_WRITE_ACCESS_KEY`, `ETCD_BACKUP_WRITE_SECRET_KEY` |
| `unfold-cluster-etcd` | `unfold-cluster-etcd-read` | yes | no | the daily restore check | `ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY` |

The key pairs go into OpenBao in B4. They need no password-manager copy: `garage key info --show-secret` on the box shows them again.

**Expire snapshots after 30 days.** Nothing to do here: every `infra` apply puts the bucket's lifecycle rule (objects under `unfold-main/` expire after 30 days) with the etcd write key, through Garage's S3 API (`scripts/set-etcd-backup-lifecycle.sh`), so a rule changed by hand is back after the next apply.

### B4. Put every value into OpenBao

Still in the homelab-cluster checkout with `bao` logged in (A2). `bao kv put` replaces everything at a path, so each path is written whole, once; later additions use `bao kv patch`, which adds or changes keys and keeps the rest.

```sh
read -r -s -p 'state passphrase (B1): ' passphrase; echo
read -r -p 'state key ID (GK...): ' state_id
read -r -s -p 'state secret key: ' state_secret; echo
bao kv put secret/unfold-cluster/tofu-state \
  STATE_S3_ACCESS_KEY="$state_id" STATE_S3_SECRET_KEY="$state_secret" STATE_PASSPHRASE="$passphrase"

read -r -p 'etcd write key ID: ' write_id
read -r -s -p 'etcd write secret key: ' write_secret; echo
read -r -p 'etcd read key ID: ' read_id
read -r -s -p 'etcd read secret key: ' read_secret; echo
bao kv put secret/unfold-cluster/etcd-backup \
  ETCD_BACKUP_WRITE_ACCESS_KEY="$write_id" ETCD_BACKUP_WRITE_SECRET_KEY="$write_secret" \
  ETCD_BACKUP_READ_ACCESS_KEY="$read_id" ETCD_BACKUP_READ_SECRET_KEY="$read_secret" \
  ETCD_BACKUP_AGE_IDENTITY=@etcd-backup.age
unset passphrase state_id state_secret write_id write_secret read_id read_secret

bao kv put secret/unfold-cluster/vars \
  STATE_BUCKET=unfold-cluster-tfstate \
  STATE_ENDPOINT=https://s3-offsite.webgrip.dev \
  STATE_REGION=garage \
  ADMIN_CIDRS='["203.0.113.7/32"]' \
  ADMIN_SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  ETCD_BACKUP_AGE_RECIPIENT="$(sed -n 's/^# public key: //p' etcd-backup.age)"

shred -u etcd-backup.age
```

`KEY=@file` makes `bao` read the value from the file, so the age key is never pasted. Replace the example address in `ADMIN_CIDRS` first, and use the `s3_region` from B3 if it was not `garage`.

What each value is:

| Path | Key | Value or format | Comes from |
| --- | --- | --- | --- |
| `secret/hetzner/unfold-tofu` | `HCLOUD_TOKEN` | Hetzner token, 64 characters | A2 |
| `secret/hetzner/unfold-cluster` | `HCLOUD_TOKEN_CLUSTER` | Hetzner token | A2 |
| `secret/hetzner/unfold-vip` | `HCLOUD_TOKEN_VIP` | Hetzner token | A2 |
| `secret/unfold-cluster/tofu-state` | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | Garage Key ID (`GK…`) and Secret key | B3 |
| `secret/unfold-cluster/tofu-state` | `STATE_PASSPHRASE` | at least 32 characters | B1 |
| `secret/unfold-cluster/etcd-backup` | `ETCD_BACKUP_WRITE_ACCESS_KEY`, `ETCD_BACKUP_WRITE_SECRET_KEY` | Garage key pair, write only | B3 |
| `secret/unfold-cluster/etcd-backup` | `ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY` | Garage key pair, read only | B3 |
| `secret/unfold-cluster/etcd-backup` | `ETCD_BACKUP_AGE_IDENTITY` | the whole age key file | B2 |
| `secret/unfold-cluster/vars` | `STATE_BUCKET` | `unfold-cluster-tfstate` | fixed |
| `secret/unfold-cluster/vars` | `STATE_ENDPOINT` | `https://s3-offsite.webgrip.dev` | fixed |
| `secret/unfold-cluster/vars` | `STATE_REGION` | `garage` | the `s3_region` line in B3 |
| `secret/unfold-cluster/vars` | `ADMIN_CIDRS` | JSON list, e.g. `["203.0.113.7/32"]` | the public IPv4 of home, where the Forgejo runners also leave from: `curl -4 https://ifconfig.me` from the home network. If the home address changes, the Talos and Kubernetes APIs close to CI until this is updated |
| `secret/unfold-cluster/vars` | `ADMIN_SSH_PUBLIC_KEY` | one line, `ssh-ed25519 AAAA… comment` | `~/.ssh/id_ed25519.pub` |
| `secret/unfold-cluster/vars` | `ETCD_BACKUP_AGE_RECIPIENT` | `age1…` | B2 |
| `secret/unfold-cluster/vars` | `ETCD_BACKUP_CHECK` | `enabled` | **stage D**, after the first snapshot; leave unset now |

Everything under `secret/unfold-cluster/vars` becomes a Forgejo **variable**, readable by anyone with access to the repository settings; everything else stays in OpenBao and is read by the runs that need it.

- [ ] All rows set except the last.
- [ ] After the bridge's next run, this repository's **Settings → Actions → Variables** lists the six variables with their values, and **Secrets** lists none. A variable missing there means the bridge did not pick it up: check the job's log in the homelab, `kubectl -n forgejo logs job/<newest forgejo-actions-secrets job>`. The credentials are checked by the first run itself: its OpenBao step prints each name it read and the path it came from, never a value, and stops naming any path or key that is missing.
- [ ] The runner `unfold-infra` shows as online under **Settings → Actions → Runners**. It is defined in the homelab (`kubernetes/apps/forgejo/forgejo-runner/app/infra/`); no job here runs without it.

## C. The apply

- [ ] **C1.** Open the newest `infra` run on `main` and read its plan. It creates the network, its subnet, two firewalls, the placement group, the SSH key, the Headscale primary IP, `hcloud_server.headscale`, `tls_private_key.headscale_tofu`, `tls_private_key.headscale_host`, `terraform_data.headscale_generation`, three `terraform_data.control_plane_tailnet_key`, two `terraform_data.worker_tailnet_key`, the `external` key reads (the workers' read during apply), three `control_plane` servers, two `hcloud_server.worker` (`unfold-app-1`, CX33, and the CI node `unfold-ci-1`, CX43; see [worker pools](runbooks/infra-workflow.md#worker-pools)), the Talos secrets, the machine-config applies, the bootstrap and the kubeconfig. Nothing is destroyed. The node servers show the image `talos-snapshot-is-built-by-the-apply-run` until the snapshot exists. Copy the run's plan digest.
- [ ] **C2.** Actions → `infra` → **Run workflow**, branch `main`, `apply`, and the digest. The run builds the Talos snapshot first (a few minutes and one temporary CX23, deleted again), then plans. The first time, that plan names the snapshot instead of the placeholder, so its digest differs and the run stops, printing its own. Read that run's plan: the same resources, with a numeric image. Dispatch again with its digest. If the create fails with the server type unavailable, Hetzner has no stock in `fsn1` at that moment: retry later, or set `location` to `nbg1` in `infra/variables.tf` through a PR; every node must share one location.
- [ ] **C3.** The apply waits for Headscale: `scripts/read-tailnet-key.sh` retries SSH to `tofu@<headscale_ipv4>`, trusting only the pinned host key, for up to 25 minutes, until cloud-init has finished and `https://headscale.webgrip.dev/health` passes with a Let's Encrypt certificate. A run that times out there names `read-tailnet-key` in its error; one that says the server `did not present the pinned SSH host key` stopped on purpose and must not be retried until that is understood; `ssh admin@headscale.webgrip.dev` then `sudo cloud-init status --long` and `sudo journalctl -u headscale` show why.
- [ ] **C4. The Talos secrets are escrowed.** The apply run's step `Escrow the Talos secrets in OpenBao` writes them to `secret/unfold-cluster/talos-secrets` (`bundle`); its log says `wrote bundle` or `is current`. For the offline copy, from a shell with the state credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` set to the B3 state key and `TF_VAR_state_passphrase` to B1, read with `bao kv get secret/unfold-cluster/tofu-state`), in `infra/` after the same `tofu init` the workflow runs: `tofu output -raw talos_secrets_bundle` into the password manager. `tofu output -raw talosconfig` and `tofu output -raw kubeconfig` give the admin files; keep them out of git (both names are in `.gitignore`).

### The Headscale server of 2026-10-25

That server predates the apply's `install`, `policy` and `gateway` steps, and its sudoers rule refuses them. `headscale_generation` 3 replaces it: no command on the server, one apply. Its plan shows `hcloud_server.headscale` `must be replaced`, the three control-plane and two worker `terraform_data.*_tailnet_key` replaced, the five `talos_machine_configuration_apply` updated in place (new `TS_AUTHKEY` only), `terraform_data.homelab_gateway_tailnet_key` replaced, and nothing else destroyed. During the run the tailnet is down for 10 to 25 minutes; Kubernetes, Flux and the workloads keep running, and the APIs stay reachable from `ADMIN_CIDRS`. Afterwards register your own devices again (stage D, first box) and update `~/.ssh/known_hosts` with the pinned line from `BAO_ADDR="$(just bao-addr)" bao kv get -field=ssh_known_hosts secret/unfold/headscale-address` (run in `homelab-cluster`; every apply writes it there).

### From the first apply's state (2026-10-24, done)

On 2026-10-24 the first apply had already created the network, the firewalls and `unfold-headscale`, from code that had no `tofu` user, no key tool and no timer. cloud-init runs only when a server is created, so that server is replaced through code. It holds nothing yet (no users, no keys, no nodes), and the primary IP `2.31.73.11` stays, so the DNS record stays valid. Hetzner refuses to delete a server with delete protection, and the provider does not lift it before a replacement, so this takes two pull requests and two applies, in this order:

- [ ] **R1.** Merge the pull request that lifts delete and rebuild protection on `unfold-headscale` only. Its plan on `main`: `0 to add, 1 to change, 0 to destroy`, the change being `hcloud_server.headscale` with `delete_protection` and `rebuild_protection` going from `true` to `false`. Anything else in that plan: stop.
- [ ] **R2.** Apply it with that run's digest.
- [ ] **R3.** Only now merge the pull request that makes the apply self-contained. Merged before R2, its apply fails at Hetzner's delete protection, before any node exists.
- [ ] **R4.** Read its plan on `main`: exactly `1 to destroy`, and that one is `hcloud_server.headscale`, `must be replaced` because of `terraform_data.headscale_generation`. Everything in C1 except what exists already is created. If the plan destroys anything else, stop.
- [ ] **R5.** Apply as in C2 (two dispatches the first time, because of the snapshot), then C3 and C4. The new server is created with delete and rebuild protection on again. The server's SSH host key changes: `ssh-keygen -R headscale.webgrip.dev`, then add the pinned line from `BAO_ADDR="$(just bao-addr)" bao kv get -field=ssh_known_hosts secret/unfold/headscale-address` (run in `homelab-cluster`; every apply writes it there) to `~/.ssh/known_hosts`. Never answer `yes` to an unknown host key instead.

## D. Verification

Each check names what must be seen. A check that has not been seen has not passed.

- [ ] **Join the tailnet.** On the laptop, on the homelab LAN or VPN: `tailscale up --login-server=https://headscale.webgrip.dev`, open the URL it prints, sign in to Authentik, and confirm with your passkey (enroll one first under Authentik **Settings → MFA Devices** if you have none). The [browser login runbook](runbooks/headscale-browser-login.md) explains each step and the refusals. `ssh admin@headscale.webgrip.dev sudo headscale nodes list` shows the laptop under your Authentik user name, expiring in 30 days. Then `tailscale status` lists `unfold-cp-1` to `-3`, `unfold-app-1` and `unfold-ci-1`, and `sudo headscale nodes list-routes` shows `10.64.0.0/24` approved, advertised by the `tag:cp` nodes.
- [ ] **The key renews itself.** On the Headscale server: `systemctl list-timers unfold-tailnet-key.timer` shows the next run, `sudo headscale preauthkeys list` shows one unexpired reusable `tag:cp` key, and `sudo ls -l /var/lib/unfold-tailnet` shows files owned by root with mode `-rw-------`.
- [ ] **The APIs answer over the tailnet.** With Tailscale up: `kubectl --kubeconfig kubeconfig get nodes -L node.webgrip.io/pool` lists five nodes, Ready, with `unfold-app-1` in pool `unfold` and `unfold-ci-1` in pool `ci`, through `https://10.64.0.10:6443`. That address is the VIP, so this also proves the `private0` alias found the private NIC.
- [ ] **The APIs do not answer from the internet.** From a network that is not in `ADMIN_CIDRS`, for example a phone hotspot, with Tailscale off: `curl -k --max-time 5 https://<public IPv4 of unfold-cp-1>:6443/version` must time out, and so must port `50000`. From home they still answer, because home is in `ADMIN_CIDRS` for CI; the README's "Open" section tracks closing that.
- [ ] **The CI node runs gVisor and nothing else.** `kubectl --kubeconfig kubeconfig get runtimeclass gvisor` shows handler `runsc`; `kubectl --kubeconfig kubeconfig get node unfold-ci-1 -o jsonpath='{.spec.taints}{"\n"}{.status.runtimeHandlers[*].name}'` shows the taint `node.webgrip.io/pool=ci:NoSchedule` and a handler list that includes `runsc`. A pod with `runtimeClassName: gvisor` is placed on `unfold-ci-1` without a selector of its own.
- [ ] **People sign in as themselves.** From the homelab LAN or VPN with Tailscale up, `export KUBECONFIG=$PWD/access/unfold-oidc.kubeconfig.yaml`, then `mise exec -- kubectl auth whoami` shows `oidc:<your user name>` in `oidc:unfold-admins`, and `mise exec -- kubectl get secrets -A` is refused. After a rebuild, first copy `certificate-authority-data` from `tofu output -raw kubeconfig` into that file. The full two-way check is in the [Kubernetes login runbook](runbooks/kubernetes-login.md#proving-it-after-the-merge); from then on the admin kubeconfig is break-glass.
- [ ] **Flux deploys only signed commits.** `kubectl -n flux-system get gitrepository` is Ready, and `kubectl -n flux-system describe gitrepository` shows the condition `SourceVerified` `True` for the commit on `main`. A commit not signed by a key in `kubernetes/clusters/main/flux-system/trusted-signers/` must leave it not Ready with a verification error; that refusal fired on 2026-10-25, when two unsigned commits were pushed straight to `main` and Flux held the previous revision until a signed merge followed. Pull requests are merged with Forgejo's button; its merge commits are signed by the instance key in `kubernetes/clusters/main/flux-system/trusted-signers/forgejo.sshpub` (README, "Only signed commits deploy").
- [ ] **Flux owns the seed.** `kubectl -n flux-system get helmrelease flux-operator` and `kubectl -n flux-system get fluxinstance flux` are Ready, and `kubectl -n flux-system get gitrepository,kustomization flux-system -o jsonpath='{.items[*].metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'` prints `flux-system flux-system`: Flux applies its own source. On a new cluster, `kubectl -n flux-system get rs -l app.kubernetes.io/name=flux-operator` shows one ReplicaSet, because adopting the operator must not restart it (README, "After the first boot").
- [ ] **OpenTofu owns the two Secrets.** `kubectl -n kube-system get secret hcloud --show-managed-fields -o jsonpath='{.metadata.managedFields[*].manager}'` names `opentofu`, and so does the same command for `-n etcd-backup secret etcd-backup`.
- [ ] **Nodes pull through Zot.** Once Zot runs (`kubectl -n zot get pod zot-0` Ready), `talosctl -n <node> read /etc/cri/conf.d/hosts/quay.io/hosts.toml` names `http://127.0.0.1:30500/v2/quay.io`, and a pod started afterwards with an image new to its node shows up as an on-demand sync in `kubectl -n zot logs zot-0`. Before Zot runs, nodes pull from upstream as before; [talos-registry-mirrors](runbooks/talos-registry-mirrors.md) explains why that fallback is safe.
- [ ] **Backups land.** The CronJob runs at minute 17 every six hours. Either wait, or start one: `kubectl --kubeconfig kubeconfig -n etcd-backup create job --from=cronjob/etcd-backup etcd-backup-first`. On the Garage host, `garage bucket info unfold-cluster-etcd` then shows one object or more.
- [ ] **The cluster cannot read its backups.** With the etcd write key, a read must be refused: `curl --aws-sigv4 "aws:amz:garage:s3" --user "<write key id>:<write secret>" https://s3-offsite.webgrip.dev/unfold-cluster-etcd?list-type=2` answers `403`.
- [ ] **The restore check passes.** `bao kv patch secret/unfold-cluster/vars ETCD_BACKUP_CHECK=enabled`, and wait for the bridge. Actions → `etcd-backup-check` → **Run workflow** with input `no`: green, and the log names the snapshot and its age.
- [ ] **The restore check catches damage.** Run it again with input `corrupt`: it must fail, and the failing step must be the restore, not the download or a missing secret. A check that has only ever passed proves nothing.
- [ ] **The homelab OpenBao knows this cluster's service-account key.** A new cluster signs its service-account tokens with a new key, and External Secrets logs in to the homelab OpenBao with those tokens. Compare `kubectl --kubeconfig kubeconfig get --raw /openid/v1/jwks` with `kubernetes/apps/security/openbao/bootstrap/unfold-main-service-account.pem` in homelab-cluster ([runbook](runbooks/external-secrets.md#when-the-cluster-is-rebuilt)); if they differ, commit the new key there first. Then `kubectl --kubeconfig kubeconfig get clustersecretstore openbao-homelab` shows `Ready` `True`.

When every box is ticked, Flux owns everything under `kubernetes/`, and changes reach the cluster only as signed commits on `main`.
