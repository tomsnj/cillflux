# CLAUDE.md

## What this is

gs-farm.net homelab — a single-node Talos Linux Kubernetes cluster managed
via GitOps (Flux CD). This file orients Claude Code sessions working in this
repo on `gsfarmctl`. For hardware inventory, tool versions, disk layouts,
backup restore procedures, and the running outstanding-items list, see
`CLUSTER.md` in this repo (or the copy kept in the Claude.ai project) — this
file covers working conventions, not the full reference.

## Environment

- **Cluster**: `talos-iok-xpu`, single-node Talos Linux at `10.0.10.10`,
  Talos v1.12.6 / Kubernetes v1.35.2
- **Control host**: `gsfarmctl` (this machine) — Debian 12, user `stecktf`
- **Storage**: TrueNAS SCALE `storage1` — `10.0.0.169` (base) /
  `10.10.10.110` (VLAN10, used for the 10Gb NFS StorageClasses)
- **GitOps**: Flux CD watches `github.com/tomsnj/cillflux` (private),
  secrets encrypted with SOPS/age
- **Tooling**: `talosctl`, `kubectl`, `flux`, `helm` — all already
  configured on this host; nothing to set up

## Core workflow rules

1. **GitOps only.** Persistent changes go through this repo: edit, commit,
   push, let Flux reconcile. Direct `kubectl apply`/`edit`/`delete` against
   the live cluster is for temporary diagnosis only — if it needs to stick,
   it needs a matching commit here, or it should be reverted.
2. **Verify before claiming done.** After something reconciles, check it
   against the live cluster (`kubectl get`, `flux get`, logs, etc.) and show
   the actual output. Don't infer success from the diff alone.
3. **Private repo — don't trust GitHub search.** The GitHub API/web search
   doesn't work reliably against this private repo. Use `grep -rn` locally
   in `~/cillflux` instead.
4. **`vi`, not `nano`**, for any interactive editing.
5. **Document non-trivial changes.** After anything significant, offer a
   dated `CLUSTER-doc-updates-YYYY-MM-DD.md` — a drop-in section in the
   style of the existing ones, not a rewrite of the whole doc.

## Guardrails

- Ask before anything destructive against the live cluster — deleting
  resources, scaling to zero, `zfs rollback`, forced pod deletion — even
  routine-seeming ones. This is live household infrastructure (DNS,
  password manager, cameras, SSO).
- Never print decrypted contents of `*.sops.yaml` files or the age private
  key. Ciphertext is fine to read and reference by name.
- Treat `kubernetes/flux/vars/cluster-settings.yaml` and everything under
  `kubernetes/apps/` as production config, not a scratchpad.
- Default to normal permission mode (ask before running/editing) unless
  told otherwise for the session.

## Known gotchas (don't rediscover these)

- Flux silently reverts manual patches — e.g. `spec.paused: true` on a
  Volsync `ReplicationSource`. Suspend the owning Kustomization first:
  `flux suspend kustomization cluster-apps -n flux-system`.
- Volsync mover pods run under a `Job` with independent retry/backoff —
  scaling the Volsync controller to zero doesn't stop retries; delete the
  `Job` itself.
- `kubectl debug --target` shares the process namespace only, not volume
  mounts — use explicit `hostPath` mounts for real filesystem access.
- Only `kube-system` is PSA-exempted for privileged pods — use it for
  debug/maintenance pods needing elevated access.
- Flux `postBuild` substitution applies to **every manifest the
  Kustomization renders**, including a ConfigMap that a HelmRelease later
  consumes via `valuesFrom`. Both such ConfigMaps in this repo rely on
  it and work: `cilium-values` resolves `${CLUSTER_CIDR}` to
  `10.42.0.0/16` and `kube-prometheus-stack-values` resolves
  `prometheus.${SECRET_DOMAIN}` to `prometheus.gs-farm.net` (verified
  against the live ConfigMaps and `cilium-config`, 2026-09-24). So
  putting variables in a `valuesFrom` ConfigMap is fine, and there is no
  need to duplicate them into `spec.values`.
  What does **not** get substituted is anything Flux never renders: a
  ConfigMap produced by the Helm chart's own templates, one created
  outside Flux (`kubectl`, another tool), or one in a Kustomization
  without `postBuild.substituteFrom`. That last case is the likely
  original culprit — the substitution is a property of the owning
  Kustomization, not of `valuesFrom`. Check with
  `kubectl get kustomization -n flux-system <name> -o jsonpath='{.spec.postBuild.substituteFrom[*].name}'`,
  then confirm the rendered ConfigMap holds a real value rather than a
  literal `${VAR}`.
