# Cluster Doc Update — 2026-09-25

## The alert that was mailing every ten minutes

The email receiver wired up on 2026-09-24 started working, and then
would not stop. Tom's report: "Alerts are toggling at a high rate...
Like every 10 minutes on average."

That was accurate to the minute. Over the preceding twelve hours:

```
54 firing episodes                             (~1 every 13 min)
alertmanager_notifications_total{email} = 83
alertmanager_notifications_failed_total = 0
```

Every one of them was the same alert:

```
InfoInhibitor  namespace=flux-system  severity=none  ->  receivers: [email]
```

### Why it went to email

`InfoInhibitor` is not an alert. It fires whenever any `severity=info`
alert is firing in a namespace where nothing warning-or-critical is
firing, and it exists for exactly one purpose: to be the *source* of an
inhibit rule that silences info alerts. kube-prometheus-stack's default
route therefore sends `alertname =~ "InfoInhibitor|Watchdog"` to the
`null` receiver.

The route written yesterday null-routed **Watchdog only**. `InfoInhibitor`
fell through to the default receiver, which is `email`. With
`send_resolved: true`, every transition produced two messages.

The same omission dropped two of the chart's three `inhibit_rules`,
including the `InfoInhibitor -> severity=info` rule that is the entire
point of the mechanism. So info alerts had nothing suppressing them
either — that had simply not been noticed yet, because the only info
alert in the cluster was stuck in `pending` and never reached `firing`.

Restored in `helmvalues.yaml`:

```yaml
routes:
  - receiver: "null"
    matchers:
      - 'alertname =~ "InfoInhibitor|Watchdog"'
inhibit_rules:
  - source_matchers: ['severity = "critical"']
    target_matchers: ['severity =~ "warning|info"']
    equal: ["alertname", "namespace"]
  - source_matchers: ['severity = "warning"']
    target_matchers: ['severity = "info"']
    equal: ["alertname", "namespace"]
  - source_matchers: ['alertname = "InfoInhibitor"']
    target_matchers: ['severity = "info"']
    equal: ["namespace"]
```

Verified against the running Alertmanager rather than the diff — the
`valuesFrom` ConfigMap trap from yesterday means the config can be
correct in git and stale in the pod:

```
$ .../api/v2/alerts?active=true&inhibited=true
Watchdog | receivers= ['null'] | state= active
```

**The generalisable rule:** when replacing a chart's default
Alertmanager route, the defaults are not boilerplate. Read what each
one is load-bearing for before dropping it.

---

## Root cause: two Kustomizations fighting over Flux's own components

The mail was noise. What was generating it had been running since the
cluster was built.

`CPUThrottlingHigh` in `flux-system` was flapping because flux
controller pods were being **created continuously** — not restarting,
but replaced, from two ReplicaSets alternating:

```
kustomize-controller    deployment revision 142326
helm-controller         deployment revision 142416
source-controller       deployment revision 141618
notification-controller deployment revision  36397
```

142,000 rollouts in 172 days. About 34 an hour, sustained, for the life
of the cluster.

### Three Kustomizations, two answers

| Kustomization | Source | Path | Interval | Renders |
|---|---|---|---|---|
| `flux` | OCI `flux-manifests:v2.9.5` | `./` | 10m | **patched** — cpu 2/2Gi, `--concurrent=8`, `--kube-api-qps=500`, `--kube-api-burst=1000`, `--requeue-dependency=5s`, OOMWatch |
| `flux-system` | git `flux-system` | `./kubernetes/flux` | 10m | **stock** — cpu 1/1Gi, no tuning |
| `cluster` | git `home-kubernetes` | `./kubernetes/flux` | 30m | same stock manifests |

`kubernetes/flux/config/flux.yaml` installs Flux from the OCI artifact
and patches it. `kubernetes/flux/flux-system/gotk-components.yaml` — a
270KB copy written by `flux bootstrap` — installs the same v2.9.5
components with none of those patches. Both were applied. Each apply
rewrote the pod template, so Kubernetes created a new ReplicaSet and
killed the running pod, every ten minutes, both directions, forever.

Two bootstrap conventions layered on top of each other: the legacy
`flux bootstrap` output was never removed when the home-ops OCI pattern
was adopted.

### Why nothing ever caught it

At any given instant every Deployment was `1/1 Available`, every
Kustomization `Ready`, every HelmRelease `Ready`. A health check that
samples state sees nothing wrong, because nothing *is* wrong at any
single moment — the fault is only visible in the derivative.

