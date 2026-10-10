# Cluster Doc Update — 2026-10-10

Weekly Renovate review. Five merges, three queued. One of the merges —
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
