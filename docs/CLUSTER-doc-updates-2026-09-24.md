# Cluster Doc Update — 2026-09-24

## Clearing the guarded-path Renovate queue

Follow-on to `CLUSTER-doc-updates-2026-09-23.md`. The four PRs that
review had deliberately left queued were assessed and merged: `#963`
(Keycloak), `#962` (Vaultwarden), `#966` (app-template ×4) and `#968`
(kube-prometheus-stack, two majors).

All four were guarded only by the *path* rules in the review workflow,
not by anything found wrong with them. They were merged with
`merge <pr> --force`, which is exactly what that flag is for — Tom
reviewed and approved each one explicitly.

**No regressions. Cluster ended fully green: all pods ready, all
Kustomizations Ready, all HelmReleases Ready.**

### Keycloak 26.7.4 (`#963`) — security release

Six CVEs, most notably a **privilege escalation** where the
impersonation role could assume realm administrator, plus a username
takeover leading to account lockout and an unauthenticated DoS via
unbounded locale caching. Also Quarkus 3.33.3.2 and a fix for a
performance regression carried since 26.6.2.

Verification that matters for SSO is not "the pod is up" — it is that
each realm still answers OIDC discovery. All four do:

```
master       HTTP 200  issuer=https://elvis.gs-farm.net/realms/master
vaultwarden  HTTP 200  issuer=https://elvis.gs-farm.net/realms/vaultwarden
grafana      HTTP 200  issuer=https://elvis.gs-farm.net/realms/grafana
immich       HTTP 200  issuer=https://elvis.gs-farm.net/realms/immich
```

### Vaultwarden 1.37.3 (`#962`)

Two security fixes — 2FA "remember" tokens are now revoked when
credentials or 2FA change, and prelogin/auth-request endpoints are rate
limited — plus a fix for password change against newer web-vault.

Note for later: this release adds `SSO_SIGNUPS_ALLOWED`. Vaultwarden's
startup log confirms `SSO_ENABLED`, `SSO_CLIENT_ID`,
`SSO_CLIENT_SECRET`, `SSO_AUTHORITY` and `SSO_SCOPES` are all already
pinned in `config.json` on the PVC, so **that new setting must be
changed in the Admin Panel**. Putting it in the HelmRelease would look
deployed and do nothing. (Existing gotcha, re-confirmed.)

## Verifying a chart bump by rendering it, not by reading about it

The reusable technique from this round, and the direct answer to the
external-dns failure the day before.

`flux diff kustomization` compares only the **HelmRelease CR**. For a
chart version bump that is nearly useless — it shows
`version: X -> Y` and nothing about what the chart actually renders.
It also produces two kinds of false positive worth recognising:

- **Unsubstituted variables.** A local build does not run Flux's
  `postBuild` envsubst, so `${SECRET_DOMAIN}`, `${TIMEZONE}` and
  friends appear as changes. They are not.
- **Stale PR branches.** `#966` was cut before `#962` merged, so the
  diff showed Vaultwarden going *backwards* to 1.37.2. A three-way
  merge does not do that. Confirmed before merging with
  `git merge-tree --write-tree main <branch>` and inspecting the
  resulting tree — clean merge, image preserved at 1.37.3.

The check that actually answers the question is to render both chart
versions against the **live values** and diff the output:

```bash
helm repo add bjw-s-labs https://bjw-s-labs.github.io/helm-charts
kubectl get hr -n <ns> <name> -o jsonpath='{.spec.values}' > values.json
for v in <old> <new>; do
  helm template <name> <repo>/<chart> --version "$v" -n <ns> -f values.json > "r.$v.yaml"
done
diff -u r.<old>.yaml r.<new>.yaml | grep -E '^[-+][^-+]'
```

JSON is valid YAML, so `-f values.json` works directly — no `yq`
needed (and `python3-yaml` is not installed on `gsfarmctl`).

**Watch out for `valuesFrom`.** `kube-prometheus-stack` keeps its
values in a ConfigMap, not `spec.values`, so the jsonpath above
returned empty and the first render silently used chart defaults. Pull
them from the right place:

```bash
kubectl get cm -n observability kube-prometheus-stack-values \
  -o jsonpath='{.data.values\.yaml}' > values.yaml
```

For `#966` this turned a four-app library bump touching Keycloak,
MinIO, Cloudflared and Vaultwarden into a provably trivial change:

| App | Objects | Diff lines | `helm.sh/chart` label | Other |
|---|---|---|---|---|
| keycloak | 3 | 6 | 6 | **0** |
| minio | 6 | 12 | 12 | **0** |
| cloudflared | 4 | 8 | 8 | **0** |
| vaultwarden | 5 | 10 | 10 | **0** |

Across all 18 rendered objects the only difference was the chart label.
The prediction that followed — no pods would restart — held exactly:
MinIO stayed at 48d uptime and Cloudflared at 15h through the upgrade.

**Generalised:** changelogs describe intent; rendering describes
effect. Use rendering whenever the risk is in *what gets deployed*.
It would not have caught external-dns, where the risk was in runtime
behaviour against a third-party API — knowing which kind of risk you
face is the actual skill.

## kube-prometheus-stack 89.2.4 → 91.5.1 (`#968`)

Two majors in one step, and the `!` in the title overstated the risk
for this cluster. Worth recording why, since the same reasoning applies
next time.

**What the majors actually were:**

- **v90.0.0** — control-plane ServiceMonitors stop using credentials on
  the scraper's filesystem (`bearerTokenFile`, `tlsConfig.caFile`) and
  switch to a Secret-based `authorization` plus the `kube-root-ca.crt`
  ConfigMap.