Both symptoms looked like other problems:

- `CPUThrottlingHigh` reads as a resources problem. It was startup
  throttling on pods that were seconds old.
- The tuning in `flux.yaml` was in effect roughly half the time, which
  makes reconcile-performance measurements meaningless.
- The four Flux controllers that crash-looped during yesterday's Talos
  apply were, it turns out, being recycled constantly anyway.

The check that does find it is the rollout counter:

```bash
kubectl get deploy -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision'
```

A revision number that cannot be explained by the number of times
anyone has actually changed that Deployment is the signature.

### The prune hazard

The obvious fix — delete `gotk-components.yaml` — would have taken the
cluster down.

Flux computes pruning by diffing a Kustomization's **previous
inventory** against the newly applied set. Removing a resource from a
path deletes it, whether or not another Kustomization also manages it.
`flux-system` and `cluster` shared **29 objects** with `flux`:

```
 11  CustomResourceDefinition     <- backing 38 Kustomizations,
  4  Deployment                      28 HelmReleases,
  4  ServiceAccount                  24 HelmRepositories
  3  Service
  3  ClusterRole
  2  ClusterRoleBinding
  1  ResourceQuota
  1  Namespace   (flux-system itself)
```

Dropping the file with `prune: true` would have garbage-collected the
Flux CRDs and cascade-deleted every Flux custom resource in the
cluster.

### The handover, in three commits

**1. Prepare** (`1cd8ed47`). `prune: false` on both `flux-system` and
`cluster`. With pruning off, the inventory shrinks without deleting
anything.

Also dropped the NetworkPolicy delete-patch from `flux.yaml`, so the
OCI Kustomization adopts `allow-egress`, `allow-scraping` and
`allow-webhooks` *before* `gotk-components.yaml` stops supplying them.
That patch was inherited from a k3s-targeted template and its comment
("does not work with k3s") does not apply here — this is Talos with
Cilium and the policies have been enforced for 172 days. They are also
real ingress restriction rather than decoration: `allow-scraping`
selects every pod in the namespace, so deleting the policies would have
*opened* `flux-system` rather than locked it down.

**2. Remove** (`3584a637`). Deleted `gotk-components.yaml` and its CRD
`substitute: disabled` patch, which existed only to stop `cluster`'s
`postBuild` envsubst mangling the single `${...}` string inside it.

Verified before and after:

```
             before   after
kustomizations   38      38
helmreleases     28      28
helmrepositories 24      24
flux CRDs        15      15
networkpolicies   5       5

inventories:  flux 43 | flux-system 64 -> 32 | cluster 64 -> 32
```

**3. Restore** (`5deaab15`). `prune: true` back on both. By this point
the stored inventory already matched the applied set, so the diff was
32 against 32 and there was nothing to collect. Confirmed: no deletions.

### Result

```
$ kubectl get deploy -n flux-system -o custom-columns=NAME:...,OWNER:...
kustomize-controller   flux
helm-controller        flux
source-controller      flux

$ kubectl get deploy -n flux-system kustomize-controller -o json | ...
  limits: {'cpu': '2', 'memory': '2Gi'}
  args:   --concurrent=8 --kube-api-qps=500 --kube-api-burst=1000
          --requeue-dependency=5s
```

Single owner, and the tuned spec is live and staying live for the first
time.

Secondary benefit: bumping Flux is now a one-line change to the
`flux-manifests` OCIRepository tag, which Renovate can track — rather
than re-running `flux bootstrap` to regenerate a 270KB file that then
has to be reviewed by hand.

---

## Suggested `CLUSTER.md` Known Gotchas entries

- **`InfoInhibitor` must be null-routed alongside `Watchdog`.** The
  kube-prometheus-stack default matcher is
  `alertname =~ "InfoInhibitor|Watchdog"`. `InfoInhibitor` is plumbing,
  not an alert — it toggles as often as the noisiest info alert in the
  cluster. Routed anywhere real it produced 83 emails in under a day.
  Carry over all three default `inhibit_rules` too; without the
  `InfoInhibitor -> severity=info` rule the mechanism is inert.

- **A Deployment can be rewritten forever without anything reporting
  unhealthy.** Two Kustomizations managing the same Deployment with
  different specs produce a new ReplicaSet and a new pod on every
  reconcile of either one. Every instantaneous check passes. Look at
  `deployment.kubernetes.io/revision` — 142,326 in 172 days here.

