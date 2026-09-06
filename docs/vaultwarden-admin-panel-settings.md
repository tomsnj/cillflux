# Vaultwarden Admin Panel settings snapshot

Vaultwarden persists anything ever changed via its Admin Panel
(`https://kumar.gs-farm.net/admin` → Settings) to `config.json` on its
PVC, and that **overrides the matching HelmRelease env var from then
on** — see the "Known gotchas" entry in `CLAUDE.md`. That means these
settings live outside GitOps entirely; if the PVC were ever lost and
had to be recreated from scratch, this file is the reference for
putting the Admin Panel back the way it was, not something Flux can
restore on its own.

**This is a point-in-time snapshot (2026-09-06). Re-run the capture
command below and update this file whenever Admin Panel settings
change** — it will silently drift out of date otherwise.

## Capture command

Pulls every `config.json` key except the three real secrets (which
live in `vw-secret` / the Keycloak client, not here):

```bash
POD=$(kubectl get pods -n vaultwarden -l app.kubernetes.io/name=vaultwarden -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n vaultwarden "$POD" -- sh -c \
  "grep -oE '\"[a-z_0-9]+\": ?[^,}]*' /data/config.json" \
  | grep -vE '"admin_token"|"smtp_password"|"sso_client_secret"'
```

## Settings (as of 2026-09-06)

### Core / domain
```
domain: https://kumar.gs-farm.net
```

### Signups & account management
```
signups_allowed: true
signups_verify: false
signups_verify_resend_time: 3600
signups_verify_resend_limit: 6
invitations_allowed: true
invitation_org_name: Vaultwarden
emergency_access_allowed: true
email_change_allowed: true
password_hints_allowed: true
show_password_hint: false
sends_allowed: true
increase_note_size_limit: false
```

### Password / crypto
```
password_iterations: 600000
```

### SSO (Keycloak) — see CLUSTER-doc-updates-2026-09-06.md for how this was set up
```
sso_enabled: true
sso_only: false                          # local login stays available as fallback
sso_client_id: vaultwarden
sso_authority: https://elvis.gs-farm.net/realms/vaultwarden
sso_scopes: email profile offline_access  # offline_access required for refresh tokens
sso_pkce: true
sso_callback_path: https://kumar.gs-farm.net/identity/connect/oidc-signin
sso_signups_match_email: true
sso_allow_unknown_email_verification: false
sso_auth_only_not_session: false
sso_client_cache_expiration: 0
sso_debug_tokens: false
# sso_client_secret lives in vw-secret (SOPS-encrypted) — Keycloak
# Admin Console → vaultwarden realm → Clients → vaultwarden →
# Credentials tab is the source of truth if it needs rotating.
```

### 2FA
```
_enable_yubico: true
_enable_duo: true
_enable_email_2fa: false
disable_2fa_remember: false
authenticator_disable_time_drift: false
require_device_email: false
email_token_size: 6
email_expiration_time: 600
email_attempts_limit: 3
email_2fa_enforce_on_verified_invite: false
email_2fa_auto_fallback: false
```

### SMTP
```
_enable_smtp: true
use_sendmail: false
smtp_host: smtp.gmail.com
smtp_security: starttls
smtp_port: 587
smtp_from: tfs05jhu@gmail.com
smtp_from_name: Vaultwarden
smtp_username: tfs05jhu@gmail.com
smtp_timeout: 15
smtp_embed_images: true
smtp_accept_invalid_certs: false
smtp_accept_invalid_hostnames: false
# smtp_password lives in vw-secret (SOPS-encrypted)
```
Note: `smtp_from_name` here (`Vaultwarden`) differs from the
HelmRelease's `smtp.fromName` value (`Tom Steck`) — another instance
of the Admin Panel override winning over git. Not a functional
problem, just worth knowing which one is actually live.

### Icons / external requests
```
disable_icon_download: false
icon_redirect_code: 302
icon_cache_ttl: 2592000
icon_cache_negttl: 259200
icon_download_timeout: 10
http_request_block_non_global_ips: true
```

### Proxy / networking
```
ip_header: X-Real-IP
ip_header_trusted_proxies: local
dns_prefer_ipv6: false
```

### Misc
```
admin_session_lifetime: 20
log_timestamp_format: %Y-%m-%d %H:%M:%S.%3f
reload_templates: false
```

## Secrets NOT captured here (by design)

These live in `vw-secret` (SOPS-encrypted) or Keycloak's own admin
data — recreate from their actual source, not from a doc:
- `admin_token` — the Vaultwarden Admin Panel login token
- `smtp_password` — Gmail app password
- `sso_client_secret` — Keycloak `vaultwarden` client's Credentials tab
