# CLAUDE.md — TrueNAS (`storage1`)

> Deploy this file to `/mnt/storage1/home/stecktf_a/CLAUDE.md` on
> TrueNAS. It is named differently in the repo so it does not
> auto-load on `gsfarmctl`, which has its own `CLAUDE.md` describing a
> different machine.

## What this host is

TrueNAS SCALE, pool `storage1`. Bare metal (Gigabyte X470), migrated
from an ESXi VM. It is the **storage** for the `gs-farm.net` homelab,
not the Kubernetes control host.

- `10.0.0.169` — base interface
- `10.10.10.110` — VLAN10, the 10Gb path used by the NFS StorageClasses
- Pool `storage1`: 8.61T, ~81% allocated, **FRAG ~49%**

**This is not `gsfarmctl`.** There is no `kubectl`, `flux`, `talosctl`
or `helm` here, and the GitOps repo does not live here. Anything
cluster-side runs on `gsfarmctl` (`stecktf@10.0.100.240`, SSH key
already authorised from this host).

## What is installed, and where

The root filesystem is **replaced on SCALE upgrades**. Anything
outside `/mnt` will not survive, and `apt` is disabled. Persistent
tooling therefore lives on the pool:

- `/mnt/storage1/home/stecktf_a/opt/` — Node, `claude`, `immich-go`
- `/mnt/storage1/home/stecktf_a/cluster-docs/` — synced cluster docs
- `/mnt/storage1/home/stecktf_a/amazon-manifests/` — filenames already
  imported to Immich, one file per year
- `/mnt/storage1/home/stecktf_a/photo-migration/` — migration scripts

`rsync` exists at `/usr/bin/rsync` but **the login `PATH` is often
trimmed and may not include it** — use the full path, or fix `PATH`
first. `sqlite3` and `npm` are not present by default.

Refresh the synced copies from `gsfarmctl` any time:

```bash
/usr/bin/rsync -av stecktf@10.0.100.240:~/cillflux/docs/ ./cluster-docs/
/usr/bin/rsync -av stecktf@10.0.100.240:~/cillflux/scripts/photo-migration/ ./photo-migration/
```

## Privileges

ZFS needs root: `zfs list`, `zpool list`, `zfs destroy` all require it
(`/dev/zfs` is root-only). `immich-go` and `claude` do not.

## Guardrails

- **`zfs destroy` is not recoverable.** There is no snapshot to fall
  back on, because snapshots are what you would be destroying. Confirm
  the exact dataset and snapshot name before every destroy, and prefer
  destroying one at a time over a recursive or wildcard sweep.
- **`home_nfs` is live cluster storage.** Every Kubernetes PVC lives
  under it — Immich's 1Ti photo library, Postgres until 2026-09-18,
  Vaultwarden, Forgejo, Grafana, Pi-hole. Do not touch its datasets or
  snapshots without checking what is mounted.
- Ask before anything destructive, even routine-seeming. This is live
  household infrastructure.
- Never print decrypted secrets or private keys.

## Current work

### 1. Space cleanup

`storage1` is ~81% allocated with ~49% fragmentation. ZFS allocation
degrades above ~80%, and that fragmentation plausibly contributes to
the IOPS ceiling the cluster has been working around.

**The photos are not the problem.** `backups` is 5.45T of the 7.02T
allocated; all cluster storage (`home_nfs`) is 619G.

| Dataset | Used | In snapshots |
|---|---|---|
| `backups/maxwell-image` | 2.38T | 0 |
| `backups/mycloud-photos` | 1.27T | — |
| ↳ `shawna-laptop-backup` | 672G | **481G** (~329G after 2026-09-19 prune; old Windows image versions) |
| `backups/desktop2` | 733G | 52.6G |
| `backups/desktop1` | 700G | 94.6G |
| `media` | 700G | — |

- **`maxwell-image` and `mycloud-photos` are described in the separate
  backup project** — get that context before proposing anything for
  them. Between them they are 3.65T, far more than snapshot pruning
  can recover.
