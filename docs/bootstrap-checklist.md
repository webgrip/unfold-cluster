# Bootstrap checklist

The owner's ordered list for taking this repository from nothing to a running, GitOps-managed cluster. Work top to bottom and tick each box. The [README](../README.md#from-nothing-to-gitops) explains the design; this page is only the steps.

Five stages:

| Stage | What happens | Roughly |
| --- | --- | --- |
| [A](#a-hetzner-project-and-tokens) | Hetzner project and API tokens | 15 minutes |
| [B](#b-keys-buckets-and-openbao) | Keys, buckets, and every value the workflows need, put into OpenBao | 45 minutes |
| [C](#c-first-apply) | First apply: network, firewalls, Headscale server | 10 minutes |
| [D](#d-between-the-applies) | DNS record, tailnet key, Talos snapshot | 30 minutes |
| [E](#e-second-apply-and-verification) | Second apply: the cluster; then prove it works | 1 hour, plus up to 6 hours waiting for the first backup |

Words used below:

* **OpenBao**: the homelab's secret store. Every value the workflows need is put there by the owner, at a fixed path, and nowhere else by hand.
* **The bridge**: the homelab CronJob `forgejo-actions-secrets` (namespace `forgejo`, hourly at minute 23). It reads those OpenBao paths and sets them on this repository as Forgejo Actions **secrets** (write-only, hidden in logs) or **variables** (readable plain text). So a value put into OpenBao reaches the workflows within the hour. To start it at once from a homelab shell: `kubectl -n forgejo create job --from=cronjob/forgejo-actions-secrets forgejo-actions-secrets-now`. Nobody types secrets into Forgejo's settings pages; this is the estate's secret model (homelab-cluster ADR-0055).
* **Password manager**: the owner's own vault, with an offline copy (paper or an encrypted USB stick in a drawer). OpenBao runs in the homelab, so anything that cannot be made again, the state passphrase, the age key and the Talos secrets bundle, also goes here, so a lost homelab does not lose the cluster.
* **Apply**: a run of the `infra` workflow (Actions → `infra` → **Run workflow** on `main`, choose `apply` in the dropdown). Pushes and PRs only plan; nothing at Hetzner changes until a run with `apply`.

## What is made by hand, and why

Almost everything is created by OpenTofu or Flux. These few things cannot be, and are made once by hand:

| Item | Why it cannot be code |
| --- | --- |
| The Hetzner Cloud project | Hetzner's API works inside a project; it has no call to create one. |
| The three Hetzner API tokens (plus a short-lived one for the snapshot) | Tokens are created only in the Hetzner Console; the API cannot mint tokens. Their values then go into OpenBao like every other secret. |
| The Garage buckets and keys | The off-site Garage is a hand-run box outside both clusters, with no declarative controller. |
| The Cloudflare record for `headscale.webgrip.dev`, for now | The record points at an address that exists only after the first apply, and it must be DNS only. It could be declared instead: `webgrip.dev` records are owned by the homelab's external-dns (`kubernetes/apps/network/cloudflare-dns` in homelab-cluster; the `webgrip/cloudflare` DNSControl repo covers only `webgrip.nl`), so a `DNSEndpoint` there with the provider-specific setting `external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"` would make it code (not tried yet). That puts a production record in the homelab's hands, which is the owner's call. A hand-made record is safe meanwhile: external-dns deletes only records carrying its own ownership marker. |
| The Headscale pre-auth key | Headscale makes it, on its own server, after the first apply. |

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

  Three tokens instead of one means each can be revoked alone: a leaked machine config exposes only `unfold-vip`. Rotate all three every six months: generate the new token, `bao kv put` it at the same path, wait for the bridge, run an apply (the cluster and VIP tokens reach the nodes only through an apply), then delete the old token in Hetzner.

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

**Expire snapshots after 30 days.** Garage v2.1 supports S3 lifecycle rules (expiry in days, filtered by prefix), but not through its CLI: the rule is set with an S3 call signed by a key that may write to the bucket, which is the etcd write key. Still on the Garage host:

```sh
cat > /root/unfold-etcd-lifecycle.xml <<'EOF'
<LifecycleConfiguration><Rule><ID>expire-after-30-days</ID><Status>Enabled</Status><Filter><Prefix>unfold-main/</Prefix></Filter><Expiration><Days>30</Days></Expiration></Rule></LifecycleConfiguration>
EOF
read -r -p 'etcd write Key ID: ' key_id
read -r -s -p 'etcd write Secret key: ' key_secret; echo
md5="$(openssl dgst -md5 -binary /root/unfold-etcd-lifecycle.xml | base64)"
printf 'user = "%s:%s"\n' "$key_id" "$key_secret" | curl -fsS --config - --aws-sigv4 "aws:amz:garage:s3" \
  -X PUT -H "Content-MD5: $md5" -H "Content-Type: application/xml" \
  --data-binary @/root/unfold-etcd-lifecycle.xml "http://127.0.0.1:3900/unfold-cluster-etcd?lifecycle"
printf 'user = "%s:%s"\n' "$key_id" "$key_secret" | curl -fsS --config - --aws-sigv4 "aws:amz:garage:s3" \
  "http://127.0.0.1:3900/unfold-cluster-etcd?lifecycle"; echo
unset key_id key_secret
rm /root/unfold-etcd-lifecycle.xml
```

`read -s` keeps the secret off the screen and out of shell history, and `--config -` keeps it out of the process list. The second `curl` must print the rule back. The prefix `unfold-main/` is where the CronJob writes. Garage's lifecycle worker runs once a day at midnight UTC, so a snapshot is gone between 30 and 31 days after it was written.

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
| `secret/unfold-cluster/vars` | `TALOS_SNAPSHOT_ID` | a number, e.g. `312345678` | **stage D**, D4 |
| `secret/unfold-cluster/tailnet` | `TAILSCALE_AUTHKEY` | Headscale pre-auth key | **stage D**, D3; leave unset now |
| `secret/unfold-cluster/vars` | `ETCD_BACKUP_CHECK` | `enabled` | **stage E**, after the first snapshot; leave unset now |

Everything under `secret/unfold-cluster/vars` becomes a Forgejo **variable**, readable by anyone with access to the repository settings; everything else becomes a **secret**.

- [ ] All rows set except the last three.
- [ ] After the bridge's next run, this repository's **Settings → Actions → Secrets** lists the eleven secret names (values stay hidden) and **Variables** lists the six variables with their values. A name missing there means the bridge did not pick it up: check the job's log in the homelab, `kubectl -n forgejo logs job/<newest forgejo-actions-secrets job>`.
- [ ] The runner `unfold-infra` shows as online under **Settings → Actions → Runners**. It is defined in the homelab (`kubernetes/apps/forgejo/forgejo-runner/app/infra/`); no job here runs without it.

## C. First apply

With `TAILSCALE_AUTHKEY` unset, OpenTofu creates only the network, the firewalls, the Headscale server and its address. No cluster node yet.

- [ ] **C1.** Open the newest `infra` run on `main` and read its plan: it should create `hcloud_network`, its subnet, two firewalls, the placement group, the SSH key, the Headscale primary IP and `hcloud_server.headscale`, and nothing named `control_plane` or `unfold_worker`.
- [ ] **C2.** Actions → `infra` → **Run workflow**, branch `main`, choose `apply` in the dropdown (the default `plan-only` creates nothing).
- [ ] **C3.** At the end of the run, note the output `headscale_ipv4`. If the create fails with the server type unavailable, Hetzner has no CX stock in `fsn1` at that moment: retry later, or set `location` to `nbg1` in `infra/variables.tf` through a PR. Decide that before the second apply, because every node must share one location.

## D. Between the applies

- [ ] **D1. DNS record.** In Cloudflare, zone `webgrip.dev`: add an `A` record `headscale` → the `headscale_ipv4` address, proxy status **DNS only** (grey cloud). Headscale serves its own TLS, and the Tailscale protocol does not pass through Cloudflare's proxy.
- [ ] **D2. Wait for Headscale.** `curl -fsS https://headscale.webgrip.dev/health` answers once Headscale has fetched its Let's Encrypt certificate, usually within a few minutes of the record resolving.
- [ ] **D3. Tailnet key.** Headscale is the self-hosted server that tells tailnet devices how to find each other; a pre-auth key lets a node join without a person approving it.

  ```sh
  ssh admin@headscale.webgrip.dev
  sudo headscale users create nodes
  sudo headscale users create ryan
  sudo headscale users list
  sudo headscale preauthkeys create --user <ID of nodes from the list> --reusable --tags tag:node --expiration 2160h
  ```

  Put it into OpenBao from the homelab-cluster checkout, then wait for the bridge:

  ```sh
  read -r -s -p 'Headscale pre-auth key: ' v; echo; bao kv put secret/unfold-cluster/tailnet TAILSCALE_AUTHKEY="$v"; unset v
  ```

  It expires after 90 days; renew it with the same Headscale command, `bao kv put` it again, and run an apply so the nodes get it.
- [ ] **D4. Talos snapshot.** The cluster nodes boot from a Hetzner snapshot of Talos with the extensions in `talos/schematics/cloud.yaml`. Use a separate, short-lived token so the CI token never sits on the laptop: in the Hetzner project, generate a Read & Write token named `unfold-snapshot`, then from a clone of this repository:

  ```sh
  ./scripts/build-talos-snapshot.sh --dry-run
  read -r -s -p 'Hetzner token: ' HCLOUD_TOKEN; echo; export HCLOUD_TOKEN
  ./scripts/build-talos-snapshot.sh
  unset HCLOUD_TOKEN
  ```

  The dry run checks that the schematic matches `infra/variables.tf` and that the Image Factory serves the image, without touching Hetzner. The real run creates a temporary CX23 server, writes the image to its disk from Hetzner's rescue system, snapshots it, deletes the server and prints the snapshot id on the last line; it reuses an existing snapshot with the same Talos version and schematic instead of building another. The temporary server is a CX23 because a snapshot can only be used on servers whose disk is at least as large as the one it was taken from, and CX23's 40 GB is the smallest disk in the cluster. If the run fails halfway, `./scripts/build-talos-snapshot.sh --cleanup` removes what it left behind.

  Put the number into OpenBao with `bao kv patch secret/unfold-cluster/vars TALOS_SNAPSHOT_ID=<id>` and wait for the bridge; the variable appears under **Settings → Actions → Variables**. Then delete the `unfold-snapshot` token in Hetzner.

## E. Second apply and verification

- [ ] **E0.** Under **Settings → Actions**, the secret `TAILSCALE_AUTHKEY` and the variable `TALOS_SNAPSHOT_ID` both exist. Without the key, the plan creates no node at all.
- [ ] **E1.** Read the plan of a fresh `infra` run: it now creates three `control_plane` servers, one `unfold_worker`, the Talos secrets, the machine-config applies, the bootstrap and the kubeconfig. Nothing is replaced or destroyed.
- [ ] **E2.** Run it with `apply`.
- [ ] **E3. Escrow the Talos secrets.** From a shell with the state credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` set to the B3 state key and `TF_VAR_state_passphrase` to B1, read with `bao kv get secret/unfold-cluster/tofu-state`), in `infra/` after the same `tofu init` the workflow runs: `tofu output -raw talos_machine_secrets` into the password manager and the offline copy. `tofu output -raw talosconfig` and `tofu output -raw kubeconfig` give the admin files; keep them out of git (both names are in `.gitignore`).

### Verify

Each check names what must be seen. A check that has not been seen has not passed.

- [ ] **Join the tailnet.** On the laptop: `tailscale up --login-server=https://headscale.webgrip.dev`. It prints a register command; run it on the Headscale server with `--user ryan`, e.g. `sudo headscale nodes register --user ryan --key <key from the URL>`. Then `tailscale status` lists `unfold-cp-1` to `-3` and `unfold-app-1`, and `sudo headscale nodes list-routes` shows `10.64.0.0/24` approved.
- [ ] **The APIs answer over the tailnet.** With Tailscale up: `kubectl --kubeconfig kubeconfig get nodes` lists four nodes, Ready, through `https://10.64.0.10:6443`. That address is the VIP, so this also proves the `private0` alias found the private NIC.
- [ ] **The APIs do not answer from the internet.** From a network that is not in `ADMIN_CIDRS`, for example a phone hotspot, with Tailscale off: `curl -k --max-time 5 https://<public IPv4 of unfold-cp-1>:6443/version` must time out, and so must port `50000`. From home they still answer, because home is in `ADMIN_CIDRS` for CI; the README's "Open" section tracks closing that.
- [ ] **Flux deploys only signed commits.** `kubectl -n flux-system get gitrepository` is Ready, and `kubectl -n flux-system describe gitrepository` shows the condition `SourceVerified` `True` for the commit on `main`. A commit not signed by a key in `infra/trusted-signers/` must leave it not Ready with a verification error; that refusal has not been exercised on this cluster yet, and proving it once is still open.
- [ ] **Backups land.** The CronJob runs at minute 17 every six hours. Either wait, or start one: `kubectl --kubeconfig kubeconfig -n etcd-backup create job --from=cronjob/etcd-backup etcd-backup-first`. On the Garage host, `garage bucket info unfold-cluster-etcd` then shows one object or more.
- [ ] **The cluster cannot read its backups.** With the etcd write key, a read must be refused: `curl --aws-sigv4 "aws:amz:garage:s3" --user "<write key id>:<write secret>" https://s3-offsite.webgrip.dev/unfold-cluster-etcd?list-type=2` answers `403`.
- [ ] **The restore check passes.** `bao kv patch secret/unfold-cluster/vars ETCD_BACKUP_CHECK=enabled`, and wait for the bridge. Actions → `etcd-backup-check` → **Run workflow** with input `no`: green, and the log names the snapshot and its age.
- [ ] **The restore check catches damage.** Run it again with input `corrupt`: it must fail, and the failing step must be the restore, not the download or a missing secret. A check that has only ever passed proves nothing.

When every box is ticked, Flux owns everything under `kubernetes/`, and changes reach the cluster only as signed commits on `main`.
