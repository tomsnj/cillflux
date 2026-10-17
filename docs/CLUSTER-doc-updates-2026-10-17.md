# Cluster Doc Update — 2026-10-17

Weekly Renovate review: six merges, five queued. One queued PR (#1012,
snapshot-controller) exposed a standing conflict between two Helm
releases that both deploy the same Deployment, and would very likely
have failed the same way csi-driver-nfs did on 10-10. Also today: the
infra-local backup alerts landed, the Forgejo backup repo was sized, a
`BackupJobFailed` for `laptop-win` came and went (see the 10-14 file's
addendum), and leftover branches were cleaned up. No outage was
observed at any point.

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

**Queued for Tom:**

- **#1012 snapshot-controller chart 5.3.0 → 5.4.0.** Not safe to merge as
  is; see the next section.
- **#1014 Pi-hole 2026.10.0.** Fixes 17 security advisories (including a
  DNS-reachable DoS), but Core v6.5 migrates `gravity.db` to schema
  version 21 automatically, moves the `listsCache` directory, and removes
  the `arpflush` command. It is household DNS. Recommend merging, after a
  fresh Volsync copy of the Pi-hole volume.
- **#1006 Keycloak 26.8.1.** Patch, but a guarded path. It fixes at least
  twelve CVEs, including a cross-realm read/write and a 2FA enforcement
  bypass, on an internet-facing Keycloak with five realms. Recommend
  approving soon.
- **#1010 app-template 5.2.1 → 5.3.0.** Touches keycloak, minio,
  vaultwarden and cloudflared, so guarded. Rendered all four at both
  versions against live values: the only difference is two selector
  labels listed in a different order. Nothing rolls. Recommend approving.
- **#1013 grafana chart 14.0.1 (major).** The new values schema accepts
  the live values, and the chart's `appVersion` is still 13.2.4, so it
  is a chart-level change only. Low risk. Renovate will rebase it onto
  the 13.7.0 merged today.

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

### Decision needed

Pick one owner. The cleaner option is to keep csi-driver-nfs's
`externalSnapshotter` and remove the piraeus `snapshot-controller`
HelmRelease (and its ServiceMonitor and CRDs would then need an owner
check before pruning). Not done; #1012 is left open. Check which
HelmReleases `dependsOn` it before removing anything.

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
  Postgres/PGO gotchas in `CLAUDE.md`) merged.
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
- **#1012, #1014, #1006, #1010, #1013** — waiting on decisions above.
- **harbor/woodpecker cleanup** — still on the to-do list in `CLUSTER.md`.
  Best done after #1006 merges and settles, as its own change, not
  bundled with the Keycloak upgrade.

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
