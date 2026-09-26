# Immich — Album Import (plan)

Album membership is the one part of the photo migration that was never
finished. The content is all in Immich; the curation mostly is not.

This plan is deliberately narrow: it covers **getting album structure
into Immich**, not importing more photographs. Those are different jobs
and only one source still has both.

## Measured state, 2026-09-26

```
library            31,455 photos + 483 videos     170 GB
in an album           562 distinct assets         1.8%
albums                 21, all created 2026-09-12/13
```

All 21 albums date from the Google Takeout stage. Nothing else ever
created one:

| Stage | Assets | Albums produced |
|---|---|---|
| Local drives (2026-09-08) | 359 | 0 |
| Google Takeout (2026-09-12) | 16,310 | **21** |
| Amazon, Shawna 2011–2025 (2026-09-14→18) | ~15,600 | 0 |
| `~/Downloads` (2026-09-26) | 2 | 0 |

The Amazon zero is not an oversight in the usual sense. All fifteen
runs are logged in `~/.cache/immich-go/` with
`--folder-as-album=NONE origin=default` and an empty `--into-album`,
but the source folders were `amazon-shawna/<year>/files` — flat,
by date range. Even with the flag set, the result would have been
fifteen albums named after years, which is what the timeline already
does. **Amazon's album structure was never in the download.** The
manifests in `~/amazon-manifests/*.txt` are bare filename lists,
16,236 lines with no album field, and Immich's `originalPath` is its
own UUID storage layout (`/data/upload/<user>/xx/yy/<uuid>.jpg`), so
no source-folder information survives anywhere on this side.

## The mechanism this plan depends on

`immich-go` adds an asset to an album **even when the server already
has it**. Verified 2026-09-26 with a dry-run against a known-present
asset downloaded back out of Immich:

```
Asset Lifecycle (DISCARDED):
  server has duplicate               :       1  (62.9 KB)

Processing Events:
  added to album                     :       1
```

No upload, album attached. That single behaviour is what makes this
worth doing: given the 95–99% redundancy measured across the last
three import stages, an album import is almost entirely an operation
on assets that are *already there*. It costs bandwidth for the
checksum probe, not for the photographs.

It also means the import source does **not** have to be the source the
photo originally came from. Any folder tree that names the right files
in the right folders will produce the right albums, regardless of
which cloud the bytes came from.

## Source assessment

| Source | Album data recoverable? | Verdict |
|---|---|---|
| Google Photos | Already imported, 21 albums | Done |
| Apple Photos | **No — zero albums on either Mac.** One *shared* album, `Family` (48), on the Air only | **Phase 1**, now a ~184-photo content import, not an album import |
| Local / network drives | Maybe — folder names may or may not be meaningful | Phase 2, survey first |
| Amazon Photos | Not in the export or the manifests — but recoverable from filenames alone | **Done** — all 12 imported 2026-09-26 |

## Phase 1 — Apple Photos

**Rescoped 2026-09-26, after surveying both Macs.** This was expected
to be the large phase. It is not:

| | MacBook Air | MacBook Pro |
|---|---|---|
| Photos | 183 | 184 |
| Regular albums | **0** | **0** |
| Shared albums | *Family* (48) | none |

**Zero regular albums on either machine.** So there is no album
structure to import here at all — `--folder-as-album` has nothing to
do, and the phase's original justification is gone. What remains is a
small content import of ~184 photographs, plus one shared album that
needs handling on its own terms.

Given the last three import stages ran 95–99% redundant against the
Google Takeout library, expect most of the 184 to already be in
Immich. The dry run will say for free.

Background in `docs/CLUSTER.md`: the 2026-09-08 attempt pointed
`immich-go` at all of `~/Pictures`, walked into the
`Photos Library.photoslibrary` package, and ingested 477 junk assets
(293 downscaled derivatives, 184 UUID-named originals with no album
membership). All 477 were deleted. **Never point the tool at the
`.photoslibrary` package** — it is an opaque bundle, not a photo
directory, and its internal layout is exactly the wrong shape.

### 1a. The 183 vs 184 question

They look like a complete overlap, but that was a visual check. It
does not need to stay a guess: export both, sha1 them, and compare.
The answer also decides whether both machines need importing or just
one.

