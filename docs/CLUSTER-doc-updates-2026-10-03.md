# Cluster Doc Update — 2026-10-03

Weekly Renovate review. Seven merges, two queued, nothing broke. The
end-of-run health pass is what earned its keep: it surfaced two faults
that predate today, and both turned out to be fallout from manual or
structural changes earlier in the week rather than anything Renovate
did. One had been sitting in the outstanding list since 2026-09-25
with a diagnosis that was wrong; the other was ten hours old and had
quietly broken part of the production Loki.

## Renovate review

`git pull` showed eight of the nine Renovate branches as `(forced
update)` — the same pattern that caught out PR #974 on 2026-09-26. No
harm this time: `check` recorded each head SHA after the force-pushes,
and every changelog below was read against that recorded head.

**Merged** (each via `weekly-renovate-review.sh merge`, pod snapshot
before and after, both `GitRepository` sources reconciled):

| PR   | Change                                   | Type  |
|------|------------------------------------------|-------|
| #984 | reloader chart 2.2.17 → 2.2.18           | patch |
| #983 | pihole chart 2.0.13 → 2.0.14             | patch |
| #982 | grafana chart 13.2.5 → 13.2.7            | patch |
| #980 | immich-server v3.2.2 → v3.2.4            | patch |
| #978 | kube-prometheus-stack 91.6.0 → 91.9.0    | minor |
| #986 | coredns chart 1.47.1 → 1.48.2            | minor |
| #981 | Flux v2.9.5 → v2.9.6                     | patch |

**Queued for Tom:**

- **#987 external-dns 1.22.0 → 1.23.0.** The chart notes say only "bump
  app to v0.23.0" — exactly the 2026-09-23 trap. The *app* notes carry
  an "Action required before upgrade" section and three breaking
  changes (`--crd-registry-namespace`, Gandi removal, webhook body cap).
  On reading, none should bite: we use `DNSEndpoint` as a *source*
  (`--crd-source-kind`), not the `crd` *registry*, and do not use TXT
  encryption. But an explicit action-required section is "Needs Tom"
  by definition. Worth noting for later: v0.23.0 adds
  `--enable-legacy-annotation-prefix`, which reads *both* annotation
  prefixes — a safer migration path off the
  `--annotation-prefix=external-dns.alpha.kubernetes.io/` pin than the
  flag-day that pin currently implies. Recommend `--dry-run` first.
- **#985 Keycloak 26.7.4 → 26.8.0.** Guarded path. Large feature
  release: automatic database index creation (a schema change on
  startup) and new `delegation:user` / `delegation:client` client
  scopes auto-created as Optional in **every realm**. Needs the
  upgrading guide read before merging.

### What was verified beyond the changelogs

Several of these were "patch" or "minor" on the label and something
more in substance, so each got a `helm template` of old vs new against
the live `spec.values` rather than a `flux diff`:

- **CoreDNS now runs as non-root.** Chart 1.48.0 changed the container
  defaults to `runAsNonRoot`, UID/GID 65532, `RuntimeDefault` seccomp.
  We do not override `securityContext`, so this applied to a
  single-replica cluster DNS. The rendered diff was exactly that plus
  the image (1.14.6 → 1.14.7, which pins the numeric UID upstream).
  The risk is binding :53 as non-root; checked before merging:

  ```
  $ kubectl exec -n pihole deploy/pihole -- cat /proc/sys/net/ipv4/ip_unprivileged_port_start
  0
  ```

  containerd sets this to 0 in every pod network namespace on this
  node, so a non-root process can bind :53 even without
  `NET_BIND_SERVICE` (which the chart keeps anyway). After merge:
  pod on 1.14.7 as UID 65532, 0 restarts, and `getent hosts` from an
  application pod resolved a cluster Service, a cross-namespace
  Service and `github.com`.
