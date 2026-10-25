# Encrypted volumes (hcloud-luks)

Hetzner documents no encryption at rest for its volumes, so the cluster encrypts them itself:
hcloud-csi formats each volume with LUKS and opens it on the node with a passphrase it reads from a
node-publish Secret. Hetzner only ever sees ciphertext.

| StorageClass | Default | `reclaimPolicy` | For |
| --- | --- | --- | --- |
| `hcloud-luks` | yes | `Retain` | every claim |
| `hcloud-luks-drill` | no | `Delete` | only the throwaway clusters of the CNPG restore drill (`cnpg.io/cluster: *-drill`) |
| `hcloud-volumes` | no | `Retain` | nothing new; only `zot/zot-data`, bound before the encrypted class existed |

The admission policy `encrypted-volumes` (Deny) refuses a claim on any other class, and
`hcloud-luks-drill` for anything but a drill cluster ([admission policies](admission-policies.md)).

## The passphrase

| Where | What |
| --- | --- |
| homelab OpenBao `secret/unfold-main/hcloud-luks`, property `encryption-passphrase` | the only original |
| homelab-cluster `kubernetes/apps/security/openbao/bootstrap/unfold-hcloud-luks.*` | generates 64 random characters once and pushes them with `updatePolicy: IfNotExists`, so a value OpenBao holds is never overwritten |
| Secret `volume-encryption/hcloud-luks` | the copy External Secrets keeps here; the StorageClasses name it as their node-publish Secret |

The kubelet reads that Secret when it mounts a volume; the Node authorizer lets a kubelet read it only
for volumes of pods on its own node. No pod runs in `volume-encryption`.

One passphrase covers every volume. **Losing it loses every volume's data**: OpenBao's snapshots
and their restore drill cover it, and it belongs on the escrow list with the Unfold state passphrase
(homelab-cluster ADR-0081) before the first volume holds client data. Rotating it means a new
class with a new Secret and moving each claim's data; LUKS key slots are not managed by hcloud-csi.

Until the homelab gateway is up the Secret does not exist, and a pod using a `hcloud-luks` claim
stays in `ContainerCreating` with a mount error naming the Secret. Nothing uses the class yet.
