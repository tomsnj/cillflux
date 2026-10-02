# Cluster Doc Update — 2026-10-02

The NanoStation 5AC disconnected twice in 24h, each needing a manual
power cycle, with no logging in place to say why. Built Alloy → Loki
ingestion and a Loki-ruler alert, then immediately power-cycled the
device to test it live. That test caught three real bugs that synthetic
test traffic had sailed straight past — worth recording in some detail,
since each one would otherwise have sat silently broken.

## Alloy now ingests NanoStation syslog

`kubernetes/apps/observability/alloy/app/` gained a `loki.source.syslog`
receiver on `0.0.0.0:51514/udp` (RFC3164 — airOS is BusyBox-based classic
syslog, not RFC5424), with a `loki.relabel` stage promoting internal
`__syslog_*` fields into real Loki labels: `host`, `severity`,
`facility`, `source_ip`, and (added later, see below) `app`.

Reachable on the LAN as a second Service, `alloy-syslog` — LoadBalancer,
Cilium L2, **10.0.10.7:514/udp** → the container's `51514/udp` (the
Alloy container runs as UID 65534 and can't bind <1024). `10.0.10.1–.6`
were already taken (nginx ×2, minio, k8s-gateway, pihole ×2) out of the
`10.0.10.1-20` pool, so the next new LoadBalancer Service in this
cluster should start checking from `.8`.

## A Loki ruler alert, not a Grafana-managed one

`NanoStationRepeatedReboots` (severity: warning) lives in
`kubernetes/apps/observability/loki/app/cm-ruler-rules.yaml`, evaluated
by Loki's own ruler (already pointed at
`kube-prometheus-stack-alertmanager` via `rulerConfig.alertmanager_url`).
Deliberately **not** a Grafana-managed alert rule — the Grafana
datasource HelmRelease has an explicit 2026-09-25 comment that Grafana
should have no alert rules of its own, to keep every alert on the one
Alertmanager pipeline (household email, severity-ladder `inhibit_rules`,
`InfoInhibitor` handling). It still shows up in Grafana's Alerting UI
through the existing Loki/Alertmanager datasources.

Getting a rule to load *at all* in `deploymentMode: SingleBinary` needed
two non-obvious HelmRelease changes, now a `CLAUDE.md` gotcha: the
chart's default ruler storage directory is empty (scans nothing,
silently), and its `sidecar.rules` ConfigMap-watcher writes flat into
one folder when the local ruler storage backend needs
`<directory>/<tenant>/<file>.yaml` (`fake`, since `auth_enabled: false`).
Sidestepped by mounting the rule ConfigMap directly via
`singleBinary.extraVolumes`/`extraVolumeMounts` at `/rules/fake`.

## Three bugs, found only by testing against the real device

Everything above passed validation — `alloy validate`, `helm template`,
a `kustomize build`, and synthetic `nc -u` test lines all landed
cleanly. Then Tom power-cycled the NanoStation to watch it for real, and
nothing arrived. Chasing that down surfaced three separate bugs, each
one invisible to synthetic traffic:

**1. The device's clock reset on power-cycle, and ingestion trusted it.**
With no battery-backed RTC, the reboot reset the NanoStation's clock to
its firmware build date. A log pulled directly off the device (not
through this pipeline) showed every line dated `Jul 30`, no year:

```
Jul 30 10:10:11 syslogd started: BusyBox v1.19.4
Jul 30 10:10:33 system: Start
...
Jul 30 10:15:59 httpd[3255]: Password auth succeeded for 'tg543998' from 10.30.1.188
```

`loki.source.syslog` had `use_incoming_timestamp: true`, so Alloy
stamped every entry `2026-07-30` and Loki's `reject_old_samples_max_age`
(168h) rejected all of them — confirmed directly in Alloy's own pod
logs (`timestamp too old: 2026-07-30T10:10:41Z, oldest acceptable
timestamp is: 2026-09-25T02:18:04Z`), nowhere else. No error in Loki, no
error in the ruler, nothing in Grafana — the data simply never arrived.
Fixed: `use_incoming_timestamp: false`, so Alloy uses its own receipt
time regardless of what the sender's clock says. Tom separately enabled
NTP (`0.ubnt.pool.ntp.org`) on the device itself; both fixes together
mean ingestion no longer depends on either one working.

**2. The alert's detection signal was wrong.** The rule was written
before any real boot log existed, based on a Ubiquiti community forum
sample showing `"syslogd started: BusyBox..."` once per boot. The real
log above shows it **twice** in one clean boot — once during airOS's
early provisioning-mode init, again after the real init takes over.
`>1` occurrences in 24h would have false-fired on every single normal
reboot. `system: Start`, logged exactly once at the point init takes
over for good, is the correct marker.

**3. The corrected match string still couldn't match anything.**
Replaying a real captured line (`<13>Jul 30 10:10:33 testhost system:
Start`) through the live pipeline to test fix #1 showed the stored Loki
line was just the bare text `Start` — Alloy's RFC3164 parser strips the
`"TAG: "` prefix from the message body before storing it. The literal
substring `"system: Start"` the alert was matching on can never exist
in a stored line; it was broken the moment it was written, synthetic
tests notwithstanding (a hand-crafted test line without going through
the real parser can accidentally avoid this). Fixed by promoting the
internal `__syslog_message_app_name` label (the stripped tag) to a real
label, `app`, in `loki.relabel`, and changing the rule to
`{job="nanostation", app="system"} |= "Start"`.

All three fixed and verified live: replaying the real captured line
landed correctly labeled `app="system"`, timestamped at Alloy's actual
receipt time rather than the stale device time, and the ruler reloaded
the corrected rule and evaluated it `health: ok`. Not yet verified:
an actual real double-reboot firing the alert end-to-end — that's
pending the device actually misbehaving again.

## The red herring: `ath1` management radio

Once real traffic was flowing, a burst of log lines looked alarming —
`ath1` going down, `dnsmasq`/`lighttpd` restarting, then a sequence of
`wireless: ath1 Set Frequency=...` lines marching through channels
(104, 52, 56, 60, 64, 67, 97, 101) about a minute apart:

```
provmode: Management radio timeout after 15 minutes, bringing ath1 down.
dnsmasq[667]: error binding DHCP socket to device ath1
dnsmasq[667]: exiting on receipt of SIGTERM
lighttpd[882]: (server.c.2091) server stopped by UID = 0 PID = 8152
init: process '/bin/lighttpd ...' (pid 882) exited. Scheduling for restart.
```

Looked like DFS radar-avoidance channel hopping on an unstable link.
It is not: per Tom, `ath1` is a *secondary management radio* that
enables itself for 15 minutes after an initial-config login from an
Android device, then shuts itself down on schedule — exactly what
`provmode`'s own message says. The subsequent channel sequence is
`ubntspecd` (the AirView spectrum analyzer, visible in the `init: Run:
/bin/ubntspecd ... -j airview1` line) restarting and sweeping channels,
not the link reconnecting. Unrelated to the original disconnects, and
unrelated to `ath0`, which is the actual client-facing radio. Recorded
here mainly as a reminder that a dramatic-looking burst of restarts on
this device is not automatically a fault — check which radio and which
process before reacting.

## Where this leaves the original question

The actual cause of the two reboots that started this is still open —
nothing captured so far shows a crash, watchdog trip, or `ath0` event.
What's different now: the pipeline is verified correct end-to-end
(timestamps survive a bad device clock, labels survive the parser, the
alert rule matches what the device actually logs), so whenever it
happens again, it will be sitting in Loki with the right timestamp, and
`NanoStationRepeatedReboots` will catch the pattern instead of needing
another live debugging session.
