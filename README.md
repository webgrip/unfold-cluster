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
      sudo headscale users list
      sudo headscale preauthkeys create --user <ID of nodes from the list> --reusable --expiration 8760h
      ```
   4. Store the key as the repository secret `TAILSCALE_AUTHKEY`, and in the password manager.
   5. Build the Talos snapshot from `talos/schematics/cloud.yaml` and set `TALOS_SNAPSHOT_ID`.
3. **Second apply.** OpenTofu creates the four cluster nodes, generates the cluster's Talos secrets, applies the machine configs, joins every node to the tailnet and bootstraps etcd. Talos installs Cilium, Hetzner's cloud controller, the Flux operator and a Flux instance that reconciles `kubernetes/clusters/main` from the public GitHub mirror.
4. From then on Flux owns everything under `kubernetes/`. The recovery set (the Flux operator and controllers, and the storage driver's controller) tolerates and is pinned to the control planes, as on the homelab: the only worker is reserved for Unfold, and the AX41 joins later.

The Kubernetes API sits on `10.64.0.10`, a Hetzner alias IP on the private network that Talos moves between control planes through the Hetzner API (`HCloudVIPConfig` on link `enp7s0`, Hetzner's name for the first private NIC on CPX servers). It costs nothing and is reachable only inside the network. The control planes advertise `10.64.0.0/16` to the tailnet; approve that route once with `sudo headscale nodes approve-routes` on the Headscale server, and the admin kubeconfig from `tofu output -raw kubeconfig` works from any tailnet device.

Admins reach the nodes over the tailnet: install Tailscale and run `tailscale up --login-server=https://headscale.webgrip.dev`, then approve the device with `sudo headscale nodes register` on the Headscale server. The tailnet uses Headscale's own relay; no Tailscale-run service is in the path.

## Machines

| Node | Hetzner type | Private address | Role |
| --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CPX22 | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CPX32 | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
| `unfold-headscale` | Cloud CPX02 | public only | Headscale, the admin tailnet's coordination server and relay |
| `unfold-metal-1` | Robot AX41 | `10.64.1.31` on the vSwitch | agent Runs and CI, both under Kata; not in `infra/` yet |

The AX41 is ordered once by hand in Robot. Its vSwitch id then goes into `vswitch_id`, which adds the vSwitch subnet to the Cloud Network. Its VLAN interface uses MTU 1400, which is why Cilium's MTU is 1350.

## How changes reach Hetzner

Pull requests and pushes to `main` that touch `infra/` run `tofu plan` only; nothing is created. Applying is a separate, deliberate step: in Forgejo, Actions → `infra` → **Run workflow** on `main`, with the input set to `apply`. That run makes a fresh plan and applies exactly that plan, so read the plan of the latest `main` run first. Every server carries `prevent_destroy`, so a plan that would replace one fails instead.

The workflow needs, on this repository in Forgejo:

| Kind | Name | Holds |
| --- | --- | --- |
| secret | `HCLOUD_TOKEN` | Hetzner Cloud API token, read and write, for the Unfold project |
| secret | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | credentials for the state bucket |
| secret | `STATE_PASSPHRASE` | at least 32 characters; encrypts the state and plans, which hold the Talos secrets |
| variable | `STATE_BUCKET`, `STATE_ENDPOINT`, `STATE_REGION` | the state bucket on the off-site Garage: `unfold-cluster-tfstate`, `https://s3-offsite.webgrip.dev`, `garage` |
| variable | `TALOS_SNAPSHOT_ID` | the Hetzner snapshot built from `talos/schematics/cloud.yaml` |
| variable | `ADMIN_CIDRS` | a JSON list of addresses allowed to reach the Talos and Kubernetes APIs, e.g. `["203.0.113.7/32"]`; it must include the address the Forgejo runners leave from |
| variable | `ADMIN_SSH_PUBLIC_KEY` | the owner's SSH public key, the only way into the Headscale server |
| secret | `TAILSCALE_AUTHKEY` | the reusable Headscale pre-auth key; leave unset for the first apply |

Without the secrets and variables other than `TAILSCALE_AUTHKEY` and `TALOS_SNAPSHOT_ID`, the workflow stops before `init`. Garage ignores S3 conditional writes, so OpenTofu's lock file cannot be trusted there; the workflow's `concurrency` group is what keeps two runs from writing the state at once.

## Bootstrap secrets

The owner keeps these in a password manager with an offline copy, never in git:

1. the state passphrase; without it the state, and with it the Talos secrets, cannot be read;
2. the Hetzner API token, which also reaches the cloud controller through a Talos inline manifest;
3. after the first apply, an export of the Talos secrets bundle: `tofu output -raw talos_machine_secrets`;
4. later, the OpenBao static-seal key, delivered through a Talos inline manifest when OpenBao is added.

The admin `talosconfig` and `kubeconfig` are read the same way, with `tofu output -raw talosconfig` and `tofu output -raw kubeconfig`, from a shell that has the state credentials and the passphrase.

## Open

* **First boot to verify.** That Talos applies the Flux instance after the operator's CRDs exist, that Cilium's MTU is right on the vSwitch path, and that the private NIC is named `enp7s0` so the API VIP comes up, are proven only by the first apply.
* **CI is not on the tailnet.** OpenTofu still reaches the Talos API from the Forgejo runners over the internet, so `ADMIN_CIDRS` keeps the runners' address until CI joins the tailnet. Closing the firewall completely waits for that.
* **Tailnet policy** is allow-all for now; an ACL file belongs on the Headscale server before anyone but the owner joins.
* **Storage Box** for backups, **OpenBao**, and the AX41 are not in the code yet.