- **Flux prune deletes shared objects.** Pruning diffs a
  Kustomization's previous inventory against the new one, with no
  awareness that another Kustomization manages the same object. Before
  removing resources from a path, compare inventories
  (`-o jsonpath='{.status.inventory.entries[*].id}'`) and, if they
  overlap, stage it: `prune: false` → remove and verify → `prune: true`.

---

## Added: a rollout churn check in the weekly review

Nothing in the weekly health pass could have found the above, because
every check in it samples current state and the fault only existed in
the derivative. Added `rollout-churn`, which does not:

```
scripts/weekly-renovate-review.sh rollout-churn   # standalone
scripts/weekly-renovate-review.sh health          # included in the pass
```

It reads `deployment.kubernetes.io/revision` for every Deployment and
compares it against the previous run's value, stored in
`~/.local/state/weekly-renovate-review/rollouts.json`. At the weekly
cadence of this review that is a week-over-week rollout rate.

The state file is the whole point. A raw revision counter cannot tell
"142k accumulated over six months" from "142k since Tuesday", and since
the counter never resets, a threshold on the absolute number would have
kept firing for years after the fix. Storing where each counter stood
last time is what turns it into a rate.

A Deployment is only reported when all three of these hold, so one busy
afternoon or a newly created workload does not trip it:

| Knob | Default | Purpose |
|---|---|---|
| `CHURN_RATE_PER_DAY` | 5 | Rollouts/day. Renovate-driven bumps run ~0.15/day, a fight runs hundreds |
| `CHURN_MIN_ROLLOUTS` | 10 | Absolute floor, so small numbers over a short window cannot produce a big rate |
| `CHURN_MIN_WINDOW_DAYS` | 0.5 | Minimum observation window |

Two details that took a second pass to get right:

- **The baseline only advances once the window is wide enough.** Without
  that, running `health` twice in an hour would reset the clock every
  time and nothing would ever accumulate.
- **First sight of a Deployment falls back to revision 0 at
  `creationTimestamp`** — the lifetime average — so the very first run
  is useful rather than silent, and it labels the output as such. It
  self-corrects: once a baseline exists, history stops counting. A
  counter that has gone *backwards* (Deployment deleted and recreated)
  takes the same fallback rather than producing a negative delta.

Verified against all three paths before committing: the live first run
correctly reported the four flux-system controllers at 822-826/day; a
synthetic baseline dated a week back flagged an injected +1200 while
suppressing an injected +9 under the floor; and an injected counter
reset fell back to lifetime cleanly.

Deployments only. StatefulSets and DaemonSets carry revision *hashes*
rather than a monotonic counter, so the same trick does not work on
them — worth knowing if something ever churns there instead.

The baseline was seeded on 2026-09-25 immediately after the fix, so the
next weekly review measures a real post-fix week rather than reporting
the 172-day lifetime average of a problem that is already solved.

---

## Alertmanager got a UI, and gsfarmctl got its own resolver

### The 404 that looked like "not exposed"

`prometheus.gs-farm.net` appearing unreachable turned out not to be an
ingress problem at all. Prometheus and Grafana are both on the
`internal` ingress class and both have worked from any LAN client since
install — Pi-hole wildcards the whole domain:

```yaml
# kubernetes/apps/network/pihole/app/helmrelease.yaml
customDnsmasq:
  - "local=/gs-farm.net/"
  - "address=/gs-farm.net/10.0.10.1"
```

What could not resolve them was **gsfarmctl itself**, whose
`/etc/resolv.conf` has pointed at `8.8.8.8` and `75.75.75.75` since
2024-09-29. That is the real reason every investigation from the control
host this week needed `kubectl port-forward`. `grafana.gs-farm.net` does
resolve from here, to Cloudflare proxy addresses — there is a public
record for a host whose only ingress is internal, which is worth a
separate look.

Alertmanager was the one genuine gap. It had no Ingress at all, only a
ClusterIP, so `alertmanager.gs-farm.net` hit the wildcard, reached nginx,
matched no rule and returned 404. Silences, inhibition state and "what
receiver will this alert actually hit" were reachable only by
port-forward — a bad thing to be missing on the same day the routing
tree was rebuilt.

### What was added

An internal Ingress in the kube-prometheus-stack values, mirroring the
Prometheus one exactly, including the absent `secretName`:

```yaml
alertmanager:
  ingress:
    enabled: true
    ingressClassName: internal
    hosts: ["alertmanager.${SECRET_DOMAIN}"]
    tls:
      - hosts: ["alertmanager.${SECRET_DOMAIN}"]
```

