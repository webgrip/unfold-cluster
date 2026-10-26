# Break-glass: when something outside the cluster is down

One section per external dependency that can stop an operation, from the
[inventory](../architecture/external-dependencies.md). Each says what still works, what to do, and
what is not possible yet. Run the read-only checks first; every imperative step here is a deliberate
exception to GitOps and ends with the change put back into git.

The examples reach the API without the tailnet and without the VIP: through one control plane's
public address, which the host firewall opens to `ADMIN_CIDRS`, checking the certificate against the
VIP's address:

```sh
kubectl --kubeconfig ~/.kube/unfold.yaml --server https://<control-plane-public-ip>:6443 --tls-server-name 10.64.0.10 get nodes
```

## The offline seed

Everything below assumes the owner's password manager, with its offline copy, holds the T0 seed. It
must hold:

| Value | Where the original is | Why it must be offline too |
| --- | --- | --- |
| state passphrase | OpenBao `secret/unfold-cluster/tofu-state` | without it the state and the Talos secrets cannot be read |
| the three Hetzner tokens | OpenBao `secret/hetzner/unfold-*` | an apply from a laptop |
| state bucket keys | OpenBao `secret/unfold-cluster/tofu-state` | the same |
| etcd backup age identity | OpenBao `secret/unfold-cluster/etcd-backup` | restoring etcd |
| Talos secrets bundle | OpenBao `secret/unfold-cluster/talos-secrets` | the cluster's identity in a rebuild |
| **disk KMS master key** | OpenBao `secret/unfold-cluster/disk-kms` (`master_key`), the state, the Headscale server | **missing from the seed until now**: it opens every encrypted node disk; with the homelab OpenBao and the state both lost, every encrypted disk is lost |
| **`hcloud-luks` passphrase** | OpenBao `secret/unfold-main/hcloud-luks` (`encryption-passphrase`) | **missing from the seed until now**: it opens every encrypted volume; a rebuilt cluster cannot mount existing volumes without it |

The owner copies the two missing values once, from a homelab-cluster checkout (the values go straight
into the password manager, never into a file or a log):

```sh
bao kv get -field=master_key secret/unfold-cluster/disk-kms
bao kv get -field=encryption-passphrase secret/unfold-main/hcloud-luks
```

## The homelab is down

Still works: every running workload, Flux on the last verified commit, node reboots while
`unfold-headscale` is up, the etcd backup CronJob (it writes to garage-fsn1, not the homelab), the
break-glass admin kubeconfig.

Stops: deploys through pull requests, secret syncs and rotation, plan and apply, OIDC login, new
tailnet devices, every alert, CI.

**Read the cluster.** The admin kubeconfig comes from the state, which lives on garage-fsn1. From a
checkout of this repository, with the state keys and passphrase from the offline seed:

```sh
cd infra
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... TF_VAR_state_passphrase=...
mise exec -- tofu init -backend-config="bucket=unfold-cluster-tfstate" -backend-config="region=garage" -backend-config='endpoints={s3="https://s3-offsite.webgrip.dev"}'
( umask 077; mise exec -- tofu output -raw kubeconfig > ~/.kube/unfold-admin.yaml )
```

The admin kubeconfig is `system:masters` and cannot be revoked; delete the file when done.

**Deploy a change without Forgejo.** Flux accepts any commit on the GitHub mirror's `main` signed by a
key in `kubernetes/clusters/main/flux-system/trusted-signers/`, the owner's included. The mirror's
ruleset `main: no rollback` lets only the mirror's token push, so:

1. In GitHub, *Settings → Rules → Rulesets → main: no rollback*, add yourself to the bypass list.
2. Commit on top of the mirror's `main`, signed with the owner's SSH key (`git commit -S`), and push it
   to GitHub as a fast-forward. Never force-push.
3. Remove yourself from the bypass list.
4. Watch Flux pick it up: `kubectl -n flux-system get gitrepository flux-system`.
5. When Forgejo is back, push the same commit to Forgejo's `main` first. Forgejo's push mirror
   force-pushes, the ruleset refuses that, and until Forgejo's `main` contains the commit the mirror
   stays stuck and the next merge does not deploy.

