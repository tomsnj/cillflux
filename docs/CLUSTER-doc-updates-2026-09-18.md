# Cluster Doc Update — 2026-09-18

## Immich — Postgres moved off NFS onto node NVMe

Implements `docs/proposal-immich-postgres-nvme.md`. The database shared
the `gsks0` HDD mirror (~78 IOPS) with the 1Ti photo library; bulk
imports starved it, Postgres was SIGKILLed on its liveness probe
(`exit 137`), and `immich-server` crash-looped behind it. It recurred
at `--concurrent-tasks 1` and again with `facialRecognition` paused,
so it was storage contention rather than client behaviour or face
clustering. Node sat at ~12% CPU throughout.

Same split Frigate already used: bulk media on NFS, hot database on
`local-hostpath` (the node's 1.9 TB NVMe).

**Result: 31,204 assets intact, ~6 minutes downtime, and 1,999
facial-recognition jobs subsequently completed with zero pod
restarts** - the workload that used to kill Postgres.

### How the migration ran

1. Fresh `pg_dump`, verified with `pg_restore --list` (528 TOC
   entries, all key tables present).
2. Manual Volsync snapshot.
3. `immich-server` to 0, then `immich-postgres` to 0.
4. New 20Gi PVC on `local-hostpath`, data copied with `cp -a`.
5. **All 1,720 files verified by md5** before switching.
6. `claimName` repointed, committed, reconciled.
7. Postgres came up from a clean shutdown - no recovery replay.

The old `immich-postgres-data` PVC and its manifest are deliberately
retained; rollback is a one-line `claimName` revert.

### It took four follow-up commits. Three were avoidable.

The move itself was clean. Everything that reads the volume
*out-of-band* broke, and that is the transferable lesson.

**1. Volsync still named the old PVC** (`99118578`). The deployment
was repointed; the `ReplicationSource` was not. Nightly backups would
have kept running, kept reporting success, and kept capturing a frozen
copy of the database. Caught before the 03:00 run only because of an
unrelated question about Frigate backups.

**2. The mover could not read the new PVC** (`ac94f4c0`). PGDATA is
mode `0700` owned by uid 999. On NFS the export's squashing masked
that; on local disk it is enforced, so every mover failed with
`ls: cannot open directory '/data': Permission denied`. Fixed with
`moverSecurityContext.runAsUser: 999`.

**3. That fix used the wrong schema path** (`c675b6e8`). It went to
`spec.moverSecurityContext`; Volsync 0.16.0 wants
`spec.restic.moverSecurityContext`. The dry-run rejected it with
`field not declared in schema`, and because an invalid field fails the
*whole* Kustomization, `cluster-apps` applied nothing for ~13 minutes.
A `kubectl apply --dry-run=server` would have caught it instantly -
and the correct path was already visible in `kubectl explain` output
from minutes earlier.

Throughout all of this the `pg_dump` CronJob kept producing verified
logical backups, because it connects over TCP as the database user
rather than reading the data directory. That is why pairing the move
with a second, differently-shaped backup mattered: the path that broke
was not the path being relied on.

**Generalised:** moving a PVC between storage classes changes more
than the path. Permission semantics differ, and every out-of-band
reader - backups above all - needs rechecking rather than assuming it
follows the workload.

## Backups — two gaps closed

### Immich Postgres: nightly logical dump (`kubernetes/apps/immich/postgres/pgdump.yaml`)

Volsync snapshots the PVC into MinIO, which lives on the node's NVMe -
so after the move, Postgres's primary data and its restic snapshots
shared one disk. A nightly `pg_dump -Fc` now lands on `gsks1`
(TrueNAS): different failure domain, different format. A logical dump
survives a corrupted data directory that restic would faithfully
preserve.

Writes to `.partial` and renames only on success, so a failed run
never leaves a file that looks like a backup. Keeps 7. Runs 02:30,
ahead of the 03:00 Volsync window.

### Frigate: the event database had no backup at all (`kubernetes/apps/frigate/app/dbbackup.yaml`)

`frigate-data` (~92 MB SQLite, WAL mode, on node NVMe) had no
`ReplicationSource` - every other stateful app has one; this was simply
missed. Found while auditing after the Postgres move.

A file-level backup is unsafe here: the database is written
continuously, and copying `frigate.db` / `-wal` / `-shm` at different
instants can produce an archive that will not open. Uses SQLite's
**online backup API** instead - a transactionally consistent snapshot
of a live database - then verifies with `PRAGMA integrity_check`
before the output is allowed to be named like a backup. A corrupt
SQLite file still looks like a file; the verification is the point.

Written in Python (stdlib `sqlite3`) for two reasons: the Frigate
image ships no `sqlite3` binary, and a Python script contains no `$`
for Flux's `postBuild` envsubst to mangle (see below).

Runs 02:45 to `gsks1`, keeps 7. Tested: 91.5 MB, verified.

**`frigate-media` (500Gi of recordings) is intentionally not backed
up** - bulky, transient, already on the NAS. To be revisited.

## Immich — family accounts

Three accounts with per-user quotas and Keycloak SSO:

| Account | Quota | Sees archive | Shares back |
|---|---|---|---|
| Shawna Gilroy | 200 GiB | yes | yes |
| Maxwell Steck | 100 GiB | yes | no |
| Calvin Steck | 100 GiB | yes | not yet logged in |

All 31,204 assets belong to `immadmin`, including ~21,000 of
Shawna's - her Takeout and Amazon imports both used Tom's API key, and
Immich cannot transfer ownership. The family-archive model was chosen
deliberately over per-person libraries; see
`CLUSTER-doc-updates-2026-09-16.md` for that decision and its cost.

Two gotchas from this are in `CLUSTER.md`: create the Immich account
*before* the first SSO login (autoregistered accounts get no quota),
and partner sharing is one-way per direction and can only be created
by the sharer - which is exactly what keeps the boys' uploads private.

## Immich — Shawna's Amazon backfill complete

Every year from 2002 to 2025 is in, except 238 files from 2025 lost to
duplicate downloads (Amazon names every batch `AmazonPhotos.zip`).

**The scoping recommendation was wrong, and worth recording why.** A
single probe of June 2024 came back 99.1% duplicate, and I generalised
that across 2022-2025 and advised skipping the lot. Tom pulled them
anyway. Actual unique rates:

| Year | Unique | Rate |
|---|---|---|
| 2022 | 659 / 709 | **93%** |
| 2023 | 154 / 548 | 28% |
| 2024 | 31 / 1,047 | 3% |
| 2025 | 64 / 624 | 10% |

**908 photos recovered from years I said were not worth pulling.** The
probe measured June 2024 accurately; what one month cannot show is
that it sits on one side of a transition - Shawna's Google account
starts in 2022, so Amazon was still her primary backup at the start of
the window and nearly redundant by the end. Probing one month to scope
one year is reasonable; four years is not.

A second correction: the `strings`-based EXIF check used throughout
produced **false negatives**. Files it flagged as dateless often had
EXIF that Immich read correctly - the wedding batch landed on exactly
the right date without help. The running "misdated" tally was
overstated roughly fivefold; the real figure is ~80 assets at Amazon
upload dates, all shared/received images.

## Still outstanding

- Tom's own Amazon library (53.7 GB) - **probe two years, not one**.
- Shawna's 238 missing 2025 files.
- Apple Photos via Export Unmodified Originals.
- `~/Downloads` hand-pick; Amazon's undated files (tag
  `amazon/undated` so they stay findable).
- Resolution-duplicate stacking pass - see On the Horizon.
- Calvin's first login.
- Old `immich-postgres-data` PVC - keep at least a week as rollback.
