# Cluster Doc Update — 2026-11-07

Weekly Renovate review run in full, then the queued "Needs Tom" PRs taken
one at a time on Tom's instruction. Thirteen PRs were open at the start;
all thirteen were resolved. Flux itself moved to v2.10.0, and the local
`flux` CLI was brought to match.

Merged on `main` (squash, each merge pinned to the reviewed head):

| PR | Change | Notes |
|---|---|---|
| #1043 | cloudflared 2026.10.3 → 2026.10.7 | patch |
| #1044 | Pi-hole image 2026.10.0 → 2026.10.1 | superseded by #1055's digest pin |
| #1046 | immich-server v3.3.5 → v3.3.6 | head moved mid-run; re-read, merged on the new head |
| #1048 | reloader chart 2.2.18 → 2.2.19 | app v1.4.22 → v1.4.23 |
| #1050 | prometheus-config-reloader v0.94.2 → v0.95.1 | |
| #1052 | alloy chart 1.14.3 → 1.15.0 | app v1.21.2 → v1.21.3; new `distroless` flag, default off |
| #1051 | Flux v2.9.6 → v2.10.0 | guarded by "Needs Tom" criteria (see Flux below) |
| #1049 | kube-prometheus-stack 92.14.1 → 92.22.0 | Prometheus v3.15.1 → v3.16.0 |
| #1053 | CoreDNS chart 1.49.0 → 1.50.2 | |
| #1054 | Grafana chart 14.0.1 → 14.4.0 | app 13.2.4 → 13.3.0 |
| #1055 | Pi-hole chart 2.1.2 → 2.2.1 | adds a default NetworkPolicy |
| #1045 | Vaultwarden 1.37.4 → 1.37.5 | guarded path; merged on Tom's instruction |
| #1047 | Keycloak 26.8.1 → 26.8.2 | guarded path; merged on Tom's instruction |

Not merged: none. Every PR from the run is now merged.

## Flux v2.10.0

**Controllers.** `flux-manifests` moved to v2.10.0. source-controller and
kustomize-controller are v1.10.1, helm-controller v1.7.1,
notification-controller v1.10.0, image-reflector and image-automation
v1.3.0, and source-watcher v2.3.1. All eight are 1/1 with zero restarts.
The tuning args in `kubernetes/flux/config/flux.yaml` (`--concurrent=8`,
`--kube-api-qps`, `--kube-api-burst`, `--requeue-dependency`) are accepted.

**Breaking changes checked against this repo.** None apply: no
ImageRepository (so the FluxStorage tag-DB reset does not happen), no
Alert/Provider objects, no remote `kubeConfig`, no `serviceaccounts/token`
use. The three upstream NetworkPolicies (`allow-egress`,
`allow-scraping`, `allow-webhooks`) match the live `flux` inventory
exactly, so nothing was pruned.

**Transient.** For about two minutes after the restart, helm-controller
logged `no route to host` for artifact fetches from source-controller
(16 lines, all from the restart window). They stopped, and every
HelmRelease is Ready.

**Local CLI.** `flux` v2.10.0 installed at `~/.local/bin/flux`, verified
against the release checksum. It shadows the root-owned v2.8.3 at
`/usr/local/bin/flux`, which is still on disk. Removing it needs sudo.

## kube-prometheus-stack 92.22.0

**What the PR label hid.** The Renovate PR was labelled minor, and its
body listed kube-state-metrics "v9" and node-exporter "v5" as if they
were app majors. Both are chart-level majors. The images did not change
(kube-state-metrics v2.20.0, node-exporter v1.12.1). The real app change
is Prometheus v3.15.1 → v3.16.0. Alertmanager v0.34.1 → v0.34.2 is
breaking for CORS on `api/v2`, but Grafana calls Alertmanager server-side,
so the change does not reach it.

**Checks.**

- Rendered with the live values from `kube-prometheus-stack-values`, using
  the real release name `kube-prometheus-stack`. (A render with the name
  `kps` shows spurious label diffs.)
- Selectors on every Deployment, DaemonSet and ServiceMonitor are
  identical between versions, so the immutable-selector trap does not
  apply.
- The CRDs are byte-identical.

