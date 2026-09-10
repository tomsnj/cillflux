# Photo Migration — Google Takeout Stage (plan)

Stage 2 of the migration in `docs/photo-storage-strategy-research.md`.
Stage 1 (local drives) is done — see
`CLUSTER-doc-updates-2026-09-08.md`, and read its gotchas before
starting this, since two of them cost most of a session.

**Scope:** Tom's Google Photos (48.38 GB) and Shawna's (45.5 GB),
~94 GB total. Google Drive (19.58 GB) is excluded — mostly non-photo.

## Why Google before Amazon

Amazon was the original next step, but the order was flipped
deliberately on 2026-09-09:

- Immich dedups by checksum, so for any photo held in both clouds,
  **whichever source imports first wins and the second is skipped**.
- Google Takeout ships `.json` sidecars (album membership,
  descriptions, geo, people) that `immich-go` reads natively. An
  Amazon export is bare files with only embedded EXIF — Amazon has no
  Takeout equivalent, no API, and no direct service-to-service
  transfer.
- Tom's Google (48.38 GB) and Amazon (53.7 GB) figures are close
  enough that the research doc already flags them as likely the same
  camera roll twice. Importing Amazon first would permanently land
  that overlap with the poorer metadata.

Doing Google first also shrinks the Amazon stage from "export
everything through a 5 GB funnel" to a targeted delta. The genuinely
Amazon-only content is **Shawna's pre-2022 history** (her Amazon
account starts 2013, her Google starts 2022) — not the bulk of the
130 GB.

Amazon's video allowance being maxed (10.2 of 10 GB) means Amazon has
*stopped accepting* new video, not that anything is at risk — new
horse-training footage goes to Google Photos in full.

## Run the import from `gsfarmctl`, not the Mac

Decided after stage 1, where the Mac cost three separate problems that
do not exist on a Linux host on the LAN:

- macOS Local Network privacy blocks unbundled CLI binaries outright
  (see the gotcha in `CLUSTER.md`).
- Routing via Cloudflare imposes a 100 MiB request-body cap.
- The WAN hairpin caps throughput far below the 10Gb LAN.

`immich-go v0.32.0` (first release with full Immich v3 support; we run
v3.1.0) is installed at `~/.local/bin/immich-go` on `gsfarmctl`, and
connectivity to Immich is verified from there.

### DNS: `gsfarmctl` needs an `/etc/hosts` entry

`gsfarmctl` resolves via public DNS (`8.8.8.8`, `75.75.75.75`), **not**
Pi-hole, so `major.gs-farm.net` resolves to Cloudflare here (over IPv6
first) — which would send the whole import out to the WAN and back
through the proxy and its body-size cap.

Fixed with a single `/etc/hosts` line:

```
10.0.10.1	major.gs-farm.net
```

**Do not** repoint this host's resolver at Pi-hole instead. The
control host resolving through the cluster it manages is a bootstrap
trap: if Pi-hole is down, DNS breaks on the one machine needed to fix
it. `/etc/hosts` gets the internal path without that dependency.

## Requesting the exports

At `takeout.google.com`, for **each account separately**:

- Deselect all, then select **Google Photos** only.
- Format **.zip**, size **10 GB** — more files, but each is
  independently resumable if a download dies.
- Delivery by email link.

Large libraries take hours to days to prepare, and **links expire in
about 7 days**, so request both at the same time and download
promptly.

Download in a browser on the Mac (the links are session-authenticated,
so headless `curl` on `gsfarmctl` is not practical), then move them
over:

```bash
rsync -avP ~/Downloads/takeout-*.zip stecktf@10.0.100.240:~/takeout-tom/
```

`rsync`/`ssh` are Apple-signed system binaries and do not hit the
Local Network problem `immich-go` did.

**Keep each account's zips together in one directory.** Google splits
albums and JSON sidecars across archives; `immich-go` needs all parts
present at once to correlate them. Keep the two accounts in *separate*
directories and import them as separate runs.

Staging space: `gsfarmctl` has ~393 GB free on `/`; the Immich library
PVC is at 19 GB of 2.1 TB.

## The import

Dry run first, always:

```bash
immich-go upload from-google-photos \
  --server https://major.gs-farm.net \
  --api-key "$(cat ~/.immich-api-key)" \
  --no-ui --dry-run \
  ~/takeout-tom/*.zip
```

`from-google-photos` reads the zips **directly** — no need to extract
94 GB first.

Relevant defaults (all on unless noted):

| Flag | Default | Note |
|---|---|---|
| `--sync-albums` | on | recreates Google albums in Immich |
| `--people-tag` | on | imports face tags as `people/<name>` |
| `--include-partner` | on | pulls partner-shared photos |
| `--include-archived` | on | |
| `--takeout-tag` | on | tags every asset `{takeout}/takeout-<ts>` |
| `--include-trashed` | **off** | leave off |
| `--include-unmatched` | **off** | see below |

`--takeout-tag` is the one to protect: it makes an entire batch
selectable in one click if the import goes wrong. Stage 1 had no such
tag, and unpicking a bad import meant regex-matching filenames against
the database — which nearly destroyed 20 real photos (see the
case-sensitivity gotcha in `CLUSTER-doc-updates-2026-09-08.md`).

`--include-unmatched` is **off by default**, so photos with no JSON
sidecar are silently skipped. Check that count in the dry-run report
before the real run and decide deliberately — do not discover it
afterward.

## Checks after each run

Stage 1's lesson: the client's own counters were misleading in both
directions. Verify server-side.

```bash
# assets by type and status
kubectl exec -n immich deploy/immich-postgres -- \
  psql -U immich -d immich -tAc \
  "SELECT status, type, count(*) FROM asset GROUP BY 1,2 ORDER BY 1,2;"

# HTTP status distribution for the import window
kubectl logs -n network deploy/nginx-internal-controller --since=2h \
  | grep '"vhost": "major.gs-farm.net"' \
  | grep -oE '"status": [0-9]+' | awk '{print $2}' | sort | uniq -c | sort -rn
```

Also worth doing before the real run, given stage 1:

```bash
find ~/takeout-tom -type f -size 0
```

A single 0-byte input can fail many unrelated concurrent uploads by
tearing down the shared HTTP/2 connection.

## Order of operations

1. Add the `/etc/hosts` line on `gsfarmctl`.
2. Request both Takeouts.
3. Download and `rsync` Tom's archives to `~/takeout-tom/`.
4. Dry run, check the unmatched count, then real run.
5. Verify against the database.
6. Repeat for Shawna into `~/takeout-shawna/` as a separate run.
7. Only then move to the Amazon stage, scoped to the pre-2022 delta.

## Still open from stage 1

- `~/Downloads` on the Mac was never imported (hand-pick; it is a junk
  drawer containing `GitHub Desktop.app`, whose bundled PNGs a
  recursive scan would import as photos).
- Apple Photos re-import via **Photos.app → File → Export → Export
  Unmodified Originals** — never point a scanner at the
  `.photoslibrary` package.
