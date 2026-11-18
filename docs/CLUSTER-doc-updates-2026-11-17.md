# Cluster Doc Update — 2026-11-17

Incident: a change I made to the Forgejo Volsync movers stopped the Forgejo
database for about six minutes (01:11:45 to 01:17:49 UTC, 2026-11-18).
Written the same evening. Times are UTC unless marked. No data was lost.

## Summary

- `VolSyncVolumeOutOfSync` (critical) fired for `gitea-shared-storage`. Two
  of the three Forgejo Volsync sources had failed every night since the
  cutover (#1071), so the new git data and PGDATA had no Volsync backup
  after 2026-11-14 03:00.
- My first diagnosis and first fix were wrong. My second fix, adding
  `fsGroup: 0` to the mover security context (`5d5a5773`), made the kubelet
  change the group of the live node-local PGDATA volume. Postgres (uid/gid
  26) was locked out, Patroni stopped it, and Forgejo went down.
- Reverted (`37aa307a`) and recovered by restarting the Postgres pod. The
  original Volsync problem is **not fixed**. A candidate fix is tested on a
  throwaway pod and not applied.

## The alert

    alertname = VolSyncVolumeOutOfSync   severity = critical
    obj_name = gitea-shared-storage   obj_namespace = forgejo   method = restic

`gitea-shared-storage` and `postgres-forgejo-pgdata` both had
`lastSyncTime` 2026-11-14T03:00 (the old PVCs, before the cutover) and had
failed on the 11-15, 11-16 and 11-17 runs. `postgres-forgejo-repo1` was fine.
The mover logged:

    unable to open cache: open /cache/CACHEDIR.TAG: permission denied
    ERROR: failure checking existence of repository

The restic repositories were not damaged. The cache open error is what failed
the existence check.

### Cause

#1071 gave those two sources a non-root `moverSecurityContext`
(`runAsUser`/`runAsGroup` 1000 and 26) so they can read the node-local
source files. The restic cache lives on a separate `local-hostpath` PVC
whose directory is `drwxrws--- 0:0`: root-owned, writable only by group 0.
A mover with primary group 1000 or 26 cannot write it. `postgres-forgejo-repo1`
was unaffected because it has no `moverSecurityContext` and runs as root.

## What went wrong

### First attempt (wrong diagnosis)

I assumed the 130-day-old cache PVCs held files owned by the previous uid,
and deleted the Jobs and both cache PVCs. Volsync recreated fresh PVCs and
the movers failed identically. A new empty cache fails the same way, so file
ownership was never the issue. I had also stated the recreated PVC would be
owned by the new uid, which was false.

### Second attempt (the outage)

I copied `immich/postgres/volsync.yaml`, which uses `runAsGroup: 0` and
`fsGroup: 0` on the same `local-hostpath` cache and works, and applied it to
both Forgejo sources (`5d5a5773`). I had not checked what `fsGroup` does to
the **source** volume.

Timeline, from the Patroni log, the events and the sync status:

- ~01:11 `5d5a5773` pushed, reconciled, Jobs deleted so the movers restarted.
- 01:11:34 Patroni last healthy ("leader with the lock").
- 01:11:45 Patroni: `released leader key voluntarily as data dir empty and
  currently leader`, then `waiting for leader to bootstrap` every 10s.
- 01:11:53 and 01:12:12 both Volsync syncs completed `Successful`.
- 01:13 Forgejo `/api/healthz` returns 424; `database ping failed`.
- ~01:15 diagnosis: `/pgdata` is `drwxrws--- 0:0`, unreadable to uid 26.
- Revert pushed as `37aa307a`; Postgres pod deleted.
- 01:17:49 Patroni `promoted self to leader by acquiring session lock`.

### Mechanism (inferred, not read from kubelet logs)

PGO runs the Postgres pod with `fsGroup: 26`, so `/pgdata` is normally
`0:26` mode 2770 and uid 26 gets in through the group. The mover pod mounted
the same PVC with `fsGroup: 0`. The kubelet changes the group of an
`fsGroup` volume to match, and setgid plus group read-write is its signature,
which is exactly what `drwxrws---` was. After that, `/pgdata` was group 0 and
postgres had no access. Patroni's data directory check treated an unreadable
directory as empty and released the leader key. The data was never empty:
the volume stayed `Bound`, 342G used on the disk (shared with other
volumes), and the PVC and PV were untouched.

After the restart the pod's `fsGroup: 26` and `fsGroupChangePolicy:
OnRootMismatch` made the kubelet reapply group 26, because the root group no
longer matched. `/pgdata` returned to `0:26`.

### Why Immich was fine

Immich's Postgres is a plain Deployment with no pod `fsGroup`. Its data
directory is already `999:0` mode 2770, so `fsGroup: 0` on its mover changes
nothing. The pattern worked there only because that volume was already group 0.
Forgejo's PGO volume depends on group 26.

## Recovery

1. Reverted `5d5a5773` as `37aa307a` (my first `git revert` used an invalid
   flag and did nothing; it was caught and redone, no history was rewritten).
2. Deleted `postgres-forgejo-local-instance1-gfzm-0`. Postgres was already
   stopped, so there was nothing to shut down. Approved first.

**Verified:**

- `/pgdata` `drwxrws--- 0:26`, `pg16` `26:26`, `PG_VERSION` `26:26`.
- `pg_isready` accepting connections; Patroni `Leader running`, timeline 1 to
  2 (normal after a promotion); `pg_is_in_recovery` false.
- Forgejo pod `1/1`; `/api/healthz` 200 in-cluster and through
  `susan.gs-farm.net`.
- Counts: 1 repo, 2 users, 0 issues, database 17 MB (previously about 16 MB).
- All pods ready.

Not tested: a login or a git clone, which need credentials.

## Backup status

- **pgBackRest** (the real database recovery path) was healthy throughout:
  hourly incrementals and the full backup completed on `postgres-forgejo-local`.
  The old `postgres-forgejo` cluster also still holds the pre-cutover data.
- **Volsync git data and PGDATA:** the two syncs at 01:11:53 and 01:12:12 are
  the only successful runs since 2026-11-14 03:00. They ran on the broken
  configuration. The PGDATA snapshot was taken while the data directory was
  inaccessible to Postgres, so do not rely on it; PGDATA copied this way is
  crash-consistent at best.
- With `5d5a5773` reverted, the movers are back to the original cache error
  and will fail again at 03:00. `VolSyncVolumeOutOfSync` can keep firing.

## Candidate fix (tested, not applied)

Keep `runAsUser`/`runAsGroup` as they are, since PGDATA needs gid 26 to read
`/pgdata`, and add `supplementalGroups: [0]` so the mover can also write the
group-0 cache. Unlike `fsGroup`, `supplementalGroups` does not make the
kubelet change ownership of any volume.

Tested on a throwaway pod (`cache-perm-test`) that mounted only the two cache
PVCs, with no data PVC and no `fsGroup`:

| Container | id | `/cache` | `mkdir` + `touch` |
|---|---|---|---|
| uid 1000, gid 1000 | `1000,0` | `drwxrws--- 0:0` | `WRITE-OK` |
| uid 26, gid 26 | `26,0` | `drwxrws--- 0:0` | `WRITE-OK` |

The pod and its test files were removed afterwards; `/pgdata` stayed `0:26`.
Applying it to `kubernetes/apps/forgejo/app/volsync.yaml` and watching the next
run is the remaining step, and needs a decision after this incident.

## Gotchas

- **`fsGroup` on a Volsync mover rewrites the group of the *source* volume,
  not just the cache.** On a node-local volume owned by another workload
  (here PGO's, which relies on group 26) that locks the owner out. The mover
  only reads the source; it should never carry `fsGroup`. Use
  `supplementalGroups` if it needs a group for the cache.
- **A pattern that works on another volume proves nothing about this one.**
  Immich worked because its volume was already group 0. Before copying a
  `moverSecurityContext`, compare the *target* volume's owner and group
  (`stat` inside the workload's pod) with what the context will impose.
- **Patroni reports an unreadable data directory as empty.** `data dir
  empty and currently leader` followed by `waiting for leader to bootstrap`
  can be a permissions fault. Check `stat /pgdata` and `ls /pgdata` as the
  postgres user before concluding anything about the data.
- **PGO pods fix the volume's group on restart** (`fsGroup: 26`, policy
  `OnRootMismatch`), so deleting the stopped Postgres pod is a safe first
  repair for a group or mode change on PGDATA.
- **Test a mover's security context on the cache PVC, not the source.** A
  throwaway pod with only the cache mounted and no `fsGroup` shows whether
  the context can write it, with no way to touch live data.
- **Deleting the mover Job is not enough on its own.** Volsync recreates the
  Job within seconds, still on the old PVC. Delete the PVC, then the Job
  again, or stop at a config change.

## Open items

- Decide whether to apply `supplementalGroups: [0]` to both sources, then
  confirm the 03:00 run and that `VolSyncVolumeOutOfSync` clears.
- Try a Forgejo login and a git clone to close the verification gap.
- Consider a check in `weekly-renovate-review.sh health` or an alert for a
  ReplicationSource whose `lastSyncTime` is older than its schedule allows;
  three nights were missed before anything made me look at it.
