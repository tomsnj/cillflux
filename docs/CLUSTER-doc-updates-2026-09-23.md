# Cluster Doc Update — 2026-09-23

## Weekly Renovate review — and a nine-minute public DNS outage

First review in about two weeks: 14 open PRs, 10 merged, 4 left queued
behind the guarded-path rules (`#968` kube-prometheus-stack v91,
`#966` app-template, `#963` keycloak, `#962` vaultwarden).

Nine of the ten were uneventful. The tenth took out public DNS for
seven hostnames, including Vaultwarden and Keycloak.

**Records were deleted at 01:03:02Z and restored at 01:12:07Z — just
over nine minutes.** Internal resolution via Pi-hole was unaffected
throughout; this was Cloudflare-side only.

### What happened

`#959` bumped the external-dns *chart* 1.21.1 → 1.22.0, which carries
*app* v0.22.0. That release changed the default annotation prefix from
`external-dns.alpha.kubernetes.io/` to `external-dns.kubernetes.io/`
**with no fallback**.

Every ingress in this repo annotates
`external-dns.alpha.kubernetes.io/target: external.gs-farm.net`. The
new version could no longer see those targets, so instead of writing a
CNAME to the tunnel it tried to publish each ingress's own
LoadBalancer IP — `10.0.10.2`, an RFC1918 address — as a *proxied* A
record. Cloudflare refused:

```
9003: Target 10.0.10.2 is not allowed for a proxied record.
```

The destructive ordering is the important part: external-dns issued
the `DELETE`s for the old CNAMEs **before** the `CREATE`s, and only the
`CREATE`s failed. `major`, `elvis`, `kumar`, `frigate`, `minio`, `s3`
and `flux-webhook` were left with no record at all. `external.gs-farm.net`
itself survived, because it comes from the cloudflared `DNSEndpoint`
CRD rather than an ingress annotation, and `susan` survived because
external-dns never reached it.

It did not self-heal. The sync loop retried every 60s and failed the
same way each time — no further damage, but no recovery either.

### Why review did not catch it

This is the transferable lesson, and it is not "read the changelog
more carefully".

**The chart and the app publish separate release notes, and only the
app's mentioned the dangerous change.** The chart 1.22.0 notes list
exactly one breaking change — `policy` no longer defaults and is now
required — which was checked and satisfied (`policy: sync` was already
set explicitly, confirmed against the live deployment). On that basis
the PR was reported as low-risk and approved.

The annotation-prefix break appears only in the upstream **app**
v0.22.0 notes, which state outright:

> "The default annotation prefix is now `external-dns.kubernetes.io/`
> with no fallback" … "This change can _delete_ **all** your DNS
> records."

**Generalised:** for any chart whose version does not track its app
version, the chart changelog is not sufficient. Check the app release
notes for the version the chart actually deploys. A *minor* chart bump
can carry a major application behaviour change.

A second contributing factor: the PR passed CI including `flux-diff`,
because the manifest diff genuinely was a single harmless line. Nothing
static could have flagged this. Upstream's own advice — run with
`--dry-run=true` before upgrading external-dns — is the only check that
would have caught it.

### The fix (`3bc7999b`)

Fixed forward rather than reverted, using upstream's documented escape
hatch:

```yaml
    extraArgs:
      - --ingress-class=external
      - --annotation-prefix=external-dns.alpha.kubernetes.io/
```

All seven CNAMEs and their `k8s.cname-*` TXT registry records were
recreated on the next sync, zero errors. Verified: eight hostnames
resolving, and Immich / Vaultwarden / MinIO returning HTTP 200 over the
public path.

**This flag is now load-bearing.** Removing it without first migrating
every `external-dns.alpha.kubernetes.io/*` annotation in the repo
reproduces the outage exactly. That warning is left in the manifest
next to the flag.

One false alarm worth recording so it is not re-investigated: `elvis`
appeared unreachable during verification while every other host
recovered. That was `gsfarmctl` attempting IPv6 — `curl -4` returned
302. Not related.

## Three HelmReleases were floating on `latest`

Found while investigating an unrelated stalled release, and arguably
the more serious finding, because it was silent.

