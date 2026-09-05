# Cluster Doc Update — 2026-09-05

## Weekly Renovate Review — script now exists

Added `scripts/weekly-renovate-review.sh`, the entry point for the
"Weekly Renovate Review" workflow documented in `CLAUDE.md`. It
automates the mechanical parts (list open Renovate PRs, check
update-type label / CI status / guarded-path / CRD / HelmRelease
chart-major-bump criteria, merge, post-merge pod-health poll, flux
kustomization health) and leaves the changelog-judgment call to the
reviewer.

First live run surfaced three bugs, since fixed (commit `23970138`):

- `flux reconcile source git cillflux` was wrong — the GitRepository
  resource is actually named `flux-system`. Also corrected in
  `CLAUDE.md`.
- `gh pr view`'s `mergeStateStatus` is computed asynchronously and can
  come back `UNKNOWN` on a cold request even for a clean PR — this
  made every open PR fail the mechanical check on the first pass.
  `fetch_pr` now retries a few times before accepting the value.
- The post-merge pod-health check slept a flat 5s before snapshotting
  — nowhere near enough for a Helm upgrade to even start rolling.
  Caught live on PR #946 (kube-prometheus-stack), which was still
  mid-rollout when the old code would have already reported success.
  Now polls for up to 3 minutes, stopping early once healthy or once
  the unhealthy set stops changing.

## This run's results

Merged: #945 (cloudflared patch), #946 (kube-prometheus-stack chart
patch), #948 (Flux component group patch — flux2, source/kustomize/
helm/notification-controller), #947 (keycloak image patch, see below).
All four verified against the live cluster post-merge — HelmReleases
`Ready`, correct image/chart versions running, all 35 kustomizations
`Ready`, no unhealthy pods cluster-wide.

Still queued, needs Tom: #950 (kube-prometheus-stack chart v88→v89,
major), #951 (`actions/checkout` v4→v7, major), #952
(`actions/github-script` v7→v9, major). #949 (flux2-only bump) turned
out to be a strict subset of #948's diff — left open for Renovate to
auto-close/rebase to empty rather than closing it manually.

## Keycloak (#947) — SSO status, corrected

`CLUSTER.md`'s "Current State & Open Issues" section (last updated
2026-06-06) still describes Keycloak as "currently crashing, blocked
on PGO/Patroni stability" and Vaultwarden SSO as "temporarily
disabled" pending that fix. As of today that's stale on the technical
cause, though the practical state is unchanged:

- Keycloak's HelmRelease reconciles cleanly and the pod is healthy
  and running (verified live during this review, both before and
  after the 26.7.3 patch merge) — it is not currently crashing.
- SSO is still not wired up anywhere, but not because of a Postgres/
  Patroni blocker: per Tom, Keycloak was never gotten to a state that
  felt reliable both internally and externally, so it was never
  turned on. Grafana and Forgejo were never configured to use it
  either. Vaultwarden's realm/client exists (`post_logout_redirect_uri`
  correctly set to `https://kumar.gs-farm.net`, not looped back
  through Keycloak) but SSO is not enabled on the Vaultwarden side.
- Practical effect for future Renovate reviews: a Keycloak PR's
  auto-merge guardrail (per `CLAUDE.md`, `keycloak/` is a guarded
  path — always "needs Tom") still applies, but the actual blast
  radius of a Keycloak change is currently zero live SSO integrations
  to break.
- `CLUSTER.md`'s High Priority / PGO-Patroni-Keycloak section should
  be refreshed next time someone's in there — it's describing a
  problem that may no longer be the current blocker to enabling SSO.