- Editing a `valuesFrom` ConfigMap does **not** trigger a Helm upgrade.
  Flux applies the ConfigMap immediately and the Kustomization goes
  `Ready`, so the change looks deployed — but the HelmRelease keeps
  serving its previous rendering until its own `interval` elapses (30m
  for `kube-prometheus-stack`). Symptom: the ConfigMap holds the new
  value while the workload is untouched, with no error anywhere. Force
  it with
  `flux reconcile helmrelease <name> -n <namespace>`; `flux reconcile
  kustomization` is not enough. Same family as the Vaultwarden
  `config.json` trap — the diff deployed, the behaviour didn't.
- kube-prometheus-stack's `*SelectorNilUsesHelmValues: true` settings
  make Prometheus select **only** resources labelled
  `release: kube-prometheus-stack`. Anything defined outside the chart is
  silently ignored: the ServiceMonitor or PrometheusRule exists, `kubectl
  get` lists it, and no target or rule group ever appears. On 2026-09-24
  that was 14 of 24 ServiceMonitors and both hand-written
  PrometheusRules. They are now `false` (select everything). If a new
  app's metrics never show up, check these before debugging the exporter:
  `kubectl get prometheus -n observability kube-prometheus-stack -o jsonpath='{.spec.serviceMonitorSelector}'`
  and compare `kubectl get servicemonitors -A` against the live target
  list from `/api/v1/targets`.
- When replacing kube-prometheus-stack's default Alertmanager route,
  **`InfoInhibitor` must be null-routed alongside `Watchdog`** — the
  chart's default matcher is `alertname =~ "InfoInhibitor|Watchdog"`.
  `InfoInhibitor` is not an alert: it fires whenever any `severity=info`
  alert is firing in a namespace with nothing warning-or-critical, and
  exists only to drive the inhibit rule that silences info alerts. Route
  it anywhere real and it mails on every transition, as often as the
  noisiest info alert in the cluster — 83 emails in under a day on
  2026-09-24, roughly one every ten minutes, doubled by
  `send_resolved`. Carry over the chart's three `inhibit_rules` too
  (critical over warning+info, warning over info, InfoInhibitor over
  info); without the third the whole mechanism is inert. Check what a
  live alert will actually do with
  `kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&inhibited=true'`
  and read the `receivers` field — the route matters more than the rule.

- After TrueNAS interface changes, NFS may bind to only the most recently
  configured interface — clear with
  `sudo midclt call nfs.update '{"bindip": []}'`.
- Renovate's strict YAML parser crashes on aliases referenced before their
  anchors are defined.
- `home-operations` images aren't published with semver tags — pin by
  digest (`@sha256:...`), which Renovate's docker datasource handles fine.
- Files with `600` permissions block reads as non-root UID in CI — sweep
  periodically: `find kubernetes/ -name "*.yaml" -perm 600`.
- A DNS outage during Helm remediation can deadlock CoreDNS recovery —
  break it by manually applying a `kube-dns` Service + CoreDNS Deployment
  with correct labels before retrying Helm.
- Use the TrueNAS CLI shell (option 7,
  `network interface update/create ... commit ... checkin`) for
  multi-interface reconfiguration, not the web UI.
- NFS over the 10Gb link performs at parity with local disk for this
  workload — the real ceiling is HDD mirror vdev IOPS (~78 combined). The
  ZFS special vdev doesn't help HDD-seek-bound workloads like Frigate
  recording.
