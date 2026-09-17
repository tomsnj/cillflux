# Cluster Doc Update — 2026-09-16

## Immich — family accounts for Shawna, Maxwell and Calvin

Three accounts added, with per-user quotas and Keycloak SSO. Until
now Immich had exactly one user (`immadmin`) owning everything.

| Account | Email | Quota | Keycloak user |
|---|---|---|---|
| Shawna Gilroy | `gilroyshawna@gmail.com` | 200 GiB | `shawna` |
| Maxwell Steck | `maxwellgsfarm@gmail.com` | 100 GiB | `maxwell` |
| Calvin Steck | `calvinsteckphoto@gmail.com` | 100 GiB | `calvin` |

Shawna's larger quota is deliberate - she shoots the horse-training
video, and the point of a quota here is to stop one person's video
filling a pool the whole cluster shares.

Temporary passwords (Immich local + Keycloak) are in
`~/immich-family-passwords.txt` on `gsfarmctl`, mode 600. All are
flagged to change on first use.

### The decision that shaped this: who owns the archive

Every one of the 27,213 assets belongs to `immadmin`, **including
~21,000 of Shawna's** - her Google Takeout library and her Amazon
backfill were both imported using Tom's API key. Immich has no
supported way to transfer asset ownership, so this was effectively a
permanent structural choice.

Two models were on the table:

- **Family archive** - Tom's account holds the shared history;
  everyone else gets an account for their own future uploads, with
  partner sharing for visibility.
- **Per-person libraries** - re-import Shawna's ~21,000 assets under
  her account and delete them from Tom's.

Went with the family archive. It matches what
`docs/photo-storage-strategy-research.md` actually planned ("partner
sharing for your wife so her horse-training footage merges straight
into the shared library"), the content is genuinely shared family
history, and the alternative meant re-doing days of work.

Worth recording honestly: the second option got materially more
expensive earlier the same day, because the Google Takeout archives
were deleted (on Claude's recommendation) once both accounts were
verified imported. Her Amazon years are still staged locally, but her
Google content would need a fresh Takeout request. That wasn't
foreseen when the archives were deleted.

### Sharing topology

| Share | Direction | Effect |
|---|---|---|
| Tom → Shawna | one-way | sees the whole archive |
| Shawna → Tom | one-way | her future uploads visible to Tom |
| Tom → Maxwell | one-way | sees the whole archive |
| Tom → Calvin | one-way | sees the whole archive |
| Maxwell/Calvin → anyone | none | **their uploads stay private** |

This is exactly what was asked for: the boys can see everything and
upload their own photos without those uploads flowing back. Partner
sharing is read-only, so they cannot modify or delete the archive.
Albums remain available between any pair of accounts for deliberate
sharing in either direction.

Shawna created her own reverse share within minutes of first login -
worth noting because **an admin cannot create it for her**. See the
partner-sharing gotcha in `CLUSTER.md`.

### Account creation order matters

Documented as a gotcha in `CLUSTER.md`, summarised here: create the
Immich account first (with its quota), create the Keycloak realm user
second, let the first SSO login link them by email. An
SSO-autoregistered account gets **no quota**, and quota is a
create-time property.

Verified after Shawna's first login:

```
gilroyshawna@gmail.com | Shawna Gilroy | 200 | sso_linked: t | created 2026-09-17 01:33
```

One row for her email, `createdAt` unchanged from creation, quota
intact, both partner shares present. That is a link, not a
re-creation. Maxwell and Calvin had not yet logged in at time of
writing.

## Immich — Amazon Photos backfill in progress

Stage 3 of the migration. Scope was set by two cheap probes rather
than assumption:

- A month from 2024 came back **99.1% duplicate** (209 of 211 already
  present from Google Takeout), so 2022-2025 is being skipped
  entirely - ~45 manual downloads to recover perhaps 80 photos.
- A month from 2018 came back **0% duplicate**, confirming 2013-2021
  is genuinely absent from Immich.

Amazon has no Takeout equivalent: the web UI caps downloads at **200
files** each, so Shawna's ~8,500 pre-2022 photos take ~43 manual
batches. The desktop app can bulk-download but showed nothing newer
than Nov 2024 while the web UI showed Oct 2025, so it cannot be
trusted for completeness.

**Progress: 2013-2019 imported, 2020-2021 outstanding. 27,213 assets
total, up from 16,992 when the Amazon stage began.**

### The operational finding: concurrency 1 is 4x faster than 2

The 2014 import failed three times - `504` on the dedup fetch, then
`502`s, then Postgres SIGKILLed by its liveness probe with
`immich-server` crash-looping behind it. Three fixes were made in
response (`584e7f8e`, `0d1499d0`, `a5534ff3`, plus a
`proxy-read-timeout` raise in `0e7e4588`).

Then `--concurrent-tasks` was dropped from 2 to 1:

| | concurrency 2 | concurrency 1 |
|---|---|---|
| Median upload | 14.5s | **3.4s** |
| Slowest | 112s | **9.2s** |
| Throughput | 4/min | **17/min** |
| Errors | 54 | **0** |
| Pod restarts | server +5, pg +1 | **none** |

**Halving the parallelism quadrupled the throughput.** Two concurrent
write streams make the `gsks0` HDD mirror thrash between them, so each
write pays a seek penalty; serialised, the disk works nearly
sequentially. Every cascading outage during this stage was
self-inflicted by parallelism the storage cannot serve.

Since the switch: seven consecutive years imported, zero errors, zero
new pod restarts.

### Method, for the remaining years

`scratchpad/watch-prep.sh <year> <zipcount>` waits for the transfer to
finish (zip count **and** a stable total size - it caught a transfer
mid-write twice on 2017), then runs `prep-year.sh`: CRC-verify every
zip, refuse to extract if any fails, extract, and EXIF-check anything
without a date in its filename. Then `fix-dates.py` recovers capture
dates from filename patterns, and the import runs detached at
concurrency 1.

Three things this catches that would otherwise be silent:

- **Truncated transfers.** `scp` has no resume; one 10 GB Takeout file
  arrived 1.11 GB short earlier in the migration.
- **Duplicate or missing batches.** Amazon names every download
  `AmazonPhotos.zip` with only the size to tell them apart. On 2017
  one batch was downloaded twice and another missed entirely -
  invisible except as `entries` (2,043) exceeding `extracted` (1,843).
- **Wrong dates.** Amazon's file mtimes are **upload** dates, not
  capture dates, so any file lacking EXIF lands years out. ~108 assets
  have no recoverable date and sit at their upload date; all are
  shared/received images rather than her own captures.

### Still outstanding

- Amazon 2020 and 2021.
- `xmas_2015.jpg` and ~107 others dated at upload time - fixable in
  the UI, not worth bulk action.
- `docs/proposal-immich-postgres-nvme.md` - proposed, not implemented.
  Less urgent after the concurrency finding, but the placement is
  still wrong.
- `frigate-data` still has no `ReplicationSource`.