- **Pi-hole FTL 6.7.1 locks `misc.dnsmasq_lines` against API/web-UI
  changes** (four High/Moderate security fixes behind it). That is
  where our `address=` + `local=` overrides live in spirit, so it
  mattered — but this chart delivers `customDnsmasq` as a ConfigMap
  mounted into `/etc/dnsmasq.d` with `FTLCONF_misc_etc_dnsmasq_d`, not
  through `dnsmasq_lines`. Unaffected. The app bump was a no-op here
  anyway: our values already pin `2026.09.0`. The render diff also
  shows the admin password changing — a `helm template` artifact
  (`randAlphaNum` with no cluster to `lookup`); the chart reuses the
  existing Secret on a real upgrade.
- **Grafana 13.2.6 sets `readOnlyRootFilesystem: true` on the
  sidecars.** Dashboard and datasource sidecars came up and wrote
  dashboards to `/tmp/dashboards` without complaint.
- **kube-prometheus-stack 91.8.1 sets `prometheusScrape: false` on the
  node-exporter subchart.** That only removes the `prometheus.io/scrape`
  annotation; the ServiceMonitor is untouched and both node-exporter
  jobs stayed `up`. Operator and CRDs unchanged at v0.94.1.

A minor pre-existing nit found along the way: Grafana's two
`k8s-sidecar` containers both try to bind the same health port, and
whichever loses logs `OSError: [Errno 98] Address in use`. Loki shows
the previous pod doing the same on 2026-09-27, the sidecar image did
not change today, and both sidecars function. Not fixed.

## `gitops.gs-farm.net`: the 504 was a NetworkPolicy

The outstanding item from 2026-09-25 said the app was fine and that an
in-cluster probe of `weave-gitops.flux-system.svc:9001` returned 200.
Today, from a pod in `kube-system`, both the Service and the pod IP
timed out:

```
podIP:9001 -> 000
svc:9001   -> 000
```

The cause is the 2026-09-25 Flux handover itself. Since
`gotk-components.yaml` was deleted, the `flux` Kustomization applies
Flux's upstream NetworkPolicies on purpose (see the comment in
`kubernetes/flux/config/flux.yaml`). One of them, `allow-scraping`, has
an empty `podSelector` — it selects **every pod in `flux-system`** and
admits only TCP 8080. Weave GitOps also lives in `flux-system`, so
nginx → :9001 was dropped. Ingress access logs in Loki show the 504s
from 2026-09-26, the day after the handover.

The pod stayed `1/1` with 0 restarts throughout because its probes —
`httpGet /` with a 1s timeout — come from the kubelet, i.e. host
traffic, which Cilium does not subject to these policies. That is also
why the earlier probe read 200: a `kubectl port-forward` arrives via
the kubelet too. Confirmed after the fix, with only nginx admitted — a
port-forward to the Service still returns 200 while a `kube-system`
pod is refused. **Any test of reachability through a
NetworkPolicy has to come from a pod in another namespace**, not from
`port-forward` or the probes.

Fixed in `ec3874a7`:
`kubernetes/apps/flux-system/weave-gitops/app/networkpolicy.yaml`
admits pods `app.kubernetes.io/name=ingress-nginx,
app.kubernetes.io/instance=nginx-internal` from namespace `network` to
weave-gitops on TCP 9001, and nothing else. Flux's own policies are
unchanged. After reconcile, `gitops.gs-farm.net/` and
`/api/flux/version` return 200, a probe from `kube-system` is still
refused, and `ingress-check` reports all 14 internal ingresses
reachable. Gitops had been the only failing host since the check was
added on 2026-09-25, so this should be its first fully clean run (past
results are not stored, so that is inferred from the 504 history).

The general lesson: **anything added to `flux-system` now needs its
own ingress NetworkPolicy**, and will look healthy without one.

## A second Loki, installed by hand into `default`

The health pass listed a HelmRelease `default/loki` failing:

```
Ingress "loki-gateway" is invalid: spec.rules[0].host:
  Invalid value: "loki.${SECRET_DOMAIN}"
```

It carried no Flux labels and was created at 2026-10-03 01:57 UTC,
inside the 2026-10-02 NanoStation session. The most likely origin is
`kubectl apply` of `kubernetes/apps/observability/loki/app/` without
`-n`: everything lands in `default`, and Flux's `postBuild`
substitution never runs, hence the literal `${SECRET_DOMAIN}`.

