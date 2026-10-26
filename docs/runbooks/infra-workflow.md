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

One cause is expected, and it settles after one extra dispatch:

1. **The Talos snapshot was built by the apply run.** Plan-only runs never build it, so before the first build their plan shows the image `talos-snapshot-is-built-by-the-apply-run`; the apply run builds it before planning and plans the numeric snapshot id. The snapshot exists from then on.

### A minted tailnet key does not change the digest

A plan-only run only reads keys from `unfold-headscale`; an apply run may mint one before it plans (the control planes' `tag:cp` key when it is missing or has 45 days or fewer left, a worker's role key for a new key slot and tag, the gateway's key for a new generation). Until 2026-10-25 this changed the digest of every apply that minted: when a `terraform_data.*_tailnet_key` is created or replaced, the plan-only run planned it with no key, which `tofu show` leaves out, and the apply run with the minted key, which it shows as `+ input = (sensitive value)`. Runs 168 (`f2d6e3b4…`, plan-only) and 169/170 (`7b4800c2…`, apply) differed in that one line.

The digest is therefore not the SHA-256 of the raw `tofu show -no-color` text but of that text with two kinds of line left out, and only inside the blocks of `terraform_data.control_plane_tailnet_key`, `worker_tailnet_key` and `homelab_gateway_tailnet_key` (`scripts/plan-digest.sh`, `--normalized` prints the text it hashes):

* the `input` line, whose value the plan only ever shows as `(sensitive value)` or `null`, so the line says whether a key could be read, not which one;
* the `# (N unchanged attributes hidden)` count, which counts that same `input` when the stored key was read again.

Nothing a reviewer can see is lost: each key resource's header (created, replaced, destroyed) and its `triggers_replace` stay in the digest, and an `input` line of any other resource does too. A newly read or minted key never reaches the plan text anyway: the new `output` of a created or replaced key resource, and every machine config built from it, are `(known after apply)` in both runs. `scripts/test-plan-digest.sh` plans such resources with tofu, with no key, the stored key and a minted one, and fails if their digests differ or if a change outside those lines keeps the digest.

Letting plan-only runs mint was the other option. It was not taken: a push-triggered plan would then write to `unfold-headscale` and wait up to 25 minutes for it, and a key minted by a plan that is never applied is still a live single-use key.

Anything else that changes between two runs, such as a Renovate merge, another pull request, or a resource changed outside OpenTofu, also changes the digest; that is what the gate is for.

## A Hetzner 5xx during the plan

Hetzner's API sometimes answers a read with `internal server error (server_error)`, `Status code: 500` (run 171, refreshing `hcloud_primary_ip.headscale`). The Plan step runs `scripts/tofu-plan.sh`, which plans again when every error of a failed plan is a Hetzner 5xx: at most three attempts, 30 and 60 seconds apart, each announced as a `::warning::`. A rate limit (429), a configuration error, a failed postcondition, or a 5xx together with any of those ends the run at once.

Only the plan is retried. A plan changes nothing at Hetzner; the one thing an apply run's plan may write is a tailnet key on `unfold-headscale`, minted once per slot and read back on the next attempt. `tofu apply` of the saved plan is never retried: if it fails, read what it changed and dispatch a new apply. `scripts/test-tofu-plan.sh` checks the cases against a stubbed tofu.

The same script replaces every `hskey-auth-…` in the printed plan with `hskey-auth-<redacted>`. A plan that replaces a tailnet key resource shows its stored `output`, the key itself, in plain text, because `sensitive()` on `input` does not mark `output`; runs 165 and 166 printed the keys of the Headscale server they then replaced.

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

The variable's validation refuses a pool whose `node.webgrip.io/pool` label is not its own name, two pools in one address block, and two pools with one name prefix. Every worker boots from the same snapshot (`talos/schematics/cloud.yaml`), joins the tailnet with its own single-use key tagged with its pool's role ([node roles](#node-roles-on-the-tailnet)), sits behind the `unfold-nodes` firewall, and carries delete protection and `prevent_destroy`. Removing a node is therefore a deliberate code change, not a smaller `node_count`.

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

`unfold-headscale` makes one single-use key per key slot and role tag and keeps it in `/var/lib/unfold-tailnet/workers/<slot>-<role>.authkey`; asked again for the same slot and tag, it returns the stored key, even after it has expired (24 hours). OpenTofu chooses both. The slot is the worker's Hetzner server id followed by the eight digits of `tailnet_key_generation`; the tag is the worker pool's role from `tailnet_tag_by_pool` in `infra/headscale.tf` (server `123456` of the `unfold` pool, generation `2026-10-25` asks for `worker 12345620261025 tag:hub`). The digits are a fixed width, so two servers never share a slot, and a slot asked for under another role gets a new key, never the stored key of the earlier role.

So a worker gets a fresh key whenever it needs one:

* **A new server** has a new id, so a new slot, and its key is minted in the apply that creates it.
* **A generation bump** replaces every `terraform_data.worker_tailnet_key` and asks every worker for the slot of the new generation, which is empty, so each gets a newly minted key instead of the expired one stored for the previous generation. Until the CI pool change the slot was the server id alone, and a bump handed the worker its old, expired key.
* **An apply that failed after the server was created** and is retried more than 24 hours later finds the key in the state expired, and the node cannot join (`ext-tailscale` logs an invalid or expired auth key). Bump `tailnet_key_generation` to today's date in a pull request; its apply gives that node a fresh key, with the digest of the plan-only run on `main`.

A running node never needs its key again: Talos joins once (`TS_AUTH_ONCE=true`) and tagged nodes do not expire, so a bump re-applies the machine configs without disturbing the tailnet.

The first apply after this scheme landed made one unused key for `unfold-app-1`, in the slot of generation `2026-10-25`. It expires unused after 24 hours.

## Node roles on the tailnet

Every node joins with the tag of its role, and the Headscale policy (`infra/templates/headscale-acl.hujson`) lets each role open only the homelab gateway ports it needs:

| Tag | Nodes | Gateway ports | Why |
| --- | --- | --- | --- |
| `tag:cp` | the control planes | 8200, 8427, 9150 | External Secrets (OpenBao, 8200) runs only there, pinned to `node-role.kubernetes.io/control-plane`; KEDA (the CI job count, 9150) runs there until the system pool has a node |
| `tag:system` | pool `system` (ADR 0013, `node_count` 0 until stage S1) | 8427, 9150 | KEDA prefers this pool and reads the CI job count from here; no CI job or Run tolerates its taint, and it never reaches OpenBao |
| `tag:hub` | pool `unfold` (`unfold-app-1`) | 8427 | it runs untrusted CI jobs under gVisor, so it must not reach OpenBao |
| `tag:ci` | pool `ci` | 8427 | untrusted CI jobs |
| `tag:runs` | a future `runs` pool | 8427 | untrusted Runs |
| `tag:metal` | the metal node | 8427 | untrusted Runs under Kata and gVisor |

alloy-logs runs on every node's host network and, until the homelab copy is retired, ships that node's logs to 8427 as well as to the cluster's own VictoriaLogs, so every role keeps 8427; no role but `tag:cp` gets 8200, and only `tag:cp` and `tag:system`, where KEDA runs, get 9150. Nodes the cluster-autoscaler adds carry no Tailscale extension and are not on the tailnet at all. `tag:node`, the single tag every worker had before, is no longer defined: no key is minted with it, Headscale refuses to set it, and a node still carrying it reaches nothing. A new pool needs a line in `tailnet_tag_by_pool`, or the plan fails; the tag then gets its owner and port 8427 from the template. `infra/tests/tailnet_roles.tftest.hcl` pins all of this; `scripts/test-headscale-config.sh` runs the pinned Headscale against the rendered policy.

### How a running node takes its role

A key only decides a node's tag when the node logs in, and a running node never logs in again (`TS_AUTH_ONCE=true`, above). A `tailnet_key_generation` bump therefore does **not** re-tag anything: it writes a fresh key into each worker's machine config, which the running node ignores. So the apply sets the tags on the server instead: `terraform_data.tailnet_node_tag`, one per node, runs `unfold-tailnet-key nodes tag <node> <tag>` after the policy is pushed. It gives every Headscale node with that name exactly that tag (`headscale nodes tag`, which replaces the node's tags and refuses one the policy does not define), leaves a node that has it alone, and leaves a node that is not on the tailnet yet to the key it will join with. It runs again when a node's role changes or Headscale is replaced, and never replaces Headscale itself.

The apply that brought the roles in did this to each node:

* `unfold-headscale`: the apply installs the new `unfold-tailnet-key`, then pushes the new policy, which restarts Headscale once (seconds; connected nodes keep their tunnels).
* `unfold-cp-1` to `-3`: `nodes tag` finds `tag:cp` already set and changes nothing.
* `unfold-app-1`: `tag:node` becomes `tag:hub` in place. Between the policy restart and this step it is briefly a node with an undefined tag, which reaches nothing, so its log and metric writes fail for those seconds. No reboot, no new key in use, no new Headscale.
* The machine configs are not touched: the worker key requests change, but `terraform_data.worker_tailnet_key` keeps the key it holds (`ignore_changes`), so `talos_machine_configuration_apply` has nothing to do. The request for the new slot and tag does mint one `tag:hub` key for `unfold-app-1` that nothing uses; it expires after 24 hours.
* A later new or rebuilt node joins straight away with a key minted for its role.

Check after the apply, from a device on the tailnet: `ssh admin@headscale.webgrip.dev sudo headscale nodes list -o json | jq -r '.[] | "\(.given_name) \(.tags)"'` shows each node with its one role tag.

## Disk-encryption runs

Adding a running cloud node to `disk_encryption_nodes` makes the next apply wipe and re-install it with LUKS2 volumes ([disk encryption](../disk-encryption.md)). Every plan, plan-only included, runs `scripts/guard-encryption-rollout.sh` after the digest: it prints `this plan wipes and re-installs <node>` when the plan does, and fails the run when the plan would re-install two running nodes. Read that line next to the digest before you dispatch the apply.

The apply run installs `talosctl` and `kubectl` and writes the cluster's talosconfig before applying, for `scripts/encrypt-node.sh`. Its output shows each step (`guard passed`, `drained`, `left etcd`, `reset`, `in maintenance mode`, `volumes unlocked`, `Node Ready`, `rejoined`). If it stops:

- **at the guard**: a node is not Ready, etcd lacks a member, or the KMS does not answer. Nothing was touched. Run `diagnose`, fix the cause, dispatch again.
- **at the drain**: the node is uncordoned and untouched; a PodDisruptionBudget or a stuck pod held it. Fix that and dispatch again.
- **after the reset**: the node is wiped. Dispatch the apply again with the new digest; `terraform_data.disk_encryption_reinstall` was tainted, finds the node in maintenance mode, and the config apply and rejoin carry on. Do not start another node before `diagnose` shows this one `luks2` and Ready, and etcd with three members.