- A new Mac (or freshly installed browser) failing to reach any
  `*.gs-farm.net` admin console with a low-level error
  (`ERR_ADDRESS_UNREACHABLE`), while `curl`/`ping`/`dig` from Terminal
  work fine — check System Settings → Privacy & Security → Local
  Network for that browser before chasing DNS/VLAN theories. Terminal
  gets this macOS permission by default; browsers often don't until
  granted. Also: `ping` failing to a Cilium L2-announced LB IP
  (redirect, then "Destination Host Unreachable") is expected and not
  a real problem — Cilium only load-balances TCP/UDP on real Service
  ports, not ICMP; test with `curl`/`nc` against the actual port
  instead.
- Vaultwarden persists any setting ever changed via its Admin Panel to
  `config.json` on its PVC, and that **silently overrides the
  matching HelmRelease env var from then on** — Vaultwarden logs a
  `[WARNING]` listing the overridden vars on startup, easy to miss. A
  git change to one of these env vars can look like it deployed fine
  (pod healthy, no errors) while having zero actual effect. Check what's
  really live with `kubectl exec -n vaultwarden <pod> -- grep -o
  '"KEY":[^,]*' /data/config.json` (skip `admin_token`,
  `smtp_password`, `sso_client_secret`) — if a setting's ever been
  touched in the Admin Panel, change it there too, not just in git.
- Pi-hole's `address=/domain/ip` (in `customDnsmasq`) only overrides
  A/AAAA queries — it does nothing for the newer HTTPS/SVCB record
  type. Without a matching `local=/domain/` entry, a query for that
  type falls through to the public upstream and returns Cloudflare's
  real HTTPS record (advertising ECH + HTTP/3 for their actual edge),
  which internal nginx supports neither. Chrome-family browsers
  (Brave) use that record for connection setup and fail in confusing,
  seemingly-unrelated ways (`ERR_ADDRESS_UNREACHABLE`,
  `ERR_QUIC_PROTOCOL_ERROR`, `ERR_ECH_FALLBACK_CERTIFICATE_INVALID`)
  — Safari doesn't, which is why "it works in Safari but not Brave"
  doesn't necessarily mean a Brave-specific setting is at fault.
  Always pair `address=/domain/ip` with `local=/domain/` for any
  internally-overridden `*.gs-farm.net` domain.
- `gsfarmctl` does **not** use Pi-hole for DNS, and must not. Until
  2026-09-25 its `/etc/resolv.conf` pointed straight at `8.8.8.8`, so
  no `*.gs-farm.net` name resolved from the control host at all — which
  is the real reason so much diagnosis here has gone through
  `kubectl port-forward`. It now runs its own loopback dnsmasq carrying
  the same two directives Pi-hole serves
  (`scripts/setup-gsfarmctl-dns.sh`, revert with `--revert`).
  Do not "simplify" this to `nameserver 10.0.10.6` with a public
  fallback: **glibc falls through to the next `nameserver` only after a
  timeout, and re-pays it on every lookup**, so cluster maintenance
  would add ~5s to every public DNS query on this host. The
  `127.0.0.1` → `1.1.1.1` fallback that is there does not have that
  problem — a dead loopback resolver *refuses* instantly rather than
  dropping, and glibc moves on with no delay. Also note `no-resolv` in
  the dnsmasq config is load-bearing: Debian's dnsmasq otherwise reads
  `/etc/resolv.conf` for upstreams, which now points at itself.
- Alertmanager has a UI at `alertmanager.gs-farm.net` as of
  2026-09-25 (internal class). Before that it was ClusterIP-only and
  the hostname 404'd — the Pi-hole wildcard resolved it, so it looked
  exposed and was not. **It is not read-only**: anyone on the LAN can
  create a silence, the same trust boundary that already exposes
  Prometheus's admin API. Grafana has an Alertmanager datasource
  pointed at it. Note Grafana can list Prometheus *rules* read-only
  through the Prometheus datasource alone, which looks like alerting
  visibility but shows no silences and no inhibition state.
  Ingresses here carry no `secretName` on purpose — `nginx-internal`
  sets `default-ssl-certificate: network/gs-farm-net-production-tls`,
  a `*.gs-farm.net` wildcard.
