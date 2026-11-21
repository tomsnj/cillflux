# Cluster Doc Update — 2026-11-21

external-dns chart 1.23.0 → 1.24.0 (app v0.23.0 → v0.24.0), merged as
PR #1085 (commit `fc140891`). Times are UTC.

## Summary

- The live app was already v0.23.0: chart 1.23.0 had been deployed since #987.
  This PR moves both the chart and the app to 1.24.0 / v0.24.0.
- The rollout was clean. The new pod (`external-dns-5bf7bdc4f5-kwmkq`) started
  at 15:05:54 and has stayed `1/1 Running` with 0 restarts.
- Over the next watch, 12 reconcile cycles all reported
  `All records are already up to date`. No create, update, delete, error
  or warn lines appeared.
- **Not done:** the DNSEndpoint CRD was not upgraded. `upgrade.crds` is not set
  on the HelmRelease, so Helm did not apply the 1.24.0 CRDs. See "Open items".

## Change

`kubernetes/apps/network/external-dns/app/helmrelease.yaml`:

    chart.spec.version: 1.23.0 → 1.24.0

Nothing else in the values changed. These flags stay exactly as they were:

- `--annotation-prefix=external-dns.alpha.kubernetes.io/` (required; see CLAUDE.md
  on the v0.22.0 annotation-prefix change)
- `policy: sync`, `txtOwnerId: default`, `txtPrefix: k8s.`
- `domainFilters: ["${SECRET_DOMAIN}"]`
- sources `crd` and `ingress`, with `crd-source-kind=DNSEndpoint` at
  `externaldns.k8s.io/v1alpha1`

### Pre-merge check

The chart release notes were checked against the app release notes (v0.24.0),
because a chart bump does not show app-side behaviour changes. The live
Deployment was confirmed to run v0.23.0 before the bump.

## Verification

Live state after the reconcile:

    pod  external-dns-5bf7bdc4f5-kwmkq   1/1 Running   restarts 0
    log  "Using custom annotation prefix: external-dns.alpha.kubernetes.io/"
    log  UserAgent=ExternalDNS/v20261023-v0.24.0
    log  12 × "All records are already up to date" (15:05:54 onward)

DNS for every ingress host resolves through Cloudflare (checked against 1.1.1.1):
`flux-webhook`, `susan`, `frigate`, `major`, `elvis`, `minio`, `s3`, `kumar`
(`*.gs-farm.net`). The records were not changed by the upgrade.

## Open items

- **CRD upgrade.** Add `upgrade.crds: CreateReplace` to the HelmRelease as a
  separate change, and only after checking that the DNSEndpoint CRD is not
  Helm-owned (the same check used for kube-prometheus-stack in CLAUDE.md).
  The v0.24.0 release notes describe admission validation for DNSEndpoint and
  DNSRecord objects. That has not been tested on this cluster, and the CRD
  upgrade is the step that would bring the 1.24.0 schema into effect.
- **Watch window.** About 12 minutes of log after the rollout, with no
  errors or record changes.

## Rollback

Revert `fc140891` in git. Flux will roll the chart back to 1.23.0, and the
live app returns to v0.23.0.