- **v91.0.0** — prometheus-operator v0.94.0, which also drops wildcard
  verbs from the operator ClusterRole.

**All four documented v0.94.0 breaking changes were non-issues here**,
which is only knowable by checking the cluster rather than the notes:

| Upstream requirement | This cluster |
|---|---|
| Alertmanager zero-value duration flags rejected | Already v0.34.0 — the change *is* the fix |
| Thanos >= v0.42.0 for delayed compaction | No Thanos configured |
| `retentionPercentage` needs Prometheus >= v3.11.0 | v3.14.0, field unset |
| `clusterPeerName` needs Alertmanager >= v0.30.0 | v0.34.0 |

### The ten CRD commands were not needed

Upstream documents ten `kubectl --server-side` commands to update the
`monitoring.coreos.com` CRDs for v0.94.0. **`crds: CreateReplace` on
the HelmRelease handled all of them automatically.** Before: all ten
CRDs stamped `operator.prometheus.io/version: 0.93.1`. After: `0.94.1`.

This works because the CRDs carry no Helm ownership labels — they come
from the chart's `crds/` directory, which is precisely what Flux's
`crds:` policy governs. They are also single-version each (`v1` or
`v1alpha1`), so there was no multi-version storage migration to worry
about. Check before assuming this holds for another chart:

```bash
kubectl get crd <name> -o jsonpath='{.metadata.labels}'   # empty = not Helm-owned
kubectl get crd <name> -o jsonpath='{range .spec.versions[*]}{.name} {end}'
```

### The real risk was the token Secret, and it was tested

The new ServiceMonitor auth depends on a legacy
`kubernetes.io/service-account-token` Secret being populated by the
control plane. Kubernetes has been steadily deprecating that mechanism
in favour of the TokenRequest API, this cluster runs **v1.35.2**, the
upstream docs were inconclusive, and there were **zero** such Secrets
anywhere in the cluster to serve as evidence.

Rather than guess, it was tested directly — a throwaway Secret in
`default`, annotated `kubernetes.io/service-account.name: default`,
was populated with `ca.crt`, `namespace` and `token` within seconds,
then deleted. **Legacy service-account-token Secrets still work on
1.35.2.**

Had that failed, apiserver, kubelet and coredns scraping would all have
broken on upgrade.

Post-upgrade the ServiceMonitors did switch as intended:

```
authorization: {"credentials":{"key":"token",
                 "name":"kube-prometheus-stack-prometheus-token"},"type":"Bearer"}
bearerTokenFile: <none>
tlsConfig.ca:    {"configMap":{"key":"ca.crt","name":"kube-root-ca.crt"}}
tlsConfig.caFile:<none>
```

Target health was identical before and after, and Prometheus logged
zero scrape errors.

**Generalised:** when an upgrade depends on a platform mechanism that
is being deprecated, and the cluster holds no example of that mechanism
working, a two-minute disposable probe beats both the documentation and
an assumption.

## Found: two control-plane scrape targets dead for ~170 days

Surfaced while assessing `#968`, unrelated to it, and **not fixed** —
recorded here as the next piece of work.

```
kube-controller-manager   down
kube-scheduler            down
storage1-node-exporter    down
```

The first two are almost certainly the standard Talos behaviour of
binding those components to localhost, so the chart's default
ServiceMonitors cannot reach them. They have been down since the stack
was installed 170 days ago, which means there has never been any
alerting on controller-manager or scheduler health.

It also means `#968`'s v90 ServiceMonitor change was lower-risk than it
looked: two of the ServiceMonitors it rewrites were already broken. The
ones genuinely at stake were apiserver, kubelet and coredns — all of
which survived.

`storage1-node-exporter` is the TrueNAS host exporter and is a separate
question from the Talos control-plane binding.

## Suggested `CLUSTER.md` Known Gotchas entries

- `flux diff kustomization` compares the **HelmRelease CR**, not what
  the chart renders — for a chart version bump it tells you almost
  nothing. To see the real effect, `helm template` both versions
  against the live values and diff. Two false positives to expect:
  unsubstituted `${VAR}` (local builds skip Flux's `postBuild` envsubst)
  and stale PR branches appearing to revert newer merges (verify with
  `git merge-tree --write-tree main <branch>` instead).
- Not every HelmRelease keeps its values in `spec.values` —
  `kube-prometheus-stack` uses `valuesFrom` a ConfigMap
  (`kube-prometheus-stack-values`, key `values.yaml`). A jsonpath on
  `.spec.values` returns empty and any render built from it silently
  uses chart defaults, which looks like a successful check but proves
  nothing.
- `crds: CreateReplace` on a HelmRelease satisfies the "run these ten
  `kubectl --server-side` commands" instruction that
  kube-prometheus-stack majors ship with — verified on the 89→91 jump,
  where all ten CRDs went 0.93.1 → 0.94.1 automatically. It works
  because those CRDs are unlabelled (installed from the chart's `crds/`
  directory, not Helm-owned). Confirm both facts before relying on it
  for a different chart.
- Legacy `kubernetes.io/service-account-token` Secrets are still
  populated by the control plane on Kubernetes **v1.35.2** — verified
  2026-09-24 with a disposable probe Secret. kube-prometheus-stack >=90
  depends on this for all control-plane scraping. If a future Kubernetes
  upgrade removes it, apiserver/kubelet/coredns metrics break. Re-run
  the probe after any major Kubernetes upgrade.
- `kube-controller-manager` and `kube-scheduler` Prometheus targets have
  been `down` since the observability stack was installed — the usual
  Talos localhost-binding behaviour, not a regression from any upgrade.
  There has been no alerting on either component. Do not read their
  absence as a symptom of whatever change you are currently making.