- Because Pi-hole wildcards `address=/gs-farm.net/10.0.10.1`, **every**
  name under the domain resolves and reaches nginx — so a successful
  lookup and a TCP response prove nothing about whether the route
  exists. Three hosts were reachable-looking and broken in one week
  (2026-09-25): `alertmanager` 404'd with no Ingress at all, `alloy`
  503'd pointing at a closed Service port, and `prometheus` was fine
  but unresolvable from gsfarmctl. Check the status code, not the
  resolution: anything on the internal class should answer 200/302, and
  a 404 or 503 means the route is wrong rather than the app being down.
- The Alloy chart's ingress backend port is `faroPort`, its only knob
  for that, defaulting to `12347` (the Faro browser-telemetry
  receiver). Faro is not enabled here, so the Service opens only
  `http-metrics` on `12345` and the default pointed at a port that did
  not exist. It is set to `12345` deliberately — do not "correct" it
  back to a Faro port without also enabling a Faro receiver.
- Wiring a new app to Keycloak SSO (per-app realm pattern, e.g.
  `vaultwarden`, `grafana`) means creating a **brand new, empty**
  realm — it has zero users even though `master`/other realms have
  yours. Creating the client and getting a valid OIDC handshake is not
  enough; login will keep silently rejecting correct-looking
  credentials until a user is created *in that specific realm*
  (`kcadm.sh create users -r <realm> ...` + `set-password ... --temporary`
  to hand off a one-time password without ever knowing the user's real
  one). Hit this with Grafana on 2026-09-07; will hit it again for
  Forgejo unless remembered.
- A Helm chart's version and the application it deploys are different
  things, and they publish **separate release notes**. A *minor* chart
  bump can carry a *major* app behaviour change, so reading only the
  chart changelog is not enough — check the app release notes for the
  version that chart actually deploys. This cost nine minutes of public
  DNS on 2026-09-23: external-dns chart 1.22.0's notes listed exactly
  one breaking change (`policy` now required, which we already
  satisfied), while the record-deleting annotation-prefix change was
  documented solely in the app v0.22.0 notes.
- external-dns is pinned to
  `--annotation-prefix=external-dns.alpha.kubernetes.io/` because
  v0.22.0 changed the default to `external-dns.kubernetes.io/` with no
  fallback. **Do not remove that flag** without first migrating every
  `external-dns.alpha.kubernetes.io/*` annotation in the repo — orphaned
  annotations make external-dns lose its CNAME targets, try to publish
  the ingress's private LB IP as a proxied A record (Cloudflare rejects
  with code 9003), and **delete the existing records**. It deletes
  before it creates, so a failed create leaves nothing behind, and it
  does not self-heal.
- A `HelmRelease` with no `chart.spec.version` resolves `*` and pulls
  the newest chart in the repo on **every reconcile** — unattended
  upgrades with no PR, and invisible to Renovate, which cannot propose
  a bump when there is no version to bump. Watch for a mis-indented
  `#      version:` *inside* `chart.spec`: it reads as pinned at a
  glance but is only a comment. Grafana, Alloy and Pi-hole were all
  floating this way until 2026-09-23. Sweep with
  `kubectl get helmcharts -A | awk '$3=="*"'`.
- A Flux `HelmRelease` can sit `Stalled: True (MissingRollbackTarget)`
  indefinitely while the app runs perfectly on its last good revision.
  Nothing alerts, and it silently refuses all further updates.
  `flux get helmreleases -A` renders it as `Unknown`, which reads like
  a transient "reconciliation in progress" — Grafana hid in that state
  for nine days. Changing the spec clears it.
- There are **two** `GitRepository` sources: `flux-system` and
  `home-kubernetes`. Most app Kustomizations track `home-kubernetes`, so
  `flux reconcile source git flux-system` reports success while leaving
  them on the previous commit. If a pushed change will not appear,
  check the revision column of `flux get kustomizations -A` for a split,
  and reconcile the source that actually owns it.