```bash
cd ~/apple-air   && find . -type f -print0 | xargs -0 sha1sum | awk '{print $1}' | sort -u > /tmp/air.txt
cd ~/apple-pro   && find . -type f -print0 | xargs -0 sha1sum | awk '{print $1}' | sort -u > /tmp/pro.txt
comm -3 /tmp/air.txt /tmp/pro.txt      # empty = identical sets
```

If both Macs are signed into the same iCloud Photos library the sets
should be identical and the 183/184 gap is sync lag. If they are
separate local libraries, the difference is real and both need
importing.

### 1b-result. Imported 2026-09-26 — 48 new assets, `Family` album created

Exported from the MacBook Air with Export Unmodified Originals,
default options, to `~/ipadExport2` — 48 files, 8.8 MB, flat folder,
all `.JPG`, `IMG_0001`–`IMG_0048`.

Pre-flight confirmed every expectation:

| Check | Result |
|---|---|
| Dimensions | **48/48 at 960x720** — iPad 2 native, no downscaling |
| Device | **48/48 `Apple` / `iPad 2`** |
| EXIF dates | **48/48 present**, 2017-11-18 → 2018-02-19 |
| Already on server (sha1) | **0 of 48** |

Imported with `--into-album "Family"` rather than
`--folder-as-album`, since the staging directory is named
`ipadExport2` and would otherwise have become the album name.

```
uploaded successfully : 48  (8.6 MB)
added to album        : 48
discarded             :  0
```

Verified after: photos **31,455 → 31,503 (+48)**, albums **31 → 32**,
memberships **824 → 872**, `Family` holds 48, all 48 byte-present by
sha1, no new job failures against the 7/3/2/2/5 baseline, all queues
idle and none left paused, all pods ready.

Dates filed correctly rather than defaulting to today: **47 in
2017-11, 1 in 2018-02**, matching the EXIF range exactly.

**A filename collision worth recording.** `IMG_0016.JPG` already
existed on the server — a Canon PowerShot ELPH 360 HS shot from
2020-12-25 at 3888x5184. Entirely different photograph, same name.
`immich-go` weighs name *and date* and size together, so the
differing dates meant it did not trip the "same name and date but
bigger on the server" skip; both now coexist. Two consequences:

- The library now has a genuine duplicate `originalFileName`, so
  name-based resolution would find it ambiguous. This is exactly why
  `immich-album-from-names.py` skips ambiguous names instead of
  guessing — had these 48 needed name resolution rather than upload,
  `IMG_0016.JPG` would have been correctly refused.
- Generic camera filenames (`IMG_00NN.JPG`) collide across devices
  far more readily than the timestamped names Amazon and Google use.
  Any future name-resolution work on camera-roll exports should
  expect ambiguity rates well above the 0.1% seen on the Amazon set.

### 1c-result. The Air's 183 loose photos — imported 2026-09-26

Exported from the MacBook Air with Export Unmodified Originals,
default options. 183 files, 55 MB, flat folder, 158 JPG + 25 PNG,
`IMG_1432`–`IMG_5097`. **All 183 new** — 0 already on the server, and
no filename collisions.

**The date trap, and the fix.** 139 files carried an EXIF date; the
other **44 carried none, no make/model, and no parseable date in the
filename** (`IMG_1432.JPG`), so `--date-from-name` could not rescue
them the way it saved `202312031443160000.jpg` in the `~/Downloads`
batch. With no EXIF, `immich-go` falls back to the file mtime as
`FileDate` — and the first transfer, a plain `scp -r`, had collapsed
all 183 mtimes onto two timestamps a minute apart. Those 44 would
have landed in the 2026 timeline, with the import reporting complete
success.

Re-transferred with `scp -rp` (`rsync -a` equivalent), which
preserves mtime. The validation that made this trustworthy: for the
**139 files that do have EXIF, mtime matched EXIF to within 1 second**
(median 0, max 1s, none over a minute). That is what proves the mtime
is the genuine capture date rather than an export artifact — and
therefore that the 44 undated files' mtimes can be believed too.
Their sequence corroborates it: `IMG_1432`–`1439` sit at 11:39–11:45
on 2018-10-06, consecutive minutes, exactly like a real burst.

Byte-identical to the first transfer (183/183 same sha1), so only
metadata changed.