`grafana`, `alloy` and `pihole` all had their `version:` key commented
out inside `chart.spec` — in Grafana's and Alloy's case mis-indented so
it was a comment *inside* the block rather than a disabled key. With no
constraint, Flux resolves `version: *` and pulls whatever is newest in
the repo **on every reconcile**:

```
flux-system   observability-alloy   alloy    *   ...   pulled 'alloy' chart with version '1.12.1'
flux-system   pihole-pihole         pihole   *   ...   pulled 'pihole' chart with version '2.0.13'
```

Two consequences, both bad:

1. **Charts upgrade unattended, with no PR and no review.** This is the
   one guardrail the whole Renovate workflow exists to provide, and
   these three bypassed it entirely.
2. **Renovate cannot see them.** There is no version to bump, so no PR
   is ever opened — which is why the gap never surfaced in a weekly
   review.

### Grafana had already been bitten (`738e807a`)

Grafana drifted to chart 13.2.5 unattended on **2026-09-15**. The
upgrade timed out waiting for the Deployment and the HelmRelease had
been `Stalled: True (MissingRollbackTarget)` for **nine days**:

```
Released: False | UpgradeFailed — grafana@13.2.5:
  timeout waiting for: [Deployment/observability/grafana status: 'InProgress']
```

Grafana itself was fine the whole time — the pod kept serving from helm
revision 2635 (chart 13.2.3) — which is exactly why nobody noticed. But
the release was wedged: `MissingRollbackTarget` means Flux could not
self-remediate, so it would not have accepted *any* further update.

The failure looks like a timeout rather than a bad chart.
`deploymentStrategy: Recreate` with an RWO PVC is correct config and
rules out the usual rolling-update volume deadlock. The date is the
tell: 2026-09-15 was mid photo-migration, when the node's 100Mb link
was saturated by Takeout uploads — a slow image pull fits the five
minute Helm timeout exactly.

Pinned to **13.2.3**, the version already running. Committing the pin
changed the spec, which cleared the stall on reconcile: revision 2642,
`Upgrade complete`, `Ready=True`.

### Alloy and Pi-hole pinned too (`5e0e2c9c`)

Pinned to the versions already resolved and running — `alloy` 1.12.1,
`pihole` 2.0.13 — so both were no-ops against the cluster. Pi-hole's
pod was untouched (17d uptime through the change) and DNS never
blinked.

Pi-hole is the one that mattered. It serves DNS for the entire house,
and it was one unattended chart upgrade away from a household-wide
outage with no review step anywhere in the path.

**Worth a periodic sweep**, since the mis-indentation is easy to
reintroduce and invisible in review:

```bash
kubectl get helmcharts -A | awk '$3=="*"'
```

Anything listed there is floating.

## Two GitRepository sources, not one

Cost several minutes mid-outage and is worth knowing before the next
incident.

There are **two** `GitRepository` sources in `flux-system`:

| Source | Tracked by |
|---|---|
| `flux-system` | `flux-system`, `forgejo`, `frigate`, `immich`, … |
| `home-kubernetes` | `external-dns`, `grafana`, `alloy`, `cilium`, `coredns`, most others |

`flux reconcile source git flux-system` reports success and updates
that source only. Kustomizations bound to `home-kubernetes` keep
applying the **old commit**, and `flux get kustomizations -A` shows it
plainly once you know to look — a split revision column.

During the outage the fix was committed, pushed and reconciled, and the
flag still did not appear on the deployment, because `external-dns`
tracks `home-kubernetes`. Reconcile the right source, or both:

```bash
flux reconcile source git home-kubernetes -n flux-system
```

Note that `scripts/weekly-renovate-review.sh` only reconciles
`flux-system` after each merge, so post-merge status for most apps is
stale until their own 30m interval comes round.

## `weekly-renovate-review.sh` health check is unreliable

Two defects, both of which produced a false "all clear" during this
run:

1. **It reads pod `STATUS`, not `READY`.** A pod that is `Running` but
   `0/1` counts as healthy. It reported "All pods Running/Completed"
   while CoreDNS was mid-rollout with the old pod terminated and the
   new one not yet ready — cluster DNS was genuinely down at that
   moment (`nslookup` → `No route to host`).
