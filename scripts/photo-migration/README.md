# Photo migration tooling

Written during the 2026-09 Immich migration (local drives → Google
Takeout → Amazon Photos, 31,204 assets). Kept because the Amazon stage
is unfinished: Tom's own library is untouched, and Shawna is missing
238 files from 2025.

Each script encodes something that went wrong at least once. Full
context in `docs/CLUSTER-doc-updates-2026-09-*.md`.

## `watch-prep.sh <year> <expected_zip_count>`

Waits for a transfer to finish, then runs `prep-year.sh`. Completion
means **both** the expected zip count *and* a total size that has
stopped changing for 60s.

The size check is not paranoia - it caught a transfer mid-write twice
on the 2017 batch. `scp` writes in place, so a file being present says
nothing about it being complete.

## `prep-year.sh <dir|year>`

Takes either an explicit directory or a year resolved under
`AMAZON_BASE` (default `~/amazon-shawna`, the 2026-09 layout):

```bash
prep-year.sh /mnt/storage1/home/stecktf_a/amazon-tom/2018
AMAZON_BASE=/mnt/storage1/home/stecktf_a/amazon-tom prep-year.sh 2018
```

CRC-verifies every zip, refuses
to extract if any fails, extracts to `files/`, then EXIF-checks
anything whose filename has no date.

It **compares `entries` against the extracted file count itself** and
warns on a mismatch. Amazon names
every download `AmazonPhotos.zip` with only the size to tell them
apart, so batches get grabbed twice and others missed. A gap means a
duplicate; a shortfall against the expected total means a missed
batch. This found three duplicated and three missed batches in 2025
alone, and a missed 200-file batch in 2017.

Note: the EXIF check produces **false negatives**. It greps for a
date string and misses plenty that Immich reads correctly. Treat its
output as "worth looking at", not "these have no date".

## `fix-dates.py <dir> <noexif-list> [--apply]`

Recovers capture dates from filenames, for files with no EXIF.
Amazon's file mtimes are **upload** dates, so anything without EXIF
otherwise lands years out - 2012 photos dated 2017.

Handles four patterns, each validated to a plausible year (2005-2026)
before being applied:

| Pattern | Example |
|---|---|
| `YYYYMMDD_HHMMSS` | `Resized_20181008_213715.jpg` |
| `YYYY-MM-DD HH.MM.SS` | `2012-10-13 11.18.28.jpg` |
| `YYYYMMDDHHMMSSmmm` | `barn external_03_20181210170805995.jpg` |
| 13-digit epoch ms | `FB_IMG_1484571007988.jpg` |

Dry-run by default. The epoch matcher requires exact digit boundaries
so it does not misread Facebook attachment IDs (17 digits) as
timestamps.

**Real EXIF always wins.** Immich reads embedded dates and ignores the
mtime, so this only affects genuinely dateless files - the 150 wedding
photos landed on the right date without any help from it.

## Importing

Run from a directory containing `immich-go.yaml` (nested under
`upload:`, with `server` and `api-key`):

```bash
immich-go upload from-folder --no-ui --dry-run \
  --concurrent-tasks 1 --on-errors 200 <dir>
```

`--concurrent-tasks 1` is deliberate and measured: on this storage it
was **4x faster** than 2 (17/min vs 4/min, median upload 3.4s vs
14.5s) and produced zero errors against 54. Two parallel write streams
thrash the HDD mirror. Raising it caused every outage in the
migration.

Before a bulk import: pause `facialRecognition` (it is **not** covered
by `--pause-immich-jobs`) and wait for all job queues to be idle.
Afterwards, verify against the database rather than the client's
counters, which have been misleading in both directions.

## `~/amazon-manifests/`

Filename lists for every year already imported. To find what a new
download is missing:

```bash
comm -13 ~/amazon-manifests/shawna-2025.txt /tmp/new-names.txt
```
