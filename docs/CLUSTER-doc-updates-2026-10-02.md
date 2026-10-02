# Cluster Doc Update — 2026-10-02

The NanoStation 5AC disconnected twice in 24h, each needing a manual
power cycle, with no logging in place to say why. Two changes, built and
verified live rather than just committed and hoped for.

## Alloy now ingests NanoStation syslog

`kubernetes/apps/observability/alloy/app/` gained a `loki.source.syslog`
receiver on `0.0.0.0:51514/udp` (RFC3164 — airOS is BusyBox-based classic
syslog, not RFC5424), with a `loki.relabel` stage promoting
`__syslog_message_hostname/severity/facility` and
`__syslog_connection_ip_address` into real Loki labels (`host`,
`severity`, `facility`, `source_ip`).

Reachable on the LAN as a second Service, `alloy-syslog` — LoadBalancer,
Cilium L2, **10.0.10.7:514/udp** → the container's `51514/udp` (the
Alloy container runs as UID 65534 and can't bind <1024). `10.0.10.1–.6`
were already taken (nginx ×2, minio, k8s-gateway, pihole ×2) out of the
`10.0.10.1-20` pool, so the next new LoadBalancer Service in this
cluster should start checking from `.8`.

Verified before commit with `alloy validate` (via `docker run
grafana/alloy validate`) on the full `config.alloy`, and a `helm
template` render of the modified chart values — both clean. Verified
live after Flux reconciled: all three new components showed `healthy`
via the component API (`alloy.gs-farm.net/api/v0/web/components`), and
a manual `nc -u 10.0.10.7 514` RFC3164 test line landed in Loki within
seconds as `{job="nanostation"}` with the expected labels.

The NanoStation's own airOS System → Syslog setting now points at
`10.0.10.7:514` (applied by Tom mid-session). As of this writing it
hadn't yet sent a real log line — everything confirmed above used
synthetic test traffic from `gsfarmctl`.

## A Loki ruler alert, not a Grafana-managed one

`NanoStationRepeatedReboots` (severity: warning) fires when
`{job="nanostation"} |= "syslogd started"` — the BusyBox syslogd banner,
logged exactly once per boot — appears more than once in a rolling 24h
window. Rule lives in `kubernetes/apps/observability/loki/app/cm-ruler-rules.yaml`,
evaluated by Loki's own ruler (already pointed at
`kube-prometheus-stack-alertmanager` via `rulerConfig.alertmanager_url`).

Deliberately **not** a Grafana-managed alert rule — the Grafana
datasource HelmRelease has an explicit 2026-09-25 comment that Grafana
should have no alert rules of its own, to keep every alert on the one
Alertmanager pipeline (household email, the existing severity-ladder
`inhibit_rules`, `InfoInhibitor` handling, etc.). This rule shows up in
Grafana's Alerting UI anyway, through the same Loki-ruler and
Alertmanager datasources already wired up — nothing new needed there.

Getting this rule *loaded at all* needed two non-obvious changes to the
Loki HelmRelease, now also recorded as a `CLAUDE.md` gotcha:

1. `loki.rulerConfig.storage.local.directory` had no default pointing
   anywhere real (chart default is `{type: local}` with no directory;
   Loki's own default for that is `""`, so the ruler would have scanned
   nothing, silently). Set to `/rules`.
2. The chart's `sidecar.rules` mechanism (a k8s-sidecar watching
   ConfigMaps labelled `loki_rule`) writes flat into one folder, but
   Loki's local ruler storage needs `<directory>/<tenant>/<file>.yaml`
   — `fake` here, since `auth_enabled: false`. Rather than fight the
   sidecar's folder-annotation behavior, the rule ConfigMap is mounted
   directly via `singleBinary.extraVolumes`/`extraVolumeMounts` at
   `/rules/fake`.

Verified end-to-end before calling it done: two synthetic
`syslogd started` lines sent 65s apart turned the rule `firing` in
`.../prometheus/api/v1/rules`, and the resulting alert showed up
`active` in Alertmanager (`.../api/v2/alerts`) routed to the `email`
receiver — the same path every other household alert uses. It will
self-clear once those two test lines age out of the 24h window.

**Caveat worth remembering**: the match string (`"syslogd started"`) is
confirmed against a real airOS community log sample, not this specific
NanoStation's own boot output, since no real reboot had logged through
the new pipeline as of this writing. Worth a quick check against
`{job="nanostation"}` in Loki once the device has actually rebooted on
its own, to make sure the real message matches what was assumed here.
