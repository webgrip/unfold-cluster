# Runbook: the infra workflow

How a change in `infra/` reaches Hetzner, why an apply run sometimes stops with a new plan digest, and how the worker pools and their tailnet keys work. The [bootstrap checklist](../bootstrap-checklist.md) is the first-time order; this page is for every run after it.

## The three modes

`.forgejo/workflows/infra.yml`, job `plan-or-apply` (or `diagnose`), runs on the repository-scoped runner `unfold-infra` and reads its credentials from OpenBao per run.

| Mode | Started by | Changes at Hetzner | Tailnet keys |
| --- | --- | --- | --- |
| plan-only | every push to `main` that touches `infra/`, or Actions → `infra` → **Run workflow** with `plan-only` | nothing | read only, once; an unreachable Headscale gives an empty answer |
| apply | **Run workflow** with `apply` and the `plan_digest` of the run whose plan you read | what the plan shows, and only if this run's own plan has that digest | may be made (`UNFOLD_TAILNET_MINT=allowed`), with retries for 25 minutes |
| diagnose | **Run workflow** with `diagnose` | nothing, no plan | none |

A pull request runs `infra-check` instead: `tofu fmt -check`, `tofu validate` and `tofu test` against mocked providers, without any credential. No plan exists until the change is on `main`.

