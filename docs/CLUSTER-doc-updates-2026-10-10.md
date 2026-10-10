# Cluster Doc Update — 2026-10-10

Weekly Renovate review. Five merges, three queued (later: two of the
three merged on Tom's go-ahead, see the addendum). One of the merges —
a *patch* bump of csi-driver-nfs — failed to deploy and failed to roll
back, and had to be unstuck by hand. Nothing was down at any point.

## Renovate review

**Merged** (each via `weekly-renovate-review.sh merge`):

| PR   | Change                                      | Type  |
|------|---------------------------------------------|-------|
| #996 | csi-driver-nfs chart 4.13.4 → 4.13.5        | patch |
| #994 | grafana chart 13.2.7 → 13.5.0               | minor |
| #993 | descheduler chart 0.36.0 → 0.37.0           | minor |
| #992 | immich-server v3.2.4 → v3.3.1               | minor |
| #990 | alloy chart 1.13.0 → 1.13.1                 | patch |

**Queued for Tom:**

- **#995 kube-prometheus-stack v91 → v92.** Major; fails the mechanical
  criteria. Nine chart PRs across v92.0.0–v92.3.0 not yet read.
- **#989 vaultwarden v1.37.4.** Patch, but touches the guarded
  `kubernetes/apps/vaultwarden/**` path.
- **#991 cloudflared v2026.10.0.** The upstream release body is only
  SHA256 checksums, so there is no changelog to check for breaking
  changes, and cloudflared carries all external access. Held back
  rather than merged on an absence of evidence.

## csi-driver-nfs 4.13.5: immutable `snapshot-controller` selector

### Symptom

The end-of-run `health` pass showed `csi-driver-nfs` Unknown and
`pihole` blocked behind it ("dependency not ready"). The HelmRelease
was `RollbackFailed`:

    Helm upgrade failed for release storage/csi-driver-nfs with chart
    csi-driver-nfs@4.13.5: server-side apply failed for object
    storage/snapshot-controller apps/v1, Kind=Deployment: ...
    spec.selector: Invalid value: {"matchLabels":{"app":
    "snapshot-controller"}}: field is immutable

The rollback to 4.13.4 failed with the identical error. Every pod was
still `Running` and ready, so the pod-readiness check passed — it was
the HelmRelease and Kustomization checks that caught it.

### Cause

A Deployment's `spec.selector` cannot be changed after creation. The
live `snapshot-controller` Deployment (86 days old) selected on
`app.kubernetes.io/instance` + `app.kubernetes.io/name`; the chart's
manifests render `app: snapshot-controller`. Helm could not apply
either the new or the old release over it, so the **rollback was no
escape hatch** — both directions hit the same wall. A patch-level chart
version said nothing about this; the release notes mention no selector
change.

### Fix

With Tom's go-ahead (a deletion, so asked first):

    kubectl delete deploy snapshot-controller -n storage
    flux reconcile helmrelease csi-driver-nfs -n storage --force

Helm recreated the Deployment with the chart's selector and completed
the upgrade (`Helm upgrade succeeded for release
storage/csi-driver-nfs.v27 with chart csi-driver-nfs@4.13.5`).
`csi-driver-nfs` and `pihole` Kustomizations went Ready;
`snapshot-controller`, `csi-nfs-controller` (5/5) and `csi-nfs-node`
(3/3) running; all pods ready. The four NFS StorageClasses (`gsks0`,
`gsks0-fast`, `gsks1`, `gsks1-fast`) were untouched and existing PVCs
were unaffected. Snapshot handling (used by Volsync) was unavailable
for the few seconds the Deployment was gone.

### Gotcha for CLAUDE.md

- **A Helm chart that changes a Deployment's `spec.selector` cannot
  upgrade — or roll back — over the existing Deployment, whatever the
  version bump size.** The failure is `field is immutable`, the
  HelmRelease goes `RollbackFailed`, and anything `dependsOn` it is
  blocked, while the workload keeps running on its old pods so nothing
  looks wrong at the pod level. The fix is to delete the Deployment
  (ask first) and `flux reconcile helmrelease <name> -n <ns> --force`.
  Check ahead of a bump with `helm template` both versions against the
  live values and diff the `selector:` blocks. Deleting a Deployment
  is safe for stateless controllers like this one; do not do the same
  to anything holding state without checking its PVCs.

## Health pass (before the fix)

Everything else was clean: pods fully ready, no charts floating on `*`,
Talos patches match live config, no rollout churn, all 14 internal
ingresses reachable.

## Addendum — queued PRs merged later the same day

Two of the three queued PRs were merged after Tom's go-ahead. #989
(vaultwarden v1.37.4) is still queued: it touches the guarded
`kubernetes/apps/vaultwarden/**` path.

| PR   | Change                                      | Type  |
|------|---------------------------------------------|-------|
| #991 | cloudflared 2026.9.3 → 2026.10.0            | minor |
| #995 | kube-prometheus-stack 91.9.0 → 92.3.0       | major |

### cloudflared #991

Merged with a normal `merge`; the mechanical criteria passed and the
only open question was the empty upstream notes (checksums only), which
Tom accepted. Verified: both `cloudflared` pods `1/1 Running` on
`2026.10.0`, each logging four `Registered tunnel connection` lines to
`ewr12`/`ewr17`/`ewr13`, no errors. An external-hostname curl from
`gsfarmctl` returned `000`, but that test was bad (hostname built from a
variable that does not exist), so it proves nothing either way.

### kube-prometheus-stack #995 (v91 → v92)

**What the major bump is.** Across v92.0.0–v92.3.0 the only functional
change is v92.0.0 defaulting Linux-only workloads to
`nodeSelector: kubernetes.io/os: linux` (chart PR #7344). v92.1.0–92.3.0
only bump the bundled Grafana subchart, which does not apply here
(`grafana.enabled: false`; Grafana is its own HelmRelease). The chart
notes list no CRD changes and no values migrations.

**Render diff before merging.** `helm template` of 91.9.0 and 92.3.0
against the live `kube-prometheus-stack-values` ConfigMap, with
`--include-crds` and version strings normalised, differed by exactly 10
lines — five `nodeSelector` additions (operator Deployment, Prometheus
CR, Alertmanager CR, two admission-webhook Jobs). Images, CRDs, RBAC,
monitors, rules and the Alertmanager config were identical. The
ConfigMap held no unresolved `${VAR}`, so the render used real values.

**Merge.** `merge 995 --force` (needed because the criteria reject any
major; `--force` also skips the changelog criterion, which had been read
by hand). The head SHA matched the one recorded by `check`
(`b6028ebd8`). Then `flux reconcile source git home-kubernetes`, the
Kustomization, and `flux reconcile helmrelease kube-prometheus-stack -n
observability`.

**Verified live:**

- HelmRelease Ready at 92.3.0 (`observability/kube-prometheus-stack.v430`).
- `prometheus`, `alertmanager` and the operator each restarted once and
  came back; all pods in the cluster ready.
- Prometheus CR `nodeSelector` is `{"kubernetes.io/os":"linux"}`;
  `serviceMonitorSelector` still `{}`.
- Alertmanager `/-/ready` OK; 32/32 active targets `up`; only
  `Watchdog` firing.
- Rules: 16 reported `unknown` straight after the restart, all in
  `kube-apiserver-availability.rules` (180s interval, not yet
  evaluated). Rechecked minutes later: **248/248 `ok`**. Not a fault —
  but a rule-health check taken right after a Prometheus restart will
  show this, so wait one interval before reading it.

The restart cost a short gap in monitoring data while Prometheus came
back; nothing alerted.
