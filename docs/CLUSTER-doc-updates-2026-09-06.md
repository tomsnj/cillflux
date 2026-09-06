# Cluster Doc Update — 2026-09-06

## Vaultwarden SSO (Keycloak) — enabled and working end-to-end

Turned on Keycloak SSO for Vaultwarden. It was already substantially
wired up back in March 2026 (env vars, a client secret, `SSO_ENABLED`
present in the HelmRelease) but left disabled — per Tom, because it
was never gotten to a state he trusted. Today's session found and
fixed four separate, stacked problems before it actually worked.

### Root causes, in the order they were found

1. **Wrong realm.** `SSO_AUTHORITY` was
   `https://elvis.gs-farm.net/realms/master` — Keycloak's own admin
   realm, not the actual `vaultwarden` realm the client lives in. This
   alone would have broken login regardless of anything else. Fixed
   in `helmrelease.yaml`; verified the correct realm's OIDC discovery
   endpoint (`/realms/vaultwarden/.well-known/openid-configuration`)
   responded correctly before flipping anything live.

2. **Stale client secret.** Rotated `SSO_CLIENT_SECRET` in
   `secret.sops.yaml` to the current value from the Keycloak
   `vaultwarden` client's Credentials tab, using
   `sops set <file> '["stringData"]["SSO_CLIENT_SECRET"]' '"<value>"'`
   — updates one field, re-encrypts, never decrypts the file to
   stdout or exposes the old/new value anywhere.

3. **`config.json` overrides HelmRelease env vars — bit us twice.**
   Vaultwarden persists any setting ever touched via its Admin Panel
   to `config.json` on the PVC, and that **completely overrides the
   corresponding environment variable** from then on (Vaultwarden
   logs a `[WARNING]` naming every overridden var on startup — easy to
   miss). Because someone used the Admin Panel back in March,
   `sso_enabled: false` was persisted there and our HelmRelease env
   var change had zero effect until Tom flipped it in the Admin Panel
   itself (Settings → SSO). Same thing happened again for
   `sso_scopes` (see below). **This is a durable gotcha, not a
   one-off** — any future Vaultwarden setting change needs to go
   through the Admin Panel if it's ever been touched there before, not
   just the HelmRelease. Check what's actually live with:
   `kubectl exec -n vaultwarden <pod> -- grep -o '"KEY":[^,]*' /data/config.json`
   (safe to check non-secret keys this way; skip `admin_token` /
   `sso_client_secret` and similar).

4. **Missing `offline_access` scope.** `SSO_SCOPES` was `"email
   profile"` — no `offline_access`. Without it, Keycloak's token
   response has no `refresh_token`, and Vaultwarden's client throws
   `No refresh token or API keys found` right after an otherwise-
   successful Keycloak login. Fixed in both `helmrelease.yaml` and
   (per point 3) the Admin Panel's SSO Scopes field, to
   `"email profile offline_access"`.

Verified Keycloak's client config directly rather than guessing,
using `kcadm.sh` from inside the Keycloak pod itself (confidential
client, standard flow enabled, `offline_access` assigned as an
optional scope, `fullScopeAllowed: true` — all correct):
```
PASS=$(kubectl get secret keycloak-admin-secret -n infrastructure -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n infrastructure deploy/keycloak -- sh -c \
  "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user admin --password '$PASS'"
# then: kcadm.sh get clients -r vaultwarden -q clientId=vaultwarden ...
```
This confirmed the actual browser-sent authorization request
(`scope=openid+email+profile+offline_access`) was correct too — the
gap really was purely `config.json`'s stale `sso_scopes`.

### Two things that looked like blockers but weren't

- **Brave (MacBook Pro) failed with `ERR_QUIC_PROTOCOL_ERROR` /
  `QUIC_NETWORK_IDLE_TIMEOUT`** hitting Vaultwarden's own
  `/identity/sso/prevalidate` endpoint — a transport-layer (HTTP/3
  over UDP) issue between that Mac and Cloudflare, unrelated to
  Keycloak/Vaultwarden config. Disabling QUIC in `brave://flags`
  didn't clean up fully (left stale connection state, needed a full
  flag reset + browser restart + cache clear to recover). **Switching
  to Safari sidestepped it entirely** and is the practical workaround
  if this recurs — no cluster-side fix applies here since the server
  side tested 100% healthy via `curl` throughout.
- **A `[SignalR] Failed to start the connection... WebSocket failed
  to connect` console error** appeared during testing. This is
  Vaultwarden's live-sync notification channel, separate from
  login/auth — it did not block the SSO login or vault unlock that
  followed in the same session. Not investigated further since it
  wasn't blocking; worth a look later if live sync (auto-refresh
  without manual reload) turns out not to work.

### Expected behavior, not a bug

After a successful SSO login, Vaultwarden/Bitwarden clients **always**
still prompt for the vault master password. SSO only proves identity;
the master password is used purely client-side to decrypt the vault
(zero-knowledge encryption — the server never sees it). Don't chase
this as a leftover SSO problem next time.

### Current state

- `SSO_ENABLED: true`, `SSO_ONLY` intentionally not set — local
  email/password login remains available as a fallback.
- Confirmed working end-to-end: Keycloak login → token exchange
  (`POST /identity/connect/token` → `200 OK`) → `GET /api/sync`
  (`200 OK`) → master password unlock → vault contents visible.
- Grafana and Forgejo are still not wired to Keycloak — no blocker,
  just not done.
