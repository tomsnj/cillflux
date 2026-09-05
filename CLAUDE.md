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
3. Run `flux get kustomizations -A` at the end (always, regardless of
   how many PRs were merged) and report anything not `Ready`.
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
