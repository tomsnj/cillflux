# Photo & Video Storage Strategy — Research Notes

*Compiled September 2026*

## The situation

Photos and videos are currently spread across a local drive, network drives, Google Photos, Google Drive, and Amazon Photos. Google Drive works for sharing with family but costs money on an ongoing basis. Amazon Prime's photo storage is unlimited for photos but caps video at 5 GB, which is a real problem given the volume of horse-training video footage. Organization is also a pain point: albums work for curated sets, but day-to-day photos really just need to land in a browsable timeline rather than be filed into albums one at a time.

Given the existing Kubernetes homelab (the `cillflux` cluster, Talos + Flux GitOps, NFS-backed storage class `gsks0`, and an existing pattern of exposing internal apps externally on `gs-farm.net` with separate internal/external nginx ingress controllers), self-hosting is a genuinely practical option here, not just a theoretical one — the hardest parts (reverse proxy, TLS, external access, GitOps deployment) are already solved problems in this environment.

## The three shapes of solution

**Cloud all-in-one services** (Google One/Photos, iCloud, Amazon Photos, SmugMug, Flickr) are the least effort but charge recurring fees that scale with video volume, and none of them elegantly unify photos that are already scattered across multiple accounts — each is its own silo.

**Cloud backup-only services** (Backblaze Personal Backup) are cheap for pure backup but aren't built for browsing or sharing — they're insurance, not a family photo experience.

**Self-hosted photo management** (Immich, PhotoPrism, Nextcloud Memories) puts one system in front of everything, with no per-GB subscription — the only ongoing cost is disk and power, which is already sunk cost in the homelab.

## Self-hosted option: Immich (recommended)

Immich has emerged as the clear leader in this space in 2026 — effectively a self-hosted Google Photos replacement, and it's a strong match for the stated requirements:

- **Timeline-first, with albums as a separate layer.** The default view is a chronological timeline of everything, exactly matching the "everyday photos just need to fit into a timeline" requirement. Albums exist alongside it for curated collections (a horse show, a vacation) without forcing everything into one or the other.
- **No artificial caps on video.** Unlike Amazon Prime's 5 GB video ceiling, storage is just whatever disk is behind it — a good fit for large horse-training video files. Hardware transcoding (Intel Quick Sync or an Nvidia GPU) can be configured if transcoding a lot of video becomes CPU-bound, though this is only needed at meaningful scale.
- **Runs well on Kubernetes.** It deploys as a set of containers (server, ML service, Postgres with pgvector, Redis) and works fine against NFS-backed storage — directly compatible with the existing `gsks0` storage class. There's an existing pattern in the cluster (Crunchy Postgres/PGO, bjw-s app-template) that maps cleanly onto how people typically deploy Immich via Helm/Flux.
- **Sharing has three tiers**, which map well onto a mixed technical household:
  - *Partner sharing* — a spouse's library merges automatically into a shared view. Best fit for a spouse who'll be actively adding photos/videos (e.g., horse-training clips).
  - *Shared albums* — invite specific Immich accounts to view or contribute to a specific album.
  - *Public share links* — a URL (optionally password-protected, with an expiration date) that lets anyone view or even upload photos without ever creating an Immich account or installing the app. This is the best option for less-technical extended family — no app, no login, just a link.
