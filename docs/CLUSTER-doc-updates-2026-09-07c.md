# Cluster Doc Update — 2026-09-07 (late)

## Immich — self-hosted photo/video library stood up

Following the research handoff in `docs/photo-storage-strategy-
research.md` (uploaded from Claude on Tom's laptop), stood up Immich
as a new app on `cillflux`. First deployment pass — core
functionality only, SSO and content migration deliberately deferred.

### Decisions made before writing any manifests

- **Storage**: `gsks0` (shared NFS pool), not a dedicated storage
  class — at ~200GB real usage / 1TB target, no case for isolating
  Immich's I/O from the rest of the pool yet.
- **Hostname**: `major.gs-farm.net`, matching the cluster's
  established single-word-pseudonym convention (elvis/kumar/susan).
- **SSO timing**: deploy and verify core functionality first, add
  Keycloak SSO later — same order every other SSO-enabled app in
  this cluster actually followed.

### The real architecture decision: Immich's database

Immich requires Postgres with the `vectorchord`/`pgvecto.rs` vector
extension baked into the image
(`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`).
This is not pluggable into a stock Postgres, and it is **not
compatible with the cluster's existing CrunchyData PGO pattern** —
PGO's images bundle their own Patroni/pgBackRest tooling that
Immich's image doesn't have, so pointing a `PostgresCluster` CRD at
it isn't a supported combination.

Two paths were on the table: install CloudNativePG (the officially
recommended production path per Immich's own docs, using the
`tensorchord/cloudnative-vectorchord` image) or run a standalone
single-pod Postgres. Went with **standalone single pod**
(`kubernetes/apps/immich/postgres/`) — this is a single-node cluster,
so PGO's Patroni failover isn't providing real HA today either, and
adding a second Postgres operator just for one app was more
infrastructure than the "get it running first" goal called for.
Backed up via Volsync/restic instead of pgBackRest, matching the
tool already used elsewhere in this cluster for PVC-level backups.

### What was set up

- `kubernetes/apps/immich/postgres/` — standalone Postgres Deployment
  (single replica, `strategy: Recreate` since it's on an RWO PVC),
  20Gi on `gsks0`, credentials in `immich-postgres-secret` (SOPS).
- `kubernetes/apps/immich/app/` — the official `immich-charts` Helm
  chart (0.12.0 / app v2.6.3): `immich-server` +
  `immich-machine-learning` + bundled `valkey` (Redis fork) subchart.
  `immich-library` PVC (1Ti, `gsks0`) created directly, not by the
  chart — the chart's `immich.persistence.library.existingClaim`
  only ever references an existing claim, it doesn't create one.
- Both PVCs (Postgres data, photo library) back up nightly via
  Volsync/restic into the cluster's existing shared
  `volsync-backups` MinIO bucket (`immich-postgres-data` and
  `immich-library` path prefixes), reusing the same backup
  credentials every other app's Volsync secret already uses — same
  bucket, same access key, unique per-repo restic encryption
  password.
- Single hostname `major.gs-farm.net` on both internal and external
  Ingress, `nginx.ingress.kubernetes.io/proxy-body-size: "0"` for
  large photo/video uploads.

### Due diligence before touching the cluster

Pulled the real chart locally and dry-ran `helm template` against
test values before writing the final HelmRelease — confirmed:
- The bjw-s common-library env syntax for `valueFrom.secretKeyRef`
  renders correctly into real container env vars.
- Only the `server` component's templates reference
  `persistence.data.existingClaim` — `machine-learning` never mounts
  the library volume. Since `server` runs as a single-replica
  Deployment, this means the library PVC only needs `ReadWriteOnce`,
  not `ReadWriteMany` as some community guidance for older chart
  versions suggested. Saved a storage-class complication that wasn't
  actually necessary.
- Exact rendered service names/ports (`immich-server:2283`) for the
  Ingress backend, verified against the real chart output rather
  than assumed from the values.yaml comments.

### Live verification

- All four pods (`immich-server`, `immich-machine-learning`,
  `immich-postgres`, `immich-valkey`) `Running`. `immich-server`
  restarted 4 times in its first ~2 minutes while Postgres finished
  its two-phase `initdb` bootstrap (normal official-Postgres-image
  behavior) — self-healed once Postgres was fully up, zero restarts
  since.
- `/api/server/ping` returns `200`/`{"res":"pong"}` through both
  `major.gs-farm.net` on the internal ingress IP and the external
  ingress IP.
- Both `immich-internal-tls` and `immich-external-tls` certificates
  issued and `Ready: True`.
- Both Volsync `ReplicationSource`s completed an initial sync
  successfully (fast — library is still empty).
- Full `flux get kustomizations -A` swept clean after the deploy —
  no knock-on breakage.

### Not done yet

- Keycloak SSO (Immich has native OAuth support — should be a
  straightforward values addition later, same shape as
  Grafana/Forgejo, unlike Frigate).
- First-run admin account setup (first person to register at
  `major.gs-farm.net` becomes the Immich admin — nobody has logged in
  yet).
- Content migration from Google Photos/Amazon Photos, per the staged
  plan in `docs/photo-storage-strategy-research.md`.

## Update (2026-09-08) — corrected course on v3, upgraded same day

The "wait for the chart to catch up" recommendation above was wrong,
and Tom was right to push back: waiting doesn't reduce risk here, it
just lets more irreplaceable photos accumulate on the exact schema
that eventually needs a one-way migration anyway.

Checked the actual v3.0.0 migration mechanics rather than assuming:
- The postgres image already deployed
  (`ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0`)
  is literally the documented **target** image for the VectorChord
  migration, not the deprecated `pgvecto.rs`-only image. No image
  swap needed - we were already there.
- Immich's own DB-side changes run automatically on startup ("can
  take seconds to minutes to finish" per the official docs) once the
  app version itself is bumped.
- Full v3.0.0 breaking-changes list checked against our actual
  deployment: API/endpoint renames (only affect third-party
  integrations - we have none) and removed deprecated env vars we
  never set. Nothing applicable.

Upgraded to v3.1.0 (latest stable at the time - confirmed via GitHub
API, not a stale/hallucinated date from a summarized fetch) same day:
- Took a fresh manual Volsync backup of `immich-postgres-data`
  immediately before (`kubectl patch replicationsource ...
  spec.trigger.manual=...`), on top of the nightly schedule, as
  extra insurance.
- Overrode `controllers.main.containers.main.image.tag: v3.1.0`
  directly in the HelmRelease rather than waiting on a new
  `immich-charts` release - confirmed via `helm template` this
  generic bjw-s-based chart has no v2-vs-v3-specific template logic
  that would require one.
- **Caught a real bug while editing**: the new image-tag override and
  the pre-existing DB-env-vars block both used `controllers:` as a
  top-level key in the same values block. YAML allows this
  syntactically but a parser only keeps the last occurrence - the DB
  vars block (defined later in the file) would have silently
  replaced the tag override, discarding it with zero error from
  Flux/Helm/kubectl. Caught via `helm template` showing `v2.6.3`
  after the "fix" instead of `v3.1.0`. Merged into one block; added
  to `CLUSTER.md`'s gotchas list.
- Verified live: `/api/server/version` → `{"major":3,"minor":1,
  "patch":0}`, clean startup logs (`Immich Server is listening...
  [v3.1.0]`, `Adding 3.1.0 to upgrade history`), zero errors, zero
  new pod restarts since. Full `flux get kustomizations -A` swept
  clean afterward.

Commit `e26a98f3`.

## Update (2026-09-08, later) — Keycloak SSO + a second incident

### Immich Keycloak SSO

Enabled using Immich's native OAuth support - no CLI/proxy needed,
unlike Forgejo/Frigate:
- New `immich` Keycloak realm + confidential client, redirect URIs
  per Immich's own OAuth docs (`/auth/login`, `/user-settings`, and
  the mobile `app.immich:///oauth-callback`).
- Config delivered via a new SOPS-encrypted Secret
  (`kubernetes/apps/immich/app/oauth-config.sops.yaml`) holding a
  full `immich-config.yaml` oauth block, wired in via
  `immich.existingConfiguration` + `configurationKind: Secret` -
  kept out of `helmrelease.yaml` itself since that file isn't
  SOPS-encrypted and this embeds the client secret.
- Verified via `helm template` before applying (volume mount, secret
  name, `IMMICH_CONFIG_FILE` env var), then live via
  `/api/oauth/authorize` returning a correctly-formed Keycloak
  authorization URL and the server's own feature-flags log showing
  `"oauth": true, "configFile": true`.
- Created the `stecktf` Keycloak user up front with a temp password,
  same as every other realm - avoiding the empty-new-realm gotcha.
- **Confirmed after Tom's first login** (queried the `user` table
  directly rather than assume): it linked to the existing local
  admin account by email - same row, same original `createdAt`,
  `oauthId` now populated with the Keycloak user id. No duplicate
  account. Same behavior as Forgejo turned out to be, this time
  verified via the database instead of guessed.

