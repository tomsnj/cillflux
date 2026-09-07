# Cluster Doc Update — 2026-09-07

## Grafana SSO (Keycloak) — enabled and working end-to-end

Wired Grafana to Keycloak SSO, following the pattern proven with
Vaultwarden (`CLUSTER-doc-updates-2026-09-06.md`).

### What was set up

- New Keycloak realm `grafana` and a confidential client `grafana` in
  it (standard flow, `fullScopeAllowed: true`, redirect URI
  `https://grafana.gs-farm.net/login/generic_oauth`, web origin
  `https://grafana.gs-farm.net`). Created live via `kcadm.sh` — not
  tracked in git, same as the existing `vaultwarden` realm, since
  Keycloak has no realm-import CRD wired up in this cluster yet.
- `kubernetes/apps/observability/grafana/app/helmrelease.yaml`:
  `grafana.ini`'s `[auth.generic_oauth]` block added — `enabled`,
  `client_id: grafana`, `scopes: "openid email profile"`, auth/token/
  userinfo URLs pointed at the `grafana` realm on
  `elvis.${SECRET_DOMAIN}`, `login_attribute_path: preferred_username`,
  a flat `role_attribute_path: "'Editor'"` (every SSO login gets
  Editor — no Keycloak group setup for now, per Tom's call), local
  login form left enabled (`disable_login_form` not set), and
  `auto_login: false` so the choice stays manual.
- New `grafana-oauth-secret` (SOPS-encrypted,
  `kubernetes/apps/observability/grafana/app/oauth-secret.sops.yaml`)
  holding the client secret, delivered to Grafana via
  `envValueFrom.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` — never inlined
  in `grafana.ini`.
- Commit `3f110c44`.

### One incident during setup: client secret briefly exposed, rotated

While building the SOPS secret file, a file-diff notification echoed
the plaintext client secret into the session transcript (the mechanism
that shows "here's what changed on disk" after an out-of-band edit).
The value was never committed in plaintext, but treating it as
compromised anyway: generated a fresh client secret in Keycloak
(`kcadm.sh create clients/<id>/client-secret`) and used `sops set` to
replace it in the encrypted file before ever committing — so the
secret that leaked into the transcript is not the one that ended up
in git or live on the cluster. No process change needed beyond this
one instance; noting it here so if the old secret value ever surfaces
anywhere, it's known-dead.

### Gotcha found: a new Keycloak realm has zero users

Confirmed the client and the OIDC handshake worked end-to-end
(`/login/generic_oauth` on Grafana → correct `302` to Keycloak →
Keycloak's `grafana` realm returns `200`), but Tom's login still
failed. Root cause: creating a new realm for an app's SSO client
creates a **separate, empty user store** — it doesn't matter that the
same person has a working account in `vaultwarden` or `master`; the
`grafana` realm had zero users (`kcadm.sh get users -r grafana` → `[]`).

Fix: created the user directly in the `grafana` realm
(`username: stecktf`, `email: tfs05jhu@gmail.com`, matching the
`vaultwarden` realm's user) with a one-time temporary password via
`kcadm.sh set-password ... --temporary`, so Keycloak forces a real
password to be set on first login without this session ever knowing
it. Confirmed via Grafana's own request logs after Tom logged in:
`uname=stecktf`, `userId=2`, and a `403` on `GET /api/teams/search`
(`accessErrorID=ACE5869102481`) — exactly the permission an Editor
(not Admin) correctly lacks, confirming the role mapping landed as
configured, not a bug.

**This will recur for Forgejo** (and anything else wired to its own
Keycloak realm going forward) unless remembered — added to `CLAUDE.md`
gotchas.

### Current state

- Vaultwarden SSO: live since 2026-09-06.
- Grafana SSO: live since today. `stecktf` confirmed logging in via
  Keycloak with `Editor` role, local admin/password login still
  available as fallback.
- Forgejo: not yet wired up — the only remaining item from the
  original Grafana/Forgejo SSO plan.
