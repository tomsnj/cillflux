# Cluster Doc Update — 2026-09-27

Immich day. Four things, and the last two only surfaced because the
first two were being chased: a display name, partner-sharing
visibility, an album rename that would not take, and — behind it — a
server that had been quietly unpatched for seven weeks.

## `immadmin` is now `Tom Steck`

Cosmetic, but worth recording *why it sticks*. Every account here logs
in through Keycloak, so the obvious worry was that the next SSO login
would overwrite the name from the OIDC profile.

It will not. From the OAuth callback in the running image
(`server/dist/services/auth.service.js`), the profile is read into
the user record **only at creation**:

```js
user = await this.createUser({
  name: profile.name || `${given_name} ${family_name}`.trim()
        || profile.preferred_username || normalizedEmail,
  ...
});
```

On every later login the only fields written are `oauthId` and, from
`roleClaim`, `isAdmin`. `storageLabelClaim` and `storageQuotaClaim` are
likewise creation-only — so the `preferred_username` → storage label
mapping in the OAuth config does not re-assert itself either.

Not to be confused with the **storage label**, still `admin`. That is a
different field, and moot here regardless: the storage template is
disabled, so originals land at `/data/upload/<ownerId>/xx/yy/<uuid>.ext`
and the label affects nothing on disk.

## Where a partner's photos actually appear

Shawna asked, in effect, why she has to navigate to a separate place to
see anything. The partner table explains it:

```
shared_by      shared_with     inTimeline
immadmin    →  Shawna Gilroy       f
immadmin    →  Calvin Steck        f
immadmin    →  Maxwell Steck       f
Shawna      →  immadmin            f
```

With `inTimeline = false` a partner's library is reachable only through
Sharing → Partners, never merged into your own timeline. Nothing is
broken; nothing has been turned on.

