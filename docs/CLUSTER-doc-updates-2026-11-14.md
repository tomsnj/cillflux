# Cluster Doc Update — 2026-11-14

Forgejo's Postgres and git data moved off the TrueNAS HDD pool onto node
NVMe (`local-hostpath` on `talos-iok-xpu`). The move was planned in
`docs/plan-forgejo-postgres-local.md` (PR #1068) and cut over in a
planned maintenance window on 2026-11-14. Forgejo logins were verified by
Tom afterwards.

The move was prompted by two Postgres episodes on 11-05 and 11-12. Both
showed storage stalls on the NFS-backed `/pgdata`, followed by a Patroni
standby restart loop. The full timeline is in the plan. The root cause
is not proven. Local storage removes the HDD pool from the commit path,
and the stall mechanism no longer applies to the live data.

## PRs

| PR | What |
|---|---|
| #1068 | Plan (`docs/plan-forgejo-postgres-local.md`) |
| #1069 | New cluster `postgres-forgejo-local` beside the old one |
| #1070 | Empty 20Gi `gitea-shared-storage-local` claim |
| #1071 | Cutover: Forgejo DB secret refs, git-data claim, Volsync sources and movers, old cluster schedules removed |

## Pre-flight

**Node disk.** `local-hostpath` is democratic-csi backed by the node's
`EPHEMERAL` partition, `/dev/nvme0n1p4`, 2.0 TB. containerd uses about
95 GB. Capacity is not a constraint for 20Gi volumes.

**Storage link.** `172.16.99.0/30` is a dedicated point-to-point link,
TrueNAS `enp10s0` (`172.16.99.2`) to the node `enp41s0` (`172.16.99.1`).
It is 10 Gb full duplex. `gsks1-fast` and `gsks0-fast` use it. They are
the same `home_nfs` pool as `gsks1` and `gsks0`, so they add link speed
but not disk speed.

**Node routing.** The node reaches `10.0.0.169` on-link through
`enp37s0` in `10.0.0.0/16`, with no gateway hop.

**Throwaway test.** A PGO cluster `pg-localtest` on `local-hostpath`,
in its own namespace, came up Ready with `stanzaCreated: true`. The
namespace was deleted afterwards.

- PGO runs Postgres as uid **26**, not 999 as on the Immich move. The
  data directory is `26:26`, mode `750`.
- Synchronous write test, 2000 × 8 KB with `dd oflag=dsync`:
  - local NVMe: 2.5 s (about 1.2 ms per write)
  - NFS (`gsks1`): 40.8 s (about 20 ms per write)

  That is roughly 16×.

## Cutover

Phases are as in the plan. The window started at 16:25 UTC.

1. **Build.** `postgres-forgejo-local` (PG16, 20Gi local, pgBackRest repo
   on `gsks1` 5Gi). Schedules are offset from the old cluster's: full at
   02:30, incremental at :40.
2. **Rehearsal.** Dump with `pg_dump -Fc` over TCP, restore with
   `pg_restore --clean --if-exists --no-privileges`. All 130 application
   tables matched on row count. The only mismatch was
   `pg_stat_statements`, which counts query statistics and changes on
   every query.
3. **Window.**
   - Suspended `kustomization/forgejo` and `hr/forgejo`, so Flux would not
     undo the scale-down.
   - Scaled the `forgejo` Deployment to 0. Confirmed no Forgejo pod was
     running.
   - Set PV `pvc-d912c8f2-…` (old `gitea-shared-storage`) to `Retain`.
   - Final `pg_dump` and `pg_restore`. Row counts matched again.
   - Copied git data with `cp -a` per top-level entry as uid 1000. The
     job does this instead of `cp -a /old/. /new/`, because the volume
     root can't be re-timed by uid 1000. Verified: 237 entries each, file
     bytes 117,150 each, owners and modes identical, and per-file
     SHA-256 sums identical.
   - Merged #1071 pinned to `0503755d`. Resumed Flux. Forced HelmRelease
     reconcile.
4. **After.** Forgejo `1/1 Running`, chart `forgejo@17.3.2`. The pod
   mounts `gitea-shared-storage-local`. The init container writes
   `app.ini` from `postgres-forgejo-local-pguser-forgejo`, and the
   database host is `postgres-forgejo-local-primary.forgejo.svc`. Public
   endpoint returns 200. All three Volsync sources point at the new PVCs
   and report `Successful`. All Kustomizations and HelmReleases are Ready.
   The 14 internal ingresses respond.

**Residual difference.** The volume root of the new git-data claim is
`0:1000` mode `2770`. The original was `2775`. Root is owned by uid 0,
which the copy job cannot change. Forgejo runs as group 1000, so the
group access it needs is intact.

**Chart behaviour.** Setting `persistence.create: false` with a new
`claimName` did not delete the old chart-created PVC on upgrade. It is
still bound. Keep it until retirement (see below).

## Cleanup

- The failed backup Job `postgres-forgejo-repo1-incr-29907970` and its
  seven failed pods are gone. Removing the old cluster's schedules made
  PGO delete its CronJobs and their Jobs. `KubeJobFailed` and
  `PostgresWALArchiveFailing` are no longer firing.
- The three migration helper Jobs (`pg-rehearsal`, `pg-counts-new`,
  `git-copy`) were deleted once complete.

## Retirement reminder

The old cluster `postgres-forgejo` stays idle for 14 days. It is the
rollback target. A one-shot reminder is set for **2026-11-28 09:17 local**.
It is session-only, so it lasts only as long as this Claude session.

Retirement needs approval, then:

- delete the `postgres-forgejo` PostgresCluster and its PVCs
  (`postgres-forgejo-instance1-wz59-pgdata`, `postgres-forgejo-repo1`)
- delete the Retained PV `pvc-d912c8f2-…` and its PVC
  (`gitea-shared-storage`)
- remove the old manifests from git

Before retiring, confirm: `postgres-forgejo-local` has completed full and
incremental backups since cutover, and no regressions are reported.

## Open items

- **PodMonitor.** `podmonitor.yaml` still targets the old cluster. The new
  cluster needs its own, or its exporter metrics are not scraped.
- **Old-cluster rollback window.** After new writes land on the new
  cluster, rollback is a logical dump back into the old cluster inside a
  new window, not a revert.
- **`postgres-infra-local`.** It runs on `gsks0`, the same HDD path, with
  its own history of restarts. It needs the same review. Track it as its
  own plan.
- **`gsks1` and `gsks0` clients.** Other NFS-backed volumes on these
  classes may show the same stall under load. None has been checked
  against the new evidence.

## Takeaways

- **Check the runtime uid from the operator, not from memory.** PGO's
  Postgres uid is 26. The Immich move used 999. A Volsync mover running
  as the wrong uid fails with `Permission denied` on local disk, and NFS
  squashing had hidden that until now.
- **`helm`'s `create: false` does not clean up the old claim.** Helm
  leaves the chart-created PVC bound. Set the PV to `Retain` before any
  change that drops a chart-owned claim, and keep it until retirement.
- **Suspend Flux before a manual scale.** `flux suspend hr` and
  `flux suspend kustomization` stop Flux from reverting a manual
  `kubectl scale`. Resume both after the cutover merge.
- **Compare copies per file, sorted.** A concatenated checksum changes
  with `find`'s traversal order, which differs between filesystems. A
  sorted per-file `sha256sum` does not.
- **Check the test tool before the measurement.** Busybox `dd` has no
  `dsync`, so the first NFS test measured nothing. The Postgres image's
  `dd` gives a valid result.
- **Removing a PGO schedule removes its CronJobs, and their failed Jobs
  with them.** This cleared the `KubeJobFailed` alert without manual
  deletion.
