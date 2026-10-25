# Disk encryption for the cloud nodes

RFC 0001 decided on 2026-10-24 that the Talos STATE and EPHEMERAL volumes of every cloud node are LUKS2. The key is sealed by a KMS server on its own small VM. This page is the design for getting there from the running cluster. The configuration is in the repository and switched off: the key server does not exist yet, and it costs money, so it is a proposal for the owner.

## What is built

[infra/disk-encryption.tf](../infra/disk-encryption.tf) renders two `VolumeConfig` documents, STATE and EPHEMERAL. Each has:

```yaml
encryption:
  provider: luks2
  cipher: aes-xts-plain64
  blockSize: 4096
  options: [no_read_workqueue, no_write_workqueue]
  keys:
    - slot: 0
      kms:
        endpoint: <disk_encryption_kms_endpoint>
```

Discards stay off: a cloud disk gains nothing from TRIM, and TRIM leaks which blocks are in use. The documents reach only the nodes named in `disk_encryption_nodes`, through each node's own `talos_machine_configuration_apply`. Both variables are empty by default, so this change alters no machine config.

The variables refuse three mistakes:

- a node list without a key server;
- a `grpc://` or scheme-less endpoint, which would carry the keys in plain text;
- a node the cluster does not have.

[infra/tests/disk_encryption.tftest.hcl](../infra/tests/disk_encryption.tftest.hcl) pins all of it.

## Why the KMS and not the other key types

Hetzner Cloud servers have no TPM, so `tpm` is not available. `nodeID` derives the key from the node's UUID, which Hetzner's metadata and anyone holding a disk image can read, so it protects nothing. `static` stores the passphrase in the machine config, and for STATE that config sits on the volume it would unlock. `kms` is the only key type that keeps the key off the disk: Talos sends the node UUID and a sealed blob to the KMS, and only the KMS can unseal it.

## The key server

**Status: does not exist.** Nothing in this repository or the Hetzner project runs one.

### Software
Sidero's reference server, `kms-server` from `github.com/siderolabs/kms-client` (MPL-2.0, v0.2.0, last commit 2026-02-09). It is a single gRPC binary. It seals with AES-GCM under a master key read from `--key-path`, and it serves TLS itself (`--tls-enable`, `--tls-cert-path`, `--tls-key-path`).

It authorises by node UUID alone. That is the RFC's accepted risk ("network isolation now; our own KMS server backed by OpenBao Transit later").

### Where it runs
The constraints, in order:

