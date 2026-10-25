# unfold-cluster

The GitOps repository of Unfold's production cluster: a Talos cluster on Hetzner in the EU, with the owner's homelab as staging. The decisions behind it are [Unfold ADR-0040](https://forgejo.webgrip.dev/webgrip/unfold/src/branch/development/docs/adr/adr-0040-unfold-production-runs-on-a-rented-eu-talos-cluster-and-the-homelab-is-staging.md) and [Ploeg ADR-0107](https://github.com/ploeg-hq/ploeg/blob/development/docs/adrs/0107-execution-runs-in-cells-that-pull-from-one-hub.md).

This repository is public. Nothing secret is committed here, encrypted or not.

## Layout

| Path | What it holds | Applied by |
| --- | --- | --- |
| `infra/` | Hetzner Cloud resources, the Talos machine configs, the cluster bootstrap, and the manifests Talos installs at bootstrap: Cilium and Hetzner's cloud controller (rendered from their `kubernetes/platform/` files), the Flux operator and the Flux instance | OpenTofu, from `.forgejo/workflows/infra.yml` |
| `talos/` | Version pins and the Image Factory schematics for the cloud and metal nodes | read by people building snapshots and by Renovate |
| `kubernetes/clusters/main/` | Flux's entry for this cluster | Flux in the cluster |
| `kubernetes/platform/` | Platform components Flux owns: Cilium, Hetzner's cloud controller and CSI driver, network and admission policy, the etcd backup, the removal of the kube-proxy Talos installed first, the roles people sign in to, the `gvisor` RuntimeClass | Flux in the cluster |
| `access/` | The OIDC kubeconfig people use daily; no secret in it | people, with `mise.toml`'s kubectl, kubelogin and k9s |

## From nothing to GitOps

One `infra` run with `apply` takes the Hetzner project from empty, or from today's state with only Headscale, to a running cluster that Flux owns. Nobody copies a key or an id between steps. What stays manual is listed, with the reason, in the [bootstrap checklist](docs/bootstrap-checklist.md#what-is-made-by-hand-and-why).

In that one run:

1. **The Talos snapshot.** Before planning, the run calls `scripts/build-talos-snapshot.sh`. It turns `talos/schematics/cloud.yaml` and the version in `talos/talenv.yaml` into a Hetzner snapshot labelled with that Talos version and schematic, or does nothing when a snapshot with those labels exists. OpenTofu then finds it with the `hcloud_images` data source by the same labels; no snapshot id is stored anywhere. Plan-only runs never build it, so before the first build their plan shows the image `talos-snapshot-is-built-by-the-apply-run`; an apply run refuses to create a node without the real snapshot. Because of the plan-digest gate, the first apply run plans the real snapshot where the run you read showed the placeholder, so it stops and prints its own digest; read that run's plan and dispatch again with it. The snapshot exists by then, so the second run plans the same and applies.
2. **Headscale.** OpenTofu creates `unfold-headscale`, a small server running Headscale, the self-hosted coordination server of the admin tailnet, on the primary IP `headscale_ipv4`. The A record for `headscale.webgrip.dev`, DNS only, is declared in homelab-cluster (`kubernetes/apps/network/cloudflare-dns/app/unfold-headscale.dnsendpoint.yaml`) and points at that address, which survives a rebuild of the server. cloud-init installs Headscale, creates the Headscale users `nodes` and the admin user, and installs `unfold-tailnet-key`, which makes the pre-auth keys.
3. **The tailnet keys.** OpenTofu generates two ed25519 keys, kept only in the encrypted state: the server's SSH host key, which cloud-init installs as the only host key `unfold-headscale` presents, and a client key that cloud-init authorizes for the user `tofu`, restricted to running `unfold-tailnet-key` and nothing else. `scripts/read-tailnet-key.sh`, run by OpenTofu's `external` data source with the system OpenSSH client, trusts no host key but the pinned one (`StrictHostKeyChecking=yes`) and refuses to talk to a server presenting any other. In an apply run it asks for the control planes' reusable `tag:cp` key and, per worker key slot (the worker's server id and the key generation, see the [infra workflow runbook](docs/runbooks/infra-workflow.md#worker-tailnet-keys)), for a single-use `tag:node` key, making either when it does not exist and retrying for up to 25 minutes until Headscale's public `/health` passes with its Let's Encrypt certificate. In a plan-only run it only reads, once: it never makes a key, and an unreachable Headscale gives an empty answer instead of failing the plan, which changes nothing because every node keeps the key it was created with. SSH reaches the server only from `ADMIN_CIDRS`.
4. **The cluster.** OpenTofu creates the cluster nodes from the snapshot, the control planes and the workers of every pool in `worker_pools`, generates the cluster's Talos secrets, applies the machine configs with the tailnet keys, and bootstraps etcd. Talos installs Cilium, Hetzner's cloud controller, the Flux operator, a Flux instance, and a GitRepository that reconciles `kubernetes/clusters/main` from the public GitHub mirror only when the newest commit carries a trusted signature.
5. From then on Flux owns everything under `kubernetes/`, Cilium and the cloud controller included (see [After the first boot, Flux owns Cilium and the cloud controller](#after-the-first-boot-flux-owns-cilium-and-the-cloud-controller)). The recovery set (the Flux operator and controllers, and the storage driver's controller) tolerates and is pinned to the control planes, as on the homelab: the workers are tainted for Unfold and for CI, and the AX41 joins later.

The Kubernetes API sits on `10.64.0.10`, a Hetzner alias IP on the private network that Talos moves between control planes through the Hetzner API (`HCloudVIPConfig` on the link alias `private0`; each control plane's machine config points that alias at the MAC address Hetzner reports for the server's private NIC, so the VIP does not depend on how a server type names its interfaces). It costs nothing and is reachable only inside the network. The control planes advertise the cloud subnet `10.64.0.0/24` to the tailnet, and the tailnet policy approves that route automatically, but only from a `tag:cp` device, so the admin kubeconfig from `tofu output -raw kubeconfig` works from any admin device.

Admins reach the nodes over the tailnet: install Tailscale and run `tailscale up --login-server=https://headscale.webgrip.dev`, then approve the device with `sudo headscale nodes register` on the Headscale server. The tailnet uses Headscale's own relay; no Tailscale-run service is in the path.

## After the first boot, Flux owns Cilium and the cloud controller

Talos applies its inline manifests when the cluster is bootstrapped and never again on its own: an `infra` apply that changes them updates the machine config, but not the cluster. So Cilium and Hetzner's cloud controller are also Flux HelmReleases, in `kubernetes/platform/cilium` and `kubernetes/platform/hcloud-cloud-controller-manager`, and a change to either reaches the cluster by merging it, like everything else under `kubernetes/`.

Each has one set of files, read by both installers:

| File | Flux reads it as | The Talos seed reads it as |
| --- | --- | --- |
| `values.yaml` | the only values, through the ConfigMap `kustomization.yaml` generates from it | the `values` of the `helm_template` in `infra/bootstrap-manifests.tf` |
| `helmrelease.yaml` | the release, its name, and for the cloud controller the chart and version | the release name, and the cloud controller's chart and version |
| `ocirepository.yaml` (Cilium) | the chart and version | the chart and version |
| `kubernetes/platform/hetzner-charts/helmrepository.yaml` | the Hetzner chart repository | the same repository |

So the seed a new cluster boots with is the release Flux then reconciles, and Flux's first install on a new cluster changes nothing. The OpenTofu test `the_talos_seed_installs_*_exactly_as_flux_reconciles_it`, run by `infra-check` on every pull request that touches these files, fails when the two could differ: a HelmRelease with inline values or a second `valuesFrom`, a `helm_template` with other values, `set` entries, another release name, namespace, chart, repository or version, or a component missing from `kubernetes/clusters/main`. The Cilium identity in `values.yaml` must stay `unfold-main` with ID 2; the plan refuses anything else.

Flux adopts the objects Talos made without recreating them: helm-controller's install takes ownership of existing objects by default and applies server-side, so the running DaemonSets and Deployments keep their pods unless their pod template changes. Both HelmReleases use the `RetryOnFailure` strategy, so a failed install or upgrade is retried and never answered with an uninstall or a rollback of the network, and both carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so deleting a file does not uninstall Cilium. The CSI driver waits for the cloud controller (`dependsOn`).

A merge that changes these files deploys through Flux on its own. The `infra` workflow plans on the same merge, because the Talos machine config embeds the same files; apply that plan when convenient so a rebuilt cluster boots with the new seed. Never run `talosctl upgrade-k8s` with machine configs older than `main`: it re-applies the inline manifests and would roll Cilium back to the seed until the next Flux upgrade.

## No kube-proxy

Cilium replaces kube-proxy (`kubeProxyReplacement: true`) and reaches the API server through KubePrism on `localhost:7445`, Talos's local load balancer, so nothing needs a Service before Cilium is up. The control planes' machine config therefore carries `KubeProxyConfig` with `enabled: false`. Deleting that document with `$patch: delete`, as the first configs did, does not work: Talos then falls back to the v1alpha1 default and deploys kube-proxy, which is why the first cluster came up with both. The OpenTofu test in `infra/tests/kube_proxy.tftest.hcl` fails on a `$patch: delete`, on a missing `enabled: false`, and on Cilium values that would need kube-proxy.

Talos installs its bootstrap manifests once and never deletes them: an object in its `talos-bootstrap-manifests-inventory` is skipped from then on, even after the config stops rendering it. So turning kube-proxy off in the config does not remove the DaemonSet that already runs. Flux does that: the Job in [kubernetes/platform/kube-proxy-removal](kubernetes/platform/kube-proxy-removal) deletes the `kube-proxy` DaemonSet, ServiceAccount and ClusterRoleBinding, with a ServiceAccount allowed to get and delete those three names and nothing else. It is idempotent (`--ignore-not-found`) and stays completed, so Flux leaves it alone. Flux cannot take the DaemonSet over instead: Talos owns its fields under the `talos` field manager, and a server-side apply by Flux keeps the `kube-proxy` container beside anything Flux adds.

The `kube-proxy` nftables tables the old pods wrote stay on each node until it reboots, at the next Talos upgrade. They match nothing: Cilium's socket load balancer (coverage `Full`) translates every Service address in `connect()`, before a packet reaches netfilter, and NodePorts are answered by Cilium's BPF program on the interface, also before netfilter.

The Talos seed still installs, and Flux does not yet own, the `hcloud` secret, the Flux operator and instance, the `trusted-signers` secret, the GitRepository and Kustomization `flux-system`, and the etcd backup's namespace and secret. A change to those still needs a `talosctl upgrade-k8s` after the apply, or a new cluster.

## Only signed commits deploy

Flux applies whatever is on the GitHub mirror's `main`, so a push made straight to GitHub would otherwise reach production. Flux therefore checks the signature of the commit it is about to apply (`verify.mode: HEAD`) and refuses anything not signed by a key in `infra/trusted-signers/`:

| Key | Signs |
| --- | --- |
| `ryan.sshpub` | the owner's own commits |
| `forgejo.sshpub` | every pull request merge made with Forgejo's merge button, signed by the instance key (published at `/api/v1/signing-key.ssh`) |

A refused commit leaves the cluster on the last verified one and marks the GitRepository not ready. Pull requests, Renovate's included, are merged with Forgejo's merge button; Forgejo signs the merge commit with its instance key, which Flux trusts. Only the owner may push or merge on `main` (branch protection in homelab-cluster's `repo-config`), and Renovate never pushes straight to `main`.

Trusting the instance key is a deliberate trade-off (owner decision, 2026-10-25). The key signs merges and web edits in every repository on the instance, so someone who can create a repository there can get an arbitrary tree signed. That commit still has to reach the GitHub mirror's `main`, which only Forgejo's mirror push and the protected Forgejo `main` feed; the mirror's own branch protection, below, closes the direct route. Adding a person or bot means adding their public key file and running an apply, because the keys reach the cluster through a Talos inline manifest; on a running cluster that manifest only lands with `talosctl upgrade-k8s` (see [After the first boot](#after-the-first-boot-flux-owns-cilium-and-the-cloud-controller)).

Verification checks only the newest commit, so it does not stop a rollback: a force-push of an older signed commit to the mirror would deploy. The GitHub mirror's `main` therefore needs branch protection that refuses force-pushes and deletion and allows pushes only from the mirror's token. That setting lives in GitHub, not here.

## Security floor from the first boot

* **Pod Security `restricted`** is the API server's default for every namespace; Talos exempts `kube-system`, where Cilium and the storage node plugin need host access.
* **Default-deny networking**: a Cilium clusterwide policy denies all ingress and egress for every pod outside `kube-system` and `flux-system`, except DNS. A workload's namespace adds its own allow policy.
* **Pinned, approved images**: a native ValidatingAdmissionPolicy refuses any pod outside `kube-system` and `flux-system` whose images, debug containers or image volumes are not pinned by digest or do not come from a repository on its `allowedPrefixes` list (today only `ghcr.io/siderolabs/`); a new workload adds its own prefix. The components in the two exempt namespaces (Cilium, the cloud controller, the CSI driver, the Flux operator and controllers) are pinned by digest in their chart values instead, and Flux at an exact version.
* **Host firewall**: every node blocks inbound connections except the ports the cluster uses, each from named sources only ([docs/runbooks/host-firewall.md](docs/runbooks/host-firewall.md)). The Talos API and the API server take ADMIN_CIDRS, the tailnet and the private network.
* **Pod traffic between nodes is encrypted** with Cilium's WireGuard. Traffic between the nodes themselves and from host-network pods is not (`nodeEncryption` is off), so it relies on each protocol's own TLS: etcd, the API server and the kubelet all use it.
* **Hubble relay** runs, so `hubble observe --verdict DROPPED` shows what default-deny refused.

## Tailnet policy

`infra/templates/headscale-acl.hujson` is Headscale's access policy:

* devices of the Headscale user `ryan` form `group:admin` and may reach everything on the tailnet, including the routed cloud subnet;
* control planes join with a reusable key tagged `tag:cp`, the worker with a single-use key tagged `tag:node`; neither tag may start a connection to anyone, they only answer;
* only `10.64.0.0/24`, the cloud subnet with the control planes, the API address and the Unfold node, is routed into the tailnet, and only when a `tag:cp` device advertises it.

The keys are made on `unfold-headscale` by `/usr/local/sbin/unfold-tailnet-key` and read by OpenTofu over SSH; they are in no secret store. The `tag:cp` key lives 90 days; a daily systemd timer, `unfold-tailnet-key.timer`, makes a new one when fewer than 45 days are left and expires the one it replaces. The key file, `/var/lib/unfold-tailnet/control-plane.authkey`, is readable by root only. Each control plane keeps the key it was created with in its machine config (Talos joins once, `TS_AUTH_ONCE`, and tagged nodes do not expire), so a renewal never changes a running node; a new control plane gets the current key, because adding one makes OpenTofu read the key again. A worker key is made for one worker server when that server is created, and again for every worker when `tailnet_key_generation` is bumped; it may join once and expires after 24 hours.

The policy and the key settings are written once when the server is created. To change them, change the templates and bump `headscale_generation` in `infra/headscale.tf`, which replaces the server through a reviewed plan. A replaced Headscale starts with an empty database: every admin device registers again, and the nodes need new keys, which is a node replacement today.

The Headscale server installs Ubuntu security updates at 04:00 UTC and reboots at 04:30 UTC when one needs it. Headscale itself is not covered: a Renovate bump of `headscale_version` is installed by hand. Both reach only a newly created server, because cloud-init runs once.

## Machines

| Node | Hetzner type | Size | Private address | Role |
| --- | --- | --- | --- | --- |
| `unfold-cp-1` to `-3` | Cloud CX23 | 2 vCPU, 4 GB, 40 GB | `10.64.0.11` to `.13` | control planes, one placement group |
| `unfold-app-1` | Cloud CX33 | 4 vCPU, 8 GB, 80 GB | `10.64.0.21` | Unfold, ploegd and their databases only (label and taint `node.webgrip.io/pool=unfold`) |
| `unfold-ci-1` | Cloud CX43 | 8 vCPU, 16 GB, 160 GB | `10.64.0.31` | CI jobs only, under the `gvisor` RuntimeClass (label and taint `node.webgrip.io/pool=ci`) |
| `unfold-headscale` | Cloud CX23 | 2 vCPU, 4 GB, 40 GB | public only | Headscale, the admin tailnet's coordination server and relay |
| `unfold-metal-1` | Robot AX41 | | `10.64.1.31` on the vSwitch | agent Runs under Kata; not in `infra/` yet |

The cloud servers are Hetzner's cost-optimized CX line, chosen on 2026-10-24 because the 2026 price rises made the CPX line (AMD, regular performance) three to four times the price. CX servers run on shared Intel or AMD x86 hosts and Hetzner limits how many it sells, so a create can fail with the type unavailable; `location` can then move to `nbg1`. They must stay x86, because the Talos snapshot and the Headscale package are amd64: Arm CAX types are refused by the variables' validation.

### What the cloud servers cost

| Node | Type | Per month | Per hour |
| --- | --- | --- | --- |
| `unfold-cp-1` | CX23 | €5.99 | €0.0096 |
| `unfold-cp-2` | CX23 | €5.99 | €0.0096 |
| `unfold-cp-3` | CX23 | €5.99 | €0.0096 |
| `unfold-app-1` | CX33 | €8.99 | €0.0144 |
| `unfold-ci-1` | CX43 | €16.49 | €0.0264 |
| `unfold-headscale` | CX23 | €5.99 | €0.0096 |
| **Total** | | **€49.44** (€59.82 with 21% VAT) | |

Hetzner list prices of 2026-10-23, checked on 2026-10-24 at [hetzner.com/cloud/cost-optimized](https://www.hetzner.com/cloud/cost-optimized/), excluding VAT, each including the server's public IPv4 address. Billing is hourly up to the monthly price, from creation until deletion, whether the server runs or not. The Cloud Network, the placement group and the alias IP of the API address cost nothing; the Talos snapshot is billed per GB stored. The first five servers on the CPX line (CPX22, CPX32, CPX02) list at €102.45 a month. The AX41 and object storage are not in this table.

The AX41 is ordered once by hand in Robot. Its vSwitch id then goes into `vswitch_id`, which adds the vSwitch subnet to the Cloud Network. Its VLAN interface uses MTU 1400, the smallest link in the cluster, so Cilium's `MTU` is set to 1400; Cilium subtracts its VXLAN (50 bytes) and WireGuard (80 bytes) overhead itself, leaving pods 1270.

Pods get addresses from `10.65.0.0/16` and Services from `10.66.0.0/16`, and Cilium runs as cluster `unfold-main` with ID 2, as the [address plan](docs/rfc/0001-security-architecture.md#address-plan) allocates them for ClusterMesh. None of these can change once the cluster exists.

## How changes reach Hetzner

Pull requests that touch `infra/` run only `fmt` and `validate`, on the shared `docker` runner and without any secret: a branch can change the Terraform code, so a plan on a branch would hand that code every production credential. Pushes to `main` run `tofu plan`; nothing is created, and the run prints a `plan digest`.

Applying is a separate, deliberate step. Read the plan of a run on `main` and copy its digest. Then in Forgejo, Actions → `infra` → **Run workflow** on `main`, with `apply` chosen in the dropdown and that digest in `plan_digest`. The run makes a fresh plan and applies it only if its digest matches the one you read; otherwise it stops and prints its own, so read that run's plan and dispatch again. Every server carries `prevent_destroy`, so a plan that would replace one fails instead.

The owner puts every value into the homelab's OpenBao; nobody types one into Forgejo. The credentials never become Forgejo secrets: each run that needs them proves who it is with its Forgejo OIDC token and reads them from OpenBao itself, through the shared `openbao-read` action, as homelab-cluster ADR-0061 lays out. OpenBao's role `ci-unfold-cluster` answers only a token for this repository, on `refs/heads/main`, from a push, the schedule or a manual run, so neither a pull request nor a workflow added on a branch can read them. Only the plain variables are still copied onto this repository, by the homelab CronJob `forgejo-actions-secrets` (in `kubernetes/apps/forgejo/forgejo-actions-secrets` of homelab-cluster, hourly at minute 23). The order and commands are in the [bootstrap checklist](docs/bootstrap-checklist.md).

| Reaches the workflow as | Name | OpenBao path | Holds |
| --- | --- | --- | --- |
| OpenBao read per run | `HCLOUD_TOKEN` | `secret/hetzner/unfold-tofu` | Hetzner Cloud API token for OpenTofu in CI, read and write |
| OpenBao read per run | `HCLOUD_TOKEN_CLUSTER` | `secret/hetzner/unfold-cluster` | a second token, for the cloud controller and CSI driver in `kube-system`; set before the apply that creates the cluster |
| OpenBao read per run | `HCLOUD_TOKEN_VIP` | `secret/hetzner/unfold-vip` | a third token, for the control planes to move the API address; set before the apply that creates the cluster |
| OpenBao read per run | `STATE_S3_ACCESS_KEY`, `STATE_S3_SECRET_KEY` | `secret/unfold-cluster/tofu-state` | credentials for the state bucket |
| OpenBao read per run | `STATE_PASSPHRASE` | `secret/unfold-cluster/tofu-state` | at least 32 characters; encrypts the state and plans, which hold the Talos secrets |
| variable | `STATE_BUCKET`, `STATE_ENDPOINT`, `STATE_REGION` | `secret/unfold-cluster/vars` | the state bucket on the off-site Garage: `unfold-cluster-tfstate`, `https://s3-offsite.webgrip.dev`, `garage` |
| variable | `ADMIN_CIDRS` | `secret/unfold-cluster/vars` | a JSON list of addresses allowed to reach the Talos and Kubernetes APIs, e.g. `["203.0.113.7/32"]`; it must include the address the Forgejo runners leave from |
| variable | `ADMIN_SSH_PUBLIC_KEY` | `secret/unfold-cluster/vars` | the owner's SSH public key, the only way into the Headscale server |
| OpenBao read per run | `ETCD_BACKUP_WRITE_ACCESS_KEY`, `ETCD_BACKUP_WRITE_SECRET_KEY` | `secret/unfold-cluster/etcd-backup` | the Garage key the cluster writes etcd snapshots with: write on `unfold-cluster-etcd`, no read |
| OpenBao read per run | `ETCD_BACKUP_READ_ACCESS_KEY`, `ETCD_BACKUP_READ_SECRET_KEY`, `ETCD_BACKUP_AGE_IDENTITY` | `secret/unfold-cluster/etcd-backup` | the restore check's read-only Garage key and the age private key |
| variable | `ETCD_BACKUP_AGE_RECIPIENT`, `ETCD_BACKUP_CHECK` | `secret/unfold-cluster/vars` | the age public key snapshots are encrypted to; `enabled` once the first snapshot exists |

A value missing from OpenBao stops the run at the read, naming the path and key; without the variables other than `ETCD_BACKUP_CHECK`, the workflow stops before `init`. The Talos snapshot and the tailnet keys are not among them: the apply run builds the first and reads the others from `unfold-headscale`. Garage ignores S3 conditional writes, so OpenTofu's lock file cannot be trusted there; the workflow's `concurrency` group is what keeps two runs from writing the state at once.

The workflow runs only on `unfold-infra`, a runner registered on this repository alone and on no other, so no other repository's job can land on the runner these credentials are read on. The runner is not what keeps other branches of this repository out: Forgejo would hand repository secrets to a workflow a branch adds, which is why there are none, and OpenBao refuses any token not from `main`. It runs one job at a time, each in a fresh pod that is deleted afterwards. The runner pool is defined in the homelab, in `kubernetes/apps/forgejo/forgejo-runner/app/infra/` of homelab-cluster.

No job installs anything. The steps run in `infra-runner`, a toolchain image built in [webgrip/infrastructure](https://forgejo.webgrip.dev/webgrip/infrastructure) (`ops/docker/infra-runner`) on a Docker Hardened Image base, with OpenTofu, age and the etcd tools baked in at pinned versions and verified checksums, signed and served from the homelab's Harbor. The `unfold-infra` pool runs it as its own container, so the secret-holding jobs never touch the shared Docker daemon; the pull-request check runs the same image as a job container on the shared `docker` pool, where it holds nothing. A tool update is a release of that image and a digest bump here and in homelab-cluster. Its etcd stays on the minor release Talos runs (a 3.7.3 `etcdutl` was tested restoring a 3.7.2 snapshot), and moves to a new minor only with a Talos upgrade that moves etcd.

### Diagnosing the cluster without the tailnet

When nobody can reach Kubernetes, run Actions → `infra` → **Run workflow** on `main` with `diagnose` in the `apply` dropdown; `plan_digest` stays empty. The `diagnose` job reads the same OpenBao credentials as a plan, runs `tofu init` against the state, and stops there: no plan, no apply, and no Hetzner call except one. `scripts/diagnose-cluster.sh` then prints:

* the Hetzner project's API budget, from the `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset` headers of one `GET /v1/locations?per_page=1` (the limit is per project, so every token in it shares the budget);
* per node, through `talosctl` against the public address: `version`, `get members`, `service`, the last 50 lines of `ext-tailscale`, `get addresses` and the host firewall's `get nftableschains`, then `etcd members`;
* per node, the Kubernetes containers (`talosctl containers -k`) and the last 100 log lines of every `kube-system` container of the cloud controller and Cilium;
* through `kubectl`: nodes, pods, `kube-system` events, the cloud controller's log and Flux's sources. The kubeconfig points at the private VIP, so the script asks the first control plane's public address on 6443, which the firewall opens to `ADMIN_CIDRS`, and checks the certificate against the VIP's address, a name the API server's certificate is issued for.

The talosconfig and kubeconfig come from `tofu output -raw`, are written with mode 0600 under `$RUNNER_TEMP`, and are deleted when the script ends; neither is printed. The job log of this public repository is public, so every line the script prints passes through a redaction of `hskey-` and `tskey-` keys, `Bearer` values, Hetzner's `for token '...'` quotes, `token=`/`password:`-style values and 64-character mixed-case tokens such as a Hetzner API token. A check that gets no answer is listed as a warning at the end; the job fails only when it cannot read the state. The script installs `talosctl` and `kubectl` at the versions pinned at its top, checked against pinned SHA-256 sums, because `infra-runner` does not carry them; Renovate proposes their bumps for approval on the dashboard.

## Credentials and rotation

Hetzner tokens cannot be narrowed below a whole project, so each job gets its own token and each can be revoked alone. Every server, the network and the Headscale address carry Hetzner's delete protection, which slows down deletion but nothing else.

Treat every one of these tokens as the whole cluster. Any token can boot a node into rescue mode or image its disk, and neither protection stops that. Until the Talos partitions are encrypted (RFC 0001, disk encryption), the disk holds the cluster's certificate authorities and the key that encrypts Secrets in etcd in clear text. Two of the three tokens live inside the cluster: `HCLOUD_TOKEN_CLUSTER` in `kube-system`, and `HCLOUD_TOKEN_VIP` in every control plane's machine config. Encrypting the disks does not close this either if the key server runs in the same Hetzner project, because the same token can image the key server. It has to run where these tokens cannot reach it.

All tokens in the project also share one API budget: Hetzner allows 3600 requests an hour per project, not per token, refilled at one a second. CI's OpenTofu, the cloud controller and CSI driver in `kube-system` and Talos's VIP controller all draw on it. A plan costs about 13 requests, so a plan that fails with `rate_limit_exceeded` means something else in the project spent the hour. On 2026-10-25 that was the VIP controller on the three control planes, which calls the API on every link change. The provider polls actions every 2 seconds rather than every 500 ms to spend less, and the `diagnose` run prints the budget left. A separate token buys no headroom; a second Hetzner project would. The per-run estimate and the evidence are in [docs/runbooks/hetzner-api-budget.md](docs/runbooks/hetzner-api-budget.md).

The workflow logs are readable without signing in, and Hetzner's API errors quote the first 32 characters of the token they refused. Both `infra` jobs therefore mask every prefix of 16 characters or more of each Hetzner token they hold. The diagnose report also redacts any such quote, because the nodes' logs quote tokens the job does not hold. A test, and a canary on a real runner, prove both on pull requests. Rotate a token whose characters ever reached a log.

| Credential | Where it lives | Rotate |
| --- | --- | --- |
| `HCLOUD_TOKEN` | OpenBao `secret/hetzner/unfold-tofu` | every 6 months |
| `HCLOUD_TOKEN_CLUSTER` | OpenBao `secret/hetzner/unfold-cluster`, encrypted state, Secret `kube-system/hcloud` | every 6 months, then apply |
| `HCLOUD_TOKEN_VIP` | OpenBao `secret/hetzner/unfold-vip`, encrypted state, control plane configs | every 6 months, then apply |
| tailnet pre-auth keys | made on `unfold-headscale`, encrypted state, node configs | `tag:cp`: renewed on the server before 45 days are left, nothing to do; `tag:node`: single use, one per worker server |
| OpenTofu's SSH client key and the pinned host key of `unfold-headscale` | encrypted state; the host key also in the server's user_data, which Hetzner's metadata service serves to the server | with the server: bump `headscale_generation` |
| `STATE_PASSPHRASE` | OpenBao `secret/unfold-cluster/tofu-state`, password manager with an offline copy | when someone with access leaves |
| State bucket keys | OpenBao `secret/unfold-cluster/tofu-state` | every 6 months |
| etcd backup keys and age key | OpenBao `secret/unfold-cluster/etcd-backup`; the age key also in the password manager with an offline copy | Garage keys every 6 months; the age key when it may have leaked |
| GitHub mirror token | Forgejo mirror settings | at its expiry date |

A rotation is a new value in OpenBao (`bao kv patch`), which the next run reads, and an apply where the table says so. OpenBao runs in the homelab, so the values that cannot be made again, the state passphrase, the age key and the Talos secrets bundle, also stay in the password manager with an offline copy.

Nothing outside `kube-system` and cluster admins may read Secrets in `kube-system`: no Role, ClusterRole or binding that grants it is added to this repository, and agents get no Kubernetes token at all.

## Backups and the restore check

Every six hours a CronJob in `etcd-backup` asks the Talos API for an etcd snapshot, encrypts it to `ETCD_BACKUP_AGE_RECIPIENT` and writes it to the `unfold-cluster-etcd` bucket on the off-site Garage ([kubernetes/platform/etcd-backup](kubernetes/platform/etcd-backup)). Talos gives the job one role, `os:etcd:backup`, and only in that namespace. The cluster's Garage key can write to the bucket but not read it, and the cluster never holds the age private key, so a compromised cluster cannot read its own backups.

A backup counts only once it has been restored. Every morning [etcd-backup-check](.forgejo/workflows/etcd-backup-check.yml) downloads the newest snapshot, fails if it is more than seven hours old, decrypts it, restores it with `etcdutl` into a throwaway etcd on the runner and reads `kube-system` and `flux-system` back out of it ([scripts/verify-etcd-snapshot.sh](scripts/verify-etcd-snapshot.sh)). Running it by hand with `corrupt` damages the snapshot first, and the run must fail; do that once after enabling the check, so the check is known to catch damage.

Set up once, before the apply that creates the cluster:

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

That admin kubeconfig is break-glass: it is in `system:masters` and cannot be revoked. Daily use is OIDC through Authentik with the committed `access/unfold-oidc.kubeconfig.yaml`, as yourself and bound by RBAC; setup, roles, the audit policy and the break-glass rules are in the [Kubernetes login runbook](docs/runbooks/kubernetes-login.md).

## Security architecture

The target design for every layer, its threat model, the residual risks and the delivery order are in [RFC 0001](docs/rfc/0001-security-architecture.md). The confidential class and the next tier of measures are in [RFC 0002](docs/rfc/0002-confidential-class-and-next-tier.md).

## Open

* **First boot to verify.** That Talos applies the Flux instance after the operator's CRDs exist, that Cilium's MTU is right on the vSwitch path, and that the `private0` alias lands on the private NIC so the API VIP comes up, are proven only by the first apply.
* **CI is not on the tailnet.** OpenTofu still reaches the Talos API from the Forgejo runners over the internet, so `ADMIN_CIDRS` keeps the runners' address until CI joins the tailnet. Closing the firewall completely waits for that.
* **Backups share a datacentre.** The off-site Garage and the cluster are both in Hetzner's Falkenstein region, so a regional outage or a lost Hetzner account takes both. A second copy outside Hetzner, on the homelab Garage, is the next step.
* **A failed restore check alerts nobody yet.** It shows as a failed run in Forgejo; wiring failed scheduled runs into the homelab's alerting is still to do.
* **Headscale has no backup.** Losing the server loses the tailnet's keys and nodes; the APIs stay reachable from `ADMIN_CIDRS`, and a new server means re-registering every device.
* **Every Hetzner token reads every disk** until the Talos partitions are encrypted with a key server outside this Hetzner project (see [Credentials and rotation](#credentials-and-rotation)). The encryption config is built and switched off until that key server exists; [docs/disk-encryption.md](docs/disk-encryption.md) has the proposal and the node-by-node rollout.
* **Two rules live outside this repository.** The GitHub mirror's ruleset `main: no rollback` refuses force-pushes and deletion of `main`, and OpenBao's role `ci-unfold-cluster` (homelab-cluster, `kubernetes/apps/security/openbao/bootstrap/config.sh`) decides who reads the credentials. A change to either is a change to this repository's security.
* **OpenBao** and the AX41 are not in the code yet.
