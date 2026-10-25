# Disk encryption

RFC 0001 decided that every node's Talos STATE and EPHEMERAL volumes are LUKS2. [ADR 0003](adr/0003-disk-encryption-key-source.md) decided where the key comes from: a KMS on `unfold-headscale`, for cloud and metal nodes alike. This page is how it is built, how a running node is moved onto it, and how to see where each node stands.

## What is built

### The VolumeConfig

[infra/disk-encryption.tf](../infra/disk-encryption.tf) renders two `VolumeConfig` documents, STATE and EPHEMERAL, for every node named in `disk_encryption_nodes`:

```yaml
encryption:
  provider: luks2
  cipher: aes-xts-plain64
  blockSize: 4096
  options: [no_read_workqueue, no_write_workqueue]
  allowDiscards: false
  keys:
    - slot: 0
      kms:
        endpoint: https://headscale.webgrip.dev:4050
```

Cloud disks keep discards off: they gain nothing from TRIM, and TRIM shows which blocks are in use. A metal node (`unfold-metal-*`) gets `allowDiscards: true` on its local NVMe, where TRIM keeps write speed and wear healthy (RFC 0001). `disk_encryption_kms_endpoint` names another KMS, and refuses `grpc://`.

### The key server

`kms-server` from `siderolabs/kms-client`, the container image `ghcr.io/siderolabs/kms-server:v0.2.0` pinned by digest in [infra/disk-kms.tf](../infra/disk-kms.tf), runs under podman on `unfold-headscale`:

- **Installed by cloud-init**, so a rebuilt Headscale server has it too. `headscale_generation` 4 replaces the live server once to get it.
- **TLS from Headscale's own certificate.** Headscale keeps its Let's Encrypt certificate and key in one file in `/var/lib/headscale/cache`; `unfold-kms-cert` copies it to `/etc/unfold-kms/tls.pem` before the KMS starts, and a path unit restarts the KMS when Headscale renews it. Talos checks the certificate against its built-in public roots, because STATE opens before any custom CA from the config could be read.
- **The master key** is in OpenBao `secret/unfold-cluster/disk-kms` (`master_key`, base64 of 32 bytes). `scripts/disk-kms-key.sh` reads it on every plan and, on an apply run that finds none, writes 32 random bytes there first; it never replaces a stored key, and the OpenBao policy of `ci-unfold-cluster` grants `create` and `read` on that path but not `update` (homelab-cluster 0a7dd339). Cloud-init writes it to `/etc/unfold-kms/master.key` (root, 0400). The container runs read-only, with every capability dropped.
- **The firewall** `unfold-disk-kms`, attached to the Headscale server, opens TCP 4050 to the nodes' public IPv4 addresses and to `ADMIN_CIDRS`. Nothing else reaches it. This matters more than usual: the reference server unseals for anyone who sends it a sealed blob from a LUKS2 header (ADR 0003).

### What it costs at boot

A node asks the KMS only when it opens STATE and EPHEMERAL at boot. A running node never asks again. A rebooting node whose KMS does not answer waits and retries until it does, so `unfold-headscale` must be up for a node to finish booting. Headscale's unattended upgrade may reboot it at 04:30 for about a minute.

## Turning it on

### A new node

A node created while it is in `disk_encryption_nodes` formats its volumes encrypted at install. The re-install step finds it in maintenance mode and leaves it alone.

### The AX41

`unfold-metal-1` is encrypted from its first install, so it never needs a wipe for encryption. Once PR #75 has merged, one commit does it:

1. In [infra/disk-kms.tf](../infra/disk-kms.tf), `disk_kms_metal_client_ipv4s` lists the metal nodes' public addresses: `[for name in keys(var.metal_servers) : data.external.metal_server[name].result.server_ip]`.
2. `disk_encryption_nodes` defaults to `["unfold-metal-1"]`.