- Two Kustomizations quietly managed Flux's own components for 172
  days: `flux` (the `flux-manifests` OCI artifact, patched to cpu
  2/2Gi with `--concurrent=8` and the API-QPS bumps) and
  `flux-system`/`cluster` (the checked-in
  `kubernetes/flux/flux-system/gotk-components.yaml`, stock 1/1Gi and
  unpatched). Both reconciled every 10m, so the controller pod
  template was rewritten continuously — a new ReplicaSet and a new pod
  each time, **deployment revision 142326** on kustomize-controller,
  about 34 rollouts an hour. Every symptom was downstream and looked
  like something else: `CPUThrottlingHigh` flapping in `flux-system`
  (startup throttling on pods seconds old), the tuning only in effect
  half the time, and controllers that were always mid-restart when
  anything else went wrong. Nothing alerted, because at any instant
  every Deployment was `1/1` and every Kustomization `Ready`.
  Resolved 2026-09-25 by deleting `gotk-components.yaml` — Flux now
  comes from the OCI artifact alone, and a version bump is a one-line
  tag change Renovate can track instead of a `flux bootstrap` re-run.
  The general check: `kubectl get deploy -A -o custom-columns=\
  'NS:.metadata.namespace,NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision'`
  and look for a revision count that cannot be explained by the number
  of times anyone has actually changed that Deployment.
- Flux computes pruning by diffing a Kustomization's **previous
  inventory** against the newly applied set, so *removing* a resource
  from a path deletes it — even if another Kustomization also manages
  it. `flux-system` and `cluster` shared 29 objects with `flux`,
  including the `flux-system` Namespace and all 11 Flux CRDs; dropping
  `gotk-components.yaml` with `prune: true` would have collected those
  CRDs and cascade-deleted all 38 Kustomizations, 28 HelmReleases and
  24 HelmRepositories in the cluster. Safe handover is three commits:
  set `prune: false` on every Kustomization applying that path, then
  remove the resources and verify the survivors, then restore
  `prune: true` — by which point the stored inventory already matches,
  so there is nothing to collect. Check for overlap first with
  `kubectl get kustomization -n flux-system <name> -o jsonpath='{.status.inventory.entries[*].id}'`
  on both sides and compare.
- Pod `STATUS` is not readiness. A pod that is `Running` but `0/1`
  passes a naive `STATUS != Running` check while being entirely
  unavailable — cluster DNS was down mid-CoreDNS-rollout on 2026-09-23
  while exactly such a check reported healthy. Compare the READY
  columns instead:
  `kubectl get pods -A --no-headers | awk '{split($3,r,"/"); if ($4!="Completed" && (r[1]!=r[2] || $4!="Running")) print}'`.
  For network-layer charts, readiness still is not enough — test the
  data path. Cilium's L2-announced LB IPs do not answer ICMP, so use
  `nc -z <ip> <port>` against the real Service port.
- `flux diff kustomization` compares the **HelmRelease CR**, not what
  the chart renders, so for a chart version bump it proves almost
  nothing. To see the real effect, `helm template` both versions
  against the live values and diff the output. Expect two false
  positives: unsubstituted `${VAR}` (a local build skips Flux's
  `postBuild` envsubst) and a stale PR branch appearing to revert a
  newer merge (check with `git merge-tree --write-tree main <branch>`).
  Note that not every HelmRelease keeps values in `spec.values` —
  `kube-prometheus-stack` uses `valuesFrom` the
  `kube-prometheus-stack-values` ConfigMap (key `values.yaml`), and a
  jsonpath on `.spec.values` returns empty, so a render built from it
  silently uses chart defaults and proves nothing.
- `crds: CreateReplace` on a HelmRelease satisfies the "run these ten
  `kubectl --server-side` commands" step that kube-prometheus-stack
  majors ship with — verified on the 89→91 jump, where all ten
  `monitoring.coreos.com` CRDs went 0.93.1 → 0.94.1 automatically. It
  works because those CRDs are unlabelled (installed from the chart's
  `crds/` directory, so not Helm-owned) and single-version. Confirm
  both before relying on it for another chart.
- Legacy `kubernetes.io/service-account-token` Secrets are still
  populated by the control plane on Kubernetes **v1.35.2** (verified
  2026-09-24 with a disposable probe Secret). kube-prometheus-stack
  >= 90 depends on this for *all* control-plane scraping, so re-run
  that probe after any major Kubernetes upgrade — if it stops working,
  apiserver/kubelet/coredns metrics break.
