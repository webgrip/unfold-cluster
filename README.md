# unfold-cluster

The GitOps repository of Unfold's production cluster: a Talos cluster on Hetzner in the EU, with the owner's homelab as staging. The decisions behind it are [Unfold ADR-0040](https://forgejo.webgrip.dev/webgrip/unfold/src/branch/development/docs/adr/adr-0040-unfold-production-runs-on-a-rented-eu-talos-cluster-and-the-homelab-is-staging.md) and [Ploeg ADR-0107](https://github.com/ploeg-hq/ploeg/blob/development/docs/adrs/0107-execution-runs-in-cells-that-pull-from-one-hub.md).

This repository is public. Nothing secret is committed here, encrypted or not.

## Layout

| Path | What it holds | Applied by |
| --- | --- | --- |
| `infra/` | Hetzner Cloud resources, the Talos machine configs, the cluster bootstrap, and the manifests Talos installs at bootstrap: Cilium, Hetzner's cloud controller, the Flux operator and the Flux instance | OpenTofu, from `.forgejo/workflows/infra.yml` |
| `talos/` | Version pins and the Image Factory schematics for the cloud and metal nodes | read by people building snapshots and by Renovate |
| `kubernetes/clusters/main/` | Flux's entry for this cluster | Flux in the cluster |
| `kubernetes/platform/` | Platform components Flux owns: today the Hetzner CSI driver | Flux in the cluster |

## From nothing to GitOps

Two manual workflow runs, with one manual step between them. The owner's step-by-step version, with every secret, command and check in order, is [docs/bootstrap-checklist.md](docs/bootstrap-checklist.md).

1. **First apply.** With neither tailnet key set, OpenTofu creates only the network, the firewalls and `unfold-headscale`, a small server running Headscale, the self-hosted coordination server of the admin tailnet. No cluster node exists yet.
2. **Between the runs, by hand.**
   1. In Cloudflare, create an A record for `headscale.webgrip.dev` pointing at the `headscale_ipv4` output, **DNS only** (grey cloud), because Headscale serves its own TLS and Tailscale's protocol does not pass Cloudflare's proxy.
   2. Wait until `https://headscale.webgrip.dev/health` answers; Headscale fetches its certificate from Let's Encrypt on first contact.
   3. Make the two tailnet keys, one for the control planes and a single-use one for the worker:

      ```sh
      ssh admin@headscale.webgrip.dev
      sudo headscale users create ryan
      sudo headscale preauthkeys create --reusable --tags tag:cp --expiration 2160h
      sudo headscale preauthkeys create --tags tag:node --expiration 24h
      ```

   4. Put the `tag:cp` key into OpenBao as `TAILSCALE_AUTHKEY_CONTROL_PLANE` and the `tag:node` key as `TAILSCALE_AUTHKEY`, both at `secret/unfold-cluster/tailnet`, and set `CLUSTER_NODES` to `enabled` at `secret/unfold-cluster/vars`, which tells the workflow to read the keys. The worker key is spent when the worker joins, so make it just before the second apply.
   5. Build the Talos snapshot with `scripts/build-talos-snapshot.sh`, which turns `talos/schematics/cloud.yaml` and the version in `talos/talenv.yaml` into a Hetzner snapshot and prints its id, and put that id into OpenBao as `TALOS_SNAPSHOT_ID` at `secret/unfold-cluster/vars`, from where the bridge sets the repository variable.
3. **Second apply.** OpenTofu creates the four cluster nodes, generates the cluster's Talos secrets, applies the machine configs, joins every node to the tailnet and bootstraps etcd. Talos installs Cilium, Hetzner's cloud controller, the Flux operator, a Flux instance, and a GitRepository that reconciles `kubernetes/clusters/main` from the public GitHub mirror only when the newest commit carries a trusted signature.
4. From then on Flux owns everything under `kubernetes/`. The recovery set (the Flux operator and controllers, and the storage driver's controller) tolerates and is pinned to the control planes, as on the homelab: the only worker is reserved for Unfold, and the AX41 joins later.

The Kubernetes API sits on `10.64.0.10`, a Hetzner alias IP on the private network that Talos moves between control planes through the Hetzner API (`HCloudVIPConfig` on the link alias `private0`; each control plane's machine config points that alias at the MAC address Hetzner reports for the server's private NIC, so the VIP does not depend on how a server type names its interfaces). It costs nothing and is reachable only inside the network. The control planes advertise the cloud subnet `10.64.0.0/24` to the tailnet, and the tailnet policy approves that route automatically, but only from a `tag:cp` device, so the admin kubeconfig from `tofu output -raw kubeconfig` works from any admin device.

Admins reach the nodes over the tailnet: install Tailscale and run `tailscale up --login-server=https://headscale.webgrip.dev`, then approve the device with `sudo headscale nodes register` on the Headscale server. The tailnet uses Headscale's own relay; no Tailscale-run service is in the path.

## Only signed commits deploy

Flux applies whatever is on the GitHub mirror's `main`, so a push made straight to GitHub would otherwise reach production. Flux therefore checks the signature of the commit it is about to apply (`verify.mode: HEAD`) and refuses anything not signed by a key in `infra/trusted-signers/`:

| Key | Signs |
| --- | --- |
| `ryan.sshpub` | the owner's own commits |

A refused commit leaves the cluster on the last verified one and marks the GitRepository not ready. Forgejo's instance key is deliberately not trusted: it signs merges and web edits in every repository on the instance, so any user who can create a repository could get an arbitrary tree signed by it. Pull requests, Renovate's included, are therefore not merged with the button; the owner merges them locally with a signed merge commit and pushes:

```sh
git fetch origin && git switch main && git pull --ff-only
git merge --no-ff -S origin/<branch>
git push origin main
```

A merge made with the button, or Renovate pushing straight to `main`, is unsigned by a trusted key, so Flux refuses it and the cluster stays where it is. Adding a person or bot means adding their public key file and running an apply, because the keys reach the cluster through a Talos inline manifest.

Verification checks only the newest commit, so it does not stop a rollback: a force-push of an older signed commit to the mirror would deploy. The GitHub mirror's `main` therefore needs branch protection that refuses force-pushes and deletion and allows pushes only from the mirror's token. That setting lives in GitHub, not here.

## Security floor from the first boot

* **Pod Security `restricted`** is the API server's default for every namespace; Talos exempts `kube-system`, where Cilium and the storage node plugin need host access.
* **Default-deny networking**: a Cilium clusterwide policy denies all ingress and egress for every pod outside `kube-system` and `flux-system`, except DNS. A workload's namespace adds its own allow policy.
* **Pinned, approved images**: a native ValidatingAdmissionPolicy refuses any pod outside `kube-system` and `flux-system` whose images, debug containers or image volumes are not pinned by digest or do not come from a repository on its `allowedPrefixes` list (today only `ghcr.io/siderolabs/`); a new workload adds its own prefix. The components in the two exempt namespaces (Cilium, the cloud controller, the CSI driver, the Flux operator and controllers) are pinned by digest in their chart values instead, and Flux at an exact version.
* **Pod traffic between nodes is encrypted** with Cilium's WireGuard. Traffic between the nodes themselves and from host-network pods is not (`nodeEncryption` is off), so it relies on each protocol's own TLS: etcd, the API server and the kubelet all use it.
* **Hubble relay** runs, so `hubble observe --verdict DROPPED` shows what default-deny refused.

## Tailnet policy

`infra/templates/headscale-acl.hujson` is Headscale's access policy:

* devices of the Headscale user `ryan` form `group:admin` and may reach everything on the tailnet, including the routed cloud subnet;
* control planes join with a key tagged `tag:cp`, workers with a single-use key tagged `tag:node`; neither may start a connection to anyone, they only answer;
* only `10.64.0.0/24`, the cloud subnet with the control planes, the API address and the Unfold node, is routed into the tailnet, and only when a `tag:cp` device advertises it. A worker's key, read from a compromised worker, can neither register more devices nor take over that route.

The control-plane key expires after 90 days; renew it with the same command and update `TAILSCALE_AUTHKEY_CONTROL_PLANE`. Each new worker gets a fresh single-use key in `TAILSCALE_AUTHKEY`. Nodes log in only when they are not already logged in (`TS_AUTH_ONCE`), so a spent or expired key does not knock a running node off the tailnet. The policy is written once when the server is created; to change it later, check it with `sudo headscale policy check -f <file>`, copy it to `/etc/headscale/acl.hujson`, run `sudo systemctl reload headscale`, and confirm with `sudo headscale nodes list-routes` that the route is approved only on control planes.

The Headscale server installs Ubuntu security updates at 04:00 UTC and reboots at 04:30 UTC when one needs it. Headscale itself is not covered: a Renovate bump of `headscale_version` is installed by hand. Both reach only a newly created server, because cloud-init runs once.

## Machines

| Node | Hetzner type | Size | Private address | Role |
| --- | --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CX23 | 2 vCPU, 4 GB, 40 GB | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CX33 | 4 vCPU, 8 GB, 80 GB | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
| `unfold-headscale` | Cloud CX23 | 2 vCPU, 4 GB, 40 GB | public only | Headscale, the admin tailnet's coordination server and relay |
| `unfold-metal-1` | Robot AX41 | | `10.64.1.31` on the vSwitch | agent Runs and CI, both under Kata; not in `infra/` yet |

The cloud servers are Hetzner's cost-optimized CX line, chosen on 2026-10-24 because the 2026 price rises made the CPX line (AMD, regular performance) three to four times the price. CX servers run on shared Intel or AMD x86 hosts and Hetzner limits how many it sells, so a create can fail with the type unavailable; `location` can then move to `nbg1`. They must stay x86, because the Talos snapshot and the Headscale package are amd64: Arm CAX types are refused by the variables' validation.

### What the cloud servers cost

| Node | Type | Per month | Per hour |
| --- | --- | --- | --- |
| `unfold-cp-1` | CX23 | €5.99 | €0.0096 |
| `unfold-cp-2` | CX23 | €5.99 | €0.0096 |
| `unfold-cp-3` | CX23 | €5.99 | €0.0096 |
| `unfold-app-1` | CX33 | €8.99 | €0.0144 |
| `unfold-headscale` | CX23 | €5.99 | €0.0096 |
| **Total** | | **€32.95** (€39.87 with 21% VAT) | |

Hetzner list prices of 2026-10-23, checked on 2026-10-24 at [hetzner.com/cloud/cost-optimized](https://www.hetzner.com/cloud/cost-optimized/), excluding VAT, each including the server's public IPv4 address. Billing is hourly up to the monthly price, from creation until deletion, whether the server runs or not. The Cloud Network, the placement group and the alias IP of the API address cost nothing; the Talos snapshot is billed per GB stored. The same five servers on the CPX line (CPX22, CPX32, CPX02) list at €102.45 a month. The AX41 and object storage are not in this table.

The AX41 is ordered once by hand in Robot. Its vSwitch id then goes into `vswitch_id`, which adds the vSwitch subnet to the Cloud Network. Its VLAN interface uses MTU 1400, the smallest link in the cluster, so Cilium's `MTU` is set to 1400; Cilium subtracts its VXLAN (50 bytes) and WireGuard (80 bytes) overhead itself, leaving pods 1270.

Pods get addresses from `10.65.0.0/16` and Services from `10.66.0.0/16`, and Cilium runs as cluster `unfold-main` with ID 2, as the [address plan](docs/rfc/0001-security-architecture.md#address-plan) allocates them for ClusterMesh. None of these can change once the cluster exists.

## How changes reach Hetzner

Pull requests that touch `infra/` run only `fmt` and `validate`, on the shared `docker` runner and without any secret: a branch can change the Terraform code, so a plan on a branch would hand that code every production credential. Pushes to `main` run `tofu plan`; nothing is created, and the run prints a `plan digest`.

Applying is a separate, deliberate step. Read the plan of a run on `main` and copy its digest. Then in Forgejo, Actions → `infra` → **Run workflow** on `main`, with `apply` chosen in the dropdown and that digest in `plan_digest`. The run makes a fresh plan and applies it only if its digest matches the one you read; otherwise it stops and prints its own, so read that run's plan and dispatch again. Every server carries `prevent_destroy`, so a plan that would replace one fails instead.

The owner puts every value into the homelab's OpenBao; nobody types one into Forgejo. The credentials never become Forgejo secrets: each run that needs them proves who it is with its Forgejo OIDC token and reads them from OpenBao itself, through the shared `openbao-read` action, as homelab-cluster ADR-0061 lays out. OpenBao's role `ci-unfold-cluster` answers only a token for this repository, on `refs/heads/main`, from a push, the schedule or a manual run, so neither a pull request nor a workflow added on a branch can read them. Only the plain variables are still copied onto this repository, by the homelab CronJob `forgejo-actions-secrets` (in `kubernetes/apps/forgejo/forgejo-actions-secrets` of homelab-cluster, hourly at minute 23). The order and commands are in the [bootstrap checklist](docs/bootstrap-checklist.md).

| Reaches the workflow as | Name | OpenBao path | Holds |
| --- | --- | --- | --- |
| OpenBao read per run | `HCLOUD_TOKEN` | `secret/hetzner/unfold-tofu` | Hetzner Cloud API token for OpenTofu in CI, read and write |
| OpenBao read per run | `HCLOUD_TOKEN_CLUSTER` | `secret/hetzner/unfold-cluster` | a second token, for the cloud controller and CSI driver in `kube-system`; set before the second apply |
| OpenBao read per run | `HCLOUD_TOKEN_VIP` | `secret/hetzner/unfold-vip` | a third token, for the control planes to move the API address; set before the second apply |
| OpenBao read per run | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | `secret/unfold-cluster/tofu-state` | credentials for the state bucket |
| OpenBao read per run | `STATE_PASSPHRASE` | `secret/unfold-cluster/tofu-state` | at least 32 characters; encrypts the state and plans, which hold the Talos secrets |
| variable | `STATE_BUCKET`, `STATE_ENDPOINT`, `STATE_REGION` | `secret/unfold-cluster/vars` | the state bucket on the off-site Garage: `unfold-cluster-tfstate`, `https://s3-offsite.webgrip.dev`, `garage` |
| variable | `TALOS_SNAPSHOT_ID` | `secret/unfold-cluster/vars` | the Hetzner snapshot `scripts/build-talos-snapshot.sh` builds from `talos/schematics/cloud.yaml` |
| variable | `ADMIN_CIDRS` | `secret/unfold-cluster/vars` | a JSON list of addresses allowed to reach the Talos and Kubernetes APIs, e.g. `["203.0.113.7/32"]`; it must include the address the Forgejo runners leave from |
| variable | `ADMIN_SSH_PUBLIC_KEY` | `secret/unfold-cluster/vars` | the owner's SSH public key, the only way into the Headscale server |
| OpenBao read per run | `TAILSCALE_AUTHKEY_CONTROL_PLANE` | `secret/unfold-cluster/tailnet` | the reusable `tag:cp` Headscale pre-auth key of the control planes; leave unset for the first apply |
| OpenBao read per run | `TAILSCALE_AUTHKEY` | `secret/unfold-cluster/tailnet` | the single-use `tag:node` Headscale pre-auth key of the next worker; leave unset for the first apply |
| OpenBao read per run | `ETCD_BACKUP_WRITE_ACCESS_KEY`, `ETCD_BACKUP_WRITE_SECRET_KEY` | `secret/unfold-cluster/etcd-backup` | the Garage key the cluster writes etcd snapshots with: write on `unfold-cluster-etcd`, no read |
| OpenBao read per run | `ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY`, `ETCD_BACKUP_AGE_IDENTITY` | `secret/unfold-cluster/etcd-backup` | the restore check's read-only Garage key and the age private key |
| variable | `ETCD_BACKUP_AGE_RECIPIENT`, `ETCD_BACKUP_CHECK` | `secret/unfold-cluster/vars` | the age public key snapshots are encrypted to; `enabled` once the first snapshot exists |
| variable | `CLUSTER_NODES` | `secret/unfold-cluster/vars` | `enabled` once both tailnet keys are in OpenBao; until then the workflow does not read them and creates no node |

A value missing from OpenBao stops the run at the read, naming the path and key; without the variables other than `TALOS_SNAPSHOT_ID`, `CLUSTER_NODES` and `ETCD_BACKUP_CHECK`, the workflow stops before `init`. Garage ignores S3 conditional writes, so OpenTofu's lock file cannot be trusted there; the workflow's `concurrency` group is what keeps two runs from writing the state at once.

The workflow runs only on `unfold-infra`, a runner registered on this repository alone and on no other, so no other repository's job can land on the runner these credentials are read on. The runner is not what keeps other branches of this repository out: Forgejo would hand repository secrets to a workflow a branch adds, which is why there are none, and OpenBao refuses any token not from `main`. It runs one job at a time, each in a fresh pod that is deleted afterwards. The runner pool is defined in the homelab, in `kubernetes/apps/forgejo/forgejo-runner/app/infra/` of homelab-cluster.

## Credentials and rotation

Hetzner tokens cannot be narrowed below a whole project, so each job gets its own token and each can be revoked alone. Every server, the network and the Headscale address carry Hetzner's delete protection, which slows down deletion but nothing else.

Treat every one of these tokens as the whole cluster. Any token can boot a node into rescue mode or image its disk, and neither protection stops that. Until the Talos partitions are encrypted (RFC 0001, disk encryption), the disk holds the cluster's certificate authorities and the key that encrypts Secrets in etcd in clear text. Two of the three tokens live inside the cluster: `HCLOUD_TOKEN_CLUSTER` in `kube-system`, and `HCLOUD_TOKEN_VIP` in every control plane's machine config. Encrypting the disks does not close this either if the key server runs in the same Hetzner project, because the same token can image the key server. It has to run where these tokens cannot reach it.

| Credential | Where it lives | Rotate |
| --- | --- | --- |
| `HCLOUD_TOKEN` | OpenBao `secret/hetzner/unfold-tofu` | every 6 months |
| `HCLOUD_TOKEN_CLUSTER` | OpenBao `secret/hetzner/unfold-cluster`, encrypted state, Secret `kube-system/hcloud` | every 6 months, then apply |
| `HCLOUD_TOKEN_VIP` | OpenBao `secret/hetzner/unfold-vip`, encrypted state, control plane configs | every 6 months, then apply |
| `TAILSCALE_AUTHKEY_CONTROL_PLANE` | OpenBao `secret/unfold-cluster/tailnet`, encrypted state, control plane configs | expires after 90 days |
| `TAILSCALE_AUTHKEY` | OpenBao `secret/unfold-cluster/tailnet`, encrypted state, worker configs | single use, made for each new worker |
| `STATE_PASSPHRASE` | OpenBao `secret/unfold-cluster/tofu-state`, password manager with an offline copy | when someone with access leaves |
| State bucket keys | OpenBao `secret/unfold-cluster/tofu-state` | every 6 months |
| etcd backup keys and age key | OpenBao `secret/unfold-cluster/etcd-backup`; the age key also in the password manager with an offline copy | Garage keys every 6 months; the age key when it may have leaked |
| GitHub mirror token | Forgejo mirror settings | at its expiry date |

A rotation is a new value in OpenBao (`bao kv patch`), which the next run reads, and an apply where the table says so. OpenBao runs in the homelab, so the values that cannot be made again, the state passphrase, the age key and the Talos secrets bundle, also stay in the password manager with an offline copy.

Nothing outside `kube-system` and cluster admins may read Secrets in `kube-system`: no Role, ClusterRole or binding that grants it is added to this repository, and agents get no Kubernetes token at all.

## Backups and the restore check

Every six hours a CronJob in `etcd-backup` asks the Talos API for an etcd snapshot, encrypts it to `ETCD_BACKUP_AGE_RECIPIENT` and writes it to the `unfold-cluster-etcd` bucket on the off-site Garage ([kubernetes/platform/etcd-backup](kubernetes/platform/etcd-backup)). Talos gives the job one role, `os:etcd:backup`, and only in that namespace. The cluster's Garage key can write to the bucket but not read it, and the cluster never holds the age private key, so a compromised cluster cannot read its own backups.

A backup counts only once it has been restored. Every morning [etcd-backup-check](.forgejo/workflows/etcd-backup-check.yml) downloads the newest snapshot, fails if it is more than seven hours old, decrypts it, restores it with `etcdutl` into a throwaway etcd on the runner and reads `kube-system` and `flux-system` back out of it ([scripts/verify-etcd-snapshot.sh](scripts/verify-etcd-snapshot.sh)). Running it by hand with `corrupt` damages the snapshot first, and the run must fail; do that once after enabling the check, so the check is known to catch damage.

Set up once, before the second apply:

1. `age-keygen -o etcd-backup.age`; keep the file in the password manager with an offline copy. Its `# public key:` line goes into `ETCD_BACKUP_AGE_RECIPIENT`, the whole file into `ETCD_BACKUP_AGE_IDENTITY`, both through OpenBao as in the [bootstrap checklist](docs/bootstrap-checklist.md#b4-put-every-value-into-openbao).
2. On the Garage: create the bucket `unfold-cluster-etcd` with a 30-day expiry lifecycle rule, one key with write only on it for the cluster (`ETCD_BACKUP_WRITE_*`), and one key with read only on it for the check (`ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY`). The commands are in [the bootstrap checklist](docs/bootstrap-checklist.md#b3-garage-buckets-and-keys).
3. After the first snapshot lands, set the variable `ETCD_BACKUP_CHECK` to `enabled` (`bao kv patch secret/unfold-cluster/vars ETCD_BACKUP_CHECK=enabled`, then the bridge's next run), run the check once normally and once with `corrupt`.

Persistent volumes are not in these snapshots; the Hetzner volumes and CNPG backups get their own when the first stateful workload arrives.

## Bootstrap secrets

The owner keeps these in a password manager with an offline copy, never in git:

1. the state passphrase; without it the state, and with it the Talos secrets, cannot be read;
2. the three Hetzner API tokens: CI's, the cluster's, and the API address's;
3. after the first apply, an export of the Talos secrets bundle: `tofu output -raw talos_machine_secrets`;
4. later, the OpenBao static-seal key, delivered through a Talos inline manifest when OpenBao is added.

The admin `talosconfig` and `kubeconfig` are read the same way, with `tofu output -raw talosconfig` and `tofu output -raw kubeconfig`, from a shell that has the state credentials and the passphrase.

## Security architecture

The target design for every layer, its threat model, the residual risks and the delivery order are in [RFC 0001](docs/rfc/0001-security-architecture.md). The confidential class and the next tier of measures are in [RFC 0002](docs/rfc/0002-confidential-class-and-next-tier.md).

## Open

* **First boot to verify.** That Talos applies the Flux instance after the operator's CRDs exist, that Cilium's MTU is right on the vSwitch path, and that the `private0` alias lands on the private NIC so the API VIP comes up, are proven only by the first apply.
* **CI is not on the tailnet.** OpenTofu still reaches the Talos API from the Forgejo runners over the internet, so `ADMIN_CIDRS` keeps the runners' address until CI joins the tailnet. Closing the firewall completely waits for that.
* **Backups share a datacentre.** The off-site Garage and the cluster are both in Hetzner's Falkenstein region, so a regional outage or a lost Hetzner account takes both. A second copy outside Hetzner, on the homelab Garage, is the next step.
* **A failed restore check alerts nobody yet.** It shows as a failed run in Forgejo; wiring failed scheduled runs into the homelab's alerting is still to do.
* **Headscale has no backup.** Losing the server loses the tailnet's keys and nodes; the APIs stay reachable from `ADMIN_CIDRS`, and a new server means re-registering every device.
* **Every Hetzner token reads every disk** until the Talos partitions are encrypted with a key server outside this Hetzner project (see [Credentials and rotation](#credentials-and-rotation)).
* **Two rules live outside this repository.** The GitHub mirror's ruleset `main: no rollback` refuses force-pushes and deletion of `main`, and OpenBao's role `ci-unfold-cluster` (homelab-cluster, `kubernetes/apps/security/openbao/bootstrap/config.sh`) decides who reads the credentials. A change to either is a change to this repository's security.
* **OpenBao** and the AX41 are not in the code yet.