No `secretName` is correct here rather than an oversight:
`nginx-internal` sets
`default-ssl-certificate: network/gs-farm-net-production-tls`, and that
certificate carries `*.gs-farm.net`. Verified before relying on it —
`openssl s_client -servername alertmanager.gs-farm.net` against
`10.0.10.1` already returned the wildcard SAN, before any Ingress
existed.

Plus an Alertmanager datasource in Grafana. Grafana could already list
Prometheus *rules* read-only through the Prometheus datasource, which is
easy to mistake for full alerting visibility; silences and inhibition
are Alertmanager-side and were simply absent.

```yaml
- name: Alertmanager
  type: alertmanager
  uid: alertmanager
  url: http://kube-prometheus-stack-alertmanager.observability.svc.cluster.local:9093
  jsonData:
    implementation: prometheus
    handleGrafanaManagedAlerts: false
```

`implementation: prometheus` distinguishes a vanilla Alertmanager from
Mimir/Cortex, which expose a different API.
`handleGrafanaManagedAlerts: false` keeps Grafana from routing alert
rules of its own through the household email receiver.

Verified through the ingress rather than from the diff:

```
alertmanager.gs-farm.net   200   (valid wildcard cert, no -k required)

/api/v2/alerts?active=true&inhibited=true
Watchdog    none    active    -> null
```

One alert, firing into the null receiver, which is the intended
steady state after the 2026-09-24 routing fix.

**This ingress is not read-only.** Anyone on the LAN can create a
silence. That is the same trust boundary that already exposes
Prometheus's admin API (`enableAdminAPI: true`, which can delete
series), so it is consistent rather than new — but it is worth knowing
before anything else lands on the internal class.

### Which UI to use for what

Grafana is the right default: it is the only one with SSO, it carries 35
provisioned dashboards, and it is the only place Prometheus and Loki sit
side by side.

The Prometheus UI earns its place for the things Grafana renders badly,
all three of which have actually bitten this cluster:

| Page | Why it matters here |
|---|---|
| `/targets` | `storage1-node-exporter` was down from install to 2026-09-24; controller-manager and scheduler pointed at a nonexistent address. A dashboard draws an absent target as an empty panel, which reads as idle |
| `/rules` | Both hand-written PrometheusRules were never evaluated under `ruleSelectorNilUsesHelmValues: true`. Grafana showed nothing either way |
| `/tsdb-status` | Cardinality, relevant while watching whether 10d retention survives 80,363 -> 108,235 series |

Grafana answers *what is the cluster doing*. Prometheus answers *is the
monitoring itself intact*. The failure mode in this cluster has
consistently been the second.

### gsfarmctl resolves gs-farm.net itself now

`scripts/setup-gsfarmctl-dns.sh` installs dnsmasq on the control host,
listening on loopback only, carrying the same two directives Pi-hole
serves and forwarding everything else to `1.1.1.1` / `8.8.8.8`.

The obvious alternative — point `/etc/resolv.conf` at Pi-hole with a
public resolver second — was rejected, and the reason generalises.
**glibc's resolver falls through to the next `nameserver` only after a
timeout, and re-pays it on every lookup.** With Pi-hole first, taking
the cluster down for maintenance would add roughly five seconds to every
public DNS query on this host — `apt`, `git`, `gh`, `curl` — exactly
when something is being fixed. A fallback that costs nothing while
healthy can still be the wrong design if the failure it covers is the
one you actually expect.

Answering locally has no such cost. gsfarmctl never queries Pi-hole, so
cluster downtime is invisible to it: public DNS is untouched, and
internal names still resolve but do not connect, which is the truth.

The `127.0.0.1` -> `1.1.1.1` fallback that *is* in the new resolv.conf
is not the same trap. A query to a loopback port with nothing listening
is **refused** immediately rather than dropped, so glibc moves on with
no timeout. Refused and unanswered are very different failures to a
resolver.

Two details the script is careful about:

- **`no-resolv` is mandatory.** Debian's dnsmasq reads
  `/etc/resolv.conf` for its upstreams by default, and that file is
  about to say `127.0.0.1`. Without `no-resolv` the resolver forwards
  to itself.
- **`local=/gs-farm.net/` is not optional**, for the same reason it is
  not optional in Pi-hole: `address=/` overrides only A and AAAA, so an
  HTTPS/SVCB query falls through to the public upstream and returns
  Cloudflare's real record advertising ECH and HTTP/3. Chrome-family
  browsers use it for connection setup and fail against internal nginx
  in ways that look unrelated to DNS.

