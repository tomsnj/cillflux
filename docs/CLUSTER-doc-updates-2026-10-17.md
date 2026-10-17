# Cluster Doc Update — 2026-10-17

Weekly Renovate review: eight merges (six by the review, then Keycloak and
Pi-hole on Tom's go-ahead), two PRs still queued. One PR (#1012,
snapshot-controller) exposed a standing conflict between two Helm
releases that both deploy the same Deployment, and would very likely
have failed the same way csi-driver-nfs did on 10-10. It was resolved by
retiring the duplicate release (#1020-#1022), without touching the live
controller. Pi-hole's upgrade also changed what `/` returns, which was
fixed at the ingress (#1019). Also today: the infra-local backup alerts
landed, the Forgejo backup repo was sized, a `BackupJobFailed` for
`laptop-win` came and went (see the 10-14 file's addendum), and leftover
branches were cleaned up. No outage was observed at any point.

## Renovate review

**Merged** (each via `weekly-renovate-review.sh merge`, then verified
live):

| PR    | Change                                      | Type  |
|-------|---------------------------------------------|-------|
| #1005 | immich-server v3.3.1 → v3.3.3               | patch |
| #1011 | grafana chart 13.5.0 → 13.7.0               | minor |
| #1008 | kube-prometheus-stack 92.3.0 → 92.10.1      | minor |
| #1009 | python 3.14 → 3.15 (Frigate DB backup job)  | minor |
| #1004 | cloudflared 2026.10.0 → 2026.10.1           | patch |
| #1007 | cilium chart 1.20.2 → 1.20.3                | patch |

**Merged afterwards, on Tom's go-ahead** (both failed the script's
mechanical criteria or were held for judgement, so neither went through
`merge`; Tom merged them on GitHub and they were reconciled and verified by
hand):

| PR    | Change                                      | Type  | Why held |
|-------|---------------------------------------------|-------|----------|
| #1006 | keycloak 26.8.0 → 26.8.1                    | patch | guarded path (`infrastructure/keycloak`) |
| #1014 | pihole 2026.09.0 → 2026.10.0                | minor | automatic `gravity.db` migration; household DNS |

- **#1006 Keycloak:** fixes at least twelve CVEs, including a cross-realm
  read/write and a 2FA enforcement bypass, on an internet-facing Keycloak
  with five realms. The release notes show no database migration.
  `weekly-renovate-review.sh merge 1006 --force` was refused by the
  permission system as a CI bypass, so Tom merged it himself.
- **#1014 Pi-hole:** fixes 17 security advisories (including a
  DNS-reachable DoS), but Core v6.5 migrates `gravity.db` to schema
  version 21 automatically, moves the `listsCache` directory, and removes
  the `arpflush` command. Details in the Pi-hole section below.

**Still queued for Tom:**

- **#1010 app-template 5.2.1 → 5.3.0.** Touches keycloak, minio,
  vaultwarden and cloudflared, so guarded. Rendered all four at both
  versions against live values: the only difference is two selector
  labels listed in a different order. Nothing rolls. Recommend approving.
- **#1013 grafana chart 14.0.1 (major).** The new values schema accepts
  the live values, and the chart's `appVersion` is still 13.2.4, so it
  is a chart-level change only. Low risk. Renovate will rebase it onto
  the 13.7.0 merged today.

**Closed:** #1012 (snapshot-controller 5.3.0 → 5.4.0), autoclosed by
Renovate once the chart was removed from git; see the next section.

## snapshot-controller: two releases, one Deployment

### What was found

Reviewing #1012 (the piraeus `snapshot-controller` chart) showed that the
live `storage/snapshot-controller` Deployment is **not owned by that
release**:

- Live Deployment: Helm annotation `meta.helm.sh/release-name:
  csi-driver-nfs`, chart label `csi-driver-nfs-4.13.5`, selector
  `app: snapshot-controller`, created 2026-10-10 (the day it was
  recreated to fix the csi-driver-nfs 4.13.5 upgrade).
- The piraeus release (`helm history`: revision 6, chart 5.3.0, last
  upgraded 2026-09-24) records a Deployment of the same name with
  selector `app.kubernetes.io/instance` + `app.kubernetes.io/name`.
- The csi-driver-nfs HelmRelease sets `externalSnapshotter.enabled: true`
  (added June 2026), which deploys its own snapshot-controller and
  VolumeSnapshot CRDs. The piraeus chart deploys the same two things. The
  duplicate has existed since June; the selector clash only became live
  after 10-10.

### Why it matters

Upgrading the piraeus release would try to change the image *and* patch
that Deployment's selector labels toward its own. `spec.selector` is
immutable, so the upgrade would very likely fail, and the automatic
rollback would hit the same error: `RollbackFailed`, exactly the 10-10
failure mode. The workload would keep running, so pod checks would stay
green.

**This is a prediction, not an observation.** The upgrade was not run,
because proving it would risk the same stuck release. Both HelmReleases
are `Ready` today only because neither has changed since 10-10; a bump
to either is what triggers the conflict.

### What each release owned

Both releases recorded the Deployment, the ServiceAccount and the three
core snapshot CRDs. Only piraeus recorded its own ClusterRole/Binding,
Role/RoleBinding (all named `snapshot-controller`), the three
VolumeGroupSnapshot CRDs, and a metrics Service and ServiceMonitor.
csi-driver-nfs was self-contained: its own RBAC
(`snapshot-controller-runner`, leader election), the CSI driver, and its
core CRDs annotated `helm.sh/resource-policy: keep`. The piraeus-only
parts did nothing: the metrics Service had no endpoints (it selects the
piraeus labels, the live pod carries csi-driver-nfs's) and Prometheus had
no snapshot-controller target; nothing uses VolumeGroupSnapshot.

Dependants: the `volsync` HelmRelease had `dependsOn: snapshot-controller`
(the piraeus one), and three ReplicationSources use `copyMethod: Snapshot`
(Pi-hole, vaultwarden-config, vaultwarden-data). The `nfs-csi-snapclass`
VolumeSnapshotClass is managed in git
(`kubernetes/apps/storage/csi-driver-nfs/app/volumesnapshotclass.yaml`).

### Decision and resolution

Tom chose to keep csi-driver-nfs as the single owner and retire the
piraeus release. Done in four steps, each verified before the next:

1. **#1020, `volsync` now depends on `csi-driver-nfs`.** A dependsOn-only
   change did **not** trigger a Helm upgrade: `volsync` stayed at release
   v3 (0.16.0, 2026-06-14), same pod (created 07-21, 4 restarts, unchanged).
   This settled a point that had been flagged as unverified.
2. **#1021, annotated the piraeus HelmRelease
   `kustomize.toolkit.fluxcd.io/prune: disabled`.** Metadata-only: release
   stayed at v6, same pod.
3. **#1022, removed the `snapshot-controller` Kustomization and its app
   folder from git.** The first attempt was wrong (see below). Once fixed
   and merged, kustomize-controller logged `garbage collection completed:
   Kustomization/flux-system/snapshot-controller deleted` at 15:08:26 UTC,
   and the event log read `HelmRelease/storage/snapshot-controller
   skipped`: the annotation did what it was meant to. The live Deployment
   kept the same UID (`1ec2da80-5f2f-4fc1-87f7-bea702f76424`) and creation
   time as in a read-only export taken before the merge, and the core CRD
   UIDs were identical to the export. The Kustomization's inventory was
   exactly one object, the HelmRelease.
4. **Supervised cleanup of the orphan (no Helm uninstall).** Suspend the
   HelmRelease so helm-controller cannot re-add the finalizer; patch the
   finalizer off and read it back, continuing only if empty (it was);
   delete the HelmRelease; delete the stale release secrets
   `sh.helm.release.v1.snapshot-controller.v5` and `.v6`. Helm no longer
   lists the release; csi-driver-nfs's own release secrets were untouched.

**Functional test afterwards:** a throwaway 10Mi PVC on `gsks0` and a
VolumeSnapshot of it with `nfs-csi-snapclass` reached `readyToUse=true`,
and the controller log showed no errors. Both objects, and their data on
the NAS, were deleted (0 snapshots, 0 contents, 0 test PVCs/PVs left).

**What remains from the piraeus release**, still live, owned by a release
that no longer exists, all unused: `Service` and `ServiceMonitor`
`snapshot-controller`, `Role` and `RoleBinding` `snapshot-controller` (in
`storage`), `ClusterRole` and `ClusterRoleBinding` `snapshot-controller`,
and the three `groupsnapshot.storage.k8s.io` CRDs (VolumeGroupSnapshot,
-Class, -Content). Left in place on purpose; deleting the CRDs in
particular is a separate decision.

**Not tested:** a real Volsync run against Pi-hole and Vaultwarden, the
two users of the Snapshot method. The next scheduled run is 03:00 UTC.

### Mistake: PR #1022 first omitted the kustomization edit

The first commit of #1022 contained only the three file deletions. The
edit removing `./snapshot-controller/ks.yaml` from
`kubernetes/apps/storage/kustomization.yaml` had been made but not staged
(`git commit` without `-a`). The flux-diff check failed:
`kustomize build ./kubernetes/apps ... open .../snapshot-controller/ks.yaml:
no such file or directory`. Merged as it was, `cluster-apps` would not have
built. The earlier "renders fine" check had been run against the working
tree, not the committed state. Fixed with a second commit; the failure was
reproduced locally on the original commit and the fix confirmed with
`flux build kustomization cluster-apps --path ./kubernetes/apps
--kustomization-file ./kubernetes/flux/apps.yaml --dry-run` on clean
worktrees (old commit: same error; fixed commit: 78 objects, 33
Kustomizations, no snapshot-controller). All four CI checks passed on the
fixed head.

## Keycloak 26.8.1 (#1006)

Held by the guarded-path rule, not by a technical concern. Before the
merge: release notes scanned for database or migration changes (none; the
only database mention is a docs link fix), backup chain confirmed fresh
(infra-local incremental ran 18 minutes earlier), and a baseline taken of
realms, users, clients and the Liquibase changelog.

Verified after Tom merged and the release was reconciled (app-template
HelmRelease `keycloak.v430`):

- Image `26.8.1`, one pod `1/1`, log line `Keycloak 26.8.1 ... started in
  8.019s`, zero `ERROR` lines.
- Realms / users / clients: **5 / 9 / 38**, identical to the baseline.
- Liquibase changesets: 237, last executed 2026-10-03, identical to the
  baseline (consistent with no migration).
- All five realm discovery endpoints (`master`, `grafana`, `vaultwarden`,
  `forgejo`, `immich`) return 200, and `elvis.gs-farm.net` returns 200 via
  the public Cloudflare IP. Three idle DB connections, as before.

**Not tested:** an actual login through any of the realms. Discovery
returning 200 shows Keycloak is serving them, not that sign-in works.

## Pi-hole 2026.10.0 (#1014) and the ingress follow-up (#1019)

Held for judgement: 17 security advisories (including a DNS-reachable DoS)
against an automatic `gravity.db` migration to schema 21, a moved
`listsCache` directory and a removed `arpflush` command, on household DNS.

**What changed the risk picture.** Pi-hole's `gravity.db` is 106 KB at
schema 20 and holds no user data: 0 adlists, 0 domain-list entries, 0
clients, gravity count 0 (it is used as a forwarder with local DNS
records). The one-way migration therefore had almost nothing to migrate.
The existing 03:00 UTC Volsync snapshot was an adequate restore point.

**Canary before merging.** The new image was run in a throwaway pod in the
`pihole` namespace with the chart's exact environment and security context,
a scratch volume, no Service labels, and a copy of the real `gravity.db`:

- `gravity.db` migrated 20 → 21 cleanly. FTL listened on TCP and UDP 53 and
  answered a query.
- FTL 6.8 logs "capability not available" warnings (`CAP_NET_BIND_SERVICE`,
  `CAP_CHOWN`, `CAP_SYS_NICE`, `CAP_SYS_TIME`) that the live 6.7.1 pod never
  logged, so they look like new logging; port 53 bound regardless.
- The canary could not reproduce the real NFS volume's file-ownership
  behaviour, and the live volume was deliberately not mounted in a test
  pod. That stayed the residual risk, checked live afterwards.

**Live result** (HelmRelease `pihole.v33`, Recreate strategy):

- Core v6.5, Web v6.6.1, FTL v6.8. `gravity.db` at 21. `pihole-FTL.db`
  already at version 22 and not migrated; 511,335 queries on disk before,
  511,397 after, so history is intact and new queries are written.
- Both init containers exited 0; all files owned `pihole:pihole`; the only
  log notice was the `CAP_CHOWN` one.
- Public and local resolution through `10.0.10.6` worked over UDP and TCP;
  `*.gs-farm.net` resolves to `10.0.10.1`; an `HTTPS` query for an
  overridden name returns empty (the `local=/gs-farm.net/` fix still holds);
  web UI `/admin/login` 200.
- **DNS gap:** a once-a-second probe through the LoadBalancer IP recorded
  330 of 330 successful queries across the roll (old pod killed 14:37:02,
  new pod created 14:37:06, Ready 14:37:21). It is not understood why a
  `Recreate` showed no failed query, so treat it as observed from one
  vantage point, not as a guarantee; the largest gap between samples was 2s.

**A behaviour change, found by the end-of-run health pass.**
`pihole.gs-farm.net` returned HTTP 404 (1 of 14 ingresses). It is Pi-hole's
own behaviour: the same 404 comes straight from the web LB, bypassing
ingress. The FTL 6.8 notes list "`/` ignoring `webserver.serve_all`" as a
fix, and `serve_all = false` here. The review script's notes say Pi-hole
answered 403 at `/` before, which the check accepts. The admin UI was
unaffected (`/admin/login` 200). That line was in the notes read before the
merge and was not flagged as a behaviour change at the time.

**#1019** added `nginx.ingress.kubernetes.io/app-root: /admin/` to the
Pi-hole ingress. Rendering the chart with the live values before and after
showed the annotation as the only manifest change (no pod restart). After
merge (`pihole.v34`): same pod, 0 restarts; `/` returns 302 to
`https://pihole.gs-farm.net/admin/`; `/admin/login` 200; ingress check 14 of
14. The chart's admin-password Secret was never at risk: its `secret.yaml`
uses `lookup`, so real upgrades keep the existing Secret (created
2026-04-25); the random value seen in a plain `helm template` is an
artefact of `lookup` not running offline.

**Hygiene note.** A scratch file holding the Pi-hole HelmRelease's values
(which include the admin password) was saved while rendering. It was never
printed, and it was deleted along with every other scratch render that
mentioned "password".

## Review method notes

What the weekly script cannot do, and what was done by hand:

- **Release notes:** fetched upstream with `gh api repos/<org>/<repo>/releases/tags/<tag>`
  for every eligible PR, including the *application* notes where the
  chart notes were empty (external-snapshotter v8.7.0 for the
  snapshot-controller chart; Pi-hole FTL, Web and Core for the Pi-hole
  image; Grafana app 13.2.4).
- **Render diffs:** `helm template` of old and new chart against the live
  values (Flux's merge order: `valuesFrom` first, then inline values),
  normalising version labels. Done for cilium, kube-prometheus-stack,
  snapshot-controller, grafana (13.5.0 → 13.7.0 and 14.0.1) and
  app-template (all four releases).
  - kube-prometheus-stack 92.3.0 → 92.10.1: only version labels and the
    `kube-webhook-certgen` image (1.11.0). CRDs, rules and selectors
    unchanged.
  - cilium: image bumps only, but `cilium-envoy` goes v1.37.6 → v1.38.6
    inside a patch release. No `CiliumNetworkPolicy`,
    `CiliumClusterwideNetworkPolicy`, `CiliumCIDRGroup` or
    `CiliumLocalRedirectPolicy` objects exist, so the two policy
    behaviour changes in the notes do not apply.
- **Python 3.15:** the only relevant porting note is that
  `sqlite3.connect` now takes everything but `database` as keyword-only.
  The Frigate script already uses `uri=True`. Beyond reading it, the same
  logic (WAL database, online backup API, integrity check, rename, prune)
  was run on `python:3.15-slim` in a throwaway pod against a temporary
  database: `python 3.15.0 | integrity ok | retained 7`. Running the
  real CronJob was avoided because an extra run uses one of its 7
  retained backups.
- **cloudflared:** the GitHub release body is only checksums again. The
  real change list is the repo's `RELEASE_NOTES` file
  (`gh api repos/cloudflare/cloudflared/contents/RELEASE_NOTES`): Go
  1.27.2 security bump, a precheck diag endpoint, CGO disabled for Linux
  CI builds. Nothing breaking.

## Verified live after the merges

The six merges done through the review script. Keycloak, Pi-hole and the
snapshot-controller work have their own sections above.

- **Immich:** HelmRelease `immich.v12` Ready, image `v3.3.3`, new server
  pod `1/1`, `/api/server/ping` 200.
- **Grafana:** `grafana.v2647` Ready, image `13.2.4-distroless`, pod
  `3/3`, `/api/health` 200.
- **kube-prometheus-stack:** `v431` Ready. 33/33 targets up, 0 rules not
  `ok`, all 10 `postgres.rules` loaded, Alertmanager ready, only
  `Watchdog` active. Prometheus and Alertmanager did not restart; the
  operator rolled.
- **Frigate backup CronJob:** now `python:3.15-slim`; not suspended. Its
  next real run is 02:45 UTC.
- **cloudflared:** image `2026.10.1`, both pods `1/1`, four tunnel
  connections registered per pod, no errors. External path: `elvis`
  (`/realms/master/.well-known/openid-configuration`) and `major`
  (`/api/server/ping`) both 200 via the public Cloudflare IP.
- **Cilium:** release `v171` Ready on 1.20.3, agent `OK`, controllers
  301/301 healthy, cluster health 1/1. All four pods `1/1`. Data-path
  test with `nc -z` against every TCP LoadBalancer port (minio 9000/9001,
  nginx-external 80/443, nginx-internal 80/443, pihole-dns 53, pihole-web
  80) was 8/8 OK before and after, and Pi-hole DNS resolved public and
  internal names both times.

### A bad test, discarded

A first external-path test for cloudflared built its hostname from a
variable that came back empty, so the `dig` and `curl` results meant
nothing and were thrown away. It was redone against two real endpoints
with known-good responses (above).

## Other work today

- **#1017 merged:** five `PostgresInfra*` alerts for `postgres-infra-local`
  (incr/diff/full staleness, suspended CronJob, missing CronJob), built on
  kube-state-metrics because the cluster has no Postgres metrics on PG18.
  They watch `kube_cronjob_status_last_successful_time`, not failed Jobs,
  since the operator sets `ttlSecondsAfterFinished: 90`. All five load and
  evaluate `ok`, none firing. Not tested end to end (that would mean
  failing a production backup). Does not cover WAL archiving between
  backups.
- **Forgejo backup repo sized:** 119 MB total (104 MB backups, 16 MB WAL
  archive) against a 5Gi claim; each full is 4.3 MB and each incremental
  about 75 KB. The 5Gi figure is not enforced: the repo is on NFS and
  `df` reports the whole 1.9T TrueNAS filesystem. Retention keeps 7 fulls
  and had not expired anything yet (6 present), so expiry is **not yet
  verified**; the 8th full, around 10-19, should trigger the first.
- **Docs:** #1015 (10-14 update, harbor/woodpecker to-do) and #1016 (five
  Postgres/PGO gotchas in `CLAUDE.md`) merged. This file is #1018.
- **PRs from the Renovate round-up:** #1019 (Pi-hole `app-root`), #1020
  (`volsync` dependency), #1021 (prune-disabled annotation), #1022 (remove
  the piraeus Kustomization).
- **Branches:** the nine merged PR branches from the Postgres work, the
  unpushed to-do branch, and four older leftover branches were deleted.
  One of the old branches (`update-truenas-claude-md-4`) held a commit
  that GitHub never saw; its content is on `main` as `8a6f1d4e`. The
  reflog shows the branch name had been reused for an unrelated commit.
  The TrueNAS host doc says the repo does not live there and that docs
  are rsynced *from* `gsfarmctl`, so TrueNAS is not a likely source of
  stray commits; how its doc edits get back into the repo is not
  documented and was not established.

## Not yet verified / open

- **Frigate DB backup on Python 3.15 against the real database** — first
  real run is tonight at 02:45 UTC; check the Job tomorrow.
- **Forgejo pgBackRest retention expiry** — see above.
- **Leftover pod `forgejo/postgres-forgejo-backup-5j85-xptsm`** (`Error`,
  3 days old): the failed first attempt of the 10-14 manual backup; its
  retry succeeded. It is the only pod `health` reports. Not deleted.
- **A real Volsync snapshot run** against Pi-hole and Vaultwarden (the
  Snapshot copy method) on the single-owner setup. The throwaway-PVC test
  proved the controller can snapshot; the 03:00 UTC run is the first real
  one. Check those ReplicationSources for a fresh `Successful` tomorrow.
- **A login through Keycloak** (any realm) after the 26.8.1 upgrade;
  discovery endpoints and data counts were verified, sign-in was not.
- **The nine piraeus-only orphans** (metrics Service/ServiceMonitor, RBAC,
  three VolumeGroupSnapshot CRDs): unused, left in place, deletion not
  decided.
- **#1010 and #1013** — waiting on Tom.
- **harbor/woodpecker cleanup** — still on the to-do list in `CLUSTER.md`.
  #1006 has now merged and settled, so it can go ahead as its own change;
  it needs `DROP DATABASE`/`DROP ROLE`, which should be asked about first.

## Gotchas for CLAUDE.md (proposed, not yet added)

- **Two Helm releases can own the same object, and the one you are
  about to upgrade may not be the owner.** `snapshot-controller` is
  deployed by both the piraeus chart and csi-driver-nfs
  (`externalSnapshotter.enabled`); the live Deployment belongs to
  csi-driver-nfs. Before merging a bump, compare the object's
  `meta.helm.sh/release-name` annotation with the release being
  upgraded (`kubectl get deploy -n <ns> <name> -o jsonpath='{.metadata.annotations}'`)
  and `helm get manifest <release>` for what that release thinks it owns.
  A mismatch plus an immutable field is `RollbackFailed` waiting to happen.
- **A Renovate "major" chart bump can be chart-level only.** Grafana
  14.0.0's only change is a values schema. Render the new chart with the
  live values (a schema rejection fails `helm template`) and compare
  `appVersion` before deciding the risk.
- **A selector diff in a render can be label order, not content.** The
  app-template 5.3.0 render swaps `name` and `instance` in the selector of
  every release. Compare the sorted key/value pairs before treating it as
  an immutable-selector change; here they were identical.
- **When a release body is only checksums, look for the project's own
  notes.** cloudflared keeps them in `RELEASE_NOTES` in the repo.
- **`helm template` regenerates certificates on every render.** The cilium
  chart's CA and TLS secrets differ between any two renders, so those
  base64 lines are noise in a diff. Filter `ca.crt`/`ca.key`/`tls.*`
  before reading, and avoid printing them.
- **Test a CronJob's script on a new interpreter in a throwaway pod, not
  by triggering the CronJob.** A manual run writes a real backup and
  consumes one of the retained copies.
- **To retire one of two Helm releases that share objects without a
  Helm uninstall:** annotate its HelmRelease
  `kustomize.toolkit.fluxcd.io/prune: disabled` (in git), remove the
  Kustomization that manages it, then `flux suspend` the HelmRelease, patch
  `metadata.finalizers` to null and **read it back before deleting**, delete
  the HelmRelease, and delete its `sh.helm.release.v1.<name>.vN` secrets.
  Verified here: the controller log showed the Kustomization garbage
  collected and the event `HelmRelease/... skipped`, and the shared
  Deployment kept its UID. That Helm uninstall would have deleted the
  shared objects is from understanding of Helm, not tested.
- **`git commit` without `-a` leaves edits behind, and a local render of
  the working tree will still pass.** Validate what was committed, in a
  clean worktree, the way CI does. `kubernetes/apps` has no
  `kustomization.yaml`, so plain `kustomize build` is not the same: use
  `flux build kustomization cluster-apps --path ./kubernetes/apps
  --kustomization-file ./kubernetes/flux/apps.yaml --dry-run`.
- **Flux reacts to a merge within seconds (the webhook receiver), so a
  "before" snapshot taken after the merge may already be post-event.**
  Capture baselines or exports before the merge, and use the
  kustomize-controller log and events for the real sequence.
- **Pi-hole FTL 6.8 answers 404 at `/`** (it was 403 before) because `/`
  honours `webserver.serve_all=false`. The ingress check reads 404 as a
  broken route, so confirm against the web LB directly before concluding
  anything; the fix is the ingress annotation
  `nginx.ingress.kubernetes.io/app-root: /admin/`.
- **Pre-test a DNS-critical image in a throwaway pod before merging**: the
  new image, the chart's exact env and securityContext, a scratch volume,
  no Service labels, and a copy of the real database. It cannot reproduce
  the real volume's permissions, so say so and check those live.
- **Do not save a live HelmRelease's values to a scratch file.** The
  in-cluster spec is already substituted and can hold secrets (the Pi-hole
  admin password was one). Render from the repo, or delete the file
  immediately.

## Health pass

Run before and after the merges (`weekly-renovate-review.sh health`):
all Kustomizations and HelmReleases Ready, no charts floating on `*`,
Talos patches match the live config (one skipped as not idempotent), no
Deployment rollout churn, all 14 internal ingresses reachable. The only
unready pod, before and after, was the leftover `Error` pod above. Pod
count went 73 → 72: every rolled workload (immich server and machine
learning, grafana, the prometheus operator, cilium agent/envoy/operator/
hubble-relay, both cloudflared pods) was a one-for-one replacement, and
the missing one was a completed `postgres-infra-local` incremental
backup pod that aged out.

The same pass was run again after the Keycloak and Pi-hole upgrades and
again after the snapshot-controller retirement: all Kustomizations and
HelmReleases Ready, no rollout churn, and the only unready pod still the
leftover `Error` pod. The Pi-hole pass is where the `pihole.gs-farm.net`
404 showed up (13 of 14 reachable until #1019); after #1019 it was 14 of
14. Helm's view of `storage` now lists `csi-driver-nfs`,
`local-path-provisioner` and `volsync`, with no `snapshot-controller`.
