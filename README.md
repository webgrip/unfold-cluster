# unfold-cluster

The GitOps repository of Unfold's production cluster: a Talos cluster on Hetzner in the EU, with the owner's homelab as staging. The decisions behind it are [Unfold ADR-0040](https://forgejo.webgrip.dev/webgrip/unfold/src/branch/development/docs/adr/adr-0040-unfold-production-runs-on-a-rented-eu-talos-cluster-and-the-homelab-is-staging.md) and [Ploeg ADR-0107](https://github.com/ploeg-hq/ploeg/blob/development/docs/adrs/0107-execution-runs-in-cells-that-pull-from-one-hub.md).

This repository is public. Nothing secret is committed here, encrypted or not.

## Layout

| Path | What it holds | Applied by |
| --- | --- | --- |
| `infra/` | Hetzner Cloud resources: the Cloud Network, its vSwitch subnet, the firewall, three control planes and the Unfold worker | OpenTofu, from `.forgejo/workflows/infra.yml` |
| `talos/` | The node inventory, version pins, Image Factory schematics and machine-config patches | `talosctl`, rendered by the generator from homelab ADR-0062 |
| `kubernetes/platform/` | Cilium, Flux, cert-manager, Kyverno, External Secrets, OpenBao, CNPG, agent-sandbox, observability | Flux in the cluster |
| `kubernetes/apps/` | Unfold, Ploeg, LiteLLM, the demo, the CI runner pool | Flux in the cluster |
| `kubernetes/clusters/main/` | Flux's entry for this cluster | Flux in the cluster |

## Machines

| Node | Hetzner type | Private address | Role |
| --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CPX22 | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CPX32 | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
| `unfold-metal-1` | Robot AX41 | `10.64.1.31` on the vSwitch | agent Runs and CI, both under Kata |

The AX41 is ordered once by hand in Robot. Its vSwitch id then goes into `vswitch_id`, which adds the vSwitch subnet to the Cloud Network. Its VLAN interface uses MTU 1400.

## How changes reach Hetzner

A pull request that touches `infra/` runs `tofu plan`. A push to `main` runs `tofu apply` on the plan it just made. Every server carries `prevent_destroy`, so a plan that would replace one fails instead.

The workflow needs, on this repository in Forgejo:

| Kind | Name | Holds |
| --- | --- | --- |
| secret | `HCLOUD_TOKEN` | Hetzner Cloud API token, read and write, for the Unfold project |
| secret | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | Object Storage credentials for the state bucket |
| variable | `STATE_BUCKET`, `STATE_ENDPOINT` | the state bucket and its endpoint, e.g. `https://fsn1.your-objectstorage.com` |
| variable | `TALOS_SNAPSHOT_ID` | the Hetzner snapshot built from `talos/schematics/cloud.yaml` |

Without them the workflow stops before `init`.

## Bootstrap secrets

Three items exist before the cluster does. The owner keeps them in a password manager with an offline copy, never in git:

1. the Talos secrets bundle;
2. the Hetzner API token, which also enters the cluster through a Talos inline manifest for the cloud controller and CSI driver;
3. the OpenBao static-seal key, delivered the same way.

Everything else lives in the cluster's own OpenBao and reaches workloads through External Secrets.

## Open

* **Kubernetes API endpoint.** `talos/nodes.yaml` points at `unfold-cp-1` for now. Talos's Layer 2 VIP does not work on Hetzner Cloud; the choice is Talos's Hetzner floating-IP VIP or a private load balancer.
* **Talos snapshot.** Built from the cloud schematic with Hetzner's rescue system or `hcloud-upload-image`, then recorded as `TALOS_SNAPSHOT_ID`.
* **Storage Box** for backups is not in `infra/` yet.
