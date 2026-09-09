# Cluster Doc Update — 2026-09-08 (evening)

## Immich — first content batch uploaded from the MacBook

First real content into Immich, per the staged plan in
`docs/photo-storage-strategy-research.md` (local drives first, Google
Takeout later). Source: `~/Pictures` on Tom's MacBook Pro, via
`immich-go` from the Mac. Ended up taking four runs and turning up two
non-obvious failure modes plus one self-inflicted data-quality
problem, all worth recording.

**Final state: 359 active assets (347 images, 12 videos).**

### Failure 1: `immich-go` could not connect at all — macOS Local Network privacy

Initial symptom: `immich-go` failed 100% of the time against
`https://major.gs-farm.net` with **zero packets leaving the machine**,
while `curl` to the identical URL succeeded 100% of the time from the
same shell. A kernel-level error appeared in Console.app. Ruled out,
each with evidence: DNS, VPN, proxy, third-party firewall,
MDM/content-filter profiles, stale ARP, wrong interface, code signing,
shell quoting, and the exact fix that resolved an identical-looking
GitHub issue.

Root cause: Pi-hole's `address=/gs-farm.net/10.0.10.1` means that on
the LAN, `major.gs-farm.net` resolves to a **private** address
(nginx-internal). macOS Sequoia's Local Network privacy blocks
unapproved local-subnet connections **in the kernel, before any packet
is emitted** — which is exactly "zero packets, kernel error, works in
curl."

The part that makes this hard to diagnose:

- `curl` works because **Terminal.app** holds the Local Network grant.
  A bare Mach-O executable launched from that same shell does **not**
  inherit it — it is attributed its own TCC identity.
- Because `immich-go` is a standalone binary with no bundle
  identifier, macOS has nothing to register, so it **silently denies
  and never appears** in System Settings → Privacy & Security → Local
  Network. There is no toggle to flip. An empty list is the bug, not
  evidence against the theory.
- Quarantine was **not** involved — the binary had no
  `com.apple.quarantine` xattr (only `com.apple.macl` /
  `com.apple.provenance`). Running from `~/Downloads` was innocent.

Confirmed both directions by pinning `major.gs-farm.net` to a
Cloudflare edge IP (`104.21.33.78`, from `dig +short @1.1.1.1`) in
`/etc/hosts`: same binary, same hostname, same TLS, only the
destination changed from private to public — and it worked
immediately.

This generalizes the existing browser-focused gotcha in `CLAUDE.md`:
it applies to **any** unbundled CLI binary, not just browsers, and
`curl` succeeding proves nothing about whether another tool will.

Workaround used for this batch; **not** the answer for Google Takeout
— see below.

### Failure 2: one 0-byte file killed nine uploads (HTTP/2 connection teardown)

Run 1 uploaded 799 assets, then reported 10 errors and left 35 files
Pending. Run 2 uploaded nothing new, reported 9 errors and 30 Pending,
and failed within seconds — deterministic, same files every time.

The client's own counters were misleading in both directions, and the
diagnosis only came from correlating them against nginx access logs:

- `immich-go` reported 9-10 errors; nginx logged exactly **2**
  `400`s per run on `POST /api/assets`, both with
  `request_length: ~1700` bytes. A multi-MB upload cannot be 1.7KB —
  those requests carried no file content.
- Exactly **two** files in `~/Pictures/pics` were 0 bytes
  (`WIN_20181227_10_02_07_Pro.mp4`, `WIN_20190117_17_35_10_Pro.mp4`).
- In the `immich-go` log, only one error line carried a status code
  (`400 Bad Request`). The other seven had **no status at all** — no
  HTTP response ever came back. Those seven were healthy files
  (66KB-6.8MB).

Mechanism: `immich-go` uploads concurrently, multiplexed over a single
HTTP/2 connection (nginx logs confirm `HTTP/2.0`). Immich correctly
rejects the empty POST with a `400`; that error tears down the shared
connection, killing every other upload **in flight on it** with no
response, and the queue then aborts — which is why the remaining 30
never got attempted and never appeared in any server log.