**After.** 33 of 33 active targets up. 258 of 258 rules `ok`. Watchdog
still routes to `null`, and the InfoInhibitor route is intact.

Right after the reload, 16 rules in `kube-apiserver-availability.rules`
reported `unknown`. The group interval is 180s, and the first evaluation
completed at 14:05:35Z, after which they were all `ok`.

## CoreDNS 1.50.2

Our values hit none of the 1.50 template changes: the server port is
explicit, `service.ipFamilies` is unset, and the ServiceMonitor is off.
The rendered Corefile is unchanged. The chart does stamp `helm.sh/chart`
into the pod template, though, so the upgrade restarted the single DNS
pod. The rollout used `maxSurge: 25%`, so the new pod came up before the
old one stopped.

**After.** `coredns-7bcf67b9bc-smshc` → `coredns-6fdb4b7569-2wfjg`. The
`kube-dns` endpoint points at the new pod. A test pod resolved
`kubernetes.default.svc.cluster.local` and public names through the
upstream. CoreDNS logs show normal query traffic with no errors.

## Grafana chart 14.4.0 (app 13.3.0)

The chart's own notes said minor, with one pod-label change. The app bump
(13.2.4 → 13.3.0) appeared only in `appVersion`, so check `appVersion` on
every Grafana chart bump.

The 13.3.0 breaking items are a plugin runtime API change, a `[marketplace]`
→ `[plugins_marketplace]` rename, and the Alpine image losing bash. None
applies: our values have no marketplace section, no plugins and no init
containers, and the image is distroless. The render diff against live
values contained only version labels, the image, and the sidecar (2.14.1
→ 2.14.3). Selectors are unchanged.

The database lives on the 10Gi `grafana` PVC, so the 13.3.0 startup
migration ran against live data. Going back to 13.2.4 would mean restoring
the database, not just reverting the chart.

**After.** `/api/health` reports `database: ok`, version 13.3.0. The
migrations and both sidecars logged no errors. Logins to Grafana and
Forgejo were verified by Tom. The datasource API was not probed directly
(it needs admin credentials).

## Pi-hole chart 2.2.1

**What changed.** The chart adds a default NetworkPolicy, which allows
only TCP/UDP 53 and TCP 80 with no source restriction. It also drops all
capabilities on the main container and re-adds a shorter set. It adds a
`chown -R pihole:pihole /etc/pihole` step to the gravity init container.
It pins the image by digest.

**Digest mismatch.** The chart pins `docker.io/pihole/pihole:2026.10.1@sha256:d34134…`.
The running pod had `sha256:30f803…`, and the registry tag `2026.10.1`
currently resolves to `30f803…`. Both are indexes for the same tag, but
their amd64 children differ (`d8d848…` in the chart's build, `1c7aba…` in
the running one). The upgrade therefore also swapped the image bytes.
Worth knowing if a "same version" image behaves differently.

**Pre-test.** A throwaway pod in the `pihole` namespace ran the pinned
image with the chart's exact main-container security context, an emptyDir
for `/etc/pihole`, and no Service labels. FTL started, applied the
capabilities, and answered DNS from a separate pod. The
`default` namespace could not be used: it enforces baseline PodSecurity,
which rejects `NET_RAW` and `SYS_NICE`. The `pihole` namespace is
privileged.

**NFS chown.** The new init step runs as root on the NFS-backed PVC
`gsks0`. On a throwaway PVC from the same class, the real chown step ran
inside the pinned image and returned RC=0. The live files are already
owned by 1000:1000, so the step changes nothing on existing data. The
test PVC and pods were deleted afterwards.

**Live capability warnings.** FTL 6.8 logs `CAP_NET_BIND_SERVICE`,
`CAP_SYS_NICE`, `CAP_CHOWN` and `CAP_SYS_TIME` "not available" both before
and after this change. This was confirmed against the old pod's logs. It
is informational, and port 53 still binds.

**Rollout.** The strategy is `Recreate`, so DNS was down for the pod
swap. The new pod `pihole-685d76576c-khkn7` has been Running since
15:41:22Z with zero restarts. `dig @10.0.10.6` resolves, the admin ingress
returns 302, and `10.0.10.5/` returns 404 as expected for FTL 6.8.

## Vaultwarden 1.37.5

