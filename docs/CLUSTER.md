# gs-farm.net Cluster Documentation

> **Last updated**: 2026-06-06  
> **Purpose**: Living reference for the Talos Linux Kubernetes homelab. Upload to this Claude Project to give Claude full cluster context in every chat.

---

## Overview

Single-node Talos Linux Kubernetes cluster managed via GitOps (Flux CD). Migrated from a previous ESXi-based environment. The cluster serves home automation, observability, security cameras, password management, and SSO.

- **GitOps repo**: `cillflux` — [github.com/tomsnj/cillflux](https://github.com/tomsnj/cillflux)
- **Pattern**: [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template)
- **Domain**: `gs-farm.net`

---

## Infrastructure

### Machines

| Hostname     | Role            | IP              | OS / Notes                          |
|--------------|-----------------|-----------------|-------------------------------------|
| `gsfarmctl`  | Control machine | `10.0.100.240`  | Debian 12, username `stecktf`       |
| Talos node   | K8s node        | `10.0.10.10`    | Talos Linux (single-node cluster)   |
| TrueNAS      | NAS / storage   | `10.10.10.110`  | Bare metal (Gigabyte X470), migrated from ESXi VM |

### Talos Image

- **Schematic ID**: `a54d7711b11ec03d0a2df42d4575584982459af1bcb6f8024ba8e0eaec4d07ea`
- **Extensions**: `nfs-utils`, `iscsi-tools`, `util-linux-tools`, `amd-ucode`

### Tool Versions

| Tool         | Version  |
|--------------|----------|
| `talosctl`   | v1.12.6  |
| `kubectl`    | v1.35.3  |
| `flux`       | v2.8.3   |
| Cilium CNI   | 1.19.2   |

---

## Networking

### LoadBalancer IPs

| IP           | Service              |
|--------------|----------------------|
| `10.0.10.1`  | `nginx-internal` ingress controller |
| `10.0.10.2`  | `nginx-external` ingress controller |
| `10.0.10.4`  | `k8s-gateway`        |

### DNS

- **Pi-hole**: Split-horizon DNS; `*.gs-farm.net` → `10.0.10.1`
- **Cloudflare tunnel**: External access
- **k8s-gateway**: Evaluated as longer-term alternative to per-host Pi-hole overrides

### Access Pattern

Services needing internal LAN access require **both** an `external` and `internal` class Ingress.

---

## Storage

### NFS (TrueNAS)

| StorageClass | Access Mode | Notes              |
|--------------|-------------|---------------------|
| `gsks0`      | RWO         | NFS-backed          |
| `gsks1`      | RWX         | NFS-backed          |

- Talos requires `nolock` NFS mount option (no `rpc.statd`)
- Requires `nfs-utils` Talos extension

### Object Storage

- **MinIO**: S3-compatible, in-cluster
- **pgBackRest**: PostgreSQL WAL archiving → MinIO

---

## Core Services

| Service           | Notes                                                       |
|-------------------|-------------------------------------------------------------|
| CrunchyData PGO   | PostgreSQL operator                                         |
| Keycloak          | SSO — currently crashing, blocked on PGO/Patroni stability |
| Vaultwarden       | Password manager — SSO temporarily disabled, local auth OK  |
| Grafana           | Observability dashboards                                    |
| Prometheus        | Metrics                                                     |
| Loki              | Logs                                                        |
| Alloy             | Log/metric agent                                            |
| Pi-hole           | DNS                                                         |
| MinIO             | S3 object storage                                           |
| Kerberos agents   | Security cameras — file-based on `gsks1`, no MongoDB/RabbitMQ dependency |
| Cilium            | CNI                                                         |

---

## Secrets & Encryption

- **Method**: SOPS with age encryption
- **Age public key**: `age1puse8jhtwqw87w9qr9j4g8dajqccn0899vpyc0wnn9y2e6wz0cms2g895x`
- **Age private key**: `~/cillflux/age.key` on `gsfarmctl` — **not in git**
- **Flux decryption**: `flux-system` kustomization in `gotk-sync.yaml` must include a `decryption` block (`provider: sops`, `secretRef: name: sops-age`); without it, Flux overwrites decrypted secrets with raw ciphertext on every reconcile

---

## Current State & Open Issues

### ✅ Recently Completed

- ESXi → Talos migration largely complete
- Most HelmReleases reconciling successfully
- Cleaned up unused releases: `echo-server`, `hajimari`, `mongodb`, `rabbitmq`, `vernemq`

### 🔴 High Priority

**PostgreSQL (PGO) — Patroni crash recovery**
- pgBackRest cannot archive WAL: TLS error (`packet length too long`) connecting to its own sidecar
- Blocks Patroni from recovering, which blocks Keycloak entirely
- **Dependency chain**: PostgreSQL → Keycloak → Vaultwarden SSO

**MinIO kustomization — PVC immutability error**
- `pvc.yaml` in git is clean (no `volumeName`)
- Error likely originates in `helmrelease.yaml` — investigation in progress

### 🟡 Medium Priority

**CoreDNS HelmRelease**
- Stuck in `Unknown / reconciliation in progress`
- Pod itself is healthy (`1/1 Running`)
- Fix: resume the suspended HelmRelease to let Flux retry

**Vaultwarden SSO**
- Disabled as workaround; local auth working
- Re-enable once Keycloak is stable

### 🔵 On the Horizon

- Evaluate k8s-gateway as longer-term replacement for per-host Pi-hole DNS overrides
- Restore dependency chain: PostgreSQL → Keycloak → Vaultwarden SSO

---

## Key Learnings & Gotchas

**SOPS / Flux decryption**  
The `flux-system` kustomization in `gotk-sync.yaml` must include a `decryption` block. Without it, every reconcile cycle overwrites decrypted secrets with raw ciphertext.

**Flux `postBuild` variable substitution**  
`${SECRET_DOMAIN}` variables are not substituted inside ConfigMap blobs used via `valuesFrom`. Move them directly to `spec.values` in the HelmRelease.

**Talos + NFS**  
Talos does not run `rpc.statd`. NFS storage classes require the `nolock` mount option and the `nfs-utils` Talos extension.

**Cilium on Talos**  
`KUBERNETES_SERVICE_HOST` and `k8sServiceHost` must reflect the actual node IP. After a node IP change, these can get hardcoded in DaemonSet env vars and require a direct JSON patch to fix.

**Internal LAN access**  
Services needing internal access require both an `external` and `internal` class Ingress. Learned through Vaultwarden, Keycloak, and Kerberos agent troubleshooting.

**StatefulSet storage migration**  
Helm blocks direct `storageClass` changes on StatefulSets. Requires `helm uninstall` + Flux suspend/resume cycle for a clean reinstall.

**Talos install disk**  
When bootstrapping, the ISO USB and install target must be separate physical devices to avoid Talos installing to the wrong disk.

**Pre-cleanup checklist**  
Before removing HelmReleases: verify no ConfigMaps/Secrets reference the service hostnames via `kubectl` grep. Suspend active releases (`flux suspend`) before destructive operations.

---

## GitOps Patterns

- Apps live under `kubernetes/apps/` with per-app subdirectories
- Flux `suspend`/`resume` used deliberately for maintenance windows and forced reconciliation
- Dependency restoration order: **PostgreSQL → Keycloak → Vaultwarden/MinIO**
- All cluster state managed through `cillflux`; manual changes are temporary and should be committed back

---

## Command Reference

```bash
# Flux
flux suspend kustomization <name>
flux resume kustomization <name>
flux reconcile kustomization <name> --with-source
flux get helmreleases -A

# Kubectl
kubectl get pods -n <namespace>
kubectl describe helmrelease <name> -n <namespace>
kubectl logs -n <namespace> <pod> --previous

# Talos
talosctl dmesg --follow
talosctl health
talosctl service list

# SOPS
sops -e -i <file>        # encrypt in place
sops -d <file>           # decrypt to stdout
```

---

*Keep this file updated as the cluster evolves. When opening a new Claude chat in this project, this file provides full context without relying on memory summarization.*