Fix: move the two 0-byte files aside. Run 3 then completed with
**0 errors, 0 pending**.

Worth remembering generally: **a single corrupt input can fail a large
number of unrelated concurrent uploads**, and the tool's error count
will understate the cause and overstate the damage.

### Cloudflare body-size ceiling (relevant only while using the /etc/hosts workaround)

With `/etc/hosts` pointing at Cloudflare, uploads hairpin out to the
WAN and back through Cloudflare's proxy, which caps request bodies
regardless of our `nginx.ingress.kubernetes.io/proxy-body-size: "0"`.

Observed: `WIN_20190427_14_58_02_Pro.mp4` at **103,325,180 bytes
(98.5 MiB / 103.3 MB) uploaded successfully**, so the limit is 100
**MiB**, not decimal 100 MB. `WIN_20190505_07_44_26_Pro.mp4` (114 MB)
was set aside untested and still needs the LAN/browser path.

None of this applies over the internal ingress — it is purely an
artifact of the Cloudflare workaround.

### Self-inflicted: `immich-go` walked into the macOS Photos library package

Runs 1-2 targeted all of `~/Pictures`, which contains
`Photos Library.photoslibrary` — an **opaque bundle**, not a photo
directory. `immich-go` scanned 5,287 paths inside it and ingested 477
assets:

- **293 Photos derivatives** (`…_1_105_c.jpeg`, `…_4_5005_c.jpeg`) —
  Photos' own downscaled renders. Different checksums and dimensions
  from their originals, so Immich's dedup can **never** catch them:
  the same photo appears twice in the timeline at two resolutions.
- **184 UUID-named originals** with no album membership, no edits, no
  curated Photos metadata.

Deleted all 477 via the Immich API (to trash, recoverable 30 days) —
Tom's call, to be redone properly later. Left the 359 clean assets.
Logged in `CLUSTER.md`'s On the Horizon list: redo via **Photos.app →
File → Export → Export Unmodified Originals** into a staging folder,
then point `immich-go` at that folder.

Two bugs caught in the cleanup script before it ran, both worth noting:

- **Case-sensitivity near-miss.** The first version used `jq`'s `"i"`
  regex flag and matched **500** assets, not the 477 counted in
  Postgres (which uses case-sensitive `~`). The extra 23 included
  **20 legitimate photos** — `WIN_20190119_08_53_15_Pro.jpg` matches
  `_[0-9]+_[0-9]+_[a-z]+\.jpg` case-insensitively because `Pro`
  satisfies `[a-z]+`. Reconciling the count against the database
  before applying is what caught it. **Always make the dry-run count
  match an independently-derived number exactly** — "close enough"
  would have destroyed real photos.
- **SIGPIPE abort.** `jq … | head -5` under `set -euo pipefail` exits
  **141** when `head` closes the pipe, silently aborting the script
  before the delete block. The first "successful" `--apply` run
  deleted nothing; only checking the database revealed it. Append
  `|| true` to any `… | head` in a `pipefail` script.

Deletion verified against the database, not the API response: 477
`trashed`, 359 `active`, **0** remaining assets matching the Photos
patterns, and all **33** `WIN_*` photos still active.

### Recommendation for the Google Takeout stage

Do **not** repeat the Mac-side approach. Download Takeout archives
directly to `gsfarmctl` or TrueNAS and run `immich-go` there, over the
LAN to `10.0.10.1`. That removes macOS Local Network privacy, the
Cloudflare proxy and its body-size cap, and the WAN hairpin from the
path entirely — all three of which cost time on this batch and none of
which exist on a Linux host on the LAN.

### Still outstanding from this batch

- `WIN_20190505_07_44_26_Pro.mp4` (114 MB) in `~/immich-oversize` —
  needs the LAN/browser upload path.
- `~/Downloads` was never imported. It is a junk drawer (contains
  `GitHub Desktop.app`, whose `Contents/Resources/*.png` a recursive
  scan would happily import as photos) — hand-pick rather than
  blanket-scan.
- Two 0-byte `WIN_*.mp4` files in `~/immich-broken` — no content to
  recover; check whether originals survive wherever they were copied
  from.
