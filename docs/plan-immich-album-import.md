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
| **Apple Photos** | **Yes** — Photos.app exports album-per-folder, and this library was never properly imported at all | **Phase 1** |
| Local / network drives | Maybe — folder names may or may not be meaningful | Phase 2, survey first |
| Amazon Photos | No. Not in the export, not in the manifests, not in Immich | Phase 3 — a decision, not an import |

## Phase 1 — Apple Photos

This is the only source where the album import and an outstanding
content import are the same job, so it goes first regardless of how
the other phases land.

Background in `docs/CLUSTER.md`: the 2026-09-08 attempt pointed
`immich-go` at all of `~/Pictures`, walked into the
`Photos Library.photoslibrary` package, and ingested 477 junk assets
(293 downscaled derivatives, 184 UUID-named originals with no album
membership). All 477 were deleted. **Never point the tool at the
`.photoslibrary` package** — it is an opaque bundle, not a photo
directory, and its internal layout is exactly the wrong shape.

### 1a. Export on the Mac, with album structure

This step has to happen on the Mac — the library lives there and
Photos.app is the only thing that can read it. Everything after it
runs on `gsfarmctl`.

The requirement is one folder per album, named for the album. Two
ways to get there:

- **GUI.** Select an album in the sidebar → File → Export → *Export
  Unmodified Originals*, into a folder named for that album. Reliable
  and needs nothing installed, but it is per-album, so it only scales
  to a handful.
- **`osxphotos`** (`brew install osxphotos`) — exports the whole
  library with album structure in one pass, roughly
  `osxphotos export <dest> --directory "{album,_no_album}"`.

I could not verify from `gsfarmctl` whether this macOS version's
Export dialog offers an album-named Subfolder Format, so **check that
before committing to the GUI route**: if it does, one export covers
everything; if it does not, the per-album loop or `osxphotos` is the
way. Worth deciding by album count — under ~10, the GUI is fine.

Either way: **Export Unmodified Originals**, not Export Photos. The
latter writes edited renders, which is precisely what produced the
293 derivative assets last time.

### 1b. Stage to `gsfarmctl`

```bash
rsync -avP ~/Desktop/photos-albums/ stecktf@10.0.100.240:~/apple-albums/
```

Then confirm the shape before importing anything — one level of
folders, each an album, no `.photoslibrary` anywhere:

```bash
find ~/apple-albums -maxdepth 1 -type d | head -30
find ~/apple-albums -name '*.photoslibrary' -o -name 'AlbumData.xml'   # must be empty
du -sh ~/apple-albums
```

### 1c. Dry run

```bash
immich-go upload from-folder --no-ui --dry-run \
  --folder-as-album=FOLDER --concurrent-tasks 1 --on-errors 200 \
  ~/apple-albums 2>&1 | tee ~/apple-albums-dryrun.log
```

`FOLDER` uses the immediate folder name; `PATH` joins the whole path
with `--album-path-joiner` (default `" / "`). Use `FOLDER` for a flat
album-per-directory export, `PATH` only if the export nests.

Read three numbers off the report before proceeding:

- `added to album` — the point of the exercise. Should approach the
  file count.
- `server has duplicate` — expected to be most of them. High is good.
- `uploaded` — new content. If this is large, the export included
  more than albums and needs a second look.

### 1d. Real run

Same command without `--dry-run`. Then re-run the album inventory
from the Verification section.

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

## Phase 3 — the Amazon half: a decision, not an import

Roughly half the library (~15,600 assets, Shawna's 2011–2025) has no
album membership and no recoverable source for it. The options:

1. **Leave it timeline-only.** The strategy doc states the
   requirement directly: *"albums work for curated sets, but
   day-to-day photos really just need to land in a browsable timeline
   rather than be filed into albums one at a time."* Fifteen years of
   camera roll is the definition of day-to-day.
2. **Re-export per album from Amazon's web UI.** Recovers real album
   names, but the UI caps downloads at 200 files, the assets are
   already in Immich so the download is purely to learn membership,
   and it is a many-hour manual grind. Hard to justify.
3. **Build a few albums in Immich directly.** Date-range or
   smart-search selections for the handful of events actually worth
   curating. No import involved, and it is the only option whose cost
   scales with the number of albums that matter rather than the
   number of photos.

Recommendation: **1, with 3 for anything specific that comes up.**
Option 2 should not be started without a named list of albums worth
the effort.

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

**Albums first, stacking second.** Reasons, measured 2026-09-26:

- An album import can add assets — an export holding a downscaled or
  re-encoded copy of something already in the library has a different
  checksum and lands as a new asset, which is a new duplicate group.
  Stacking first means re-running it against a library that grew.
- `immich-go`'s stacking flags (`--manage-raw-jpeg`,
  `--manage-heic-jpeg`, `--manage-burst`) are import-time only. Any
  coupled files in the Apple export get stacked for free during
  Phase 1; hand-stacking first does that work twice.
- Album membership is the signal for choosing a stack's primary copy,
  and at 1.8% coverage it barely exists yet.
- Deferring costs almost nothing today: of 512 duplicate groups, 10
  touch an album, 2 of those differ in resolution, and exactly **one**
  album entry points at a smaller copy
  (`IMG_20250706_130219.jpg` 2048x1542 where
  `PXL_20250706_171353719.jpg` 4080x3072 exists).

Re-run **Duplicate Detection** after Phase 1 settles, before starting
the stacking pass, so its numbers reflect the post-import library.

Note for that pass, since it changes its scope: of the 512 groups,
only **64** differ in resolution — the actual stacking target, worth
60 MB. The other 448 are same-resolution duplicates, which is a
keep-or-delete decision rather than a stack.

## Open questions

1. How many albums does the Apple Photos library have, and does this
   macOS version's Export dialog offer an album-named Subfolder
   Format? Decides GUI vs `osxphotos` in 1a.
2. Are the local/network drive folder names meaningful enough to be
   albums? Decides whether Phase 2 exists.
3. Is there a named list of Amazon-era albums worth a manual re-export?
   If not, Phase 3 closes as "timeline-only, by design".