- Scraping `kube-controller-manager` and `kube-scheduler` on Talos needs
  **two** things, and neither works alone: `bind-address: 0.0.0.0` in the
  Talos machine config (Talos binds both to `127.0.0.1` by default) *and*
  a correct `endpoints` address in the kube-prometheus-stack
  `helmvalues.yaml`. Both were wrong until 2026-09-24 — the endpoint was
  `10.10.1.110`, an address that does not exist on this network,
  inherited from a k3s-derived template along with its "duplicate labels
  provided by k3s" relabeling comments. Fixed; both targets now scrape.
- Changing the Talos machine config **never requires reading it** — it
  holds the cluster CA private key, etcd CA key, service-account signing
  key and join tokens. `talosctl patch machineconfig` merges a patch
  containing only the changed fields, server-side. Safe sequence:
  `--dry-run` (prints the merged diff, changes nothing), then
  `--mode=try` (applies and auto-reverts after its timeout, so you can
  verify before committing), then `--mode=no-reboot`. Keep `try`'s
  default 1m timeout — `--timeout=5m` silently fails to apply. And
  despite the "Applied configuration without a reboot" message, a
  permanent apply **does** restart the control-plane static pods: the API
  server refused connections on 6443 for ~30s before recovering on its
  own. Ordinary serving workloads ride through it (Immich, Vaultwarden,
  Pi-hole, ingress, NFS all kept serving), but **anything that talks to
  the API server does not** — four Flux controllers crash-looped five
  times each with `exitCode 1` until the API returned, then recovered
  unaided. Don't do it mid-migration or during a backup window.
  Patches live in `~/talos-config/` and are tracked in `talos/patches/`;
  the machine config itself is deliberately not in git.

## Where things live

- Repo root: `~/cillflux`
- Cluster vars: `kubernetes/flux/vars/cluster-settings.yaml`
- App manifests: `kubernetes/apps/`
- Observability configs: `kubernetes/apps/observability/`
- Backup monitoring script: `/root/check-backups.sh` on TrueNAS (canonical
  copy also at `/mnt/storage1/home/stecktf_a/check-backups.sh`)
- talosconfig: `~/.talos/config` on `gsfarmctl`
- Control-host DNS: `scripts/setup-gsfarmctl-dns.sh` (writes
  `/etc/dnsmasq.d/gs-farm.conf` and `/etc/resolv.conf`; original saved
  to `/etc/resolv.conf.pre-dnsmasq`)
- Talos machine-config patches: `talos/patches/` in this repo, with
  `talos/README.md` covering the apply workflow. The machine config
  *itself* is deliberately not in git (CA private keys, signing keys,
  join tokens) — it lives in `~/talos-config/` on `gsfarmctl`, which is
  gitignored along with `talosconfig`, `worker.yaml` and
  `controlplane-*.yaml`.

## Full reference

For anything not covered above — hardware inventory, exact tool versions,
disk layouts, backup/restore procedures, and the outstanding-items list —
see `CLUSTER.md` and the dated `CLUSTER-doc-updates-*.md` files.
## Weekly Renovate Review

Renovate opens PRs on a Saturday schedule. Most patch/digest bumps are
handled by `renovate.json` automerge rules and never need review — what
shows up here is the remainder: minors, majors, and anything automerge
rules excluded.

**Entry point:** `~/cillflux/scripts/weekly-renovate-review.sh`
Run `--dry-run` first if it's been a while since the last review, or if
`renovate.json` automerge rules changed recently.

### Workflow

Tom reviews at the end of the run, not per-PR — the whole point is to
walk away and come back to one summary, not baby-sit each PR. That
means nothing in this workflow blocks mid-run waiting on an answer.

1. `git pull --ff-only` before touching anything (avoids push conflicts
   if a PR needs a manual tweak mid-review).
2. For each open Renovate PR:
   - Read the PR diff **and** the linked changelog/release notes — not
     just the file diff. The diff shows *what* changed; the changelog
     shows *whether it's safe*.
   - Classify as one of:
     - **Auto-mergeable** — see criteria below. Merge immediately, no
       need to wait for anything.
     - **Needs Tom** — do NOT merge. Add it to a queue with a 1-3
       sentence risk summary and move on to the next PR. Don't guess
       "to save time" — a wrong guess here costs more than the time
       saved, and queuing costs nothing since no one's waiting on it.
   - Snapshot `kubectl get pods -A` before and after each auto-merge.
   - `flux reconcile source git flux-system` after each auto-merge so
     status reflects the new commit, not stale state.
