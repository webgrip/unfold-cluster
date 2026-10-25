---
status: proposed
date: 2026-10-25
---

# ADR 0008: Ploeg's and Unfold's data move as two encrypted files, verified on both sides

## Context and problem statement

Two datasets move in the cutover ([ADR 0005](0005-unfold-and-ploeg-move-in-one-cutover-after-the-run-gates.md)):

* **Ploeg's database**, `app` in the homelab's CNPG cluster `ploeg-db`: 23 MiB, PostgreSQL 18.
* **Unfold's data directory** on the PVC `unfold-data`: 88 MiB, holding a SQLite database and the store key file that decrypts every stored link and credential.

Everything else is generated again or starts empty here ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md) §4).

The two clusters share no network path for data:

* The tailnet carries only named gateway ports from this cluster into the house ([ADR 0006](0006-production-reaches-the-homelab-from-the-hub-pool-only.md)).
* The homelab's CNPG backups sit in a bucket whose keys reach every homelab database.

## Considered options

* **Two age-encrypted files** (`pg_dump -Fc` and a tarball of the data directory) through a short-lived bucket on this cluster's object storage, each restored by a Job.
* **CNPG's `import` bootstrap** (microservice type) from the homelab primary. This needs a temporary database port across the gateway.
* **CNPG's `recovery` bootstrap** from the homelab's barman backups. It needs a read key on a bucket that holds every homelab database's backups.

## Decision

Chosen option: two age-encrypted files.

1. **Freeze.** The homelab's executor and ploegd go to 0 replicas, and so does Unfold.
2. **Export.** A homelab Job runs `pg_dump -Fc` against the frozen primary. A second Job runs `sqlite3 .backup` and tars it with the store key file. Each output is encrypted with age to a recipient whose identity only this cluster's restore Job can read (`secret/unfold-main/migration/age`). Each Job prints its file's sha256 and the source-side verification output.
3. **Upload.** The Jobs write to the bucket `unfold-migration`, using a key that may write and nothing else. This cluster reads with a key that may read and nothing else.
4. **Restore.** A Job restores into a CNPG cluster created by `initdb`, owned by `app`, with the managed roles declared here and not dumped. An init Job unpacks the data directory into the new PVC before Unfold's first start.
5. **Verify.** One script compares, between source and target:
   * the row counts per table;
   * an md5 per table over its rows in a stable order;
   * every sequence's `last_value`;
   * Ploeg's applied migration versions;
   * SQLite's `integrity_check`, per-table counts and the file sha256.

   It exits non-zero on any difference. On top of that, one stored Unfold link must decrypt.
6. **Delete.** After the 14-day soak, the bucket and both keys are deleted.

The whole sequence is rehearsed twice against the shadow environment before the real window.

## Consequences

* Good, because no database port crosses the tailnet, and this cluster never holds a key to the homelab's backups.
* Good, because the files are small. A rehearsal takes minutes and leaves the source untouched.
* Good, because the reverse direction is the same procedure, which makes rollback during the soak a rehearsed step.
* Bad, because the Jobs are one-off manifests that are removed again after the soak.
* Bad, because the database is dumped and restored logically: anything that depends on physical layout or OIDs is not carried. Ploeg uses neither.

## Confirmation

* The comparison script fails on a target missing one row and on a target with one changed value. It passes on an identical copy.
* The cutover's log shows the script exiting 0, and the decrypt check passing.
* Fourteen days after the cutover, the bucket `unfold-migration` no longer exists.
