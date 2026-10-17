# Cluster Doc Update — 2026-10-14

Forgejo's Postgres had never archived WAL or taken a pgBackRest backup.
The cause was a pinned database image that did not match the operator's
pgBackRest, and it had been failing silently since the cluster was
built. Fixed, backed up, reindexed, and now alerting. The work spans
2026-10-13 evening (Eastern) into 2026-10-14 UTC.

## What was wrong

The alert that prompted this (`KubePodNotReady` for a Forgejo pod) was
noise: that pod belonged to an old ReplicaSet and was already gone. The
real problem was found while checking it.

- **WAL archiving had never worked on `postgres-forgejo`.** The stanza
  was never created. `pg_stat_archiver` showed `archived_count=0`,
  `failed_count=801`. Cause: `spec.image` was pinned to
  `crunchy-postgres:ubi8-16.4-0`, which bundles pgBackRest **2.52.1**,
  while the operator's sidecars and repo host run **2.59.0**. Every
  stanza-create failed with `expected value '2.52.1' ... got '2.59.0'`
  (exit 39).
- **No scheduled backups.** The repo had no `schedules`, so only a
  one-off full existed. `repo1-retention-full` was unset.
- **No Postgres metrics anywhere.** Neither PGO cluster ran the
  postgres exporter, and the `postgres-infra` PodMonitor selected
  `postgres-infra`, while the cluster is named `postgres-infra-local`.
  No alert could have fired on any of the above.
- **Collation mismatch.** After the image change, every database on the
  cluster reported `collation version mismatch` (created under glibc
  2.28, OS now provides 2.34). Locale `en_US.utf-8`, so text index order
  could differ.
- **Operator error on `postgres-forgejo`.** `ConfigMap
  "forgejo-init-sql" not found` on every reconcile. The ConfigMap was
  never committed; nothing mounted it.

## Changes merged

| PR    | Change                                                                 |
|-------|------------------------------------------------------------------------|
| #997  | Drop the pinned `crunchy-postgres` image; operator default is `ubi9-16.15-2633` (Postgres 16, pgBackRest 2.59.0) |
| #998  | Daily full at 01:30 UTC, hourly incremental at :10, `repo1-retention-full: 7` |
| #999  | Enable the postgres exporter on `postgres-forgejo`, add PodMonitor |
| #1000 | Set `namespace: forgejo` on the PodMonitor (#999 broke the apply; see below) |
| #1001 | Exporter + selector fix on the shared component, and a `postgres` PrometheusRule |
| #1002 | Revert the exporter on `postgres-infra-local` (PG18 is unsupported); scope `PostgresExporterAbsent` to forgejo |
| #1003 | Remove `databaseInitSQL` pointing at the missing ConfigMap            |

### Mistakes made along the way

- **#999 broke the forgejo Kustomization.** The PodMonitor had no
  namespace, and `postgres-forgejo` has no `targetNamespace`, so Flux
  rejected the whole apply and `forgejo` showed `dependency not ready`.
  Forgejo itself was unaffected. My dry run passed because `kubectl`
  falls back to a default namespace and Flux does not. Fixed in #1000.
- **#1001 enabled the exporter on Postgres 18.** The shared component
  was verified only on the Postgres 16 forgejo cluster. PGO 6.0.3 does
  not support `postgres_exporter` on PG18 (`use OTel for postgres 18 and
  later`). The exporter could not log in (`ccp_monitoring` never
  created), the target showed `up` with no metrics, and the operator
  reconcile failed roughly every 11 seconds. Reverted in #1002. Keycloak
  restarted once and recovered.
- **The `postgres-infra` Kustomization patches in users for four
  databases with no running app.** Only Keycloak uses `postgres-infra-local`.
  Left in place; logged as a to-do in `CLUSTER.md`.

## Verified live

- **Forgejo Postgres (`postgres-forgejo`):** pod `5/5`; image
  `ubi9-16.15-2633`; `stanzaCreated=true`.
- **Archiving:** `archived_count` rising (306 at last check); `failed_count`
  stuck at 840, the count from before the fix. No new failures.
- **Backups:** the first scheduled incremental (`20261014-001001I`)
  completed. A manual full (`20261014-003434F`) completed in 91 seconds
  (38.5 MB database, 4.3 MB in the repo). `pgbackrest check` exits 0.
- **Exporter:** target `cpgo-postgres-forgejo` `up`,
  `pg_exporter_last_scrape_error=0`.
- **Infra-local:** pod `4/4`, Keycloak `1/1` and reachable
  (`elvis.gs-farm.net` 200). Operator reconcile errors stopped.
- **Alerts:** all five `postgres.rules` evaluate `ok`; none firing.
- **Forgejo app:** `susan.gs-farm.net` 200 throughout; one database ping
  failure during the exporter restart, none since.

## Manual backup (outside GitOps)

Before the reindex, a full backup was taken with:

    kubectl exec -n forgejo postgres-forgejo-instance1-wz59-0 -c pgbackrest -- \
      pgbackrest backup --stanza=db --repo=1 --type=full

