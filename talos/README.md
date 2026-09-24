# Talos machine config patches

The Talos machine config for `talos-iok-xpu` (`10.0.10.10`) is **not** in
this repo and should not be. It contains the cluster CA private key, the
etcd CA key, the service-account signing key, the aescbc encryption
secret and the machine/cluster join tokens.

What *is* here are the patches — the deliberate deviations from Talos
defaults. Each one records a decision that was otherwise invisible: the
config lived only on `gsfarmctl` and inside the node, so there was no
record of why the cluster is configured the way it is.

## Never commit these

Live on `gsfarmctl` in `~/talos-config/`, deliberately untracked, and
covered by `.gitignore` at the repo root:

| File | Why |
|---|---|
| `worker.yaml` | Full machine config — CA keys, signing keys, join tokens |
| `controlplane-final.yaml` | Same, earlier revision |
| `controlplane-patched.yaml` | Same, earlier revision |
| `controlplane.yaml.notused` | Same, unused |
| `talosconfig` | Talos client cert + key (`os:admin` on this cluster) |
| `kubeconfig` | `client-key-data` — full cluster admin |

`kubeconfig` is worth calling out: a naive grep for `BEGIN PRIVATE KEY`
or `token:` returns **zero** matches on it, because the credentials are
base64 in `client-key-data`. Marker counts are not a safety check. Read
a file before deciding it is safe to track.

## Current patches

Applied and reflected in the running cluster.

| Patch | What it does |
|---|---|
| `patch.yaml` | Pod subnet `10.42.0.0/16`, service subnet `10.43.0.0/16`, `kube-proxy` disabled (Cilium runs `kubeProxyReplacement`) |
| `scheduler-patch.yaml` | `allowSchedulingOnControlPlanes` + the control-plane node label. Misleadingly named — nothing to do with kube-scheduler. Required, since this is a single node that must run workloads |
| `talos-storage-link-patch.yaml` | `enp41s0` at `172.16.99.1/30` — the direct link to TrueNAS |
| `talos-cp-metrics-patch.yaml` | `bind-address: 0.0.0.0` on kube-controller-manager and kube-scheduler so Prometheus can scrape them (2026-09-24) |

## `historical/`

`patch-network.yaml` is **superseded and must not be applied**. It sets
the node to `10.0.0.170/16` on `enp37s0`; the node actually runs
`10.0.10.10/16`. It is kept only as a record of the original install and
carries a warning header.

Anything in `historical/` is a record, not a runbook.

## Applying a patch

Changing the machine config **never requires reading it**. `talosctl
patch machineconfig` merges only the fields in the patch, server-side,
so the secrets are never touched or printed.

```bash
# 1. Preview the merged diff. Changes nothing.
talosctl -n 10.0.10.10 patch machineconfig \
  --patch @talos/patches/<patch>.yaml --dry-run

# 2. Apply temporarily. Auto-reverts after the timeout (default 1m),
#    so you can verify before committing to it.
talosctl -n 10.0.10.10 patch machineconfig \
  --patch @talos/patches/<patch>.yaml --mode=try

# 3. Make it permanent.
talosctl -n 10.0.10.10 patch machineconfig \
  --patch @talos/patches/<patch>.yaml --mode=no-reboot
```

Two things learned doing this on 2026-09-24:

- **Keep `try`'s default 1m timeout.** `--mode=try --timeout=5m`
  silently failed to apply — no error, config unchanged, static pods
  never restarted. The only way to notice was checking that the pods
  had not restarted.
- **"Applied configuration without a reboot" does not mean no
  disruption.** The permanent apply restarted the control-plane static
  pods; the API server refused connections on `6443` for roughly 30
  seconds before recovering on its own. Running workloads, networking
  and storage were unaffected, but do not do this mid-migration or
  during anything time-sensitive.

Keep this directory and `~/talos-config/` in sync by hand — nothing
automates it, and Flux does not read this directory.