**Rotate a secret or apply infrastructure.** Not possible yet. The plan reads the disk KMS master key
from OpenBao (`scripts/disk-kms-key.sh` exits `OpenBao could not be read`), and every credential of the
workflow comes from there. [ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md)
adds a laptop apply from the offline seed and moves production's secrets into the cluster. Until
then, wait for the homelab, or for a dead node, accept the outage.

## The GitHub mirror is down or stuck

Still works: everything running. Stops: deploys, also when only the mirror's token has expired, which
nothing shows except that the GitHub `main` falls behind Forgejo's:

```sh
git ls-remote https://forgejo.webgrip.dev/webgrip/unfold-cluster.git refs/heads/main
git ls-remote https://github.com/webgrip/unfold-cluster.git refs/heads/main
```

To deploy from Forgejo instead, point the source at Forgejo for one fetch. Flux applies
`gitrepository.yaml` again from the new commit and resets the address to GitHub; that fetch fails while
GitHub is down, and Flux keeps the artifact it fetched from Forgejo:

```sh
kubectl -n flux-system patch gitrepository flux-system --type merge -p '{"spec":{"url":"https://forgejo.webgrip.dev/webgrip/unfold-cluster.git"}}'
kubectl -n flux-system get gitrepository flux-system -w
```

The signature check is unchanged, so only a trusted-signed commit deploys. Repeat for each later
deploy while GitHub is down. When GitHub is back and the mirror has caught up, Flux fetches the same
commit from there and nothing changes.

## The disk KMS (`unfold-headscale`) is down

Still works: every running node. Stops: a node that reboots stays locked at STATE, and no new node
joins. Do not reboot or upgrade nodes until it is back.

Check it answers TLS with a valid certificate, from an address in `ADMIN_CIDRS`:

```sh
echo | openssl s_client -connect headscale.webgrip.dev:4050 -servername headscale.webgrip.dev 2>/dev/null | openssl x509 -noout -subject -enddate
```

If the server is off, start it in the Hetzner Console. If it is gone, raise `headscale_generation` and
apply: the new server gets the same master key from OpenBao, so every disk opens again. That apply
needs the homelab OpenBao today; with the homelab down too, there is no way back until it returns.
A second KMS in another project (ADR 0015) removes this.

## Cloudflare DNS is down

Nodes reach the KMS by the name `headscale.webgrip.dev` before their machine config is read, through
Hetzner's resolvers, so no host entry in Talos can help. Do not reboot nodes until names resolve again.
Certificate renewals wait; certificates have at least 30 days left when renewal starts.

## Headscale's tailnet is down

Admins use the public path above with the admin kubeconfig and `talosctl` against a node's public
address. External Secrets, metrics and logs to the homelab, and the CI trigger use the tailnet today
and pause.

## Authentik is down

OIDC `kubectl`, Headscale's browser login and Grafana stop. Use the admin kubeconfig as above
([kubernetes-login](kubernetes-login.md#break-glass)); every call it makes shows in the audit log as
user `admin`, which Vector holds in its buffer while the homelab log store is unreachable.

## garage-fsn1 is down

No plan or apply can read the state, the etcd backup fails and alerts after 7 hours, the restore
check fails. Nothing to do from the cluster; bring the box back. The state has no second copy yet
(RFC 0001 step 3).

## An upstream registry is down

Zot serves what it has cached, and nodes fall back to upstream for the rest. Do not replace or reboot
nodes: a booting node pulls Cilium and the control plane images upstream, before Zot runs. Check what
Zot holds: `kubectl -n zot logs zot-0 | grep -i "on demand"`.

## The Hetzner API is down

The API VIP cannot move if its control plane dies; use another control plane's public address as
above. Pods with volumes cannot move to another node, the autoscaler cannot add nodes, and no apply
works. In-cluster clients reach the API servers through KubePrism and keep working.