The operator's manual-backup route needs a `spec.backups.pgbackrest.manual`
block, which `postgres-forgejo` does not have. The backup lives in the
repo and shows in `pgbackrest info`, but the operator's status does not
record it.

## Reindex and collation refresh

Run with Tom's go-ahead, after the backup above.

    kubectl exec -n forgejo postgres-forgejo-instance1-wz59-0 -c database -- \
      psql -d forgejo -c "REINDEX DATABASE forgejo;"

- **Duration:** about 55 seconds (00:38:14 → 00:39:09 UTC). Forgejo was
  unavailable for that window.
- **Gotcha:** `REINDEX DATABASE` must run while connected to that
  database. Run from `postgres` it fails with `can only reindex the
  currently open database`.
- **Invalid indexes afterwards:** 0.
- **Version markers refreshed:** `ALTER DATABASE … REFRESH COLLATION
  VERSION` on `forgejo`, `postgres` and `template1`, each from 2.28 to
  2.34. All three now report no mismatch.
- **Infra-local:** already on 2.34 (its PG18 image was built on the newer
  glibc), so it needed no reindex.

## Not yet verified

- **Retention:** the 7-full policy is set, but the repo's real size
  against its 5Gi PVC has not been checked.
- **Infra-local has no Postgres metrics or alerts.** PG18 is not
  supported by the exporter. Options are OTel via `spec.instrumentation`
  (untested) or alerts on the backup CronJobs. `PostgresExporterAbsent`
  deliberately excludes it.
- **Immich** runs standalone Postgres outside PGO. Its protection is the
  nightly `pg_dump` plus Volsync; it is not covered by these alerts.

## Gotchas for CLAUDE.md

- **A PGO image pin that doesn't match the operator's pgBackRest fails
  silently.** Stanza-create exits 39 (`expected value '2.52.1' ... got
  '2.59.0'`), archiving fails on every WAL segment, and nothing alerts
  unless archive failures are monitored. Check `pg_stat_archiver` and
  `stanzaCreated` after any PGO image change. Prefer no `image:` pin; the
  operator picks a matching one.
- **`postgres_exporter` does not support Postgres 18 in PGO 6.0.3.** The
  exporter sidecar fails to log in, the target still reports `up`, and
  the operator reconcile loops. Check `pg_exporter_last_scrape_error`,
  not `up`, and do not enable `monitoring.pgmonitor.exporter` on a
  Postgres 18 cluster.
- **A PodMonitor needs `metadata.namespace` when the Kustomization has no
  `targetNamespace`.** Flux rejects the whole apply, not just the
  PodMonitor. `kubectl apply --dry-run` does not catch this, because it
  falls back to a default namespace.
- **`REINDEX DATABASE` runs only against the connected database.** It
  must be run with `psql -d <db>`.
- **Collation mismatch shows up as a warning, not an error.** Check with
  `pg_database_collation_actual_version(oid)` against `datcollversion`
  after any OS or image change, and refresh once the indexes are rebuilt.

## Health pass

- `flux get kustomizations` / `helmreleases`: all Ready after the last
  reconcile of `postgres-forgejo`, `postgres-infra`, `kube-prometheus-stack`
  and `forgejo`.
- Unready pods: none apart from completed backup Jobs.
- Operator errors: zero in the last 3 minutes at the time of writing.

## Addendum — 2026-10-17: `BackupJobFailed` for `laptop-win`

`BackupJobFailed{backup_job="laptop-win"}` (critical) fired from
2026-10-16 13:00 UTC, the 09:00 Eastern run of `check-backups.sh`. Every
other backup job was healthy and the `storage1-node-exporter` target was
`up`, so the failure was the check's own verdict, not a missing metric.

**What the metrics showed.** `backup_success` was 1 through 10-16 08:49Z
and 0 by 14:49Z. `backup_last_success_days` stayed at 0 until 10-14
morning, then reached 1 on the evening of 10-14 and 2 on the evening of
10-16: the nightly restic run (02:00) had stopped producing a fresh
snapshot after about 10-13/14.

**Cause (as reported by Tom, not verified from `gsfarmctl`).** The laptop
was not plugged in or powered on, so the nightly run did not happen. The
restic job itself is fine. Separately, a space problem was traced to an
old snapshot that needed deleting, and it was deleted.

**Outcome.** The alert cleared on its own: `backup_success=1`,
`backup_last_success_days=0`, no `Backup*` alerts active.

**Limits of the investigation.** TrueNAS is not reachable from
`gsfarmctl` (SSH as `stecktf` is refused; the documented direction is
TrueNAS to `gsfarmctl`), so the restic snapshot list and the script's
logic were not read directly. The diagnosis above rests on Prometheus
history plus Tom's confirmation.

**Takeaway.** `BackupJobFailed` for a laptop-class job usually means the
machine was off or away, not that restic is broken. Check that first:
power and network at the laptop, then the restic Task Scheduler history.
The alert is correct either way; a short silence is the right response
if the machine is knowingly away, not a looser threshold.