- Snapshot pruning yields roughly **692G total**, under 10% of the
  pool. **Corrected 2026-09-19:** the 481G under
  `shawna-laptop-backup` is **not** the Amazon/Google Takeout zips. It
  is retired versions of the Windows Image Backup of Mom's laptop
  (`WindowsImageBackup/Moms-laptop/*.vhdx`), whose old blocks stay
  pinned by snapshots after Windows replaces the image. The dataset
  is a full-disk image, so the Takeout zips (`C:\Users\gilro\Takeout\`)
  would exist only inside the `.vhdx`, and the newest image (2026-08-24)
  predates the 2026-09 migration; the September snapshots add no
  unique blocks. There is nothing Takeout-related to prune here.
  **Refined 2026-09-20** (from `~/gs-farm-backup-documentation.md`):
  `mycloud-photos/*` is a **weekly rsync (Sun 01:00, `/root/mycloud-sync.sh`)
  from the WD MyCloud (10.0.0.201)**, which holds the primary copy of
  Mom's laptop image; TrueNAS only mirrors it. When Windows renames the
  backup folder (`Backup <date>`), rsync sees a new path and rewrites
  the whole ~220 GiB `.vhdx` as a new file. On 2026-09-20 the rewrite was
  byte-identical (same size/mtime, first GiB equal, new inode 401 vs 524);
  202 snapshots still pin the old copy, and `mycloud-photos` also keeps
  90-day daily snapshots. So much of the "image versions" space is
  duplicate rsync churn, not distinct restore points.
  **Fixed and installed 2026-09-22:** `/root/mycloud-sync.sh` replaced
  (backup at `/root/mycloud-sync.sh.bak-2026-09-22`; drafts at
  `~/mycloud-sync.proposed-v2.sh`). Changes: skip a share that fails to
  mount or mounts empty instead of running `rsync --delete` against an
  empty dir (the real risk — would have silently wiped the TrueNAS
  mirror); `--exclude 'WindowsImageBackup/'` on Shawna's share (stops
  the rewrite churn above); `--exclude 'Desktop.ini'`/`'desktop.ini'`
  on all three shares (a Windows junk file the `wd_backup_master`
  account can't read off the MyCloud — was failing every run with
  rc=23, found via the new alerting actually firing); `--max-delete=1000`
  guard; per-share result written to `/var/log/mycloud-sync.status`
  (`RESULT=OK|FAIL`, `TIME=<epoch>`) for `check-backups.sh` to read;
  on failure, emails immediately via `midclt call mail.send`.
  **Real cron schedule (checked via `midclt call cronjob.query`, not
  `crontab -l` — TrueNAS SCALE doesn't use the system crontab for its
  own Cron Jobs feature) is Sun 04:00**, not 01:00 as this doc and
  `~/gs-farm-backup-documentation.md` say. Verified end to end
  2026-09-22: dry run then real run, all three shares `OK rc=0`.
  - **The shell `mail` command on this host does not work** — local
    MTA is exim4, unconfigured to relay anywhere. TrueNAS's own alerts
    (e.g. quota) go via `midclt call mail.send`, Gmail OAuth through the
    middleware, confirmed working 2026-09-22. Any script that alerts
    must use `midclt call -j mail.send '{"subject":...,"html":...,
    "to":[...]}' ` (message dict as a single arg — do not wrap it in an
    extra array), not `mail`.
  - **`check-backups.sh` had no schedule at all** (checked Cron Jobs,
    root crontab, `/etc/cron.d`, systemd timers, init/shutdown scripts —
    found nothing), despite this doc and the backup-documentation file
    saying "daily 9:00 AM via root crontab". Combined with `mail` not
    working, backup warnings had likely never reached anyone. **Fixed
    2026-09-22:** installed the updated script (same `mail`→`midclt`
    fix; backup at `/root/check-backups.sh.bak-2026-09-22`, draft at
    `~/check-backups.proposed.sh`) and added a Cron Job for it,
    daily 09:00 (`midclt call cronjob.query` id 2).
  - **CAUTION:** while debugging this, a `midclt call mail.config`
    query printed the Gmail OAuth `client_secret` and `refresh_token`
    in plaintext (2026-09-22). The user redid the OAuth sign-in
    afterward, invalidating that token. Never run `mail.config` (or
    similar config-dumping calls) without filtering secret-shaped
    fields out of the output first.
- Per-snapshot `used` is `0B` for this dataset because blocks are
  shared across consecutive snapshots. Size a prune with a range dry
  run (`zfs destroy -nv ds@first%last`), never by summing `used`.
- **Done 2026-09-19:** destroyed
  `shawna-laptop-backup@auto-2026-08-13_02-30%auto-2026-08-17_02-30`
  (dry run: 152G, the 2026-07-27 image). Remaining ~330G is the
  2026-08-10 and 2026-08-18 image versions, kept at the time as
  restore points (see the 2026-09-20 note above: low value, the MyCloud
  is primary). The laptop did back up again: the newest source folder
  is `Backup 2026-09-15 041236`.
- **Done 2026-09-20:** destroyed `shawna-laptop-backup@auto-2026-08-18_02-30%auto-2026-09-20_06-00`
  (227 snapshots, dry run 496G): `backups` headroom 421G to 917G, pool
  usable free ~828G to ~1.3T. It will refill the next time the MyCloud
  sync rewrites the image after a Windows folder rename; fix the rsync
  (exclude `WindowsImageBackup/` or shorten snapshot retention) first.
- **Mom's laptop image plan (decided 2026-09-20).** Her hard drive is
  showing signs of failing, so **do not delete the frozen
  `shawna-laptop-backup/WindowsImageBackup` copy or the MyCloud copy
  until a new image is on TrueNAS and verified.** Note the newest
  `.vhdx` (C:) still has mtime 2026-08-24 even though the folder is
  `Backup 2026-09-15`, so C: may not have been captured since 08-24.
  Plan: Windows 11 "Backup and Restore (Windows 7)" system image
  straight to a new share `backups-laptop-win-image` (dataset
  `backups/laptop-win-image`, 400G quota, currently empty, root-owned),
  user `backup-laptop-win-image`, laptop on Ethernet for the first full.
  No MyCloud secondary. Restic (`laptop-win`, nightly 02:00) covers files
  (last snapshot 2026-09-19). WinRE has no Wi-Fi: restoring needs
  Ethernet or a USB copy of the image.
  **RESOLVED 2026-09-22/23.** First full image (09-20) completed over
  Wi-Fi (5 h, ~12 MB/s) to `laptop-win-image/WindowsImageBackup/
  Moms-laptop/Backup 2026-09-20 160006` (C: vhdx 183 GiB apparent /
  126 GiB on disk, virtual size 456 GiB — a replacement drive must be
  at least that big). `qemu-img check` clean. **Verified 2026-09-22**
  by attaching the vhdx directly from a network path in Windows Disk
  Management (`\\10.0.0.169\backups-laptop-win-image\...\9179c6a3-….
  vhdx`, read-only; the volume needed a manual drive letter via
  "Change Drive Letter and Paths" or `diskpart assign`, since Windows
  Backup sets a no-default-drive-letter flag on system volumes) —
  files browsed and confirmed good.
  **Found 2026-09-22: her laptop's old scheduled backup was still
  pointed at the MyCloud** (`10.0.0.201`), independent of the one-time
  manual backup we'd sent to TrueNAS — this is what produced the
  unexpected `Backup 2026-09-21 020005` folder under
  `shawna-laptop-backup/WindowsImageBackup`. Redirected it via
  Backup and Restore (Windows 7) → Change settings → the network
  location, to `\\10.0.0.169\backups-laptop-win-image`. **Not yet
  confirmed whether the old MyCloud destination was fully replaced or
  is still separately configured** — check next time on her laptop.
  New schedule: **weekly, Saturday 03:00** (an hour after her nightly
  Restic run, off the Sun 04:00 MyCloud-sync and Mon/Wed 23:00 Veeam
  slots). System-image only (unchecked the file/library items —
  Restic already covers `C:\Users`).
  First scheduled run (2026-09-23 01:24) landed as
  `Backup 2026-09-23 012417`: same byte size and disk usage as 09-20
  (196,416,110,592 bytes / 126 GiB), finished in under a minute with
  ~0 MB/s sustained network traffic — almost certainly a server-side
  block clone (SMB copy offload + ZFS block cloning) against the
  unchanged prior image rather than a re-transfer. If this holds for
  future runs, weekly images to this destination should stay cheap;
  not yet confirmed on a run with real C: changes.
  Old copies retired: the frozen `shawna-laptop-backup/
  WindowsImageBackup` copy on TrueNAS (167G) deleted 2026-09-22. The
  MyCloud's own copy was stuck behind a lock on the device itself
  (held even across Mac Finder and Windows Explorer, i.e. server-side,
  not a client issue — the `wd_backup_master` account is read-only
  there anyway, so this could only be fixed on the MyCloud itself);
  resolved by rebooting the MyCloud, then deleting normally.
- Two snapshots from **2020-11-04** (`media@manual`, `share@manual`,
  4.3G combined) and `home_nfs@pre-maintenance-2026-05-02` (12.3G) are
  obvious stale candidates.
- **Fragmentation does not drop when space is freed.**
- **`backups` has a 6T quota** (`zfs get quota storage1/backups`, set
  locally). Writers under `backups` see only the headroom under it
  (~710G on 2026-09-19), not the pool's free space. Leave it: it
  stops a runaway backup from filling the pool that `home_nfs`
  shares. A job that hits it fails; it does not take the cluster down.
- **Two space figures.** `zpool list` gave 79% on 2026-09-19 (raw,
  includes parity). The TrueNAS UI showed 85.5%: it is
  used/(used+avail) in usable terms (about 1.16 TiB avail vs 1.73T
  `zpool` free). The pool is **two mirror vdevs, not raidz**
  (`zpool status`), so parity does not explain the ~0.57T gap; ZFS
  slop space (~0.27T) accounts for part, and the rest is unidentified
  (check `zfs get -r refreservation storage1`). Both figures are real. The ~80% guideline applies to `zpool list`.
- **`maxwell-image` (Veeam, job "Maxwell Full Backup", Veeam 13)** is
  2.4T because **two chains are on disk at once**: a full plus
  incrementals (~1.5 TiB) and the newer full (~880 GiB, 2026-09-16).
  Retention is set to **3 days** (was 7, changed 2026-09-20 while
  debugging — see below); the job runs **Mon/Wed 23:00** on Maxwell's
  PC (Veeam Agent, free edition) and writes over SMB to
  `\\10.0.0.169\backups-maxwell-image`. It also makes a **monthly
  active full on the first Monday** (next: 2026-10-05).
  - **Restore points as of 2026-09-20 (from the Agent's own list):** 4
    good (09-02 tail of the old chain; 09-16 full, succeeded on retry;
    09-19 and 09-20 manual incrementals) and 3 failed/incomplete
    (the 09-07, 09-09, 09-14 scheduled runs — each failed outright and
    was never retried to success, unlike 09-16 which retried until it
    worked on 09-18 01:19).
  - Cause of the 09-17 failure (the retry of the 09-16 full) per
    Veeam's log: the SMB connection dropped mid-write ("Failed to
    flush file buffers") and the PC reconnected on a new port. TrueNAS
    showed no kernel, disk, NIC-error, ZFS or smbd problem, so the
    cause is on the PC/network side. Suspect: the PC's 2.5Gb NIC had
    power saving enabled (found and disabled 2026-09-19). The Wi-Fi
    latency/power-saving fixes made the next long write (the Mom's-
    laptop image, 2026-09-20) succeed cleanly, which is supporting but
    not conclusive evidence. Causes of the three outright-failed runs
    (09-07/09/14) are unknown.
  - **RESOLVED 2026-09-21, automatically, no manual deletion needed.**
    Mechanism (pieced together from the job log and Veeam Agent for
    Windows docs, helpcenter.veeam.com/docs/agentforwindows/userguide/
    retention_days.html): forward-incremental retention normally shrinks
    a chain point-by-point via **transform** (merge oldest incremental
    into the full, delete it) — this job's log shows that step skipped
    every run (`[TransformFull] Transformation skipped due to it turned
    off in a job options.`), and no transform/merge setting exists
    anywhere in the job (checked all 3 Advanced Settings tabs — Backup,
    Maintenance, Storage — likely a structural limit of Veeam Agent Free
    on an SMB-share target). **But there is a second, coarser mechanism:
    once the current chain's restore-point count exceeds the retention-
    days setting, Veeam drops the entire previous chain in one shot.**
    Retention was lowered 7→3 on 2026-09-20; the 2026-09-21 23:00
    scheduled run gave the new chain its 4th point (09-16 full + 09-19,
    09-20, 09-21 incrementals — one more than the retain-3 setting), and
    at 23:52 all 10 old-chain files (08-03 full through 09-02) were
    deleted in one step, confirmed both on disk and in the `.vbm`.
    `backups` headroom: ~795G → 1.1T (2.3T avail total).
  - **Ongoing expectation:** after each monthly active full (next
    2026-10-05), the old chain should self-clear once the new chain
    reaches ~4 points at twice-weekly runs — roughly 2 weeks of two
    chains overlapping, then automatic cleanup. No manual deletion
    expected to be needed going forward; if a chain is still present
    well past that window, revisit (the file-list-and-snapshot approach
    from 2026-09-20/21 is the fallback, not yet needed). **Never delete
    `.vbk`/`.vib` files by hand outside that fallback plan** — it can
    break the chain in `Maxwell Full Backup.vbm`. No ZFS snapshots on
    this dataset, so freed space returns at once. A second forced full
    before an old chain clears (~880G) would still exceed the `backups`
    quota headroom in the tightest part of the cycle.
- **Snapshot policy changed 2026-09-20** (was 2,369 snapshots, now ~752).
  Recursive tasks on `backups` (all exclude `maxwell-image` and
  `laptop-win-image`): hourly **1 day** (was 1 week), daily 02:00
  **14 days** (was 30), Sunday 03:00 **4 weeks** (was 8). Kept on
  purpose: `mycloud-photos` daily 02:30 for 90 days (safety net for the
  `rsync --delete` mirror; costs ~nothing) and `home_nfs` hourly/daily/
  weekly (live cluster storage, not yet reviewed). `laptop-win-image` has
  its own non-recursive daily 04:00 task (`img-` names, 7 days) plus the
  manual `image-2026-09-20` (delete it after the next verified image).
  A shortened lifetime is applied at the next hourly run. Excluding a
  dataset from a task probably orphans its old snapshots, so delete
  those by hand once.

### 2. Tom's Amazon Photos import

Shawna's library is complete (2002–2025, minus 238 files from 2025).
Tom's has never been pulled: ~5,674 photos, 53.7 GB.

**2013–2019 is the priority — 2,367 photos his Google Takeout does not
have at all** (confirmed from the year distribution of what is already
imported, not a guess). 2010 and 2023–2026 are likely to dedup.

Import from here rather than `gsfarmctl`: that host has a **100 Mb**
NIC, which does not slow the import itself (~12 Mb/s, IOPS-bound) but
makes the transfer eight times slower. Do **not** run `immich-go` from
the MacBook — macOS Local Network privacy blocks it outright; see the
gotcha in `cluster-docs/CLUSTER.md`.

```bash
immich-go upload from-folder --no-ui --dry-run \
  --concurrent-tasks 1 --on-errors 200 <dir>
```

`--concurrent-tasks 1` is measured, not a typo: **4x faster than 2**
on this storage. Raising it caused every outage in the migration.
Before a bulk import, pause Immich's `facialRecognition` queue (it is
not covered by `--pause-immich-jobs`) and wait for all queues idle.
Full reasoning in `photo-migration/README.md`.

Immich is at `https://major.gs-farm.net`, 31,204 assets. Its API key
is on `gsfarmctl` at `~/.immich-api-key`; keep it out of command
lines, which are visible in `ps`.

**Mystery 2026-09-20/22: all 5 non-facialRecognition queues (thumbnail-
Generation, metadataExtraction, videoConversion, faceDetection,
smartSearch) were found paused on 2026-09-22, not just the
intentionally-paused facialRecognition.** They'd been confirmed
correctly resumed right after the 2026-09-19 import. Investigated
2026-09-23 via `kubectl` on `gsfarmctl` (this TrueNAS host has no
kubectl): server logs pin the pause to sometime during the day on
**Sunday 2026-09-20** (midnight retry errors present 09-19 and 09-20,
absent 09-21 onward; normal activity continues up to 09-20 23:03,
so the exact hour isn't narrower than "sometime that day"). Ruled out:
Volsync's nightly backups (`immich-library`, `immich-postgres-data`,
both 03:00 UTC — their `ReplicationSource` specs have no pre/post
hooks); the nightly `immich-postgres-dump` CronJob (read the full
script — plain `pg_dump`, no API calls); a pod/Redis restart
(`immich-valkey` has been up since 09-08, so the persisted pause flag
wasn't reset by one; `immich-server`/`immich-postgres` did restart
together on 09-18, but that's before the pause and queues were
confirmed fine after it). Immich doesn't log successful admin API
calls with enough detail to show who/what issued the pause. Best
remaining explanation was a manual pause via the Immich admin UI by
someone with access — **ruled out 2026-09-23: confirmed no one else
has Immich admin access.**

Also checked 2026-09-23: `~/.immich-api-key` on `gsfarmctl` is used by
manual `immich-go` runs for the earlier Shawna-library migration
(2026-09-09 through 09-18, all one-off, per `~/.cache/immich-go/` on
`gsfarmctl`), with **no runs on or after 09-19** and no systemd
timer/cron wired to it — not a scheduled automation either.

**Resource-pressure check (the user's hypothesis), via Prometheus
(`kube-prometheus-stack`, `observability` ns, port-forward
`svc/kube-prometheus-stack-prometheus` 9090):** this is a **single-
node cluster** (`talos-iok-xpu` is the only node — every workload,
including Immich, Postgres, Grafana, Vaultwarden, Forgejo, Pi-hole,
shares one box). Node CPU genuinely spiked from a ~20-25% baseline to
**60-76% for ~35 min (03:05-03:40 UTC = 11:05-11:40 PM EDT on 09-19)**,
right at the Volsync backup trigger (03:00 UTC), plausibly compounded
by Immich's own background workers still processing that evening's
bulk import. **Real, but not a clean match**: it had fully settled
back to baseline a full hour before the 04:57-04:58 UTC (12:57-12:58
AM EDT) "No microservices worker connected" warnings — 1-minute-
resolution CPU at that exact moment is flat baseline (23.8%), and
those warnings were themselves a harmless self-healing blip (job
processing continued right through both, never recurred), so they're
probably not the pause mechanism either.

**Net: still unresolved.** Everything checkable has been checked —
no other admin, no automation anywhere in the namespace or on
`gsfarmctl`, no pod/Redis restart, no clean resource-pressure
correlation, and Immich doesn't log the actual pause action at any
level. The one operationally useful thing that came out of this: a
big Volsync backup and a big bulk photo import can genuinely compete
for CPU on this single-node cluster — avoid running a bulk `immich-go`
import right around 03:00 UTC (11 PM EDT) if it can be helped. If this
recurs, check queue state (`GET /api/jobs`) more promptly next time,
before too much log history ages out, and note the exact time noticed.

### 3. node_exporter monitoring

**Fixed 2026-09-24.** `gsfarmctl`'s Prometheus flagged
`storage1-node-exporter` as down (connection refused, 10.0.0.169:9100).
Root cause: the original setup (`~/install-node-exporter.sh`,
2026-06-13) relied on `/etc/local.d/node_exporter.start` as a boot
hook — **that was never real on TrueNAS SCALE** (Debian-based; it
doesn't process `/etc/local.d`), so the "startup script" only ever
ran once, by hand, at install time. The process then died on its own
around 2026-07-04 (its log ends mid-write that day) and nothing ever
restarted it — silently broken for over two months before anyone
noticed.

Also relocated the binary from `/mnt/storage1/apps/node_exporter/`
(a plain directory on the pool's *root* dataset) to
`~/opt/node_exporter/` (under `storage1/home`, matching where
`immich-go`/`node`/`claude` already live). This wasn't actually the
live-failure cause — direct execution worked fine from the old
location too once retried — but it's the right place for it, and is
where the registered start script now points.

**Fix:** `~/opt/node_exporter-start.sh` (kills any existing instance,
starts the binary with the textfile collector pointed at
`/var/lib/node_exporter/textfile_collector`, same dir `check-backups.sh`
writes `backup_*` metrics to), registered via TrueNAS's own **Init/
Shutdown Scripts** feature — `midclt call initshutdownscript.query`,
`id: 1`, type `SCRIPT`, `when: POSTINIT`, `enabled: true` — a
middleware-backed mechanism stored in TrueNAS's config database, which
actually does survive reboots/upgrades (unlike `/etc/local.d`).
Confirmed working now: process up, `:9100/metrics` returns both
`node_exporter_build_info` and all `backup_*` metrics with HTTP 200.
**Not yet confirmed to survive an actual reboot** — the registration
and the manual test both look right, but no reboot has happened since
to prove it. If `storage1-node-exporter` goes down again after a
TrueNAS reboot, check `midclt call initshutdownscript.query` first
before re-diagnosing from scratch.

A few `nohup`/backgrounding attempts during debugging failed
intermittently with `Function not implemented` (ENOSYS) when run via
`sudo`, but isolating `nohup`, plain backgrounding, and `setsid`
individually all worked fine, and a plain retry of the full script
also worked — never got a clean root cause, likely transient.

## Further reading

`cluster-docs/CLUSTER.md` — the cluster reference and its gotchas
list, including the ones from the 2026-09 migration. Written from
`gsfarmctl`'s perspective; read it as reference, not as instructions
for this host.
