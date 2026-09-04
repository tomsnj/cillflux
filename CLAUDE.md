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
- Helm `valuesFrom` ConfigMaps do **not** receive Flux `postBuild` variable
  substitution — put variables in the HelmRelease's `spec.values` directly.
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

## Where things live

- Repo root: `~/cillflux`
- Cluster vars: `kubernetes/flux/vars/cluster-settings.yaml`
- App manifests: `kubernetes/apps/`
- Observability configs: `kubernetes/apps/observability/`
- Backup monitoring script: `/root/check-backups.sh` on TrueNAS (canonical
  copy also at `/mnt/storage1/home/stecktf_a/check-backups.sh`)
- talosconfig: `~/.talos/config` on `gsfarmctl`

## Full reference

For anything not covered above — hardware inventory, exact tool versions,
disk layouts, backup/restore procedures, and the outstanding-items list —
see `CLUSTER.md` and the dated `CLUSTER-doc-updates-*.md` files.