2. **It polls before the Helm upgrade starts rolling.** After the
   Cilium merge it declared success while `cilium` was still at
   `Init:0/6`, because the unhealthy set was momentarily empty between
   `flux reconcile source` and the DaemonSet actually rolling.

Both were transient here and resolved on their own, but the check would
miss a real failure just as readily. Until it is fixed, verify merges
with:

```bash
kubectl get pods -A --no-headers \
  | awk '{split($3,r,"/"); if ($4!="Completed" && (r[1]!=r[2] || $4!="Running")) print}'
```

For network-layer charts, pod readiness is not sufficient either —
check the actual data path. After Cilium, that means the L2-announced
LB IPs, which do not answer ICMP:

```bash
for t in 10.0.10.1:443 10.0.10.2:443 10.0.10.3:9000 10.0.10.5:80; do
  nc -z ${t%:*} ${t#*:} && echo "$t OPEN"
done
dig +short @10.0.10.6 google.com
```

## Merged this round

| PR | Type | Change |
|---|---|---|
| #956 | patch | reloader 2.2.16 → 2.2.17 |
| #967 | minor | snapshot-controller 5.2.0 → 5.3.0 |
| #965 | minor | python 3.12 → 3.14 (frigate db backup) |
| #953 | patch | kube-prometheus-stack 89.2.2 → 89.2.4 |
| #957 | minor | cloudflared 2026.8.3 → 2026.9.1 |
| #954 | patch | cert-manager v1.21.1 → v1.21.2 |
| #955 | patch | coredns 1.47.0 → 1.47.1 |
| #964 | patch | cilium 1.20.1 → 1.20.2 |
| #958 | minor | prometheus-config-reloader v0.93.1 → v0.94.1 |
| #959 | minor | external-dns 1.21.1 → 1.22.0 — **caused the outage** |

On `#965`: Renovate labels python 3.12 → 3.14 a *minor* update because
Docker tag ordering says so, which understates two CPython feature
releases. There is no changelog on a Docker Hub tag, so it was cleared
by inspection instead — the frigate backup job imports only `sqlite3`,
`os`, `glob`, `time`, `sys`, none of which are touched by the PEP 594
removals, and it installs nothing via pip. Verifying the consumer is a
stronger check than reading a changelog, and is the right move whenever
a base image bumps under a script we own.

## Suggested `CLUSTER.md` Known Gotchas entries

- A Helm chart's version and its application's version are different
  things, and they publish **separate release notes**. A minor chart
  bump can ship a major app behaviour change. For external-dns
  specifically, the chart 1.22.0 notes mention only the `policy`
  change; the app v0.22.0 notes carry the annotation-prefix break that
  deletes DNS records. Always check the app release notes for the
  version the chart actually deploys.
- external-dns is pinned to `--annotation-prefix=external-dns.alpha.kubernetes.io/`.
  v0.22.0 changed the default with no fallback. Removing this flag
  without migrating every `external-dns.alpha.kubernetes.io/*`
  annotation in the repo will orphan them and **delete** the records
  they own — external-dns deletes before it creates, so a failed create
  leaves nothing behind.
- A `HelmRelease` with no `chart.spec.version` resolves `*` and pulls
  the newest chart on **every reconcile** — unattended upgrades with no
  PR, and invisible to Renovate because there is no version to bump.
  The mis-indented `#      version:` inside `chart.spec` reads as
  pinned at a glance but is just a comment. Sweep with
  `kubectl get helmcharts -A | awk '$3=="*"'`.
- There are two `GitRepository` sources, `flux-system` and
  `home-kubernetes`. Most app Kustomizations track `home-kubernetes`, so
  `flux reconcile source git flux-system` succeeds while leaving them on
  the previous commit. Check the revision column of
  `flux get kustomizations -A` when a pushed change does not appear.
- A Flux `HelmRelease` can sit `Stalled: True (MissingRollbackTarget)`
  indefinitely while the application runs perfectly on its last good
  revision — nothing alerts, and it silently refuses all further
  updates. `flux get helmreleases -A` shows it as `Unknown`, easily read
  as a transient "reconciliation in progress". Changing the spec clears
  it.