3. Run `scripts/weekly-renovate-review.sh health` at the end (always,
   regardless of how many PRs were merged) and report anything wrong. It
   checks kustomizations, HelmReleases (a release can sit `Stalled` while
   its Kustomization is `Ready`), pod *readiness* rather than STATUS,
   charts floating on `*`, Talos patch drift, Deployment rollout churn,
   and internal ingress reachability.

   Two of those are not snapshots of cluster state. **Rollout churn**
   compares each Deployment's `deployment.kubernetes.io/revision`
   against the previous run's, stored in
   `~/.local/state/weekly-renovate-review/rollouts.json`, so the weekly
   cadence gives a week-over-week rate
   (`scripts/weekly-renovate-review.sh rollout-churn`).
   **Ingress reachability** is the only check that leaves the cluster
   and speaks to the data path: it GETs every internal-class host and
   flags anything not answering 200/3xx/401/403
   (`scripts/weekly-renovate-review.sh ingress-check`). It needs this
   host's own resolver, and says so plainly if nothing resolves rather
   than reporting every ingress as broken. Quiet a known-bad host with
   `INGRESS_SKIP="host.gs-farm.net"`, but record why — an undocumented
   skip is how a broken route becomes permanent.
4. `git pull --ff-only` again at the end to sync local `main` — no push
   needed, merges happen on GitHub.
5. Present one consolidated end-of-run summary (see below). Then stop
   and wait — don't act on the queued PRs until Tom responds.

### End-of-run summary format

- **Merged automatically:** PR list, one line each, with update type
  (patch/minor) and package name.
- **Queued — needs a decision:** PR list, each with the 1-3 sentence
  risk summary from step 2. This is the only part Tom needs to read
  closely.
- **Pod/kustomization health:** anything not `Running`/`Ready`, with
  what's already been investigated (see Post-merge investigation below).
- **Nothing to report** is a valid summary — say so plainly rather than
  padding the update with restated details.

### Auto-merge criteria (ALL must be true)

- Update type is `minor` or `patch` (never auto-merge `major`)
- All CI checks green, including `flux-diff`
- Changelog contains no mention of breaking changes, config schema
  changes, or required manual migration steps
- PR does **not** touch any of:
  - `kubernetes/apps/database/**` (CrunchyData PGO / postgres-infra)
  - `kubernetes/apps/vaultwarden/**`
  - `kubernetes/apps/forgejo/**`
  - `kubernetes/apps/minio/**`
  - `kubernetes/apps/keycloak/**`
  - any `*.sops.yaml` file
  - any CRD definition
- PR does not change a HelmRelease's `chart.spec.version` major number

If any of these is false, it's "Needs Tom" — no exceptions, even if the
diff looks trivial. The namespace list above is deliberately broader
than "things that are currently stateful," because misjudging that
boundary is exactly the failure mode this guardrail exists to prevent.

### Post-merge investigation

If the after-merge pod snapshot shows anything not `Running`/`Completed`:
- Don't just flag it and move on — investigate immediately, in the same
  run. `kubectl describe` the pod, `kubectl logs --previous` if it's
  restarted, and correlate against the PR that just merged.
- If it's a transient rollout (pod still starting, image pulling),
  keep going — recheck it before the run ends and only report it if
  it's still not settled.
- If it's a genuine failure, do NOT roll back or patch anything
  unprompted. Put it in the summary's health section with what you
  found and a proposed fix, and wait for Tom's go-ahead — this applies
  even if the merge that caused it was auto-mergeable.

### Hard rules (apply regardless of the above)

- Never print decrypted SOPS contents or the age private key.
- Never `git push --force` to `main`.
- GitOps-only: no direct `kubectl apply`/`kubectl edit` as a substitute
  for a committed change, except documented break-glass recovery.
- All commands run from `gsfarmctl`, never the MacBook.
