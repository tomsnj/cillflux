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

Update: all four remaining PRs were reviewed and merged later the same
day, after reading each changelog for breaking changes:
- #950 (kube-prometheus-stack chart v88→v89, major) — the only
  substantive change behind the major bump was an embedded `grafana`
  subchart going v12→v13; this cluster runs `grafana.enabled: false`
  (Grafana is deployed as its own separate app), so that breaking
  change was inert. Merged clean.
- #951 (`actions/checkout` v4→v7) and #952 (`actions/github-script`
  v7→v9) — both majors, CI-only workflow with no advanced options/API
  usage touching either package's documented breaking changes. Merged
  clean.
- #949 (flux2-only bump) was **not** a strict subset of #948 as first
  assumed — it carried ~100+ `app.kubernetes.io/version` label updates
  on `gotk-components.yaml` that #948 never touched. Those labels are
  on the flux controllers' own pod templates, so applying them forced
  a real rolling restart of source-controller/kustomize-controller/
  helm-controller — briefly causing "no route to host" errors on
  dependent Kustomizations mid-restart. Fully self-healing (confirmed
  settled ~90s later); worth remembering that a "cosmetic label" diff
  to `gotk-components.yaml` isn't actually inert.

Renovate queue was fully empty after this.

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

## New-device gotcha: Keycloak admin console unreachable from a new Mac

Tom's MacBook Pro (new to this network) couldn't load
`https://auth-console.gs-farm.net`, while his MacBook Air (already
configured) worked fine. Root cause was **not** Keycloak, DNS, or the
network — it took a long troubleshooting chain to rule out:

- Confirmed clean at every layer checked: DNS resolution (both `dig`
  direct-to-Pi-hole and `dscacheutil`, which is what apps actually
  use — `dig` alone is not sufficient, it bypasses `/etc/hosts` and
  the normal resolver cache entirely), ARP/L2 connectivity, TCP
  connect + TLS handshake + valid Let's Encrypt cert + correct
  Keycloak 302 response (verified with `curl` straight to the LB IP).
- `ping`ing the LB IP (`10.0.10.1`) failing with ICMP redirects then
  "Destination Host Unreachable" is **expected and not a real
  problem** — Cilium's L2 announcement only load-balances TCP/UDP
  traffic matching an actual Service port; raw ICMP falls through to
  the node's real kernel routing table, which has no route for a
  virtual/announced LB IP. Don't chase `ping` failures to a Cilium
  L2-announced IP as if they mean something — test with `curl`/`nc`
  against the real port instead.
- **Actual root cause**: macOS's Local Network privacy permission
  (System Settings → Privacy & Security → Local Network) was off for
  Brave on this not-yet-configured Mac. Terminal already had it
  (hence `curl`/`ping`/`dig` all working fine), but Brave didn't, so
  every connection attempt from Brave to a private IP
  (`10.0.10.0/16`) failed with `ERR_ADDRESS_UNREACHABLE` — a socket
  level failure that looks identical to a real network/routing
  problem. Toggling it on for Brave fixed it immediately.
- **For next time**: on any new Mac or freshly (re)installed browser
  on this network, check Local Network permission for that browser
  *before* spending time on DNS/routing/VLAN theories — this is a
  five-second check that would have shortcut most of this session's
  troubleshooting.