Security release (two advisories: website icons, emergency access). The
web vault moves to 2026.10.1. The HelmRelease diff is the image tag and
digest only.

The new config validation was checked against live values: `smtp_timeout`
15, `email_attempts_limit` 3, and the rate-limit, purge and retention
settings are unset. The `config.json` overrides of `DOMAIN`, `ADMIN_TOKEN`
and the SSO variables are unchanged. Volsync had completed successful
backups of `vaultwarden-data` and `vaultwarden-config` at 03:00Z that
morning.

**After.** Running 1.37.5. Startup logs are clean apart from the existing
override warning. `/alive` returns 200 internally and externally.
`/data` is intact. Tom verified a login.

## Keycloak 26.8.2

Security release with a long list of CVE fixes in the release notes
(including a login-page XSS and several SAML endpoint DoS issues). The
HelmRelease diff is the image tag only.

**Migration.** On first start, Keycloak migrated the realms `master`,
`grafana`, `vaultwarden`, `forgejo` and `immich` to 26.8.2. This is a
one-way schema/model change. The restore point is the pgBackRest diff
backup of `postgres-infra-local` that completed at 15:20Z that day.

**After.** Keycloak is 1/1 Running. The logs show no errors. Discovery
for the vaultwarden, grafana and forgejo realms returns 200 internally
with the issuer `https://elvis.gs-farm.net/realms/<name>` and JWKS. The
vaultwarden and grafana realms also answer externally. Tom verified
Grafana and Forgejo logins. `/health/ready` is not exposed by the
ingress (it lives on the management port 9000), so readiness was
confirmed through the pod's probe.

## Small app and chart bumps

- **cloudflared** 2026.10.3 → 2026.10.7. The upstream `RELEASE_NOTES`
  file (the GitHub release body is only checksums) lists no breaking
  changes. External ingress answered 200 after the rollout.
- **reloader** chart 2.2.18 → 2.2.19 (app v1.4.23).
- **Alloy** chart 1.14.3 → 1.15.0 (app v1.21.3). The new `distroless` option
  defaults to off.
- **immich-server** v3.3.6. Disables onnxruntime telemetry in the ML
  container.

## Checks (all merges)

- Cluster pod count was 71 before and after every merge, and every pod
  was Ready at each check.
- All Kustomizations and HelmReleases are Ready.
- `scripts/weekly-renovate-review.sh ingress-check`: all 14 internal
  ingresses reachable.
- After the Vaultwarden merge, `forgejo` and `immich` briefly showed
  `dependency 'flux-system/postgres-*' revision is not up to date`. This
  cleared within a minute as the postgres Kustomizations caught up to the
  new revision.

## Takeaways

- **Read the chart's app version, not just the PR label.** Grafana 14.4.0
  moved the app from 13.2.4 to 13.3.0. Kube-prometheus-stack's
  "kube-state-metrics v9" was a chart major with an unchanged image. Run
  `helm pull` on both versions and compare `appVersion`, and check
  `image:` in the rendered output.
- **A chart can pin a different build of the same image tag.** Compare the
  digest in the rendered manifest with the registry's current digest for
  the tag before merging. The Pi-hole chart's digest differs from the
  running one.
- **Render with the live release name.** kube-prometheus-stack's labels
  depend on the release name. Use the name the HelmRelease actually has.
- **Pre-test a DNS-critical image in a privileged namespace.** The
  `default` namespace enforces baseline PodSecurity and rejects
  `NET_RAW` and `SYS_NICE`. Use the namespace the workload really runs in.
- **`gh pr merge --match-head-commit` needs the full 40-character SHA.**
  The short SHA fails with a GraphQL error (before any merge happens).
- **Keycloak migrates every realm on startup.** Take a database backup
  first and confirm it is recent. Downgrading means restoring the
  database.
- **`pgrep -f` / `pkill -f` with a pattern that appears in your own
  command line kills the shell** (exit 144). Match on `pgrep -x kubectl`
  and check `/proc/<pid>/cmdline` instead.
- **A Renovate patch bump can be a security release.** Vaultwarden
  1.37.5 and Keycloak 26.8.2 both fix advisories, so keep them on the
  quicker path, but still verify logins and realms afterwards.