- **The catch:** by default, the mobile app only auto-uploads new photos while on the home Wi-Fi network, and shared albums need the server to be reachable from the internet for remote family to view them. Both are non-issues here specifically because external ingress with a real domain (`gs-farm.net`) is already running for other apps — exposing Immich externally is the same pattern already in use, not new work.
- **Migration in:** existing photos come in from Google Photos via Google Takeout exports and from Amazon Photos via its own export/download tool, then get bulk-imported (tools like `immich-go` handle Google Takeout's metadata/album structure reasonably well). Local and network-drive photos import directly. Immich also does duplicate detection, which will matter given how scattered things currently are.

**Alternatives considered:** PhotoPrism is lighter-weight and has strong AI tagging, but its sharing/collaboration features and mobile app are less mature than Immich's. Nextcloud Memories is a solid choice if Nextcloud is already in use as a general file-sync/Drive replacement, and it inherits Nextcloud's excellent multi-user sharing — worth a look if replacing Google Drive itself (not just Photos) is also on the table, since Nextcloud + Memories would cover both jobs at once.

## Cloud pricing, for comparison

| Service | Plan | Price | Notes |
|---|---|---|---|
| Google One | 2 TB | $9.99/mo ($99.99/yr) | Shareable with up to 5 others; storage pooled but files stay private |
| Google One | 200 GB | $2.99/mo ($29.99/yr) | |
| Amazon Photos | Prime included | Free (photos) | Unlimited full-res photos; only 5 GB for video |
| Amazon Photos | +1 TB add-on | $6.99/mo | For video beyond the 5 GB Prime allowance |
| Amazon Photos | +2 TB add-on | $11.99/mo | |
| Backblaze Personal Backup | Unlimited, per computer | ~$99/yr | Backup only — not browsable/shareable, and only covers computers it's installed on (not phones or NAS) |
| Backblaze B2 | Pay-as-you-go object storage | ~$6.95/TB/mo | Useful as an off-site backup target for a self-hosted setup (e.g., backing up Immich's library), not as the primary system |

Self-hosting on the existing cluster avoids all of these recurring costs; the only new spend would be additional disk capacity if the current NFS-backed pool doesn't have enough headroom for the full photo/video library plus growth.

## Suggested path forward

1. ~~**Size the storage need first**~~ — done; see "Storage sizing" below.
2. **Stand up Immich on `cillflux`** via Flux/Helm, backed by `gsks0` (or a dedicated storage class if the video volume argues for separating photo storage from the rest of the cluster's NFS pool). *(Continuing in Claude Code on `gsfarmctl` from here — this doc is the handoff reference.)*
3. **Expose it externally** on `gs-farm.net` using the existing internal/external ingress pattern, so shared links work for family without extra explanation.
4. **Migrate content in stages**: local/network drives first (lowest risk, no export step), then Google Takeout, then Amazon Photos export — checking Immich's duplicate detection after each batch.
5. **Set up partner sharing** for your wife so her horse-training footage merges straight into the shared library, and set up a small number of public share links or invited accounts for the family members who currently rely on Google Drive.
6. **Decide what happens to Google Drive/Photos and Amazon Photos afterward** — likely downgrade or cancel once migration is verified, keeping one of them (or Backblaze B2) purely as an off-site backup target for the Immich library rather than as a second live copy people access directly.

## Mobile capture workflow (Pixel 9 / Pixel 8 Pro)

Immich's mobile app does auto-backup, the same basic shape as Google Photos: it uploads new shots both when the app is opened (foreground) and periodically in the background without needing to be opened. By default background uploads are Wi-Fi-only, which is worth deciding on deliberately given the horse-training video files — Wi-Fi-only means a big video shot at the barn just queues and waits for the phone to be back on home Wi-Fi rather than eating mobile data, but it also means it isn't backed up right away; the app can be switched to allow cellular for uploads if same-day backup matters more than data usage.

The one real difference from Google Photos, and the thing to set up once and mostly forget: Android's battery optimization can quietly stop background workers on some phones, so Immich's background backup is less "bulletproof" out of the box than Google's own first-party app. Pixels run close to stock Android, which is one of the better-behaved cases, but it's still worth doing for both phones: in Settings → Apps → Immich → Battery, set battery usage to Unrestricted (not just "optimized"), and make sure background data and autostart-equivalent permissions are allowed. With that set, the two of you shouldn't need to think about it day to day.

So the normal process becomes: shoot photos and video as usual, Immich backs them up automatically in the background (or as soon as the app is next opened), and if it's clear a big set of horse-training clips got shot away from home Wi-Fi, opening the app once back on the home network gives a visual confirmation the queue has drained before deleting anything off the phone. Partner sharing means your wife's shots merge straight into the same shared library rather than needing a separate step — functionally the same as how Google Photos partner sharing works today, just pointed at your own server instead of Google's.

## Storage sizing (September 2026)

Sized by checking each account's own storage dashboard (Google One's per-category breakdown, Amazon Photos' storage page) and by running a small custom scan script (`photo_scan.sh` for macOS/Linux, `photo_scan.ps1` for Windows — both walk a folder tree and total up file count/size by Images, RAW, and Videos) against local folders on both your Mac and Shawna's Windows laptop.

**Current usage by source:**

| Who | Source | Amount | Note |
|---|---|---|---|
| Tom | Google Photos | 48.38 GB | |
| Tom | Amazon Photos (own share) | 53.7 GB | Family Vault splits "my photos" from "family"; this is Tom's own unique share |
| Tom | Local (Mac: Pictures + Downloads) | 1.2 GB | No RAW files present locally — RAW lives on-phone/in-cloud only |
| Tom | Google Drive | 19.58 GB | Mostly non-photo files; not counted toward the photo/video total |
| Shawna | Google Photos | 45.5 GB | Account history starts 2022 |
| Shawna | Amazon Photos (own share) | 75.9 GB | Account history starts 2013 (handful from 2007) |
| Shawna | Laptop (OneDrive-synced Pictures/Documents/Desktop/Downloads) | ~89 GB | 98% of this is two old full phone camera-roll dumps (`DCIM\Camera`, dated ~Aug 2021) manually copied to the laptop; matches her ~95 GB OneDrive usage almost exactly, confirming it's the same data, not additional |
| Shared | Amazon video allowance | 10.2 of 10 GB (maxed) | Amazon has stopped receiving new horse-training video; Google Photos is getting it in full instead, so this isn't a real gap |

Naive sum across everything: ~324 GB. That overstates it — there's real, confirmed overlap (Tom's Google/Amazon figures are close, suggesting the same camera roll backed up twice; Shawna's laptop dump likely overlaps with the older end of her Amazon library). **Realistic unique total: roughly 180–230 GB**, with the exact figure only resolvable once Immich's own duplicate detection runs during migration.

**Growth rate:** Shawna's Google Photos (45.5 GB over ~4 years) works out to roughly 11–12 GB/year recently, and the true recent rate is likely at or above that — older years in both accounts contain much smaller file sizes than current phone photos/video, so the trend is accelerating, not flat. Horse-training video is phone-shot only (no separate camera/GoPro in the mix), so it's already fully reflected in these numbers rather than being a hidden additional category.

**Recommendation:** provision the initial Immich storage volume at **1 TB**, not at the current ~200 GB — it comfortably covers today's library with 4–5x headroom and multiple years of runway at the current growth rate, and the drive cost is trivial next to what Google + Amazon cost annually. Expanding an NFS/storage pool later is more disruptive than starting generous.

Sources: [Immich Sharing docs](https://docs.immich.app/features/sharing/), [Immich Partner Sharing docs](https://docs.immich.app/features/partner-sharing/), [Immich family sharing setup guide](https://famstack.dev/guides/immich-family-sharing-setup/), [Immich hardware transcoding docs](https://docs.immich.app/features/hardware-transcoding/), [Immich Mobile Backup docs](https://docs.immich.app/features/mobile-backup/), [Google One pricing overview](https://www.androidheadlines.com/google-one), [Google One pricing (Internxt)](https://blog.internxt.com/google-one-pricing/), [Amazon Photos 2026 review](https://tecnoyfoto.com/en/amazon-photos-review-2026), [Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing), [Backblaze Personal Backup pricing (StackScored)](https://www.stackscored.com/pricing/backup-tools/backblaze/), [Immich vs PhotoPrism vs Nextcloud Photos comparison](https://selfhostr.com/comparatifs/immich-vs-photoprism-vs-nextcloud-photos-2026/).