The digest is the SHA-256 of `tofu show -no-color` of the plan. An apply run plans again, from scratch, and refuses to apply unless that new plan's digest equals the one you pasted. It then prints its own digest: `the plan changed since it was reviewed; read this run's plan and dispatch again with its digest (...)`.

## When the apply run's digest differs from the run you read

Something other than the code changed between the two plans. Read the new run's plan: it must create, change and destroy the same resources as the one you read. If it does, dispatch again with its digest. If it does not, stop and find out why.

Two causes are expected, and both settle after one extra dispatch:

1. **The Talos snapshot was built by the apply run.** Plan-only runs never build it, so before the first build their plan shows the image `talos-snapshot-is-built-by-the-apply-run`; the apply run builds it before planning and plans the numeric snapshot id. The snapshot exists from then on.
2. **The apply run minted a tailnet key.** A plan-only run only reads keys from `unfold-headscale`. An apply run may make one before it plans: the control planes' `tag:cp` key when it is missing or has 45 days or fewer left, and a worker's `tag:node` key when none was made for that worker's key slot yet (see [Worker tailnet keys](#worker-tailnet-keys)). The key itself is sensitive and never printed, but two things derived from it are in the plan text: whether the `input` of `terraform_data.*_tailnet_key` shows as changed, and the `machine_configuration_hash` of `talos_machine_configuration_apply.*`, which Talos computes over a machine config that embeds the key. So when a key resource is created or replaced in that plan, the plan-only run planned it with the key it could read (often none) and the apply run with the key it just made, and the digests differ. The key now exists on `unfold-headscale`, so the next apply run reads the same key and plans the same digest.

   Seen on 2026-10-25 with the bump of `tailnet_key_generation`: the plan-only run on `main` printed `e0293ce5…`, the first apply run `ae310573…` with the same eight resources, and the second apply run `ae310573…` again, which applied.

   It does not happen when a key resource is not created or replaced: `terraform_data` ignores later changes to its `input`, so a running node keeps the key it was created with. Nor does it happen for a server created in the same apply: its server id is unknown until Hetzner creates it, so both runs plan its key as read during the apply.

Anything else that changes between two runs, such as a Renovate merge, another pull request, or a resource changed outside OpenTofu, also changes the digest; that is what the gate is for.

## Worker pools

`var.worker_pools` in `infra/variables.tf` lists the fixed worker pools OpenTofu creates. Each pool has:

| Field | Meaning |
| --- | --- |
| `server_type` | Hetzner type, x86 only (CAX is refused) |
| `node_count` | nodes in the pool, at most ten |
| `name_prefix` | nodes are `name_prefix-1`, `-2`, ... |
| `first_host` | the pool's block of ten private addresses in `10.64.0.0/24`: 21 to 30, 31 to 40, ... |
| `labels`, `taints` | Kubernetes node labels and taints, set by Talos (`KubeNodeConfig`), taint value as `value:Effect` |

| Pool | Nodes | Type | Address | Label and taint | Runs |
| --- | --- | --- | --- | --- | --- |
| `unfold` | `unfold-app-1` | CX33 | `10.64.0.21` | `node.webgrip.io/pool=unfold`, `:NoSchedule` | Unfold, ploegd and their databases |
| `ci` | `unfold-ci-1` | CX43 (8 vCPU, 16 GB) | `10.64.0.31` | `node.webgrip.io/pool=ci`, `:NoSchedule` | CI jobs under gVisor (RFC 0001 step 13) |

The variable's validation refuses a pool whose `node.webgrip.io/pool` label is not its own name, two pools in one address block, and two pools with one name prefix. Every worker boots from the same snapshot (`talos/schematics/cloud.yaml`), joins the tailnet with its own single-use `tag:node` key, sits behind the `unfold-nodes` firewall, and carries delete protection and `prevent_destroy`. Removing a node is therefore a deliberate code change, not a smaller `node_count`.

Nodes a cluster-autoscaler adds later are not in this variable: the autoscaler creates them through the Hetzner API from the same snapshot and the worker machine config.

### gVisor on the CI pool

The cloud schematic already carries `siderolabs/gvisor`, so every cloud node, the CI node included, has containerd's `runsc` handler; no separate snapshot is needed. The OpenTofu test `the_snapshot_every_worker_boots_carries_gvisor` fails if the extension leaves the schematic. `kubectl get node unfold-app-1 -o jsonpath='{.status.runtimeHandlers[*].name}'` listed `runc runsc runsc-kvm` on 2026-10-25.

Flux installs the RuntimeClass `gvisor` (handler `runsc`) from `kubernetes/platform/gvisor`. Its `scheduling` adds the node selector `node.webgrip.io/pool: ci` and the matching toleration to every pod that names it, so a pod with `runtimeClassName: gvisor` lands only on the CI pool and needs no placement of its own. A pod without it cannot land there, because of the taint.

### Adding a node or a pool

1. Raise `node_count`, or add a pool with its own `first_host` block and its own `node.webgrip.io/pool` label. A new server costs money: get the owner's approval first.
2. `tofu test` in `infra/` must pass; the pull request's `infra-check` runs it.
3. After the merge, the plan-only run on `main` must show, per new node, `hcloud_server.worker["<name>"]`, `terraform_data.worker_tailnet_key["<name>"]` and `talos_machine_configuration_apply.worker["<name>"]` to add, `data.external.worker_tailnet_key["<name>"]` read during apply, and nothing changed or destroyed.
4. Apply with that digest. The run creates the server, mints its key on `unfold-headscale`, applies its machine config, and the node registers with its label and taint.

## Worker tailnet keys

`unfold-headscale` makes one single-use `tag:node` key per key slot and keeps it in `/var/lib/unfold-tailnet/workers/<slot>.authkey`; asked again for the same slot, it returns the stored key, even after it has expired (24 hours). The script on the server is written by cloud-init and changes only with a new Headscale server, so OpenTofu chooses the slot: the worker's Hetzner server id followed by the eight digits of `tailnet_key_generation` (server `123456`, generation `2026-10-25` asks for `worker 12345620261025`). The digits are a fixed width, so two servers never share a slot.

So a worker gets a fresh key whenever it needs one:

* **A new server** has a new id, so a new slot, and its key is minted in the apply that creates it.
* **A generation bump** replaces every `terraform_data.worker_tailnet_key` and asks every worker for the slot of the new generation, which is empty, so each gets a newly minted key instead of the expired one stored for the previous generation. Until the CI pool change the slot was the server id alone, and a bump handed the worker its old, expired key.
* **An apply that failed after the server was created** and is retried more than 24 hours later finds the key in the state expired, and the node cannot join (`ext-tailscale` logs an invalid or expired auth key). Bump `tailnet_key_generation` to today's date in a pull request; its apply gives that node a fresh key. Expect the digest to change once on that apply (cause 2 above).

A running node never needs its key again: Talos joins once (`TS_AUTH_ONCE=true`) and tagged nodes do not expire, so a bump re-applies the machine configs without disturbing the tailnet.

The first apply after this scheme landed made one unused key for `unfold-app-1`, in the slot of generation `2026-10-25`. It expires unused after 24 hours.

## Disk-encryption runs

Adding a running cloud node to `disk_encryption_nodes` makes the next apply wipe and re-install it with LUKS2 volumes ([disk encryption](../disk-encryption.md)). Every plan, plan-only included, runs `scripts/guard-encryption-rollout.sh` after the digest: it prints `this plan wipes and re-installs <node>` when the plan does, and fails the run when the plan would re-install two running nodes. Read that line next to the digest before you dispatch the apply.

The apply run installs `talosctl` and `kubectl` and writes the cluster's talosconfig before applying, for `scripts/encrypt-node.sh`. Its output shows each step (`guard passed`, `drained`, `left etcd`, `reset`, `in maintenance mode`, `volumes unlocked`, `Node Ready`, `rejoined`). If it stops:

- **at the guard**: a node is not Ready, etcd lacks a member, or the KMS does not answer. Nothing was touched. Run `diagnose`, fix the cause, dispatch again.
- **at the drain**: the node is uncordoned and untouched; a PodDisruptionBudget or a stuck pod held it. Fix that and dispatch again.
- **after the reset**: the node is wiped. Dispatch the apply again with the new digest; `terraform_data.disk_encryption_reinstall` was tainted, finds the node in maintenance mode, and the config apply and rejoin carry on. Do not start another node before `diagnose` shows this one `luks2` and Ready, and etcd with three members.
