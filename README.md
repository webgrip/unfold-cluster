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

Two manual workflow runs, with one manual step between them:

1. **First apply.** With no `TAILSCALE_AUTHKEY` set, OpenTofu creates only the network, the firewalls and `unfold-headscale`, a small server running Headscale, the self-hosted coordination server of the admin tailnet. No cluster node exists yet.
2. **Between the runs, by hand.**
   1. In Cloudflare, create an A record for `headscale.webgrip.dev` pointing at the `headscale_ipv4` output, **DNS only** (grey cloud), because Headscale serves its own TLS and Tailscale's protocol does not pass Cloudflare's proxy.
   2. Wait until `https://headscale.webgrip.dev/health` answers; Headscale fetches its certificate from Let's Encrypt on first contact.
   3. Make the tailnet key:
      ```sh
      ssh admin@headscale.webgrip.dev
      sudo headscale users create nodes
      sudo headscale users create ryan
      sudo headscale users list
      sudo headscale preauthkeys create --user <ID of nodes from the list> --reusable --tags tag:node --expiration 2160h
      ```
   4. Store the key as the repository secret `TAILSCALE_AUTHKEY`, and in the password manager.
   5. Build the Talos snapshot from `talos/schematics/cloud.yaml` and set `TALOS_SNAPSHOT_ID`.
