#!/usr/bin/env bash
# create-alertmanager-smtp-secret.sh
#
# Creates the SOPS-encrypted secret holding the Gmail app password that
# Alertmanager uses to send alert mail.
#
# Run this yourself. It prompts for the password without echoing it, so
# the credential never appears in a terminal transcript, a shell history
# file, a process listing, or a Claude Code conversation.
#
#   ./scripts/create-alertmanager-smtp-secret.sh
#
# Get an app password at https://myaccount.google.com/apppasswords
# (a normal account password will not work once 2FA is on). Generate one
# dedicated to alerting rather than reusing Vaultwarden's, so revoking it
# later does not take out anything else.
#
# Re-run at any time to rotate: it overwrites the secret in place, and
# Flux pushes the new value out on its next reconcile.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/kubernetes/apps/observability/kube-prometheus-stack/app/secret.sops.yaml"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v sops >/dev/null 2>&1 || die "sops not found"
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
[[ -f "$SOPS_AGE_KEY_FILE" ]] || die "age key not found at $SOPS_AGE_KEY_FILE"
export SOPS_AGE_KEY_FILE

# The file is written in plaintext and then encrypted in place, because
# sops picks its recipients from the creation_rules path_regex in
# .sops.yaml and that only matches under kubernetes/. If anything fails
# between those two steps, remove the file rather than leave a plaintext
# credential sitting in the working tree.
cleanup_plaintext() {
  if [[ -f "$OUT" ]] && ! grep -q 'ENC\[' "$OUT" 2>/dev/null; then
    rm -f "$OUT"
    printf 'aborted: removed the unencrypted file at %s\n' "$OUT" >&2
  fi
}
trap cleanup_plaintext EXIT

printf 'Gmail app password for Alertmanager (input hidden).\n'
read -rsp 'Password: ' pw1; echo
read -rsp 'Again:    ' pw2; echo

# Google displays app passwords in groups of four; the spaces are
# presentation only and must not be sent to the SMTP server.
pw1="${pw1// /}"
pw2="${pw2// /}"

[[ -n "$pw1" ]]          || die "empty password"
[[ "$pw1" == "$pw2" ]]   || die "passwords did not match"
if [[ ${#pw1} -ne 16 ]]; then
  printf 'warning: got %d characters; Google app passwords are normally 16.\n' "${#pw1}" >&2
  read -rp 'Continue anyway? [y/N] ' ok
  [[ "$ok" == [yY] ]] || die "aborted"
fi

umask 077
cat > "$OUT" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-smtp
  namespace: observability
type: Opaque
stringData:
  # Mounted by alertmanagerSpec.secrets at
  #   /etc/alertmanager/secrets/alertmanager-smtp/password
  # and read via smtp_auth_password_file, so the credential is never in
  # the Alertmanager config itself.
  password: "$pw1"
EOF
unset pw1 pw2

sops --encrypt --in-place "$OUT"
grep -q 'ENC\[' "$OUT" || die "sops did not encrypt $OUT - refusing to continue"
grep -q 'password: ENC\[' "$OUT" || die "the password field is not encrypted - refusing to continue"

trap - EXIT
chmod 644 "$OUT"

enc_count=$(grep -c 'ENC\[' "$OUT")
printf '\nWrote encrypted secret: %s\n' "${OUT#"$REPO_ROOT"/}"
printf '  %s fields encrypted (the password plus SOPS metadata).\n' "$enc_count"
printf '  The password field is encrypted; the file is safe to commit.\n\n'
printf 'Next: commit it. Flux creates the secret in the observability namespace.\n'
