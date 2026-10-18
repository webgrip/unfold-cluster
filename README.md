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

One manual workflow run does all of it:

1. OpenTofu creates the network, firewall and four servers from the Talos snapshot. They boot into Talos maintenance mode.
2. OpenTofu generates the cluster's Talos secrets, applies a machine config to every node over the Talos API, and bootstraps etcd on `unfold-cp-1`.
3. Talos installs its inline manifests on the control planes: Cilium as the network, the Hetzner cloud controller with its API token, the Flux operator, and a Flux instance that reconciles `kubernetes/clusters/main` from the public GitHub mirror.
4. From then on Flux owns everything under `kubernetes/`. Cilium, the cloud controller and Flux itself are upgraded by changing their versions in `infra/bootstrap-manifests.tf` and applying.

## Machines

| Node | Hetzner type | Private address | Role |
| --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CPX22 | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CPX32 | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
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

Without them the workflow stops before `init`. Garage ignores S3 conditional writes, so OpenTofu's lock file cannot be trusted there; the workflow's `concurrency` group is what keeps two runs from writing the state at once.

## Bootstrap secrets

The owner keeps these in a password manager with an offline copy, never in git:

1. the state passphrase; without it the state, and with it the Talos secrets, cannot be read;
2. the Hetzner API token, which also reaches the cloud controller through a Talos inline manifest;
3. after the first apply, an export of the Talos secrets bundle: `tofu output -raw talos_machine_secrets`;
4. later, the OpenBao static-seal key, delivered through a Talos inline manifest when OpenBao is added.

The admin `talosconfig` and `kubeconfig` are read the same way, with `tofu output -raw talosconfig` and `tofu output -raw kubeconfig`, from a shell that has the state credentials and the passphrase.

## Open

* **Kubernetes API endpoint.** The cluster endpoint is `unfold-cp-1`'s private address. Talos's Layer 2 VIP does not work on Hetzner Cloud; the choice is Talos's Hetzner floating-IP VIP or a private load balancer.
* **First boot to verify.** That Talos applies the Flux instance after the operator's CRDs exist, and that Cilium's MTU is right on the vSwitch path, are proven only by the first apply.
* **Storage Box** for backups, **OpenBao**, and the AX41 are not in the code yet.
