# Proposal — move Immich's Postgres off NFS onto node NVMe

**Status:** proposed, not implemented. Written 2026-09-15.

## The problem

`immich-postgres-data` (20Gi PVC, **313 MB actually used**) sits on
`gsks0` — the TrueNAS HDD mirror, ~78 combined IOPS — alongside
`immich-library` (1Ti, currently 132 GB of photos). A hot
transactional database and a bulk media store compete for the same
spindles.

This is not theoretical. During the 2026-09-15 Amazon import at
`--concurrent-tasks 2`:

- Postgres stopped answering `pg_isready` for over three minutes.
- Its liveness probe killed it (`exit 137`, SIGKILL).
- `immich-server` then crash-looped (`exit 1`, up for two seconds at a
  time) because its database had vanished, hitting `BackOff`.
- The import aborted with 54 errors after 119 uploads.
- Five server restarts and one Postgres restart.

Node CPU was 10% and memory 42% throughout. Nothing was short of
compute; the database was starved of disk.

Three fixes this week were all downstream of this single cause:
probe timeouts on the server (`584e7f8e`), the same on Postgres
(`0d1499d0`), and a liveness period increase (`a5534ff3`).

**Important caveat, discovered after those fixes:** dropping to
`--concurrent-tasks 1` took throughput from 4/min with cascades to
**17/min with zero restarts**, median upload 14.5s → 3.4s. Parallel
writes were thrashing the mirror. So the ceiling is substantially
further away than it appeared, and this proposal is no longer urgent -
but the placement is still wrong, and the next bulk workload will find
it again.

## Precedent: Frigate already does this

`kubernetes/apps/frigate/app/helmrelease.yaml` splits its storage and
says why:

```yaml
# Separate small PVC for the SQLite DB - keeps it off NFS for performance
# (NFS + SQLite under write load can cause locking issues)
data:
  storageClass: local-hostpath
```

Frigate: bulk recordings on `gsks1` (500Gi NFS), database on
`local-hostpath`. Immich puts both on NFS. **Immich is the outlier**,
and it is the one app whose database gets hammered by its own bulk
ingest.

`local-hostpath` is not a compromise tier - it is the Talos node's
`/dev/nvme0n1p4`, 1.9 TB with 1.6 TB free, already carrying MinIO's
233 GB of backups, Frigate's database, and every Volsync cache.

## Proposal

Move `immich-postgres-data` from `gsks0` to `local-hostpath`. Leave
`immich-library` on `gsks0` - bulk sequential media is what that pool
is good at.

## The real cost: failure domains collapse

Today's layout has a property worth preserving, whether or not it was
deliberate:

| | Primary | Backup |
|---|---|---|
| Today | TrueNAS (NFS) | Node NVMe (MinIO) |
| After this change, for Postgres | **Node NVMe** | **Node NVMe** |

Right now TrueNAS failing loses primaries but keeps backups, and the
node failing loses backups but keeps primaries. Moving Postgres to the
node puts its primary data *and* its restic snapshots on the same
physical disk.

The photo files would survive on TrueNAS, but the database holds every
album, face cluster, and piece of metadata - the entire result of this
week's migration. Losing it means re-importing ~18,000 assets and
rebuilding all derived data.

**This change should not be made without the mitigation below.**

## Mitigation: a second, independent backup path

Add a nightly `pg_dump` to a `gsks1`-backed PVC (TrueNAS), separate
from the Volsync/restic snapshot:

- **Different failure domain** - lands on the NAS, not the node.
- **Different format** - a logical dump, not a filesystem snapshot, so
  it survives a corrupted data directory that restic would faithfully
  preserve.
- **Cheap** - 313 MB compresses to very little, and the existing
  Volsync run takes 73 seconds.

A `CronJob` running `pg_dump -Fc` into a small PVC, with a handful of
dated files retained, is enough. This is worth doing *regardless* of
whether the NVMe move happens - a single backup mechanism for
irreplaceable metadata is thin either way.

## Migration procedure

The database is 313 MB, which makes this far lower-risk than it
sounds. Total downtime should be a few minutes.

1. **Fresh backup first.** Trigger the Volsync source manually and
   confirm it completes:
   `kubectl patch replicationsource immich-postgres-data -n immich --type=merge -p '{"spec":{"trigger":{"manual":"premigrate"}}}'`
2. **Also take a logical dump** to somewhere off-cluster:
   `kubectl exec -n immich deploy/immich-postgres -- pg_dump -Fc -U immich immich > immich-$(date +%F).dump`
3. **Scale the app down** so nothing writes: `immich-server` to 0
   replicas, then Postgres to 0.
4. **Create the new PVC** (`immich-postgres-data-nvme`, 20Gi,
   `local-hostpath`). Note `WaitForFirstConsumer` binding - it will
   stay Pending until a pod mounts it, which is expected.
5. **Copy the data** with a throwaway pod in `kube-system` (the only
   PSA-exempt namespace) mounting both PVCs, `rsync -aHAX` between
   them. Verify byte counts match.
6. **Repoint** `postgres.yaml` to the new claim, commit, reconcile.
7. **Verify**: Postgres starts, `/api/server/version` responds, asset
   count matches 18,521 (or whatever it is at the time), a few
   thumbnails load.
8. **Leave the old `gsks0` PVC in place** for at least a week before
   deleting - it is 20Gi of a 1.5T pool and it is the cheapest
   rollback available.

## Rollback

Repoint `postgres.yaml` at the original `immich-postgres-data` claim
and reconcile. As long as step 8 is respected, the old data directory
is untouched and the rollback is a one-line revert.

## What this does not fix

- **The library is still on the HDD mirror.** Bulk imports remain
  IOPS-bound; this only stops them taking the database down with them.
- **No HA.** Single node, single replica, single NAS.
- **Not a substitute for an SSD tier on TrueNAS**, which would fix
  this class of problem for every app while keeping redundancy and
  separate failure domains. This proposal is the zero-hardware
  approximation of that.

## Related finding

`frigate-data` (the Frigate event database, on node NVMe) has **no
`ReplicationSource` at all** - it is not backed up anywhere. Every
other stateful app in the cluster has one. Unrelated to this proposal
but found while writing it, and worth its own decision.