**Result:** photos **31,503 → 31,686 (+183)**, all 183 byte-present
by sha1, no new job failures against the 7/3/2/2/5 baseline, pods
healthy. Timeline placement matched the mtime spread exactly, with
**zero assets in 2026**:

```
2018-10  85     2019-02   7     2019-05  17     2020-04  13
2018-11  21     2019-03   8     2019-06   6     2021-07   1
2018-12  10     2019-04   8     2019-07   2
2019-01   5
```

The 44 previously-undated assets span 2018-10-06 → 2021-07-30.

Approaches ruled out along the way:

- **XMP sidecars.** `immich-go` v0.32.0 logs `discovered sidecar` but
  still reports `CaptureDate=0001-01-01`, under both the
  `IMG_1433.xmp` and `IMG_1433.JPG.xmp` conventions. The "Export IPTC
  as XMP" checkbox does not help.
- **Bracketing undated files between dated neighbours** in the
  `IMG_NNNN` sequence. Median uncertainty 8.9 days, max 273, and 10
  of the 44 unbounded at the ends of runs. Not worth it when a
  transfer flag recovers the real dates.

### Still open in Phase 1

The **MacBook Pro's 184 photos**. The 183-vs-184 question stands: if
both machines share one iCloud Photos library the sets are identical
and there is nothing left to do, but that was a visual check. Settle
it by exporting with `scp -rp` and comparing sha1 against the 183
just imported — anything already present will simply report
`server has duplicate`.

## Phase 2 — local and network drive folders

Stage 1 imported 359 assets from `~/Pictures/pics` and similar with
no album structure. Whether those folders *deserve* to be albums is a
judgement call that needs eyes on the folder names first — a tree of
`2015`, `misc`, `new folder` should stay timeline-only.

Survey before planning:

```bash
find <drive-root> -maxdepth 2 -type d -printf '%p\t' \
  -exec sh -c 'find "$1" -maxdepth 1 -type f | wc -l' _ {} \;
```

If the names are meaningful, this is the same `--folder-as-album`
run as Phase 1 and the files are already on the server, so it is
cheap. If they are not, skip it — say so explicitly rather than
leaving the phase open.

## Phase 3 — the Amazon half: names, not photographs

