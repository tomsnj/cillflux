#!/usr/bin/env bash
# setup-gsfarmctl-dns.sh
#
# Gives gsfarmctl its own resolver so *.gs-farm.net works from the
# control host, WITHOUT making the control host depend on the cluster.
#
#   sudo bash scripts/setup-gsfarmctl-dns.sh
#
# Idempotent: safe to re-run. Pass --revert to undo.
#
# Why not just point /etc/resolv.conf at Pi-hole (10.0.10.6)?
# Because glibc's resolver only falls through to the next `nameserver`
# after a TIMEOUT, and it re-pays that timeout on every lookup. With
# Pi-hole first and a public resolver second, taking the cluster down
# for maintenance would add ~5s to every public DNS query on this host
# -- apt, git, gh, curl -- precisely when you are trying to fix
# something. So this host never asks Pi-hole anything.
#
# Instead dnsmasq answers *.gs-farm.net locally from static config
# (the same two directives Pi-hole serves to the rest of the LAN) and
# forwards everything else straight upstream. When the cluster is down,
# public DNS is untouched and internal names still resolve -- they just
# do not connect, which is the truth.
#
# The 127.0.0.1 -> 1.1.1.1 fallback in resolv.conf is not subject to the
# timeout problem above: if dnsmasq is not running, the loopback query
# is REFUSED immediately rather than dropped, so glibc moves to the next
# nameserver with no delay.

set -euo pipefail

DNSMASQ_CONF=/etc/dnsmasq.d/gs-farm.conf
RESOLV=/etc/resolv.conf
BACKUP=/etc/resolv.conf.pre-dnsmasq
INTERNAL_LB=10.0.10.1
DOMAIN=gs-farm.net

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"

if [[ "${1:-}" == "--revert" ]]; then
  rm -f "$DNSMASQ_CONF"
  systemctl disable --now dnsmasq 2>/dev/null || true
  if [[ -f "$BACKUP" ]]; then
    cp -a "$BACKUP" "$RESOLV"
    printf 'restored %s from %s\n' "$RESOLV" "$BACKUP"
  else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV"
    printf 'no backup found; wrote public resolvers to %s\n' "$RESOLV"
  fi
  exit 0
fi

# ---- 1. install ----------------------------------------------------
if ! command -v dnsmasq >/dev/null 2>&1; then
  printf '==> installing dnsmasq\n'
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq
else
  printf '==> dnsmasq already installed\n'
fi

# ---- 2. config -----------------------------------------------------
# Written before the first successful start, so dnsmasq never comes up
# with Debian's default behaviour of reading /etc/resolv.conf for its
# upstreams -- which, once resolv.conf points at 127.0.0.1, is a loop.
# no-resolv below is what prevents that.
printf '==> writing %s\n' "$DNSMASQ_CONF"
cat > "$DNSMASQ_CONF" <<EOF
# Managed by scripts/setup-gsfarmctl-dns.sh in ~/cillflux. Edit there.
#
# Mirrors the customDnsmasq block in
# kubernetes/apps/network/pihole/app/helmrelease.yaml, so this host
# resolves internal names identically to every other LAN client -- but
# answers them itself, with no dependency on Pi-hole being up.
#
# local=/ is NOT optional. Without it, address=/ overrides only A and
# AAAA; an HTTPS/SVCB query falls through to the public upstream and
# returns Cloudflare's real record, advertising ECH and HTTP/3 for
# their edge. Chrome-family browsers use that for connection setup and
# fail with ERR_ADDRESS_UNREACHABLE / ERR_QUIC_PROTOCOL_ERROR /
# ERR_ECH_FALLBACK_CERTIFICATE_INVALID against internal nginx, which
# supports neither. Same trap documented in CLAUDE.md.
local=/${DOMAIN}/
address=/${DOMAIN}/${INTERNAL_LB}

# Upstreams, matching Pi-hole's upstreamDns. no-resolv is mandatory:
# it stops dnsmasq reading /etc/resolv.conf, which will point here.
no-resolv
server=1.1.1.1
server=8.8.8.8

# Loopback only. This host is not a DNS server for the network --
# that is Pi-hole's job at 10.0.10.6.
listen-address=127.0.0.1
bind-interfaces

cache-size=1000
domain-needed
bogus-priv
EOF

printf '==> checking config syntax\n'
dnsmasq --test --conf-file="$DNSMASQ_CONF" || die "dnsmasq rejected the config"

systemctl enable --now dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq
systemctl is-active --quiet dnsmasq || die "dnsmasq failed to start: $(systemctl status dnsmasq --no-pager -l | tail -5)"
printf '==> dnsmasq active\n'

# ---- 3. resolv.conf ------------------------------------------------
# Only switch it once dnsmasq is proven to answer, so a failure here
# cannot leave the host with no working resolver at all.
printf '==> verifying dnsmasq answers before switching resolv.conf\n'
got=$(dig +short +time=2 +tries=1 @127.0.0.1 "prometheus.${DOMAIN}" 2>/dev/null | head -1)
[[ "$got" == "$INTERNAL_LB" ]] || die "dnsmasq returned '$got' for prometheus.${DOMAIN}, expected $INTERNAL_LB"
dig +short +time=2 +tries=1 @127.0.0.1 github.com >/dev/null || die "dnsmasq cannot resolve public names"

if [[ ! -f "$BACKUP" ]]; then
  cp -a "$RESOLV" "$BACKUP"
  printf '==> backed up original resolv.conf to %s\n' "$BACKUP"
fi

cat > "$RESOLV" <<EOF
# Managed by scripts/setup-gsfarmctl-dns.sh in ~/cillflux.
# Original saved at ${BACKUP}; re-run that script with --revert to undo.
#
# 127.0.0.1 is dnsmasq (see /etc/dnsmasq.d/gs-farm.conf). The public
# fallback below costs nothing in the normal case: a query to a dead
# loopback resolver is refused instantly, not dropped, so glibc moves
# on without paying a timeout. That is why this list is safe and
# "Pi-hole first, public second" would not be.
nameserver 127.0.0.1
nameserver 1.1.1.1
EOF
printf '==> wrote %s\n' "$RESOLV"

# ---- 4. verify -----------------------------------------------------
printf '\n==> verification\n'
for h in prometheus alertmanager grafana pihole; do
  printf '  %-26s %s\n' "$h.$DOMAIN" "$(getent hosts "$h.$DOMAIN" | awk '{print $1}' | head -1)"
done
printf '  %-26s %s\n' "github.com (public)" "$(getent hosts github.com | awk '{print $1}' | head -1)"
printf '\nDone. Revert with: sudo bash scripts/setup-gsfarmctl-dns.sh --revert\n'
