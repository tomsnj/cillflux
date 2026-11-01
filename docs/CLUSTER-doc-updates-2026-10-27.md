# Cluster Doc Update — 2026-10-27

Immich Postgres Volsync backup restored after three days of failures. The
fault was in the restic cache ownership, not in the data or the repository.
Also: the `laptop-win` `BackupJobFailed` alert from 10-26 was the laptop
being powered off, not a fault in the backup path.

## VolSyncVolumeOutOfSync for `immich-postgres-data`

**Symptom.** `VolSyncVolumeOutOfSync` (critical) fired for
`immich/immich-postgres-data`. The last good Volsync copy was 10-24
03:00Z. Every nightly run from 10-25 failed at the start.

**Cause.** The mover runs as UID 999 on purpose: PGDATA is `0700` and
owned by 999 on the NVMe disk, so the mover must run as that user. The
restic cache PVC `volsync-src-immich-postgres-data-cache` held 72
entries owned by UID 0, left from earlier runs. Restic 0.19.1 (the
`quay.io/backube/volsync:0.17.0` mover image) calls `chtimes` on those
entries as UID 999 and fails:

    unable to open cache: chtimes /cache/7d95be…: operation not permitted
    ERROR: failure checking existence of repository

The failure first appeared on 10-25, after volsync 0.17.0 was merged at
10:00Z on 10-24 (`a3a77abb`). The 10-24 03:00Z run was before that merge.
The volsync upgrade is the likely trigger. Not reproduced directly: the
mechanism is inferred from the error text and the file ownership.

**Fix (done 2026-10-27, by hand).**

1. Deleted the stuck mover Job `volsync-src-immich-postgres-data`
   (`kubectl delete job … --cascade=foreground`). Volsync recreated it at
   once because the sync was still in progress.
2. Ran `chown -R 999:0 /cache` on the cache PVC from a short-lived
   busybox pod (deleted afterwards). All 72 entries are now UID 999. The
   source PVC and the restic repository were not touched.
3. The recreated mover ran to completion. `ReplicationSource` status:
   `result=Successful`, `lastSyncTime=2026-10-27T02:49:42Z`.
   `volsync_volume_out_of_sync{obj_name="immich-postgres-data"}` returned
   to `0` and the alert cleared.

No git change was needed. The `moverSecurityContext` in
`kubernetes/apps/immich/postgres/volsync.yaml` is correct, and must stay
at `runAsUser: 999`: running the mover as root would not help, because
the mover drops all capabilities, so it cannot read a `0700` directory
owned by 999.

**Checks.**

- `lastSyncDuration` still reads `47h49m42s`. This is an artifact of the
  stale `lastSyncStartTime` (10-25 03:00Z) and the real sync took a few
  minutes.
- Not checked directly: the new restic snapshot list. Confirm it on the
  next scheduled run (03:00Z, 10-27 and after).
- The nightly logical dump `immich-postgres-dump` (CronJob, 02:30Z) kept
  succeeding through the outage, so the database had a logical copy
  the whole time. Only the Volsync copy was stale.

**Takeaway.** A Volsync mover image bump can change how restic treats
cache files left by an older mover. If a source with a non-root
`moverSecurityContext` starts failing right after a Volsync upgrade, check
the cache PVC ownership first:

    kubectl run -n <ns> probe --rm -i --restart=Never --image=busybox:1.36 \
      --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"p","image":"busybox:1.36","command":["sh","-c","ls -ln /cache"],"volumeMounts":[{"name":"c","mountPath":"/cache","readOnly":true}]}],"volumes":[{"name":"c","persistentVolumeClaim":{"claimName":"volsync-src-<name>-cache","readOnly":true}}]}}'

Follow-up, not done: add a comment in
`kubernetes/apps/immich/postgres/volsync.yaml` noting that the cache must
stay owned by the mover UID, so the next mover-image bump is checked
against it.

## BackupJobFailed for `laptop-win` (2026-10-26)

`backup_success{backup_job="laptop-win"}` went to `0` at the 13:00Z check
on 10-26. `backup_last_success_days` reached 2. Other backup jobs were
healthy. Confirmed by Tom: the laptop was powered off. No change needed.

The same cause as the 10-17 incident (see the 10-14 file's addendum): a
laptop-class backup failing means the machine was off or away, not that
restic is broken. Once the laptop is powered on and its nightly 02:00 run
completes, `backup_success` returns to `1` at the next check. Note that
`BackupStale` (warning) fires once `backup_last_success_days` exceeds 2.

## Not changed

- No Kubernetes manifests changed. Only the stuck Job and the cache
  ownership were touched, both live and by hand.
- No Flux suspend was needed, and none was done.
