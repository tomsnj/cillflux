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
| ↳ `shawna-laptop-backup` | 672G | **481G** |
| `backups/desktop2` | 733G | 52.6G |
| `backups/desktop1` | 700G | 94.6G |
| `media` | 700G | — |

- **`maxwell-image` and `mycloud-photos` are described in the separate
  backup project** — get that context before proposing anything for
  them. Between them they are 3.65T, far more than snapshot pruning
  can recover.
- Snapshot pruning yields roughly **692G total**, under 10% of the
  pool. The 481G under `shawna-laptop-backup` is mostly the Amazon and
  Google Takeout zips downloaded during the 2026-09 photo migration.
  Those have been deleted from the laptop and their content is
  verified in Immich, but **the blocks stay pinned until the
  snapshots covering that window are pruned or age out**.
- Two snapshots from **2020-11-04** (`media@manual`, `share@manual`,
  4.3G combined) and `home_nfs@pre-maintenance-2026-05-02` (12.3G) are
  obvious stale candidates.
- **Fragmentation does not drop when space is freed.**

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

## Further reading

`cluster-docs/CLUSTER.md` — the cluster reference and its gotchas
list, including the ones from the 2026-09 migration. Written from
`gsfarmctl`'s perspective; read it as reference, not as instructions
for this host.
