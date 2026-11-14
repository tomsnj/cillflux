# Plan — move Forgejo's Postgres off NFS onto node-local storage

**Status:** proposed, not implemented. Written 2026-11-14.
**Owner:** Tom. Nothing here is applied until approved.

## The problem

`postgres-forgejo` (PGO, PostgreSQL 16) keeps its data directory on an
NFS volume from TrueNAS:

- Instance PVC `postgres-forgejo-instance1-wz59-pgdata`: 5Gi, `gsks1`
- pgBackRest repo PVC `postgres-forgejo-repo1`: 5Gi, `gsks1`

`gsks1` mounts `10.0.0.169:/mnt/storage1/home_nfs/knfs`, which sits on
the TrueNAS HDD mirror (about 78 combined IOPS). The database is small
(about 16 MB), but its write path is not. Evidence from the 2026-11-05
and 2026-11-12 episodes (`/pgdata/logs/postgres/postgresql-Thu.log`):

- Checkpoint `sync` times of 1–4 s routinely, and a checkpoint `total`
  of 113 s at 07:11 on 11-12. Normal is about 0.05 s.
- `archive-push` exceeded its 60 s async timeout (exit 82) from 08:21 to
  15:47 on 11-12. The WAL did reach the repo later.
- Patroni's health query hit `statement timeout` at 10:12:36. Postgres
  got a fast-shutdown request at 10:12:38 and restarted at 10:20:32 as
  a **standby** (`entering standby mode`). It then sat in archive
  recovery until the liveness probe killed it. That is the restart loop.

TrueNAS reports no scrub, resilver, replication, pool error or NIC
reset in either window. The stall is visible from the client, and the
pattern is consistent with an HDD-bound volume under commit load. It has
not been proven as the root cause, and this plan does not depend on that
proof: local disk removes the HDD from the commit path either way.

Tom's observation, which this plan accepts: a faster network does not
fix an HDD-bound volume. `gsks1-fast` and `gsks0-fast` exist as
classes, but they point at `172.16.99.2`, the same `home_nfs` pool over a
dedicated 10 Gb point-to-point link. They would move the bottleneck
around, not remove it.

## Decision

Move the live data directory to `local-hostpath` on `talos-iok-xpu`
(node NVMe). Do **not** do an in-place storage-class change on the
existing cluster. Build a new PostgresCluster beside the old one, copy
the data with a logical dump, and cut the application over. The old
cluster stays untouched until the cutover is verified.

Why not in place: PGO does not migrate data between storage classes. A
`storageClassName` change on an existing instance would provision a
fresh, empty volume beside the old one and leave the cluster in an
undefined state.

The pgBackRest repo stays off-node (see the section on the 10 Gb link).

## Target design

| Item | Old (keep until rollback is retired) | New |
|---|---|---|
| Cluster name | `postgres-forgejo` | `postgres-forgejo-local` |
| PostgreSQL | 16 | 16 (same major, so `pg_dump` restore is straightforward) |
| Instance data | `gsks1`, 5Gi, NFS | `local-hostpath`, **20Gi** (WAL headroom) |
| pgBackRest repo1 | `gsks1`, 5Gi | `gsks1`, new 5Gi PVC, **new stanza** |
| Schedules | full `30 1 * * *`, incr `10 * * * *` | same, offset to avoid overlap with the old cluster while both exist |
| App credentials secret | `postgres-forgejo-pguser-forgejo` | `postgres-forgejo-local-pguser-forgejo` |

Sizing check: 20Gi holds the data, WAL during a full-backup window, and
headroom. Confirm the `talos-iok-xpu` disk behind `local-hostpath` has
at least 25 Gi free before starting.

The new repo PVC is a separate NFS volume, so there is no shared stanza
with the old cluster.

## Pre-flight (no changes to the live cluster)

1. **Node disk.** Confirm free space on the `local-hostpath` disk on
   `talos-iok-xpu` (`talosctl` read, no writes).
