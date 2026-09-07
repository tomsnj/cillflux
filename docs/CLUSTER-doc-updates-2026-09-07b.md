# Cluster Doc Update — 2026-09-07 (evening)

## Forgejo hostname unification

Forgejo now uses a single hostname (`susan.gs-farm.net`) for both
internal and external access, matching the split-horizon pattern
already used by Keycloak (`elvis`) and Vaultwarden (`kumar`).

- `kubernetes/apps/forgejo/app/ingress-internal.yaml`: host changed
  `susan-int.gs-farm.net` → `susan.gs-farm.net`. `susan-int.gs-farm.net`
  is fully retired (no Ingress listens for it — confirmed 404).
- New TLS cert issued automatically by cert-manager for the internal
  Ingress's new hostname; verified valid (`CN=susan.gs-farm.net`,
  matching SAN) via `openssl s_client` against the internal LB IP.
- `app.ini`'s live `ROOT_URL`/`DOMAIN` confirmed matching
  (`susan.gs-farm.net`), so the canonical-URL mismatch banner no
  longer triggers when browsing internally.
- Commit `87f527b9` (config), `b299459b` (docs).

## Forgejo SSO (Keycloak) — enabled and working, native `gitea.oauth`

Wired Forgejo to Keycloak, following the pattern proven with
Vaultwarden and Grafana, but this time using the Forgejo Helm chart's
own declarative `gitea.oauth` values block (available since the
17.x chart line the cluster upgraded to earlier today) instead of
the admin-panel-click approach the other two apps needed.

### What was set up

- New Keycloak realm `forgejo` and confidential client `forgejo`
  (standard flow, redirect URI
  `https://susan.gs-farm.net/user/oauth2/Keycloak/callback`, web
  origin `https://susan.gs-farm.net`). Created live via `kcadm.sh` —
  not tracked in git, same as `vaultwarden`/`grafana`.
- `kubernetes/apps/forgejo/app/helmrelease.yaml`: added a
  `gitea.oauth` entry — `name: Keycloak`, `provider: openidConnect`,
  `autoDiscoverUrl` pointed at the `forgejo` realm's
  `.well-known/openid-configuration` on `elvis.gs-farm.net`,
  `scopes: "openid profile email"`, `existingSecret:
  forgejo-oauth-secret`. No `admin-group`/`restricted-group` claim
  mapping — every SSO login lands as a normal (non-admin) user,
  matching the flat-role approach used for Grafana.
- New `forgejo-oauth-secret` (SOPS-encrypted,
  `kubernetes/apps/forgejo/app/oauth-secret.sops.yaml`) holding the
  client id/secret under keys `key`/`secret` — names the chart
  hardcodes (same convention as `gitea.admin.existingSecret`'s
  `username`/`password` keys).
- Local login form left enabled — `DISABLE_REGISTRATION` only blocks
  self-registration, it doesn't touch an already-configured OAuth
  source — so `fjmaster` (local admin) keeps working as a fallback.
- Commit `bfb229c9`.

### How this differs from Vaultwarden/Grafana

The chart's init container (`configure-gitea`) runs `forgejo admin
auth add-oauth` on first install and `update-oauth` on every
subsequent reconcile — fully idempotent and declarative, no manual
admin-panel client setup needed on the Forgejo side at all. Verified
this rendering was correct with `helm template` against the real
chart and real values *before* touching the cluster (same
due-diligence habit used for the version-17 upgrade earlier today):
confirmed the exact `add-oauth`/`update-oauth` CLI flags generated,
and that `GITEA_OAUTH_KEY_0`/`GITEA_OAUTH_SECRET_0` env vars on the
main container pull from `forgejo-oauth-secret`'s `key`/`secret`
fields.

Post-deploy, confirmed live via the `configure-gitea` init container
logs (`No oauth configuration found with name 'Keycloak'. Installing
it now... ...installed.`), `forgejo admin auth list --vertical-bars`
showing `Keycloak | OAuth2 | true`, the OIDC discovery doc resolving
from inside the cluster, and the login page rendering a working
"Sign in with Keycloak" button pointed at the right callback path.

### Gotcha avoided this time: empty realm

Learned from the Grafana incident (`CLUSTER-doc-updates-2026-09-07.md`)
that a new Keycloak realm starts with zero users regardless of other
realms. This time, created the `stecktf` user directly in the new
`forgejo` realm *before* ever testing login, with a one-time
temporary password (forced change on first login) — avoiding a repeat
of the Grafana debugging cycle.

### Correction: Forgejo *does* offer account linking by email

**This section originally said the wrong thing** — written before
Tom actually completed the login flow. Corrected after testing:

On first Keycloak login, Forgejo detected that the `stecktf`
Keycloak identity's email (`tfs05jhu@gmail.com`) matched the existing
local `fjmaster` admin account's email, and prompted an account-link
step (enter the existing local account's password to confirm
ownership) instead of silently creating a duplicate user. Tom
completed this with `fjmaster`'s local password — `fjmaster` now logs
in via either Keycloak SSO or the local password, still the sole
admin either way. No separate `stecktf` account was created; the
"reconcile two identities later" question this section originally
raised doesn't apply and was removed from `CLUSTER.md`.

### Current SSO state across the cluster

- Vaultwarden: live since 2026-09-06.
- Grafana: live since 2026-09-07 (morning).
- Forgejo: live since 2026-09-07 (evening) — the last of the three
  originally planned.