A precondition on the KMS firewall refuses step 2 without step 1, because the node's STATE would never open. The metal node's config already takes `local.disk_encryption_patches` (PR #75). Talos needs the public DHCP address before STATE opens; the vSwitch VLAN comes from the machine config and is not up yet, which is why the KMS is reached over the public address. That the AX41's DHCP comes up before STATE opens is proven on its first install, not before.

A TPM key slot is a later, separate step (ADR 0003): one KVM session, a SecureBoot image, a reinstall through `install_generation`. Adding that slot needs no wipe.

### A running cloud node

Talos encrypts a volume only when it formats it, and refuses a plain volume once encryption is configured (`block dev type mismatch: xfs != luks`, `HandleEncryptionWithHandler` in Talos v1.14.4). So a running node is wiped and rejoined. The apply does it, one node per reviewed plan:

1. **A commit adds one node to `disk_encryption_nodes`.** Its plan replaces three things for that node: `terraform_data.disk_encryption_reinstall`, its `talos_machine_configuration_apply` (now carrying the encrypted `VolumeConfig`) and `terraform_data.disk_encryption_rejoin`. A worker also gets a new tailnet key slot, because its single-use key was spent at its first boot and its tailnet state is wiped with EPHEMERAL.
2. **The plan guard** ([scripts/guard-encryption-rollout.sh](../scripts/guard-encryption-rollout.sh)) runs on every plan, plan-only included. It names the node the plan re-installs and refuses a plan that re-installs two running nodes, which could take two control planes out of etcd at once.
3. **Re-install** ([scripts/encrypt-node.sh](../scripts/encrypt-node.sh) `reinstall`):
   - waits until the node answers on the Talos API;
   - does nothing when its volumes already match, or when it waits in maintenance mode for its first config;
   - **refuses** unless every Kubernetes node is Ready, etcd has one member per control plane and each answers its status, and the KMS answers TLS with a certificate that verifies; so a node left unhealthy by the previous run stops the next one;
   - cordons and drains the node; a drain that does not finish in 10 minutes uncordons it and stops, with nothing wiped;
   - for a control plane, `talosctl etcd leave`, then checks etcd has exactly one member fewer (two of two: quorum holds, with no margin until the node is back);
   - `talosctl reset --graceful=false --reboot` with STATE and EPHEMERAL wiped, deletes the Node object, and waits until the node answers in maintenance mode.
4. **The machine config apply** sends the full config to the node in maintenance mode. Talos asks the KMS to seal fresh keys, formats both volumes as LUKS2, and joins etcd as a new member and Kubernetes as a new kubelet.
5. **Rejoin** (`encrypt-node.sh rejoin`) waits until the node reports `luks2` and `ready` for both volumes, its Node is Ready and, for a control plane, etcd has all three members answering; then it uncordons the node. It fails the apply after 30 minutes.

The order is `unfold-app-1` first, which has no etcd and proves the path, then `unfold-cp-3`, `unfold-cp-2` and `unfold-cp-1`. Each is its own commit, plan and apply. `talos_machine_bootstrap` is in the state and never runs again, so re-installing `unfold-cp-1` is no different.

Taking a node back to plain volumes is the same path with the node removed from the list. A worker taken back needs a `tailnet_key_generation` bump in the same commit, because its old key slot holds a spent key.

### What a run does to the cluster

One node is drained and rebooted twice, a few minutes each. Its pods reschedule. On a control plane the API address moves if that node held it, and etcd runs on two members for the length of the run: one more failure in that window loses quorum. The guard checks the cluster at the start of a run, not during it.

## Seeing where each node stands

The infra workflow's **diagnose** mode prints, for each node, `STATE=luks2:ready EPHEMERAL=luks2:ready` or `none`, and whether the KMS answers TLS with a certificate that verifies. By hand, with a talosconfig: `scripts/encrypt-node.sh status <node public IP>`.

## Risks that stay

| Risk | Why | Mitigation |
| --- | --- | --- |
| A cluster Hetzner token reads every disk | It can image `unfold-headscale`, master key included, without a reboot | A KMS in a second Hetzner project turns that into a node outage (proposed, ADR 0003); later our own KMS that checks the caller |
| The KMS unseals for anyone who reaches it | The reference server has no client authentication | The firewall: node addresses and `ADMIN_CIDRS` only |
| Headscale down when a node reboots | The node waits for the KMS | Running nodes are unaffected; the diagnose run checks the KMS |
| etcd on two members during a control plane's run | One member is out for the wipe | One node per plan; the guard refuses to start without three healthy members |
| Hetzner reads memory | No confidential computing on cloud servers | Accepted in RFC 0001 |