2. **PGO on local-hostpath.** The Immich precedent was a non-PGO
   deployment. PGO has not been shown to work on `local-hostpath` in
   this cluster. Prove it first with a throwaway cluster in a scratch
   namespace (`postgres-scratch`, `postgres-forgejo-test`). Delete it
   afterwards. This step needs approval because it creates real volumes.
3. **Permissions.** On local disk the data directory is `0700` and owned
   by the PostgreSQL uid. On NFS the export squashed this away. Check
   the uid the new cluster's pod runs as (`kubectl get pod … -o
   jsonpath='{.spec.securityContext}'`, and the uid of files in
   `/pgdata` from a read-only check) before setting any mover uid. The
   Immich move used 999. PGO images normally use 26. **Verify, do not
   assume.**
4. **Volsync `ReplicationSource` inventory.** Two sources read this
   cluster today: `postgres-forgejo-pgdata` (sourcePVC
   `postgres-forgejo-instance1-wz59-pgdata`) and `postgres-forgejo-repo1`.
   The new cluster's PVCs have new names. Each source must be updated in
   the same commit as its PVC change (Immich lesson).
5. **Current backup state.** Confirm the last full and incremental
   backups succeeded (`status.pgbackrest.repos[].stanzaCreated` and
   `status.pgbackrest.scheduledBackups`), and that the 03:00 Volsync
   copies of `postgres-forgejo-pgdata` and `postgres-forgejo-repo1` are
   Successful. Both were Successful at 03:00 today.
6. **Logical dump rehearsal.** Dump the current database and restore it
   into the new cluster, then compare row counts per table and a
   `pg_dump --schema-only` diff. Do this before any maintenance window.

## Cutover runbook

Each step has a gate. Stop and roll back if a gate fails.

**Phase 1 — build the new cluster (no traffic).**
1. Add `kubernetes/apps/forgejo/postgres/postgres-cluster-local.yaml`
   with the design above. Add it to the `postgres` kustomization.
   Commit to a branch, open a PR, merge after `flux-diff` passes.
2. Gate: `kubectl get postgrescluster -n forgejo postgres-forgejo-local`
   shows the instance Ready, and `stanzaCreated: true` for its repo.
3. Gate: `pg_stat_archiver` on the new cluster shows `failed_count` not
   rising, and the first full backup of the new repo completes.

**Phase 2 — rehearsal (no maintenance window yet).**
4. Dump the old cluster over TCP to the scratch area, restore into the
   new cluster, compare counts and schema (pre-flight step 6).
5. Gate: all tables match, no errors in the restore log.

**Phase 3 — cutover window (planned; announce it).**
6. Scale the Forgejo Deployment to 0 replicas. This stops all writes.
7. Final logical dump from the old cluster (`pg_dump -Fc`), restore into
   `postgres-forgejo-local`, run `ANALYZE`.
8. Gate: row counts match the old cluster as of the stop. Forgejo's
   `forgejo` role owns the same objects.
9. In **one commit**: point the Forgejo HelmRelease at
   `postgres-forgejo-local-pguser-forgejo` for host, user and password,
   and update both Volsync `ReplicationSource` sourcePVC references to
   the new PVC names. Merge. Flux reconciles.
10. Scale Forgejo back to 1. Gate: pod Ready, and the database host in
    Forgejo's logs is the new cluster.
11. Verify logins (Tom: Forgejo SSO), a git clone, a push to a test
    repo, and the admin page. Gate: all pass.

**Phase 4 — soak and retire.**
12. Keep the old cluster running but unused for at least 14 days. It is
    the rollback target. Set its schedules to off after cutover so its
    repo stops growing.
13. After 14 days with no regressions, and after the first 7 daily
    full backups of the new repo have succeeded, delete the old cluster
    and its PVCs. This is a destructive step: it needs approval.

## Rollback

- **Before step 9 merges:** nothing changed for users. Scale Forgejo
  back up. Nothing to undo.
- **After step 9, before any new writes land on the new cluster:** revert
  the commit (restores the old secret refs and Volsync sources), scale
  Forgejo up. The old cluster still holds the pre-cutover data.
- **After new writes land:** the old cluster no longer matches. Rollback
  then means a logical dump from the new cluster back into the old one,
  inside a second window. Decide before cutover whether to accept that
  or to keep the window small enough that it is unlikely.

Retire the old cluster only after the rollback criteria have expired
(step 13).

## Backups and the 10 Gb point-to-point link

Question raised: put pgBackRest on the point-to-point 10 Gb link to keep
backup traffic off the LAN?

Facts:
- The `172.16.99.0/30` link is 10 Gb full duplex (`enp41s0` on the node,
  `enp10s0` on TrueNAS). `gsks1-fast` already uses it for the same
  `knfs` share.
- The pgBackRest repo is currently on `gsks1` over the LAN
  (`10.0.0.169`).
- The archive failures were caused by latency at the source. The async
  push waited 60 s on the storage stall, and the repo ultimately got the
  files. A faster network does not reduce HDD commit latency.

Recommendation: **keep the repo on the LAN path for this cutover**, and
treat `gsks1-fast` as a separate, later decision. Reasons:

1. One variable at a time. The cutover already changes the storage of the
   live data. Changing the repo path in the same change makes any
   failure ambiguous.
2. Same HDD pool. The 10 Gb link moves the repo's bytes faster, but the
   spindles are the same. Measure repo write latency on each path before
   deciding (`ioping` or a short `dd` from a debug pod, with approval).
3. A second NFS path is a second failure mode. If the point-to-point link
   drops, `archive_command` fails and WAL accumulates on the 20Gi local
   volume. That is the same signature as the alert on 11-12, so the link
   needs its own monitoring before it carries the only archive path.
4. Keep the repo **off-node**. A local repo would be lost with the node.
   Node loss is the scenario the off-node repo protects against.

If the later measurement favours `gsks1-fast`, the change is a repo
migration (a new `repo1` PVC on `gsks1-fast`, a new stanza, and a check
of `archive-get` from a restore). It is not a storage-class edit.

## Verification (end state)

- `kubectl get postgrescluster -n forgejo postgres-forgejo-local` Ready,
  one replica.
- Liveness: no restarts over 7 days. The probe is not required to carry
  storage stalls, because the data is local.
- `pg_stat_archiver` `failed_count` flat over 7 days.
- Scheduled full and incremental backups succeed daily.
- Volsync `postgres-forgejo-pgdata` and `postgres-forgejo-repo1` report
  Successful against the **new** PVCs. Confirm `sourcePVC` matches.
- Forgejo logins, git operations and the admin UI work (Tom verifies).

## Risks

- **Node loss.** The data is on one node's disk. Recovery is the off-node
  pgBackRest repo: restore into a new cluster. Test that restore once
  before retiring the old cluster. This is the main risk the move adds.
- **Node reinstall.** A Talos reinstall wipes `local-hostpath` volumes.
  Treat a reinstall as a restore event, not a routine step.
- **Local-hostpath capacity.** A single disk with no quota. Monitor it.
- **Permission drift.** The uid mismatch from the Immich move. Covered by
  pre-flight step 3.
- **Scope creep.** Forgejo's git data volume `gitea-shared-storage`
  (20Gi, `gsks?`) is also on NFS and may hit the same class of stall
  under git load. That is out of scope here and should get its own plan.

## Out of scope

- `postgres-infra-local` (PG18 for the infrastructure namespace). It is
  also on `gsks0` (50Gi, same HDD path) and needs the same review. Track
  it separately.
- Immich's Postgres, already on `local-hostpath`.
- Changing the NFS classes themselves.

## Open questions for Tom

1. Approve the approach: a new cluster beside the old one, with a
   logical dump, rather than an in-place change?
2. Maintenance window: when, and how long can Forgejo be unavailable? The
   database is small, so the expected outage is minutes.
3. Approve the throwaway PGO-on-local-hostpath test (pre-flight step 2)?
4. Keep the pgBackRest repo on the LAN path for this cutover, as
   recommended, or move it to `gsks1-fast` now?
5. Is `gitea-shared-storage` a priority for its own plan?