Roughly half the library (~15,600 assets, Shawna's 2011–2025) has no
album membership. Confirmed 2026-09-26: **Tom's Amazon account has no
albums at all, and Shawna's has 12.** So the scope here is twelve
albums, not fifteen years of camera roll.

The original framing — "re-export per album through a 200-file cap" —
was wrong, and it was wrong in a way worth writing down.

### The bytes are already here. Only the names are missing.

Every one of those photographs is in Immich. The only thing Amazon
still holds that Immich does not is *which album each name belonged
to*. And filenames resolve to assets almost perfectly:

```
live assets                         32,809
globally unique originalFileName    32,484   (99.0%)
ambiguous names (>=2 assets)           155 names / 325 assets
```

Tested directly against the 16,236 names in `~/amazon-manifests/`:

```
resolve to exactly one asset   16,046   98.8%
ambiguous                          15
not in Immich                     175    mostly "name(1).jpg" copies
                                         immich-go skipped as duplicates
```

So album membership can be **reconstructed from a filename list
alone** — no download, no re-import, no 200-file grind. Whatever gets
a list of names per album out of Amazon is sufficient, including
downloading an album and reading `unzip -l` without ever extracting
it.

### Mechanism

Confirmed present on v3.1.0 by probing a non-existent album id, which
creates nothing:

```
PUT  /api/albums/{id}/assets  -> 400   (route exists, empty ids rejected)
POST /api/albums/{id}/assets  -> 404   (no such route)
```

So the sequence per album is:

1. Get the album's filenames from Amazon.
2. Resolve each against `originalFileName` (the map is one query:
   `SELECT "originalFileName", id FROM asset WHERE "deletedAt" IS NULL`).
3. `POST /api/albums` to create it, then
   `PUT /api/albums/{id}/assets` with the resolved ids.

Handle the ~1.2% remainder explicitly rather than silently: report
ambiguous and unresolved names per album and decide them by hand.
An unresolved `name(1).jpg` is usually a duplicate Immich already
holds under the un-suffixed name, so the album is not actually missing
the photograph — but confirm that rather than assume it.

### Scope

Twelve albums, all on Shawna's account. Cost scales with that twelve,
not with the 15,600 photographs — which is the whole point of
resolving by name.

The Windows Amazon Photos desktop app exports **one album at a time**,
which is the piece that makes this practical.

### Tooling

`scripts/immich-album-from-names.py` does the resolution and the
album write. Dry run by default:

```bash
scripts/immich-album-from-names.py --dir ~/amazon-albums/"Summer 2014"
scripts/immich-album-from-names.py --names-file list.txt --album "Summer 2014"
scripts/immich-album-from-names.py --dir ... --create     # actually write
```

It builds its name index from **one read-only SELECT against
Postgres**, not the search API. That is deliberate:
`/api/search/metadata`'s `originalFileName` filter is a **substring**
match, not an exact one — `0190101_091427.jpg`, missing its leading
digit, still returns the asset — so resolving through it needs
per-name post-filtering and can truncate at the page limit. Writes go
through the API (`POST /api/albums`, `PUT /api/albums/{id}/assets`),
never the database.

Behaviour worth knowing:

- Exact match first, then case-insensitive as a fallback, reported
  separately — Windows exports can differ in case.
- **Ambiguous names are skipped, never guessed**, and listed.
- Refuses to create an album whose name already exists; pass
  `--album-id` to add to that one instead.
- Skips `Thumbs.db`, `.DS_Store`, `desktop.ini`, `picasa.ini`.
- Resolved ids are deduped — two source names can point at one asset.

Verified 2026-09-26: dry run against 60 real manifest names plus three
planted failures resolved 60 exact, 1 case-insensitive, 1 unresolvable,
`Thumbs.db` skipped. The `PUT` response shape
(`[{"id":…,"success":false,"error":"duplicate"}]`) was confirmed by
re-adding an asset already in the *Drop Box* album — a genuine no-op,
count stayed 3.

### The pilot — DONE 2026-09-26, name-matching validated

Two albums exported from the Windows app (one was selected by
accident, which is how it became two): **Chadwick** 23 files / 95 MB
and **home** 8 files / 21 MB, landing as
`~/AmazonAlbum/Amazon Photos Downloads/<album>/`. All JPEG, no
`Thumbs.db`, no nesting.

The point of the pilot was not to get two albums done; it was to find
out whether matching by *name* is as good as matching by *bytes*
before trusting it for the rest. Three independent methods were run
over the same 31 files:

| Method | Result |
|---|---|
| sha1 vs `asset.checksum` (ground truth) | 31/31 resolved |
| `originalFileName` resolution | 31/31 resolved |
| `immich-go --folder-as-album` dry run | 31 `server has duplicate`, 31 `added to album`, 0 uploaded |

**Every file resolved to the same asset id under both name-matching
and checksum-matching — 31 of 31, zero disagreements.** Name
resolution is therefore trustworthy here, and the remaining albums
need only a filename list.

Note `asset.checksum` is plain sha1 of the original bytes, stored as
`bytea`, so `encode(checksum,'hex')` compares directly against
`sha1sum` output. That makes a byte-level truth set cheap to build
whenever a method needs checking.

Created with the resolver:

```
created album 2ae272ea-4e71-452f-b1b8-7295d406878f
added 23 assets to 'Chadwick'
created album 5791cc65-b95f-47ff-95ba-a4f9d81f2072
added 8 assets to 'home'
```

Verified after: 21 -> **23 albums**, 606 -> **637 memberships**,
photo/video totals **unchanged at 31,455 / 483** (nothing uploaded),
both albums owned by `immadmin` as intended, and each album's live
membership **identical** to the checksum-derived truth set. The
duplicate-name guard was confirmed by re-running `--create`, which
refused and exited 1.

Ownership is not on the `album` table in v3.1.0 — it is a role in
`album_user`:

```sql
SELECT a."albumName", u.email, au.role FROM album a
JOIN album_user au ON au."albumId" = a.id
JOIN "user" u ON u.id = au."userId";
```

### Batch 2 — 2026-09-26, 8 of the remaining 10 created

The other ten exported in one capture to
`~/AmazonAlbum2/Amazon Photos Downloads/`: 187 files, 666 MB, all
JPEG, no junk, no nesting. Name-matching held again — **187 of 187
resolved identically under sha1-vs-`asset.checksum` and under
`originalFileName`**, zero disagreements, so that is now 218 of 218
across both batches.

Created: `camping 2022` (39), `Dutches` (12), `Hens` (6), `HVAC` (10),
`Igloo` (3), `L120` (5), `Macy` (18), `rabbits` (7). Verified 23 ->
**31 albums**, 637 -> **737 memberships**, photo/video totals
**unchanged at 31,455 / 483**, and every album's live membership
identical to its checksum-derived truth set.

`~/AmazonAlbum` (the pilot, 115 MB) was re-verified — all 31 files
byte-present on the server by sha1 — and deleted.

### `Charmer` and `Edie` — merged 2026-09-26

Two names differed from existing albums only in capitalisation, with
**zero asset overlap**: the existing pair came from Google Takeout and
are 2024 Pixel files (`PXL_2024…`), the Amazon sets are entirely
different photographs of the same subjects.

| Amazon export | Existing album | Result |
|---|---|---|
| `Charmer` (54) | `charmer` (7) | merged -> **61** |
| `Edie` (33) | `edie` (5) | merged -> **38** |

Merged with `--album-id`, keeping the existing lowercase names, so
each subject is one complete album. No case-only duplicate album
names remain anywhere in the library.

**This exposed a defect in the resolver's duplicate-name guard**,
which compared names exactly and would have created `Charmer`
alongside `charmer` without complaint — precisely the mess the guard
exists to prevent, and Immich itself does not stop you. It is now
case-insensitive and says which it found:

```
an album named 'charmer' already exists (differs from 'Charmer' only in case):
13bead70-…, 61 assets.
Pass --album-id to add to it.
```

### Where the albums landed

Shawna's content was imported with Tom's API key, so all 31,455
assets belong to `immadmin` and her account holds zero. Albums built
from her Amazon content are therefore **Tom's albums**. Confirmed as
a deliberate choice on 2026-09-26 rather than left as a side effect;
partner sharing covers visibility, and moving asset ownership is a
much larger question that this phase does not touch.

### Phase 3 result

All 12 Amazon albums are in. **31 albums, 824 memberships**, up from
21 / 606 at the start of the day. Photo and video totals are
**unchanged at 31,455 / 483** throughout — not one byte was
re-uploaded, which was the entire point of resolving by name.

Name-matching agreed with checksum-matching on **218 of 218 files**
across both batches, with zero disagreements.

Both staging folders are gone: `~/AmazonAlbum` (115 MB) and
`~/AmazonAlbum2` (666 MB), each re-verified byte-present on the
server by sha1 immediately before deletion. 781 MB reclaimed, nothing
left on disk from this phase.

One incidental finding from that verification: the 187 files carry
only 186 distinct checksums — `20210306_170417.jpg` appears in both
`rabbits` and `Igloo`. That is a photograph genuinely filed in two
Amazon albums, and it resolved to one asset added to both, which is
the correct outcome.

**Phase 3 is closed.**

## Verification

Same inventory before and after each phase.

All three use the same key-handling pattern as the rest of this
migration — the key never appears in a command line visible to `ps`:

```bash
imm() {
  printf 'header = "x-api-key: %s"\nsilent\n' "$(cat ~/.immich-api-key)" \
    | curl --config - "$@"
}
```

```bash
# album count and sizes
imm https://major.gs-farm.net/api/albums \
  | python3 -c 'import json,sys
a=json.load(sys.stdin)
print(len(a),"albums,",sum(x["assetCount"] for x in a),"memberships")
for x in sorted(a,key=lambda y:-y["assetCount"]): print("  %6d  %s"%(x["assetCount"],x["albumName"]))'
```

Album asset lists come from `POST /api/search/metadata` with
`{"albumIds":["<id>"],"size":250,"page":N}` — **not** from
`GET /api/albums/{id}`, which returns `assetCount` correctly but an
empty `assets` array on v3.1.0 even with `?withoutAssets=false`.

Also check, as after every import stage, that the job queues picked
up no new failures against the pre-run baseline:

```bash
imm https://major.gs-farm.net/api/jobs \
  | python3 -c 'import json,sys
for k,v in json.load(sys.stdin).items():
    c=v.get("jobCounts",{})
    if c.get("failed"): print(k, c["failed"])'
```

Baseline 2026-09-26: `thumbnailGeneration` 7, `ocr` 5, `faceDetection`
3, `facialRecognition` 2, `duplicateDetection` 2.

## Gotchas

- **`--pause-immich-jobs` defaults to `true`.** Every run, dry ones
  included, pauses `thumbnailGeneration`, `metadataExtraction`,
  `videoConversion`, `faceDetection` and `smartSearch` and resumes
  them at the end. The 2026-09-25 log shows a clean symmetric
  pause/resume, and no queue is paused today — but an interrupted run
  leaves them paused with nothing to say so. After any aborted run:

  ```bash
  imm https://major.gs-farm.net/api/jobs \
    | python3 -c 'import json,sys
  print([k for k,v in json.load(sys.stdin).items() if v.get("queueStatus",{}).get("isPaused")])'
  ```

  Pass `--pause-immich-jobs=false` for small probe runs where the
  pause buys nothing.
- **Album membership is additive and safe; it is the export that is
  risky.** An album import cannot lose photographs. The failure mode
  is the 2026-09-08 one — exporting the wrong thing and ingesting
  derivatives — which happens on the Mac, before any of this.
- **`gsfarmctl` has 5.7 GB of RAM** and an `immich-go` run indexes the
  whole server list first. It died at 53% on a 12,000-asset run on
  2026-09-12. An Apple export is likely small enough not to matter,
  but split it if the index phase starts swapping.
- **Run from `gsfarmctl`, never the Mac.** macOS Local Network privacy
  blocks `immich-go` outright.
- Config lives in `/home/stecktf/immich-go.yaml` (server + API key),
  so neither needs to appear on the command line.

## Ordering against the stacking pass

**Updated 2026-09-26, after Phase 3 and the Apple survey.** The
original argument was that album imports can add assets, so stacking
should wait. Most of that has now resolved itself:

- **Phase 3 added nothing.** All 12 Amazon albums were built by name
  resolution; photo/video totals never moved off 31,455 / 483. It
  cannot have changed the duplicate picture.
- **Album coverage is no longer the problem it was.** 562 assets in
  albums became **824 memberships across 31 albums**, so the "which
  copy did someone actually curate" signal now exists where it did
  not.
- **Phase 1 has no albums at all**, so `--folder-as-album` and its
  import-time stacking flags are irrelevant to it.

What survives, and it is the sharp one:

> The `Family` shared album is the only remaining source that can add
> assets, and what it would add is **specifically downscaled copies**
> of photographs already held at full resolution — up to 48 brand-new
> resolution-variant duplicate groups, created immediately before the
> pass whose whole job is cleaning those up.

So the ordering still holds, for a narrower reason: **settle the
shared album before stacking.** Either import only the
other-contributor photos (see 1b), or decide to skip it entirely.
Either way the answer must land first, because the alternative is
stacking a library that is about to grow in exactly the dimension
being stacked.

The ~184 ordinary Apple photos are lower risk — if they behave like
the `~/Downloads` batches they will be near-100% redundant and add
nothing — but they are cheap to settle first too.

Re-run **Duplicate Detection** once Phase 1 is done, before starting
the stacking pass, so its numbers reflect the final library.

Scope for that pass, unchanged: of 512 groups only **64** differ in
resolution — the actual stacking target, worth 60 MB. The other 448
are same-resolution duplicates, a keep-or-delete decision rather than
a stack.

## Open questions

1. ~~How many albums does the Apple Photos library have?~~
   **Answered 2026-09-26: zero on both Macs.** One shared album,
   `Family` (48 photos), on the Air only. Phase 1 is therefore a
   small content import, and the only real question left in it is
   which of the 48 shared-album photos were contributed by *other
   people* — those are the unique content; the rest are downscaled
   copies of originals already in the library.
2. Are the 183 photos on the Air and the 184 on the Pro the same set?
   Looks like a complete overlap visually. Settle it with sha1 after
   export (1a) rather than by eye.
3. Are the local/network drive folder names meaningful enough to be
   albums? Decides whether Phase 2 exists.
4. ~~Are there Amazon-era albums worth recovering?~~ **Done
   2026-09-26** — none on Tom's account, 12 on Shawna's, all 12
   imported.
