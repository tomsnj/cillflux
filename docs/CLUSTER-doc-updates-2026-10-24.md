# Cluster Doc Update — 2026-10-24

NanoStation outage alerting, syslog recovery, and the UISP re-adoption
pattern. Most of the day's work was off-cluster (UISP on this host and the
NanoStations themselves), so this section records what was done there and
how it was verified. Nothing in `kubernetes/` changed.

## What the NanoStations do now

- **UISP (on `gsfarmctl`, 10.0.100.240, 3.1.65) is the device monitor.**
  It runs in Docker (`unms-*` containers, up three weeks at the time of
  writing). UNMS and UISP are the same product; the UI says UISP.
- **Outage alert = UISP's outage email.** UISP sends a report about three
  minutes after a device drops. It goes to the household inbox through
  Gmail SMTP (`smtp.gmail.com:587`, STARTTLS), using a **separate** Google
  app password from the one Alertmanager uses, so either can be revoked
  without touching the other.
- **Syslog = `loki.source.syslog` in Alloy**, as set up on 10-02. Both
  devices now send to `10.0.10.7:514/udp`: 252 since 10-02, 253 since
  today.

## Verified today

- **Outage email:** a restart of 252 from the UI on 10-24 at 11:06:27 UTC
  (shutdown logged) was reported by UISP as "Disconnected at 7:07" for
  three devices (the AP, its station and a downstream UniFi mini), in a
  report timed 7:10 Eastern (11:10 UTC). Eastern on 10-24 is EDT, so the
  two clocks agree. The device was back at 11:07:30 UTC.
- **252 syslog target:** `syslogd -R 10.0.10.7:514` applied at the reset
  boot. Loki resumed receiving 252 entries once it was set again.
- **253 syslog:** 156 entries from 252 and 11 from 253 in the 30 minutes
  after 253 was pointed at Loki.
- **Reachability:** both devices answer `nc -z` on 443 and 22 from this
  host.

## What broke, and the fix

Factory resets and restarts both broke the UISP link. The pattern on each
device:

1. The device restarts or resets, and its SSH host key changes. The
   fingerprint for 252 went from `SHA256:3mWu…` to `SHA256:N+xz…`.
2. UISP shows "connecting" and then a popup: adopt the device, then
   "UISP key is not the right key, reset?"
3. Fix: adopt with the **UISP adoption key** copied from the Device
   Adoption page, then accept UISP's device-key update. The global
   "Reset UISP Key" option was not used.

For 252 this was done at 11:38 UTC. For 253, after a restart at 12:13, no
action was needed: UISP showed "no connection" with no popup, and the
device settled by itself at 12:15 (`got unmsSetup`). That is the key
point for the runbook: **after a restart, wait a few minutes before
adopting or resetting anything.**

On this host, `~/.ssh/known_hosts` was updated for 10.0.100.252. The
previous file is at `~/.ssh/known_hosts.bak-nanostation-2026-10-24`.

## Decisions

- **No ping watchdog.** The NanoStation's ping watchdog would check the
  device's link to UISP, not the device itself, so a dead device still
  logs nothing. Its failure action may also be a reboot, which would bounce
  every NanoStation whenever UISP restarts. Enable it only if its failure
  action is log-only, and treat it as a secondary signal.
- **No Loki silence alert or blackbox probe for the NanoStations.** The
  device logs are event-driven: quiet stretches of days happen while the
  link is stable, so "no logs for N hours" can't tell healthy from dead.
  The UISP outage email covers a device going offline.

## Mistakes and corrections

- **I told you UISP was polling the NanoStation over SSH.** That was an
  inference from `Child connection from 10.0.100.240` lines in the device
  log. 10.0.100.240 is this host, so those connections could be UISP or my
  own `ssh-keyscan`/`ssh` probes. Not established.
- **I printed a Pi-hole admin password** from a `helm template` render (the
  chart generates it per render). It was not the live password: the live
  `pihole` Secret was created 2026-04-25 and was not replaced. The render
  file was deleted. Worth rotating only if the render output was shared
  anywhere.
- **Two earlier render summaries were incomplete.** My selector-only
  compare hid pod-template label changes, so the pre-merge notes said
  fewer pods would roll than did. The Pi-hole first pass used a wrong chart
  path and reported an empty render as identical; the corrected render
  shows the pod template does change (chart version labels), which is why
  Pi-hole restarted at 10:03 UTC. Pi-hole uses the Recreate strategy, so
  DNS was down for that restart. The gap was not timed.

## Related: weekly Renovate review, 10-24

Twelve Renovate PRs merged (#1028 through #1039): cloudflared, immich,
prometheus-config-reloader, cert-manager, volsync, coredns, pihole chart,
csi-driver-nfs, kube-prometheus-stack, alloy, loki and cilium. Health pass
clean afterwards. Pod restarts followed the Helm upgrades as expected.
Alloy briefly dropped 82 batches of old rotated logs after its pod restart
(Loki rejects entries older than its window); it stopped within minutes.

## Open items

- **UISP vault key decryption popup**, the one that started this: the
  root cause is not established. The device-specific reset fixed the
  NanoStations, but the global vault still reports "decryption failed" in
  some views. Two different key files from 2020 sit in `~/Downloads`
  (`unms-vault-key.txt`, `unms-vault-key(1).txt`). Neither has been
  tested, and neither should be used for a reset without a database backup
  first.
- **`update.sh --cron` runs every minute** as the `unms` user (`/etc/cron.d/unms-update`).
  Its contents are not readable from `stecktf`. Check whether it touches
  the key before any UISP upgrade.
- **UISP's own availability is unmonitored.** If `gsfarmctl` or UISP is
  down, no device reports, and nothing in the cluster would notice.
- **Discovery warning on 253:** `_xsocket_bind(): Address already in use`
  appeared after the 12:13 restart. It did not stop the connection. Watch
  whether it recurs on later boots; if it does, it's a real fault.
- **Device logs are the only trace of a link problem:** UISP itself did not
  show the reconnect loop on 253. Keep the device syslog on.