The toggle is **not** on the Sharing page in the sidebar, which is why
it could not be found from either the phone or the browser. It lives at
`/user-settings` — Account Settings → **Sharing** accordion → **Partner
Sharing** → *Show in timeline* ("Show photos and videos from this user
in your timeline"). Confirmed by pulling the strings and the component
out of the served bundle rather than guessing at menu names.

It is also conditionally rendered, which makes it look missing even on
the right page. From `nodes/39` (the user-settings route):

```js
N(O, e => { n(r).sharedWithMe && e(j) })
```

The toggle draws only for partners who share **with you** — not for
people you share **to**. So Tom's panel lists three partner cards and
only Shawna's carries the toggle. `inTimeline` is a column on the
recipient's `partner` row, so each person sets their own; an admin API
key cannot flip it on someone else's behalf.

Worth stating plainly because it came up: Immich never merges
libraries. A phone backs up to whichever account it is signed in as,
the assets are owned by that user, and they count against that user's
quota. Partner sharing changes visibility, not ownership.

## The album rename that returned 400

Renaming an album from the Android app failed twice, a night apart,
with only "unable to change the title".

The Immich server log said nothing at the default `log` level. The
ingress access log did:

```
11:14:29  PATCH  400  /api/albums/ff7eb18a-...   immich-android/3.2.1
```

Two false starts are worth recording, because both look like "the
request was never sent":

- The phones reach Immich through the **external** ingress (Cloudflare
  tunnel); browsers on the LAN use the internal one. Grepping
  `nginx-internal` alone finds nothing.
- The access log is JSON with separate `method` and `path` fields, so
  `grep '"PATCH /api/albums'` matches nothing either.

Counting the `http_user_agent` field across 24h gave the real shape of
the problem: **3,588 requests from `immich-android/3.2.1`** — every
phone in the house — against a server on v3.1.0.

The cause is a schema change in v3.2.0, `server/src/dtos/album.dto.ts`:

```js
// v3.1.0
description: z.string().optional()

// v3.2.2
// TODO: drop the empty-string-to-null transform in v4 (clients should send null)
description: z.string().nullable().transform(v => v === '' ? null : v).optional()
```

The 3.2.1 client follows the new contract and sends `null`. The v3.1.0
server rejects it. Reproduced exactly:

```
{"albumName":"Lake Ozark 2025","description":null}  → 400
   "Invalid input: expected string, received null"   path: ["description"]
{"albumName":"Lake Ozark 2025","description":""}    → 200
```

Ruling out the obvious wrong theory first: `PUT /api/albums/:id` *is*
gone in v3 (404), which looks like the same story, but the app was
correctly using `PATCH`. Unknown fields are stripped rather than
rejected, so the failure had to be a *value* on a known field — which
is what pointed at the nulls.

## Immich v3.1.0 → v3.2.2

Fixing the rename properly meant fixing the skew. Immich does not
support a split client/server pair, and the rename was simply the first
place it showed.

Checked before touching anything:

- `VECTORCHORD_VERSION_RANGE` and `VECTOR_VERSION_RANGE` are
  **identical** in both releases, so the Postgres image stays as-is.
  This is the check that mattered — the v3.0.0 pgvecto.rs → VectorChord
  step was one-way, and it would have been easy to assume another one.
- Release notes for v3.2.0/.1/.2 name no breaking change and no manual
  migration step.
- 8 new migrations. Two touch data, and both were measured against the
  live database first: `AlbumDescriptionNullable` (31 empty-string
  descriptions → NULL — and it has a real `down()`) and
  `DeleteMismatchedMemoryAssets` (**0 rows** here, no cross-owner memory
  entries exist). `AssetOcrSyncReset` reads alarmingly but only deletes
  a sync checkpoint so clients backfill; it does not re-OCR anything.

A fresh logical dump was taken immediately before
(`/dumps/immich-20260927-1204.dump`, 191 MiB), on top of the 03:00
Volsync snapshots.

Per the standing gotcha, the values change was verified by rendering
both versions rather than by `flux diff`:

```
helm template ... -f values-old.yaml  vs  -f values.yaml
→ 4 differing lines: the two image tags, nothing else
```

Result: both images on v3.2.2, all 8 migrations succeeded, `Immich
Server is listening ... [v3.2.2]`, 31 album descriptions now NULL and 0
empty, queues idle with failure counts unchanged at the 7/3/2/2/5
baseline, 0 unready pods cluster-wide. The original payload now returns
200.

## Renovate had never seen this image

The real question is not why the server was on v3.1.0 but why nothing
said so for seven weeks while v3.2.0, v3.2.1 and v3.2.2 shipped.

Renovate's `helm-values` manager builds a dependency name from a
`repository` + `tag` pair. This HelmRelease overrides only the tag —
the repository comes from the chart default — so there was nothing to
match, no PR was ever opened, and no check anywhere reports "this image
is untracked". `gh pr list` showed no Immich PR because none had ever
existed.

The house style elsewhere (Vaultwarden, Frigate) is an explicit
`repository:` + `tag:` pair, and it cannot be used here.
`controllers.main.containers.main` is shared: the chart hands it to
both the server and machine-learning sub-charts, which is deliberate —
they release in lockstep. A `repository:` at that level would drag
machine-learning onto the server image.

So tracking goes through the regex customManager in
`.github/renovate.json5`:

```yaml
              # renovate: datasource=docker depName=ghcr.io/immich-app/immich-server
              tag: "v3.2.2"
```

**The quotes are load-bearing.** That manager's matchString captures
`"(?<currentValue>.*)"`. Both spellings were tested against the actual
regex before committing:

```
quoted    -> {'depName': 'ghcr.io/immich-app/immich-server', 'currentValue': 'v3.2.2'}
unquoted  -> NO MATCH
```

An unquoted tag with a `# renovate:` comment above it looks tracked, is
not, and would have reproduced the whole seven-week silence with a
comment on top claiming otherwise. The reasoning is recorded in the
HelmRelease itself so nobody tidies the quotes away.

This is a class of blind spot, not a one-off. Worth a sweep of running
images against what Renovate has ever proposed:

```bash
kubectl get deploy -A -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' | sort -u
```

## Lake Ozark: two albums, one trip, and five strays

Spotted while renaming. The two albums were not overlapping variants —
`Lake Ozark July 25` was a **strict subset** of the 47-asset album:

```
Lake Ozark July 25   42 assets   2025-07-04 → 2025-07-07
Lake Ozark 2025      47 assets   2025-05-17 → 2025-07-07
overlap 42, to add 5 — all VIDEO, all 2025-05-17
```

So "combine" meant exactly five May videos moving into a July-named
album. Flagged before acting rather than after; Tom had already noticed
at least one asset that belongs to neither July nor Lake Ozark and will
move those out separately.

Merged into `Lake Ozark July 25` (47 assets, all still live — deleting
an album never touches assets) and the source album deleted. Albums
32 → 31. Pre-merge membership of both albums, enough to recreate
either, is at `docs/restore/2026-09-27-lake-ozark-merge.json`.

## Suggested `CLUSTER.md` edits

Two Known Gotchas entries were added to `CLAUDE.md` rather than here,
since both are things a future session needs *before* it starts
debugging: the auto-updating-client skew, and the untracked-image
blind spot.

For `CLUSTER.md` itself, the line that needs amending is the
2026-09-08 entry at line 169, "Upgraded to Immich v3.1.0 the same
day" — it should gain a sentence noting the 2026-09-27 move to v3.2.2,
that the Postgres image again needed no change (both version ranges
identical), and that the image is now tracked by Renovate via the
customManager comment.

Also worth reflecting in the Immich rows of *Current State & Open
Issues*: album count is back to **31** after the Lake Ozark merge.

Two observations there are qualified "in v3.1.0" (lines 438 and 453 —
the album asset routes, and ownership living in `album_user` rather
than an `ownerId` column). Both were re-checked against v3.2.2 after
the upgrade and **still hold unchanged**, so they need no correction;
only the version qualifier now reads narrower than the truth.
