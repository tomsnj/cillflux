# gs-farm.net Cluster Documentation

> **Last updated**: 2026-09-06  
> **Purpose**: Living reference for the Talos Linux Kubernetes homelab. Upload to this Claude Project to give Claude full cluster context in every chat.

---

## Overview

Single-node Talos Linux Kubernetes cluster managed via GitOps (Flux CD). Migrated from a previous ESXi-based environment. The cluster serves home automation, observability, security cameras, password management, and SSO.

- **GitOps repo**: `cillflux` — [github.com/tomsnj/cillflux](https://github.com/tomsnj/cillflux)
- **Pattern**: [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template)
- **Domain**: `gs-farm.net`

---

## Infrastructure

### Machines

| Hostname     | Role            | IP              | OS / Notes                          |
|--------------|-----------------|-----------------|-------------------------------------|
| `gsfarmctl`  | Control machine | `10.0.100.240`  | Debian 12, username `stecktf`       |
| Talos node   | K8s node        | `10.0.10.10`    | Talos Linux (single-node cluster)   |
| TrueNAS      | NAS / storage   | `10.10.10.110`  | Bare metal (Gigabyte X470), migrated from ESXi VM |

### Talos Image

- **Schematic ID**: `a54d7711b11ec03d0a2df42d4575584982459af1bcb6f8024ba8e0eaec4d07ea`
- **Extensions**: `nfs-utils`, `iscsi-tools`, `util-linux-tools`, `amd-ucode`

### Tool Versions

| Tool         | Version  |
|--------------|----------|
| `talosctl`   | v1.12.6  |
| `kubectl`    | v1.35.3  |
| `flux`       | v2.8.3   |
| Cilium CNI   | 1.19.2   |

---

## Networking

### LoadBalancer IPs

| IP           | Service              |
|--------------|----------------------|
| `10.0.10.1`  | `nginx-internal` ingress controller |
| `10.0.10.2`  | `nginx-external` ingress controller |
| `10.0.10.4`  | `k8s-gateway`        |

### DNS

- **Pi-hole**: Split-horizon DNS; `*.gs-farm.net` → `10.0.10.1`
- **Cloudflare tunnel**: External access
- **k8s-gateway**: Evaluated as longer-term alternative to per-host Pi-hole overrides

### Access Pattern

Services needing internal LAN access require **both** an `external` and `internal` class Ingress.

---

## Storage

### NFS (TrueNAS)

| StorageClass | Access Mode | Notes              |
|--------------|-------------|---------------------|
| `gsks0`      | RWO         | NFS-backed          |
| `gsks1`      | RWX         | NFS-backed          |

- Talos requires `nolock` NFS mount option (no `rpc.statd`)
- Requires `nfs-utils` Talos extension

### Object Storage

- **MinIO**: S3-compatible, in-cluster
- **pgBackRest**: PostgreSQL WAL archiving → MinIO

---

## Core Services

| Service           | Notes                                                       |
|-------------------|-------------------------------------------------------------|
| CrunchyData PGO   | PostgreSQL operator                                         |
| Keycloak          | Deployed and healthy (26.7.3); SSO live for Vaultwarden (2026-09-06), Grafana (2026-09-07), Forgejo (2026-09-07), see below |
| Vaultwarden       | Password manager — Keycloak SSO enabled (`vaultwarden` realm), local email/password login still available as fallback (`SSO_ONLY` not set) |
| Grafana           | Observability dashboards                                    |
| Prometheus        | Metrics                                                     |
| Loki              | Logs                                                        |
| Alloy             | Log/metric agent                                            |
| Pi-hole           | DNS                                                         |
| MinIO             | S3 object storage                                           |
| Kerberos agents   | Security cameras — file-based on `gsks1`, no MongoDB/RabbitMQ dependency |
| Cilium            | CNI                                                         |
| Immich            | Self-hosted photo/video library (`major.gs-farm.net`), live since 2026-09-07. Standalone Postgres (not PGO), see below |

---

## Secrets & Encryption

- **Method**: SOPS with age encryption
- **Age public key**: `age1puse8jhtwqw87w9qr9j4g8dajqccn0899vpyc0wnn9y2e6wz0cms2g895x`
- **Age private key**: `~/cillflux/age.key` on `gsfarmctl` — **not in git**
- **Flux decryption**: `flux-system` kustomization in `gotk-sync.yaml` must include a `decryption` block (`provider: sops`, `secretRef: name: sops-age`); without it, Flux overwrites decrypted secrets with raw ciphertext on every reconcile

---

## Current State & Open Issues

### ✅ Recently Completed

- ESXi → Talos migration largely complete
- Most HelmReleases reconciling successfully
- Cleaned up unused releases: `echo-server`, `hajimari`, `mongodb`, `rabbitmq`, `vernemq`
- Forgejo upgraded chart `9.0.0` → `17.1.5` (app `8.0.3` → `15.0.7`),
  2026-09-07 — see `CLUSTER-doc-updates-2026-09-07.md`. Fixed a
  live `passwordMode: keepUpdated` risk along the way (chart default
  since day one, would silently reset the admin password to
  `forgejo-admin-secret`'s value on any pod restart) and retired a
  dead duplicate Ingress the chart was generating.
- Forgejo internal/external hostnames unified on `susan.gs-farm.net`,
  2026-09-07 — matches the single-hostname split-horizon pattern used
  by Keycloak (`elvis`) and Vaultwarden (`kumar`). Retired
  `susan-int.gs-farm.net`; `ROOT_URL`/`DOMAIN` confirmed live-matching
  in `app.ini`, new TLS cert issued and verified for the internal
  Ingress, old hostname now cleanly 404s instead of serving stale
  content. Fixes the canonical-URL mismatch banner from browsing
  Forgejo internally.
- Max's Windows laptop pointed at Pi-hole for DNS, 2026-09-07.
  Network's UniFi DHCP hands out `10.0.100.1` as DNS by default —
  same as every other device in the house, all on manual overrides.
  Set manual DNS to Pi-hole's DNS service IP `10.0.10.6` (not the
  `10.0.10.5` web UI or `10.0.10.1` HTTP ingress IP — three different
  IPs, easy to mix up). See gotcha below re: leaving an alternate DNS
  server configured.
- Immich (self-hosted photo/video library) stood up, 2026-09-07 —
  `kubernetes/apps/immich/`, following the research in
  `docs/photo-storage-strategy-research.md`. Server + machine-learning
  + bundled valkey via the official `immich-charts` Helm chart
  (0.12.0 / app v2.6.3), standalone Postgres (see gotcha below — not
  CrunchyData PGO), `immich-library` PVC on `gsks0` at 1Ti, single
  hostname `major.gs-farm.net` matching the cluster's split-horizon
  pattern. Both the Postgres data and library PVCs back up nightly
  via Volsync into the existing shared `volsync-backups` MinIO
  bucket. Verified live: pods healthy, TLS certs issued for both
  ingresses, `/api/server/ping` returns `200` internally and
  externally. Keycloak SSO deliberately deferred — see On the
  Horizon. Not yet done: initial admin account setup (first user to
  register becomes admin), content migration from Google/Amazon
  Photos.
- **Incident, found and fixed same day (2026-09-08)**: Immich's two
  Volsync `ReplicationSource`s were pointed at the wrong S3 endpoint
  (`minio.minio.svc.cluster.local`, which doesn't match MinIO's real
  cert — see gotcha below). Every backup attempt failed instantly on
  TLS verification and retried continuously from the first 3am
  trigger for 8+ hours, saturating the shared `gsks0` NFS pool the
  whole time. This is almost certainly what caused Max's "Pi-hole is
  too laggy" report that morning — Pi-hole's own PVC lives on that
  same pool, confirmed via Prometheus: `iowait` was flat 2-4% the
  night before, spiked to 25-64% for hours starting right at 3am the
  night Immich went live. Fixed by pointing both secrets at
  `s3.gs-farm.net` instead (verified with a real TLS handshake).
  Commit `6a6d78e0`.
- Upgraded to Immich v3.1.0 the same day, 2026-09-08 — correcting an
  earlier "wait for the chart to catch up" call after Tom pushed
  back: the postgres image already deployed
  (`vectorchord0.4.3-pgvectors0.2.0`) turned out to already be the
  documented post-VectorChord-migration target, so no image swap was
  needed at all — just an app version bump, with Immich's own
  automatic startup DB migration handling the rest. Overrode the
  chart's default image tag directly in the HelmRelease rather than
  waiting on a new `immich-charts` release (confirmed via `helm
  template` this chart has no v2-vs-v3-specific logic to need one).
  Took a fresh manual Volsync backup immediately before, as an extra
  safety net. Verified live: `/api/server/version` reports
  `3.1.0`, clean startup logs, zero errors, zero new restarts.
  Caught and fixed a real YAML bug while editing — see gotcha below.
- Keycloak SSO enabled for Immich, 2026-09-08 — native OAuth support
  (unlike Forgejo/Frigate, no CLI or forward-auth proxy needed).
  Dedicated `immich` realm + client, config delivered via a SOPS
  Secret mounted as `IMMICH_CONFIG_FILE` (`immich.existingConfiguration`
  + `configurationKind: Secret`, not inline in the HelmRelease since
  that file isn't SOPS-encrypted). `autoRegister: true`, no admin
  role-claim mapping. Verified via `/api/oauth/authorize` returning a
  correctly-formed Keycloak authorization URL, and confirmed after
  Tom's first login by querying the `user` table directly: it linked
  to the existing local admin account by email (same row, same
  `createdAt`, `oauthId` now populated) rather than creating a
  separate one — same behavior as Forgejo, confirmed via DB query
  this time instead of assumed.
- **Second incident, found and fixed same day (2026-09-08)**:
  `major.gs-farm.net` was unreachable externally because its Ingress
  was missing the `external-dns.alpha.kubernetes.io/target:
  external.gs-farm.net` annotation. Without it, external-dns
  defaulted to an A record pointing at nginx-external's private LAN
  IP (`10.0.10.2`), which Cloudflare rejects outright for a proxied
  record — it had been retrying and failing every 60s for ~13 hours
  straight since the ingress was first created, never producing a
  usable DNS record. Confirmed via the Cloudflare API that every
  working app's actual record is a CNAME to `external.gs-farm.net`
  (matching Keycloak's own external ingress, which already had this
  annotation). Fixed by adding it; external-dns created the correct
  CNAME within a minute, external access confirmed working
  (`curl https://major.gs-farm.net/api/server/ping` → `200`, real
  public DNS, no `--resolve` needed). Forgejo's external ingress had
  the same gap — fixed same day (commit `c39b0b44`), confirmed
  external-dns treated it as a no-op (record already matched the
  annotation's target, no change attempted) and `susan.gs-farm.net`
  kept resolving/responding throughout.

### 🔴 High Priority

*(The PostgreSQL/PGO Patroni crash-recovery issue and the MinIO PVC
immutability error from the previous update have both been resolved
or are no longer reproducing — Postgres and MinIO have been stable
for 6+ days as of 2026-09-05. Nothing currently open here.)*

### 🟡 Medium Priority

**CoreDNS HelmRelease**
- Stuck in `Unknown / reconciliation in progress`
- Pod itself is healthy (`1/1 Running`)
- Fix: resume the suspended HelmRelease to let Flux retry

**Keycloak / SSO — live for Vaultwarden (2026-09-06) and Grafana (2026-09-07)**
- Keycloak itself is healthy: HelmRelease `Ready`, pod running
  (`26.7.3`), no crash-loop. The Postgres instance it depends on has
  also been stable for 6+ days.
- Vaultwarden SSO is enabled and confirmed working end-to-end
  (Keycloak auth → Vaultwarden token exchange → vault master password
  unlock). See `CLUSTER-doc-updates-2026-09-06.md` for the full
  troubleshooting trail and root causes. Local email/password login
  is still available as a fallback (`SSO_ONLY` intentionally not set).
- Grafana SSO is enabled and confirmed working end-to-end (dedicated
  `grafana` Keycloak realm + client, `role_attribute_path` fixed to
  `Editor` for all SSO logins, local admin/password login left
  enabled as fallback). See `CLUSTER-doc-updates-2026-09-07.md` for
  setup details and the empty-realm gotcha hit along the way.
- Forgejo SSO is enabled and confirmed working (2026-09-07) —
  dedicated `forgejo` Keycloak realm + client, configured
  declaratively via the chart's native `gitea.oauth` values block
  (no admin-panel clicking needed, unlike Vaultwarden/Grafana). No
  admin-group mapping, so a brand-new SSO login would land as a
  normal (non-admin) user. In practice Forgejo detected the Keycloak
  account's email matched the existing local `fjmaster` admin and
  offered an account-link flow (confirmed with `fjmaster`'s local
  password) instead of creating a duplicate — `fjmaster` now logs in
  via Keycloak *or* local password, still admin either way. Local
  login form left enabled as fallback.

### 🔵 On the Horizon

- Evaluate k8s-gateway as longer-term replacement for per-host Pi-hole DNS overrides
- **Frigate SSO** — Frigate has no native OIDC/OAuth2 client, unlike
  Vaultwarden/Grafana/Forgejo. It only supports proxy-based header
  auth (trusts `X-Forwarded-User`/`Remote-User`-style headers from an
  upstream forward-auth proxy, with `header_map` config to translate
  proxy group claims into its `admin`/`viewer`/custom-role model).
  Getting this to Keycloak means deploying a new piece of
  infrastructure — most likely `oauth2-proxy` configured against
  Keycloak, wired into nginx-ingress via `auth-url`/`auth-signin`
  annotations in front of the Frigate Ingress — not just a
  HelmRelease values change like the other three apps. Bigger scope,
  not started.
- **Immich follow-ups**: migrate content in from Google Photos/Amazon
  Photos per the staged plan in `docs/photo-storage-strategy-
  research.md` (local/network drives first, then Google Takeout,
  then Amazon Photos export, checking duplicate detection after each
  batch); decide what happens to Google Photos/Drive and Amazon
  Photos subscriptions once migration is verified. **Stage 2 (Google
  Takeout) is planned in detail in
  `docs/photo-migration-google-takeout-plan.md`** — including why
  Google now goes before Amazon, and why the import runs from
  `gsfarmctl` rather than the Mac.
- **Apple Photos re-import (Immich)** — the 2026-09-08 first-batch
  import pointed `immich-go` at all of `~/Pictures`, which walked
  into the `Photos Library.photoslibrary` package (5,287 paths
  scanned) and ingested 477 assets from inside it: **293 Photos
  derivatives** (`…_1_105_c.jpeg` — downscaled renders whose
  checksums never match their originals, so Immich's dedup can't
  catch them) plus **184 UUID-named originals** carrying no album
  membership or curated metadata. All 477 deleted 2026-09-08 (Tom's
  call: "will fix later"). Redo properly via **Photos.app → File →
  Export → Export Unmodified Originals** into a staging folder, then
  point `immich-go` at *that folder* — never at the `.photoslibrary`
  package, which is an opaque bundle, not a photo directory. The 359
  normal-filename assets (`~/Pictures/pics` etc.) were clean and were
  kept. Still outstanding from the same batch: the 114 MB
  `WIN_20190505_07_44_26_Pro.mp4` in `~/immich-oversize` (exceeds
  Cloudflare's 100 MiB proxy cap — needs the LAN/browser path), and
  `~/Downloads` was never imported.

---

## Key Learnings & Gotchas

**A new externally-exposed app needs the external-dns target annotation, or it just silently never gets DNS**  
`external-dns` in this cluster watches `ingressClassName: external`
Ingress objects and, with no override, defaults to an A record
pointing at nginx-external's private LAN IP (`10.0.10.2`). Cloudflare
rejects that outright for a proxied record (error code 9003, "Target
... is not allowed for a proxied record") - and `external-dns` just
retries the same failing create every 60 seconds forever, with no
escalation, no visible failure anywhere except its own pod logs. The
app's Ingress applies fine, TLS cert issues fine, everything *looks*
healthy - it's simply unreachable from outside the LAN, with the only
symptom being "I can't get to it" from off-network. Every actually-
working external hostname in this cluster is a CNAME to
`external.gs-farm.net` (verified via the Cloudflare API), which
requires the Ingress annotation `external-dns.alpha.kubernetes.io/
target: external.gs-farm.net` (Keycloak's external ingress has always
had this; Grafana/Vaultwarden/Frigate do too). **Add this annotation
to every new app's external Ingress from the start** - don't wait to
discover it's missing when someone tries to reach the app remotely.
If a new external hostname works from inside the LAN but not outside,
check `kubectl logs -n network -l app.kubernetes.io/name=external-dns`
for repeating `9003`/"not allowed for a proxied record" errors before
looking anywhere else.

**A duplicate top-level YAML key silently discards the first one - no error**  
A HelmRelease's `spec.values` is one YAML mapping. Adding a second
top-level key with the same name as one already present later in the
file (e.g. two separate `controllers:` blocks meant to be merged) is
valid YAML syntax but not valid *data* - the parser silently keeps
only the last occurrence and drops the first entirely, no warning
from `kubectl apply`, Flux, or Helm. Caught this adding an image tag
override to Immich's HelmRelease: the new `controllers:` block landed
above an existing one for DB env vars, and the DB one silently won,
discarding the version bump with zero indication anything was wrong
until `helm template` was checked. When adding a new top-level key to
an existing values block, grep the file for that key name first, and
merge into the existing block rather than assume a second same-named
key will combine with the first.

**A failed Volsync backup Job retries forever, not just once**  
When a Volsync `ReplicationSource`'s restic backup fails immediately
(e.g. a bad S3 endpoint), Kubernetes' Job controller keeps recreating
failed pods indefinitely from that same scheduled trigger — it does
not back off to "try again next scheduled run." A backup broken at
3am can still be retrying at 11am, continuously hammering whatever
storage the source/cache PVCs live on the entire time. Check for a
Job stuck recreating pods (`kubectl get pods -n <ns> | grep volsync`
showing many recent `Error` pods a few minutes apart) whenever a
Volsync-adjacent app is acting slow long after its 3am backup window
should have finished — don't assume a failure means it just stopped
trying.

**`mc --insecure` (or curl `-k`) can hide a real endpoint mismatch**  
Testing MinIO connectivity with `--insecure`/`-k` skips TLS
verification entirely, so a wrong hostname (e.g. the in-cluster
`minio.minio.svc.cluster.local` vs the actual cert's
`minio.gs-farm.net`/`s3.gs-farm.net`) will connect fine — but restic
(used by every Volsync backup) verifies certs for real and refuses
the same connection outright. A static `public.crt` file can also be
stale documentation, not the live cert — check the actual
`Certificate` resource (`kubernetes/apps/minio/minio/app/
certificate.yaml`) for the real SAN list before writing a new
`RESTIC_REPOSITORY` value, and verify with a real (non-`-k`)
`curl`/`openssl s_client` handshake, not just a successful
`--insecure` connection. Caused an 8+ hour disk-I/O incident when a
new Immich Volsync secret used the internal hostname instead —
see Immich's 2026-09-08 entry above.

**Not every app's Postgres fits the CrunchyData PGO pattern**  
Immich requires a Postgres image with the `vectorchord`/`pgvecto.rs`
vector-search extension compiled in
(`ghcr.io/immich-app/postgres:14-vectorchord...`) — a custom image,
not an extension you install into a stock Postgres. PGO's own images
bundle its own Patroni/pgBackRest tooling that this image doesn't
have, so pointing a `PostgresCluster` at it isn't a supported
combination. Immich's database runs as a standalone single-pod
Deployment instead (`kubernetes/apps/immich/postgres/`), backed up
via Volsync/restic rather than pgBackRest. Worth checking this early
for any future app that needs a database extension PGO's images
don't ship — don't assume every app's Postgres can go through the
shared `postgres-infra` pattern.

**Windows + manual DNS + a fallback server = split-horizon breaks silently**  
Windows' "Smart Multi-Homed Name Resolution" queries every configured
DNS server in parallel for normal app lookups (`ping`, browsers) and
accepts whichever answers first — it does not go primary-then-fallback
like `nslookup` does. Pointing a Windows client at Pi-hole
(`10.0.10.6`) with a public resolver like `1.1.1.1` as the alternate
means any `*.gs-farm.net` split-horizon override is a race: if the
public resolver's answer (the real public/Cloudflare-tunnel IP) comes
back before Pi-hole's, that's what apps use, even though Pi-hole is
listed first and `nslookup` shows the correct internal IP. Fix: don't
configure a second DNS server on clients that need split-horizon
overrides to work — Pi-hole already forwards non-overridden queries
upstream (`1.1.1.1`/`8.8.8.8`) on its own, so a single-DNS setup loses
nothing except a fallback if Pi-hole itself goes down (a tradeoff
already accepted everywhere else on this network). Hit this getting
Max's laptop onto Pi-hole, 2026-09-07.

**macOS Local Network privacy blocks unbundled CLI binaries, and `curl` hides it**  
Pi-hole's `address=/gs-farm.net/10.0.10.1` means every
`*.gs-farm.net` host resolves to a **private** address on the LAN, so
any tool reaching one is making a *local network* connection - which
macOS (Sequoia and later) gates behind Local Network privacy and
blocks **in the kernel, before a single packet is emitted**. The
symptom is a tool that fails 100% of the time with zero packets
leaving the machine and a kernel error in Console.app, while `curl`
to the identical URL from the same shell succeeds 100% of the time.
`curl` works because **Terminal.app** holds the grant; a bare Mach-O
executable launched from that shell does **not** inherit it and is
attributed its own TCC identity. Worse, a standalone binary has no
bundle identifier, so macOS has nothing to register - it silently
denies and **never appears** in System Settings -> Privacy & Security
-> Local Network. An empty list is the bug, not evidence against the
theory, and there is no toggle to flip. Quarantine is unrelated (the
binary that hit this had no `com.apple.quarantine` xattr). Confirm in
one step by pinning the host to its **public** Cloudflare IP
(`dig +short @1.1.1.1 <host>`) in `/etc/hosts`: if the same binary
suddenly works, it is Local Network privacy. Note this generalizes
the browser-focused entry in `CLAUDE.md` - it applies to any
unbundled CLI tool, and **`curl` succeeding proves nothing about
whether another tool will**. Best fix is usually to take macOS out of
the path: run the tool from `gsfarmctl` or TrueNAS over the LAN. Hit
this with `immich-go`, 2026-09-08.

**One corrupt input can fail many unrelated concurrent uploads (HTTP/2)**  
An upload tool that parallelises over a single HTTP/2 connection will
lose **every in-flight transfer** when the server rejects any one of
them hard enough to tear the connection down. `immich-go` hit this:
two 0-byte files produced `400 Bad Request` from Immich, which killed
the shared connection and took seven healthy uploads (66KB-6.8MB)
with it, then aborted the queue so another 30 files were never
attempted. Removing the two 0-byte files fixed all of it in one run.
The tool's own counters were misleading in both directions - it
reported 9-10 errors when only **2** requests ever reached the
server. Diagnose by correlating the client log against nginx access
logs rather than trusting either alone: the giveaway was nginx
logging exactly two `400`s with `request_length: ~1700` bytes (a
multi-MB upload cannot be 1.7KB, so those requests carried no file
content), and the client log showing a status code on only one error
line while the rest had **no HTTP response at all**. When a bulk
upload fails on a stable subset of files, check for 0-byte and
truncated inputs first: `find <dir> -type f -size 0`.

**SOPS / Flux decryption**  
The `flux-system` kustomization in `gotk-sync.yaml` must include a `decryption` block. Without it, every reconcile cycle overwrites decrypted secrets with raw ciphertext.

**Flux `postBuild` variable substitution**  
`${SECRET_DOMAIN}` variables are not substituted inside ConfigMap blobs used via `valuesFrom`. Move them directly to `spec.values` in the HelmRelease.

**Talos + NFS**  
Talos does not run `rpc.statd`. NFS storage classes require the `nolock` mount option and the `nfs-utils` Talos extension.

**Cilium on Talos**  
`KUBERNETES_SERVICE_HOST` and `k8sServiceHost` must reflect the actual node IP. After a node IP change, these can get hardcoded in DaemonSet env vars and require a direct JSON patch to fix.

**Internal LAN access**  
Services needing internal access require both an `external` and `internal` class Ingress. Learned through Vaultwarden, Keycloak, and Kerberos agent troubleshooting.

**StatefulSet storage migration**  
Helm blocks direct `storageClass` changes on StatefulSets. Requires `helm uninstall` + Flux suspend/resume cycle for a clean reinstall.

**Talos install disk**  
When bootstrapping, the ISO USB and install target must be separate physical devices to avoid Talos installing to the wrong disk.

**Pre-cleanup checklist**  
Before removing HelmReleases: verify no ConfigMaps/Secrets reference the service hostnames via `kubectl` grep. Suspend active releases (`flux suspend`) before destructive operations.

---

## GitOps Patterns

- Apps live under `kubernetes/apps/` with per-app subdirectories
- Flux `suspend`/`resume` used deliberately for maintenance windows and forced reconciliation
- Postgres → Keycloak → Vaultwarden/MinIO was the recovery order while
  the PGO/Patroni issue was open; no longer a live dependency chain
  since all four are independently stable now
- All cluster state managed through `cillflux`; manual changes are temporary and should be committed back

---

## Command Reference

```bash
# Flux
flux suspend kustomization <name>
flux resume kustomization <name>
flux reconcile kustomization <name> --with-source
flux get helmreleases -A

# Kubectl
kubectl get pods -n <namespace>
kubectl describe helmrelease <name> -n <namespace>
kubectl logs -n <namespace> <pod> --previous

# Talos
talosctl dmesg --follow
talosctl health
talosctl service list

# SOPS
sops -e -i <file>        # encrypt in place
sops -d <file>           # decrypt to stdout
```

---

*Keep this file updated as the cluster evolves. When opening a new Claude chat in this project, this file provides full context without relying on memory summarization.*
