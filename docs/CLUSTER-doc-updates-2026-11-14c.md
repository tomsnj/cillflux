# Cluster Doc Update — 2026-11-14 (c)

Follow-up to the Forgejo cutover (`CLUSTER-doc-updates-2026-11-14.md`).
`PostgresIncrBackupStale` fired for the old `postgres-forgejo` cluster.
The alert was correct and expected, but chasing it found that the new
`postgres-forgejo-local`, which now serves Forgejo, was not being scraped
at all. Closes the "PodMonitor" open item in that doc.

## The alert

    alertname = PostgresIncrBackupStale   pg_cluster = forgejo/postgres-forgejo
    summary   = No pgBackRest backup of forgejo/postgres-forgejo for 4h 30m 9s.

Not a fault. #1071 removed the old cluster's `schedules:` on purpose and
keeps it idle for 14 days as the rollback target (plan phase 4), so its
last incremental simply aged past the 4h threshold. Its repo was healthy
(`ccp_backrest_last_info_backup_error` 0) and it was not failing anything.
`PostgresFullBackupStale` would have followed about 37h after its last full
(it was at 20.4h when checked).

## The real problem: the new cluster was not scraped

`kubernetes/apps/forgejo/postgres/podmonitor.yaml` selected
`postgres-operator.crunchydata.com/cluster: postgres-forgejo` (exact match).
`postgres-forgejo-local` carries `cluster: postgres-forgejo-local`, so no
PodMonitor selected it, even though its pod had the `exporter` container and
the `crunchy-postgres-exporter=true` label. Every `ccp_backrest_*` and
`ccp_archive_*` series for namespace `forgejo` came from the old cluster.

Consequence: from creation until the fix, none of `PostgresBackupFailed`,
`PostgresFullBackupStale`, `PostgresIncrBackupStale` or the archive-failure
alerts covered the live Forgejo database. Its backups were in fact running
(initial backup `Complete`, hourly incrementals completing), so nothing was
lost, but nothing would have said so if they had stopped.

`PostgresExporterAbsent` did not catch it. Its expression is
`absent(ccp_archive_command_status_failed_count{namespace="forgejo"})`, which
is per namespace. While the old cluster still produced the series, the
absent check was satisfied by a cluster nobody was using.

## Fix

`0962b8d5`: selector changed to `postgres-forgejo-local`, with a comment
saying why and that it must be pointed back at `postgres-forgejo` if the
cutover is rolled back. Scraping the new cluster only also removes the old
cluster's series, so the stale alert resolves without a silence.

Trade-off, accepted: the idle old cluster is unmonitored for the soak. Its
backups are off by design, so there is nothing for an alert to report.

**Verified live after `flux reconcile`** (`postgres-forgejo` and `forgejo`
Kustomizations Ready at `0962b8d5`):

- PodMonitor selector reads `postgres-forgejo-local`; the only active
  `forgejo` target is `postgres-forgejo-local-instance1-gfzm-0`, `up`. The
  old pod appears under dropped targets.
- `postgres-forgejo-local`: last incremental 2,444s ago, last full 28,485s
  ago, `ccp_backrest_last_info_backup_error` 0, failed WAL archives 0.
- The old cluster's series stayed visible for a few minutes (Prometheus
  holds a dropped target's samples for its 5-minute lookback), then went
  away. The alert stayed `firing` until the rule group's next evaluation,
  then resolved: Prometheus 0, Alertmanager 0 active Postgres alerts. All
  pods ready.

## Gotchas

- **A PodMonitor that names one cluster does not follow a new one.** Moving a
  PGO cluster (new name, new storage) leaves monitoring on the old name, and
  nothing complains: the new exporter runs, the PodMonitor is `Ready`, and
  the dashboards and alerts keep showing the old cluster as if all were well.
  After any PGO cluster move or rename, check that a series exists for the
  *new* `pg_cluster`:
  `ccp_backrest_last_incr_backup_time_since_completion_seconds{namespace="<ns>"}`
  should list it.
- **`absent()` over a namespace cannot detect one missing cluster in it.**
  `PostgresExporterAbsent` only fires when the whole namespace has no series.
  While two clusters coexist (a cutover, a soak), one can be unscraped
  indefinitely. The existing comment in `prometheusrule-postgres.yaml` says
  "absent() cannot enumerate clusters"; it also cannot see a partial gap.
- **A removed target's alert outlives it by a few minutes.** Series linger for
  the 5-minute lookback, then the alert clears on the next rule evaluation.
  Don't read "still firing" a minute after a fix as the fix failing; check
  the sample age or the target list first.

## Open items

- **`PostgresExporterAbsent` is per namespace.** Not changed. A per-cluster
  form would need the cluster names listed explicitly (one `absent(...)` per
  `pg_cluster`), the same limitation the rule's comment already describes. Add
  it when the old cluster is retired, so the list is one name long.
- **Soak and retirement** are unchanged: the old cluster stays until at least
  **2026-11-28**, and only after 7 daily full backups of the new repo have
  succeeded. Deleting it is destructive and needs approval. When it is
  retired, remove the "point back at the old cluster" comment from
  `podmonitor.yaml` along with the old manifests.
- **Rollback now costs a monitoring change too.** Rolling back means
  re-enabling the old cluster's `schedules:` and pointing the PodMonitor at
  `postgres-forgejo` again.