`resolv.conf` is switched only after dnsmasq is proven to answer both an
internal and a public name, so a failure cannot strand the host without
a resolver. The original is saved to `/etc/resolv.conf.pre-dnsmasq` and
`--revert` restores it.

### Third instance the same day: alloy.gs-farm.net

Verifying the new resolver turned up one more host that looked exposed
and was not. `alloy.gs-farm.net` resolved, reached nginx, and returned
**503 — as it had since the ingress was written**.

```
svc/alloy      http-metrics 12345 -> 12345
ingress/alloy  backend port 12347
```

The Alloy chart exposes exactly one knob for the ingress backend port,
`faroPort`, and it defaults to `12347` — the Faro browser-telemetry
receiver. Faro is not enabled here, so the Service never opens that
port and the ingress pointed at a service port that did not exist. The
chart's own comment (`Enables ingress for Alloy (Faro port)`) describes
an intent this deployment never had; the value was inherited unchanged.

Nothing was actually broken. The pod was healthy at 2/2 and log
shipping to Loki was unaffected — only the UI was unreachable. Fixed by
setting `faroPort: 12345`, the port the Service does expose, with a
comment recording why a key named for Faro is serving the UI.

```
alloy.gs-farm.net  200   <title>Grafana Alloy</title>   /-/ready 200
```

Checked before exposing it: the Alloy config carries no inline
credentials (its only `secrets` reference is an RBAC rule for
Kubernetes discovery), so the UI reveals nothing the internal class
should not already see.

### The pattern worth naming

Three hosts in one week were reachable-looking and not, each for a
different reason, and none of them alerted:

| Host | Looked like | Actually |
|---|---|---|
| `prometheus` | not exposed | exposed; **gsfarmctl** could not resolve it |
| `alertmanager` | exposed (DNS resolved, nginx answered) | no Ingress at all — 404 |
| `alloy` | exposed | Ingress pointed at a closed Service port — 503 |

The common cause is the Pi-hole wildcard: `address=/gs-farm.net/` means
*every* name under the domain resolves and reaches nginx, so DNS
success and a TCP response prove nothing about whether the thing exists.
A blackhole reply would be a stronger signal, but the wildcard is what
makes new ingresses work without touching DNS, so the tradeoff stays.
The practical check is a status code, not a resolution: anything on the
internal class should answer 200/302, and a 404 or 503 there means the
route is broken rather than the app being down.

### And the fourth: s3.gs-farm.net on the internal class

The sweep's other survivor. `s3.gs-farm.net` answered **400** with
`Client sent an HTTP request to an HTTPS server.` — a message from
MinIO, not from nginx, which is the tell: the request arrived, at a TLS
listener, in plaintext.

MinIO serves TLS on its api port. The external ingress has always
carried the annotation that tells nginx so; the internal one had no
`annotations` block at all:

```yaml
ingress:
  main:      # external
    annotations:
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
  internal:  # <- had none
    className: internal
```

So `s3.gs-farm.net` worked from outside the LAN and was broken from
inside it, from the day it was written. Nothing noticed because
in-cluster consumers reach MinIO by Service name and never traverse
this ingress — **backups were never affected**, which is worth stating
plainly given what MinIO holds.

Fixed by adding the annotation. Verified, and note what "working" looks
like for an S3 endpoint:

```
s3.gs-farm.net/                    403  <Error><Code>AccessDenied</Code>...
s3.gs-farm.net/minio/health/live   200
```

A 403 carrying well-formed S3 XML is the healthy unauthenticated
response. Only the health endpoint gives a plain 200, which is what
actually proves MinIO is answering through the ingress rather than
nginx synthesising an error.

The MinIO pod was untouched by the Helm upgrade — same pod name, 0
restarts, unchanged 49-day age — since only ingress annotations
changed and the pod template did not. Checked for in-flight Volsync
mover jobs beforehand regardless; there were none.

### Sweep result

Thirteen of fourteen internal hosts now answer 200/302/403. The one
survivor is `gitops.gs-farm.net` (504), moved to the open-issues list
in `CLUSTER.md` at Tom's call. The check itself is three lines and
worth folding into the weekly health pass:

```bash
kubectl get ingress -A -o jsonpath='{range .items[?(@.spec.ingressClassName=="internal")]}{.spec.rules[*].host}{"\n"}{end}' \
  | tr ' ' '\n' | sort -u | while read -r h; do
      printf '%-28s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' "https://$h/" --max-time 20)"
    done
```
