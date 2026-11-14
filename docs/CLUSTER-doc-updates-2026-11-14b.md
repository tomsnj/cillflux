# Cluster Doc Update — 2026-11-14 (b)

Weekly Renovate review, run in full, then the queued "Needs Tom" PRs taken
one at a time on Tom's instruction. Eleven PRs were open at the start of the
sweep (#1057–#1067). All eleven are now merged. No `--force` merges were
used. The one major bump (#1057) was merged by hand, pinned to the reviewed
head, as CLAUDE.md prescribes.

Merged on `main` (squash, each merge pinned to the reviewed head):

| PR | Change | Notes |
|---|---|---|
| #1058 | prometheus-config-reloader v0.95.2 (Alloy sidecar) | patch; release notes empty |
| #1059 | coredns chart 1.50.2 → 1.50.7 | patch; 1.50.5 starts probes without delay (intentional) |
| #1060 | grafana chart 14.4.0 → 14.4.1 | patch; app 13.3.0 → 13.3.1; Grafana pod rolled once |
| #1062 | reloader chart 2.2.19 → 2.2.20 | patch; app v1.4.23 → v1.4.24 |
| #1063 | cloudflared 2026.10.7 → 2026.11.0 | no breaking changes in RELEASE_NOTES |
| #1065 | immich-server v3.4.0 → v3.4.1 | bug fixes and shared-link perf only |
| #1064 | Pi-hole image → 2026.11.0 | Tom's instruction; FTL 6.9 behaviour changes reviewed (see Pi-hole) |
| #1061 | pihole chart 2.2.1 → 2.2.2 | Tom's instruction; same HelmRelease as #1064 |
| #1066 | alloy chart 1.15.0 → 1.16.0 | Tom's instruction; app v1.21.3 → v1.22.0 (breaking entries, see Alloy) |
| #1067 | loki chart 7.5.0 → 7.6.0 | Tom's instruction; release notes empty (see Loki) |
| #1057 | kube-prometheus-stack chart 92.22.0 → 93.3.0 | **major**; Tom's instruction; merged pinned to `56c32d7c8` (see below) |

Not merged: none.

## Pi-hole (#1064, #1061)

Pi-hole runs in namespace `pihole` (the Kustomization's `targetNamespace`),
not `network`. The HelmRelease is `pihole/pihole`.

- Image is now `docker.io/pihole/pihole:2026.11.0`. Chart is `pihole@2.2.2`.
- Pre-merge DNS baseline via `10.0.10.6`: `google.com` answered, and
  `gs-farm.net` answered `10.0.10.1` (wildcard). Post-merge, both answered
  the same way after each merge.
- FTL logs showed zero error lines after each rollout.
- Ingress `/admin/` returns 308 (HTTP→HTTPS redirect), not 404.
- FTL 6.9 "behaviour changes" reviewed. This repo sets no `webserver.acl`.
  Regex lower bounds (`{,n}`) and API session listing (403 for CLI/app
  sessions without `app_sudo`) were not exercised by anything here.

## Alloy (#1066)

Alloy v1.22.0 carries a BREAKING CHANGES list: `loki.enrich` arguments,
`otelcol.receiver.kafka` / `otelcol.exporter.kafka`, and
`database_observability` defaults. None of those components appear in
`kubernetes/apps/observability/alloy/`, which was grepped before merging.

- Post-merge: `docker.io/grafana/alloy:v1.22.0`, zero `error`/`warn` lines.
- NanoStation syslog still arriving through `alloy-syslog` (10.0.10.7:514/udp):
  12 lines in the 2 h after the merge.

## Loki (#1067)

Release notes for `helm-loki-7.6.0` are empty. The Loki HelmRelease pulls
from the `grafana` HelmRepository, and that repo's Loki chart README says
it is maintained for Grafana Enterprise Logs only. OSS users are pointed to
`grafana-community`. Not a blocker for this bump, but a separate migration
item.

Pre-merge render check (`helm template` of 7.5.0 and 7.6.0 against live
values from `spec.values`): the only change was `loki-canary` 3.6.16 →
3.6.18. Post-merge `loki-0` was not restarted (still 43 days old, still
`loki:3.6.11`). The NanoStation ruler still reports both rules `ok`.

## kube-prometheus-stack v93 (#1057, major)

Merged by hand, pinned to the reviewed head: `gh pr merge 1057 --squash
--match-head-commit 56c32d7c8…`. Merge commit `362b2acd`.

**Pre-merge checks**

- Render of 92.22.0 vs 93.3.0 against live values from
  `kube-prometheus-stack-values` (`values.yaml`): 658 changed lines, no
  selector or label-selector changes. Kinds and names unchanged. Ten
  `monitoring.coreos.com` CRDs updated (schema and descriptions), which
  `crds: CreateReplace` handles.
- Operator v0.94.2 → v0.95.2. Alertmanager v0.34.2 → v0.35.0.
  Prometheus image unchanged in the render.
- Alertmanager 0.35.0 breaking changes checked: `--enable-feature=auto-gomemlimit`
  (removed) and `eventrecorder` outputs (now require `name`). Neither is
  used in this repo.
- Probe `timeoutSeconds` on the operator 1s → 5s.

**Baseline (before merge)**

- Prometheus targets 33/33 up; rules 258/258 `ok`; alerts: `Watchdog` firing,
  `BackupMetricsAbsent` pending.

**Post-merge**

- HelmRelease `Ready`, `Helm upgrade succeeded for release
  observability/kube-prometheus-stack.v437 with chart kube-prometheus-stack@93.3.0`.
- Prometheus `v3.16.0-distroless`, Alertmanager `v0.35.0`. All pods ready.
- Targets 33/33 up. Rules 258/258 `ok` once the
  `kube-apiserver-availability.rules` group completed its first evaluation
  after the Prometheus restart. Until that first evaluation, 16 rules in
  that group were `unknown` with a zero `lastEvaluation`. The group's
  interval is 180 s. I didn't time the gap.
- `Watchdog` still routes to `null` (checked via Alertmanager
  `/api/v2/alerts?inhibited=true`).
- `KubeContainerWaiting` pending ×2 at the last check, from the rollout.

**Pre-existing, not caused by this merge**

- The `prometheus-kube-prometheus-stack-0` pod has 72 container restarts
  over 7 days. The most recent was a clean, graceful stop
  (`See you next time!`) 36 minutes before the merge. Cause not
  investigated.

## Renovate queue

After this sweep no Renovate PRs are open for review.

## Follow-ups

- Loki: move from the `grafana` (Enterprise) chart to `grafana-community`
  for OSS. Plan a render check before switching.
- Prometheus: investigate the 72 container restarts (check previous
  container logs and the probe definitions) before the next operator bump.
- Watch `KubeContainerWaiting` clear after the rollout.