### Second incident: major.gs-farm.net unreachable externally

Tom reported it right after setup - off the LAN, `major.gs-farm.net`
just didn't load at all.

Root cause: the external Ingress was missing the
`external-dns.alpha.kubernetes.io/target: external.gs-farm.net`
annotation that Keycloak's own external ingress has always had.
Without it, `external-dns` defaulted to creating a plain A record
pointing at nginx-external's private LAN IP (`10.0.10.2`) -
Cloudflare rejects this outright for a proxied record
(`code: 9003, "Target ... is not allowed for a proxied record"`),
and `external-dns` had been silently retrying the same failing
create every 60 seconds for roughly 13 hours since the Ingress was
first created (793+ consecutive soft errors in its logs) - `
major.gs-farm.net` never had a public DNS record at all.

Confirmed the correct pattern by querying the Cloudflare API
directly (using `external-dns`'s own token from a throwaway debug
pod) for `susan.gs-farm.net`'s actual live record: a CNAME to
`external.gs-farm.net`, not an A record - matching Keycloak's
existing annotation, not what a from-scratch Ingress gets by
default.

Fixed by adding the same annotation to Immich's external ingress;
`external-dns` created the correct CNAME within a minute. Verified
externally: `curl https://major.gs-farm.net/api/server/ping` → `200`,
resolved via real public DNS (matching Cloudflare's edge IPs, same
as every other app), no `--resolve` override needed.

**Found in the process**: Forgejo's external ingress is *also*
missing this annotation. It currently works only because its DNS
record predates whatever changed to make this matter (created
2026-06-03) - not because its own Ingress config is self-sufficient.
It's one deleted/recreated DNS record away from failing exactly the
way Immich just did. Flagged in `CLUSTER.md`'s On the Horizon list,
not fixed yet since nothing is currently broken.

Commits `e8a73fed` (SSO), `897c6e20` (DNS fix).