"Failed" undersold it. Only the Ingress had been rejected; the rest of
the release was installed and running for ten hours — StatefulSet
`loki-0`, gateway, canary DaemonSet, results-cache, and a 10Gi PVC on
`gsks0`. Nothing was writing to it: Alloy pushes to `http://loki:3100`,
which resolves in Alloy's own namespace, `observability`.

The real damage was cluster-scoped. Both releases render a
`ClusterRole/loki-clusterrole` and `ClusterRoleBinding/loki-clusterrolebinding`
under the same names, and the live objects had been re-created by the
stray release, with the binding's subject switched to
`ServiceAccount default/loki`. The production Loki's rules sidecar
had lost its ConfigMap/Secret permissions:

```
403 Forbidden lines in observability/loki-0, last 6h: 5674
```

Nothing alerted, because the NanoStation rules are mounted directly at
`/rules/fake` (the 2026-10-02 workaround) and never go through that
sidecar — so the breakage had no visible symptom at all.

Three loose ConfigMaps came along with it — `loki-dashboard`,
`loki-datasource`, `loki-ruler-rules` — byte-identical to their
`observability` counterparts, unowned by Helm or Flux. Grafana's
sidecars watch `NAMESPACE=ALL`, so the stray datasource and dashboard
were being loaded into Grafana as duplicates.

Cleanup, in this order (the order matters):

1. `kubectl delete hr -n default loki` — the Flux finalizer runs the
   Helm uninstall, so nothing reinstalls it. This **also deleted the
   shared ClusterRole and ClusterRoleBinding**, leaving production Loki
   with no binding at all for a moment.
2. `flux reconcile helmrelease loki -n observability --force`
   immediately, which re-applied the real release's manifest. Both
   objects came back annotated `release-namespace: observability`,
   bound to `ServiceAccount observability/loki`.
3. The PVC needed no action: the chart's StatefulSet retention policy
   deleted `storage-loki-0` with the StatefulSet, and the `Delete`
   reclaim policy removed the PV.
4. Deleted the three ConfigMaps after confirming no owner.

After: 0 `Forbidden` lines in the next minute, both NanoStation rules
`health=ok`, Loki ingesting (556 lines in 2m), nothing named `loki`
left in `default`, full health pass clean. No commit — the stray was
never in git.

The general lessons, both worth a `CLAUDE.md` gotcha:

- **A hand-applied copy of a Flux app is wrong in two ways at once:**
  no `-n` puts it in `default` (Kustomizations here set the namespace
  via `targetNamespace`, not in the manifests), and skipping `postBuild`
  leaves `${VAR}` literals. Use `flux build kustomization <name>
  --path ...` or let Flux apply it.
- **Cluster-scoped chart objects collide across release namespaces.**
  A second install of the same chart under the same release name
  silently takes over the first install's ClusterRoles and webhooks. And uninstalling the
  second deletes them outright, so the first must be force-reconciled
  straight after.

## Suggested `CLUSTER.md` edits

- **Line 774, the `gitops.gs-farm.net returns 504` item** — resolve it,
  and correct it: the claim that an in-cluster probe returned 200 does
  not hold from a pod outside `flux-system`. Point at the NetworkPolicy
  section above. The note about Weave GitOps OSS being sunset upstream
  still stands as a reason to consider removing it later.
- **Line 225, "CoreDNS HelmRelease — stuck in Unknown"** — stale. The
  HelmRelease is `Ready` on chart 1.48.2 as of today and was upgraded
  cleanly through Flux. Remove, or move to resolved with a note that
  CoreDNS now runs non-root.
- **Line 90, the Keycloak row** — says 26.7.3; the live image is
  `26.7.4`. Will change again if #985 merges.
- Flux is at **v2.9.6**, Immich at **v3.2.4**, kube-prometheus-stack
  at **91.9.0**, wherever the tool-version table records them.
- Under *Key Learnings & Gotchas*, the two lessons from the Loki
  section and the `flux-system` NetworkPolicy one. They belong in
  `CLAUDE.md` too, since all three are things a session needs before
  it starts debugging rather than after.