3. **Second apply.** OpenTofu creates the four cluster nodes, generates the cluster's Talos secrets, applies the machine configs, joins every node to the tailnet and bootstraps etcd. Talos installs Cilium, Hetzner's cloud controller, the Flux operator, a Flux instance, and a GitRepository that reconciles `kubernetes/clusters/main` from the public GitHub mirror only when the newest commit carries a trusted signature.
4. From then on Flux owns everything under `kubernetes/`. The recovery set (the Flux operator and controllers, and the storage driver's controller) tolerates and is pinned to the control planes, as on the homelab: the only worker is reserved for Unfold, and the AX41 joins later.

The Kubernetes API sits on `10.64.0.10`, a Hetzner alias IP on the private network that Talos moves between control planes through the Hetzner API (`HCloudVIPConfig` on link `enp7s0`, Hetzner's name for the first private NIC on CPX servers). It costs nothing and is reachable only inside the network. The control planes advertise the cloud subnet `10.64.0.0/24` to the tailnet, and the tailnet policy approves that route automatically, so the admin kubeconfig from `tofu output -raw kubeconfig` works from any admin device.

Admins reach the nodes over the tailnet: install Tailscale and run `tailscale up --login-server=https://headscale.webgrip.dev`, then approve the device with `sudo headscale nodes register` on the Headscale server. The tailnet uses Headscale's own relay; no Tailscale-run service is in the path.

## Only signed commits deploy

Flux applies whatever is on the GitHub mirror's `main`, so a push made straight to GitHub would otherwise reach production. Flux therefore checks the signature of the commit it is about to apply (`verify.mode: HEAD`) and refuses anything not signed by a key in `infra/trusted-signers/`:

| Key | Signs |
| --- | --- |
| `ryan.sshpub` | the owner's own commits |
| `forgejo.sshpub` | every pull request merge, signed by Forgejo's instance key (published at `/api/v1/signing-key.ssh`) |

A refused commit leaves the cluster on the last verified one and marks the GitRepository not ready. Renovate's own commits are unsigned, so they reach `main` only through a pull request merge, which Forgejo signs; Renovate must never push straight to `main` here. Adding a person or bot means adding their public key file and running an apply, because the keys reach the cluster through a Talos inline manifest.

## Security floor from the first boot

* **Pod Security `restricted`** is the API server's default for every namespace; Talos exempts `kube-system`, where Cilium and the storage node plugin need host access.
* **Default-deny networking**: a Cilium clusterwide policy denies all ingress and egress for every pod outside `kube-system` and `flux-system`, except DNS. A workload's namespace adds its own allow policy.
* **Pinned, approved images**: a native ValidatingAdmissionPolicy refuses any pod outside `kube-system` and `flux-system` whose images are not pinned by digest or come from a registry not on the list.
* **Pod traffic between nodes is encrypted** with Cilium's WireGuard, so nothing crosses Hetzner's private network or the vSwitch in clear text.
* **Hubble relay** runs, so `hubble observe --verdict DROPPED` shows what default-deny refused.

## Tailnet policy

`infra/templates/headscale-acl.hujson` is Headscale's access policy:

* devices of the Headscale user `ryan` form `group:admin` and may reach everything on the tailnet, including the routed cloud subnet;
* cluster nodes join with a key tagged `tag:node` and may start no connection to anyone; they only answer;
* only `10.64.0.0/24`, the cloud subnet with the control planes, the API address and the Unfold node, is routed into the tailnet, and only when a `tag:node` device advertises it.

The node key expires after 90 days; renew it with the same command and update `TAILSCALE_AUTHKEY`. The policy is written once when the server is created; to change it later, copy the file to `/etc/headscale/acl.hujson` and run `sudo systemctl reload headscale`.

## Machines

| Node | Hetzner type | Private address | Role |
| --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CPX22 | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CPX32 | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
| `unfold-headscale` | Cloud CPX02 | public only | Headscale, the admin tailnet's coordination server and relay |
| `unfold-metal-1` | Robot AX41 | `10.64.1.31` on the vSwitch | agent Runs and CI, both under Kata; not in `infra/` yet |

The AX41 is ordered once by hand in Robot. Its vSwitch id then goes into `vswitch_id`, which adds the vSwitch subnet to the Cloud Network. Its VLAN interface uses MTU 1400, the smallest link in the cluster, so Cilium's `MTU` is set to 1400; Cilium subtracts its VXLAN (50 bytes) and WireGuard (80 bytes) overhead itself, leaving pods 1270.

Pods get addresses from `10.65.0.0/16` and Services from `10.66.0.0/16`, and Cilium runs as cluster `unfold-main` with ID 2, as the [address plan](docs/rfc/0001-security-architecture.md#address-plan) allocates them for ClusterMesh. None of these can change once the cluster exists.

## How changes reach Hetzner

Pull requests and pushes to `main` that touch `infra/` run `tofu plan` only; nothing is created. Applying is a separate, deliberate step: in Forgejo, Actions → `infra` → **Run workflow** on `main`, with the input set to `apply`. That run makes a fresh plan and applies exactly that plan, so read the plan of the latest `main` run first. Every server carries `prevent_destroy`, so a plan that would replace one fails instead.

The workflow needs, on this repository in Forgejo:

| Kind | Name | Holds |
| --- | --- | --- |
| secret | `HCLOUD_TOKEN` | Hetzner Cloud API token for OpenTofu in CI, read and write |
| secret | `HCLOUD_TOKEN_CLUSTER` | a second token, for the cloud controller and CSI driver in `kube-system`; set before the second apply |
| secret | `HCLOUD_TOKEN_VIP` | a third token, for the control planes to move the API address; set before the second apply |
| secret | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | credentials for the state bucket |
| secret | `STATE_PASSPHRASE` | at least 32 characters; encrypts the state and plans, which hold the Talos secrets |
| variable | `STATE_BUCKET`, `STATE_ENDPOINT`, `STATE_REGION` | the state bucket on the off-site Garage: `unfold-cluster-tfstate`, `https://s3-offsite.webgrip.dev`, `garage` |
| variable | `TALOS_SNAPSHOT_ID` | the Hetzner snapshot built from `talos/schematics/cloud.yaml` |
| variable | `ADMIN_CIDRS` | a JSON list of addresses allowed to reach the Talos and Kubernetes APIs, e.g. `["203.0.113.7/32"]`; it must include the address the Forgejo runners leave from |
| variable | `ADMIN_SSH_PUBLIC_KEY` | the owner's SSH public key, the only way into the Headscale server |
| secret | `TAILSCALE_AUTHKEY` | the reusable Headscale pre-auth key; leave unset for the first apply |
| secret | `ETCD_BACKUP_WRITE_ACCESS_KEY`, `ETCD_BACKUP_WRITE_SECRET_KEY` | the Garage key the cluster writes etcd snapshots with: write on `unfold-cluster-etcd`, no read |
| variable | `ETCD_BACKUP_AGE_RECIPIENT` | the age public key snapshots are encrypted to |

Without the secrets and variables other than `TAILSCALE_AUTHKEY` and `TALOS_SNAPSHOT_ID`, the workflow stops before `init`. Garage ignores S3 conditional writes, so OpenTofu's lock file cannot be trusted there; the workflow's `concurrency` group is what keeps two runs from writing the state at once.

The workflow runs only on `unfold-infra`, a runner registered on this repository alone and on no other, so no other repository's job can land on the runner that holds these secrets. It runs one job at a time, each in a fresh pod that is deleted afterwards. The runner pool is defined in the homelab, in `kubernetes/apps/forgejo/forgejo-runner/app/infra/` of homelab-cluster.

## Credentials and rotation

Hetzner tokens cannot be narrowed below a whole project, so each job gets its own token and each can be revoked alone. Every server, the network and the Headscale address carry Hetzner's delete protection, so a stolen token cannot remove them in one call; removing one takes a deliberate change in this repository first.

| Credential | Where it lives | Rotate |
| --- | --- | --- |
| `HCLOUD_TOKEN` | Forgejo secret, password manager | every 6 months |
| `HCLOUD_TOKEN_CLUSTER` | Forgejo secret, encrypted state, Secret `kube-system/hcloud` | every 6 months, then apply |
| `HCLOUD_TOKEN_VIP` | Forgejo secret, encrypted state, control plane configs | every 6 months, then apply |
| `TAILSCALE_AUTHKEY` | Forgejo secret, encrypted state, node configs | expires after 90 days |
| `STATE_PASSPHRASE` | Forgejo secret, password manager | when someone with access leaves |
| State bucket keys | Forgejo secrets | every 6 months |
| GitHub mirror token | Forgejo mirror settings | at its expiry date |

Nothing outside `kube-system` and cluster admins may read Secrets in `kube-system`: no Role, ClusterRole or binding that grants it is added to this repository, and agents get no Kubernetes token at all.

## Backups and the restore check

Every six hours a CronJob in `etcd-backup` asks the Talos API for an etcd snapshot, encrypts it to `ETCD_BACKUP_AGE_RECIPIENT` and writes it to the `unfold-cluster-etcd` bucket on the off-site Garage ([kubernetes/platform/etcd-backup](kubernetes/platform/etcd-backup)). Talos gives the job one role, `os:etcd:backup`, and only in that namespace. The cluster's Garage key can write to the bucket but not read it, and the cluster never holds the age private key, so a compromised cluster cannot read its own backups.

A backup counts only once it has been restored. Every morning [etcd-backup-check](.forgejo/workflows/etcd-backup-check.yml) downloads the newest snapshot, fails if it is more than seven hours old, decrypts it, restores it with `etcdutl` into a throwaway etcd on the runner and reads `kube-system` and `flux-system` back out of it ([scripts/verify-etcd-snapshot.sh](scripts/verify-etcd-snapshot.sh)). Running it by hand with `corrupt` damages the snapshot first, and the run must fail; do that once after enabling the check, so the check is known to catch damage.

Set up once, before the second apply:

1. `age-keygen -o etcd-backup.age`; keep the file in the password manager with an offline copy. Its `# public key:` line goes into `ETCD_BACKUP_AGE_RECIPIENT`, the whole file into the secret `ETCD_BACKUP_AGE_IDENTITY`.
2. On the Garage: create the bucket `unfold-cluster-etcd` with a 30-day expiry lifecycle rule, one key with write only on it for the cluster (`ETCD_BACKUP_WRITE_*`), and one key with read only on it for the check (`ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY`).
3. After the first snapshot lands, set the variable `ETCD_BACKUP_CHECK` to `enabled`, run the check once normally and once with `corrupt`.

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

* **First boot to verify.** That Talos applies the Flux instance after the operator's CRDs exist, that Cilium's MTU is right on the vSwitch path, and that the private NIC is named `enp7s0` so the API VIP comes up, are proven only by the first apply.
* **CI is not on the tailnet.** OpenTofu still reaches the Talos API from the Forgejo runners over the internet, so `ADMIN_CIDRS` keeps the runners' address until CI joins the tailnet. Closing the firewall completely waits for that.
* **Backups share a datacentre.** The off-site Garage and the cluster are both in Hetzner's Falkenstein region, so a regional outage or a lost Hetzner account takes both. A second copy outside Hetzner, on the homelab Garage, is the next step.
* **A failed restore check alerts nobody yet.** It shows as a failed run in Forgejo; wiring failed scheduled runs into the homelab's alerting is still to do.
* **OpenBao** and the AX41 are not in the code yet.