1. **Not in this cluster.** A node needs the KMS before STATE opens, which is before Talos has its machine config, so long before kubelet or any pod exists. A KMS inside the cluster is a bootstrap loop: a full restart could never come back.
2. **Not in this cluster's Hetzner project.** Every token in that project can boot any server of the project into rescue mode or image its disk (README, "Credentials and rotation"). A KMS VM in the same project falls to the same token as the disks it protects.
3. **Reachable before the tailnet.** Tailscale is a Talos extension, so it starts after EPHEMERAL is open. The KMS must be reachable over the public internet, or the private network, which a different project cannot join.
4. **A certificate from a public CA.** STATE is unlocked before the machine config is read, so a custom CA from the config cannot be trusted at that point (Talos's own `EncryptionKeyKMS` documentation).
5. **Up whenever a node boots.** A running node never asks again, but a rebooting node waits until the KMS answers.

The proposal, which **needs the owner's approval because it costs money**:

- **One CX23 in a second Hetzner project, `unfold-kms`.** It runs Ubuntu with `kms-server` installed by cloud-init from a checksum-pinned release binary, the same pattern as `unfold-headscale`. It has its own API token, which none of the cluster's tokens can reach.
- **The Hetzner Cloud Firewall of that project** opens the KMS port to the four nodes' public IPv4 addresses only, port 80 to the internet for the certificate's HTTP-01 challenge, and SSH to ADMIN_CIDRS.
- **The DNS name `kms.webgrip.dev`**, an unproxied A record declared in homelab-cluster like Headscale's. A Let's Encrypt certificate is obtained and renewed by the HTTP-01 challenge on the VM.
- **The master key** is generated once by OpenTofu and kept in that module's own encrypted state. It is also stored in OpenBao and in the owner's password manager. Losing it does not lose data: every node can be wiped and rejoined, and etcd survives on the other members and in the backups. Losing it during a full-cluster outage, though, means rebuilding from the etcd backup.
- **Its own OpenTofu root**, `infra/kms/`, with its own state key and token, applied before any node lists encryption. It must not depend on anything in the cluster.

The homelab was considered and rejected as the KMS host. A homelab outage would leave every rebooting Unfold node locked, and the cluster is designed to keep running when the homelab is down (Flux reads from the GitHub mirror for the same reason).

## Turning it on

New nodes are the easy case. A node created after `disk_encryption_kms_endpoint` is set, and listed in `disk_encryption_nodes` from its first apply, formats its volumes encrypted at install. The CI node `unfold-ci-1` can start that way.

Existing nodes are the hard case. Talos encrypts a volume only when it formats it, and it refuses to open a plain volume once encryption is configured: `block dev type mismatch: xfs != luks`, from `HandleEncryptionWithHandler` in Talos v1.14.4. So adding a running node to the list without wiping it leaves the node unable to mount STATE and EPHEMERAL at its next reboot. Each existing node goes through a wipe and rejoin, one at a time.

### The rolling path, one node per run

This is a new `infra` workflow mode, `encrypt-node`, with the node name as its input. It is not built yet. It needs the KMS to test against, and an untested destructive workflow is worse than none.

1. **Preflight, read-only.**
   - All nodes are Ready.
   - etcd has three healthy members (`talosctl etcd status`).
   - The node is listed in `disk_encryption_nodes` on `main` and still reports its volumes unencrypted (`talosctl get volumestatus`).
   - No other node is mid-rotation.
   - The run refuses on any failure.
2. **Wipe.** A graceful Talos reset of that node only, wiping the system labels STATE and EPHEMERAL, with a reboot. Graceful means:
   - the node is cordoned and drained;
   - a control plane leaves etcd first, so the remaining two keep quorum (two of two);
   - the node comes back in maintenance mode, without a config.
3. **Rejoin.** A `tofu apply` replaces that node's `talos_machine_configuration_apply`, using a per-node `terraform_data` generation in `replace_triggered_by`, and sends the full config, now with the encrypted `VolumeConfig`, to the maintenance-mode node. Talos then:
   - asks the KMS to seal fresh keys;
   - formats both volumes as LUKS2;
   - rejoins etcd as a new member;
   - registers the kubelet again.
4. **Postflight.** Wait until the node is Ready, etcd shows three healthy members again, and `volumestatus` shows `luks2` for STATE and EPHEMERAL. Only then may the next run start.

The order is `unfold-app-1` first, which has no etcd and proves the path, then `unfold-cp-3`, `unfold-cp-2` and `unfold-cp-1`. `talos_machine_bootstrap` targets `unfold-cp-1` but is already in the state, so it never runs again.

Two things are proven only on the first node:

- that the Talos provider applies to a node in maintenance mode within the same resource replacement;
- that the private network's DHCP address is up before STATE unlocks, if the KMS is ever reached privately.

What each run does to the running cluster: one node is drained and rebooted twice, a few minutes each. Its pods reschedule. On a control plane the API VIP moves if that node held it, and etcd runs on two members for the length of the run.

## Risks that stay

| Risk | Why | Mitigation |
| --- | --- | --- |
| KMS down when a node reboots | The node waits for the KMS | Running nodes are unaffected; alert on the KMS's reachability from the homelab; keep its VM boring |
| The KMS authorises by UUID only | Sidero's reference server has no client auth | Firewall to the four node addresses; later our own server on OpenBao Transit (RFC 0001) |
| Hetzner reads memory | No confidential computing on cloud servers | Accepted in RFC 0001 |
