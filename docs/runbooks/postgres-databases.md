# Postgres databases (CloudNativePG)

RFC 0001 section 7 and delivery step 10. CloudNativePG runs Postgres; the barman-cloud plugin
archives WAL and takes base backups to object storage; a weekly drill proves a backup restores.

## What runs where

| Piece | Where | Owner |
| --- | --- | --- |
| CloudNativePG operator 1.30.1 | `cnpg-system`, on the control planes (recovery set) | Flux Kustomization `cloudnative-pg` |
| barman-cloud plugin v0.15.1 | `cnpg-system`, on the control planes; its mutual TLS comes from cert-manager | Flux Kustomization `plugin-barman-cloud` (after `cloudnative-pg` and `cert-manager`) |
| A database | its own namespace, instances on the hub pool (`node.webgrip.io/pool=unfold`) | the app's Flux Kustomization, built from the template below |

## The template

[`kubernetes/platform/cloudnative-pg/cluster-template`](../../kubernetes/platform/cloudnative-pg/cluster-template)
is the only way a database is made. An app includes it and fills it through Flux `postBuild.substitute`:

```yaml
# kubernetes/apps/<app>/database/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app>
resources:
  - ../../../platform/cloudnative-pg/cluster-template
components:
  - ../../../platform/cloudnative-pg/cluster-template/backup
```

```yaml
# the app's Flux Kustomization
spec:
  dependsOn:
    - name: plugin-barman-cloud
  postBuild:
    substitute:
      CNPG_CLUSTER: <app>-db
      CNPG_NAMESPACE: <app>
      CNPG_DATABASE: <app>
      CNPG_OWNER: <app>
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `CNPG_CLUSTER`, `CNPG_NAMESPACE`, `CNPG_DATABASE`, `CNPG_OWNER` | required | names |
| `CNPG_INSTANCES` | `1` | raise to 3 once the hub pool has three nodes; anti-affinity is `required`, so a third instance on two nodes stays Pending |
| `CNPG_ENABLE_PDB` | `false` | `true` with more than one instance; with one, the PDB would block every node drain |
| `CNPG_STORAGE_SIZE`, `CNPG_WAL_SIZE` | `10Gi` each | separate `hcloud-luks` volumes, so WAL growth cannot fill the data volume |
| `CNPG_CPU_REQUEST`, `CNPG_MEMORY_REQUEST`, `CNPG_MEMORY_LIMIT` | `100m`, `256Mi`, `1Gi` | |
| `CNPG_BACKUP_HOST`, `CNPG_BACKUP_BUCKET` | `nbg1.your-objectstorage.com`, `unfold-cnpg` | backup component only |
| `CNPG_BACKUP_WRITER_CREDENTIALS_KEY`, `CNPG_BACKUP_READER_CREDENTIALS_KEY` | `unfold-main/cnpg-backup/hetzner-nbg1-writer`, `…-reader` | OpenBao paths, each with `access-key-id` and `secret-access-key` |
| `CNPG_BACKUP_SCHEDULE`, `CNPG_RESTORE_DRILL_SCHEDULE` | daily 02:00, Sunday 04:00 UTC | |

What every database gets:

- Postgres 18.6 (`minimal` image; the plugin's sidecar carries barman-cloud), data checksums on.
- TLS 1.3 only, and `pg_hba` that refuses every connection that is not TLS: `hostssl all all all
  scram-sha-256`, then `host all all all reject`. Certificate-only client authentication (RFC 0001
  section 11) is the next step and needs a client CA per database.
- A CiliumNetworkPolicy: the operator reaches the instances on 8000, the instances reach each other
  on 5432 and 8000, and only pods labelled `cnpg.webgrip.io/client: <cluster>` reach 5432.
- A `restore_canary.marks` table owned by the app's role, which the drill writes to.
- The namespace must carry `external-secrets.webgrip.io/openbao-homelab: allowed` when the backup
  component is used.

## Backups: built, off until the bucket exists

The backup component adds, per database: the plugin as WAL archiver on the Cluster, an
`ObjectStore` that writes to `s3://<bucket>/<namespace>/<cluster>/`, a second `ObjectStore` with
read-only credentials that only the drill uses, a daily `ScheduledBackup`, the egress rule to the
store's name and nothing else, and the restore drill.

It is **not included anywhere yet**, on purpose. The target RFC 0001 chose for CNPG backups, Hetzner
Object Storage in Nuremberg with a scheduled copy to OVHcloud, does not exist, and a WAL archiver
pointed at a missing bucket keeps every WAL segment on the volume until it fills. Include the
component only after the bucket and both keys exist.

The writer key never deletes: there is no `retentionPolicy` on the ObjectStore. Expiry is a bucket
lifecycle rule (35 days keeps 30 days of restorable history with daily base backups), the same
pattern as the etcd snapshots, so a stolen writer key cannot erase history. barman-cloud cannot
encrypt on the client; at Hetzner the copy relies on the provider, at OVH on `AES256` server-side
encryption (RFC 0001, object storage).

### Cost, and the owner decision

| Item | Cost |
| --- | --- |
| Hetzner Object Storage (one subscription covers etcd, OpenTofu state, Zot and CNPG; 1 TB storage and 1 TB egress included) | €6.49 a month, already in RFC 0001 delivery step 3 |
| OVHcloud second copy | about €3.30 a month at the start |
| Each database's two 10 GB volumes | about €0.88 a month |
| The weekly drill's throwaway volumes | an hour a week, cents a month |

The decision is RFC 0001 step 3's: order the object storage. Then, per provider, create a write key
and a read-only key in its console (if the provider cannot scope a key to read-only, use a second
key and say so in the PR), and seed them:

```sh
cd ~/projects/webgrip/homelab-cluster
just secret-set unfold-main/cnpg-backup/hetzner-nbg1-writer access-key-id
just secret-set unfold-main/cnpg-backup/hetzner-nbg1-writer secret-access-key
just secret-set unfold-main/cnpg-backup/hetzner-nbg1-reader access-key-id
just secret-set unfold-main/cnpg-backup/hetzner-nbg1-reader secret-access-key
```

## The restore drill and its canary

`<cluster>-restore-drill` runs weekly in the database's namespace:

1. **write-canary** inserts a fresh random token into `restore_canary.marks` as the app's role, over
   `verify-full` TLS, and notes the WAL segment that holds it. It waits until `pg_stat_archiver`
   reports that segment archived (CNPG's `archive_timeout` is five minutes); 30 minutes without it
   fails the drill as "WAL archiving is broken".
2. **recover** creates `<cluster>-drill`, a one-instance Cluster recovered from the read-only
   ObjectStore onto `hcloud-luks-drill` volumes, and waits up to an hour for it to be Ready.
3. **read-canary** reads the token back from the recovered cluster. Present means base backup plus
   WAL replay reached the latest archived segment; absent fails the drill.
4. **discard** deletes the throwaway cluster; its volumes go with it (`reclaimPolicy: Delete`).

A failed drill leaves `<cluster>-drill` in place to inspect, and the next run deletes it first. The
drill holds `create` on Clusters and `get`, `watch` and `delete` on `<cluster>-drill` only.

The failure signal is the Job: kube-state-metrics already ships `kube_job_status_failed` and
`kube_cronjob_status_last_successful_time` to the homelab, and the alert on a failed or missing
drill is added with the first database.
