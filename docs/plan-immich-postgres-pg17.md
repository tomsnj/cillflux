# Work plan: Immich Postgres 14 → 17

Status: **Phase 1 (rehearsal) complete and passed, 2026-09-26. Phase 2 ready to execute.** Written 2026-09-26 against PR
[#960](https://github.com/tomsnj/cillflux/pull/960)
(`ghcr.io/immich-app/postgres` 14 → 16), which is queued as "needs Tom"
from that day's Renovate review.

**Target decided 2026-09-26: PostgreSQL 17, not 16.** The work is
identical either way and a single hop buys three more years of runway,
so PR #960 should be **closed rather than merged** — it proposes the
wrong destination, not merely a premature one.

---

## 1. Read this first: the PR cannot simply be merged

PR #960 changes one thing in two files — the image tag:

```
-  ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf6335…
+  ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvectors0.2.0@sha256:1a078b2…
```

**PostgreSQL does not read a version-14 data directory with a version-17
binary.** The on-disk format changes between majors. Merging this PR as
delivered starts a newer server against the existing `PG_VERSION = 14`
directory, it refuses to start with

```
FATAL: database files are incompatible with server
DETAIL: The data directory was initialized by PostgreSQL version 14,
        which is not compatible with this version 17.6.
```

and `immich-postgres` crash-loops. Immich itself then follows, because
`immich-server` has no database. Nothing is *destroyed* — the v14 data
directory is untouched by a server that never starts — but Immich is
down until the image is reverted.

There is also no operator to do this for us. Unlike the rest of the
cluster's databases, Immich's Postgres is a **plain Deployment, not
CrunchyData PGO** (see the header comment in `postgres.yaml`: the
`ghcr.io/immich-app/postgres` image is incompatible with PGO's
Patroni/pgBackRest image layout). So there is no `PGUpgrade` CRD and no
managed path. This is a manual dump-and-restore.

## 2. Should we do it at all?

**There is no deadline.** Immich's own documentation states it "is known
to work with Postgres versions `>= 14, < 20`", so 14.19 is a supported
configuration today and will be for a long time. Nothing in Immich
v3.1.0 requires 17 — or even 15.

Reasons to do it anyway, in honest order:

- PostgreSQL 14 reaches community end-of-life in **November 2026**.
  After that the `ghcr.io/immich-app/postgres:14-…` tag stops receiving
  rebuilds, including for CVEs in Postgres itself and in the Debian
  base. That is the real driver.
- Renovate will keep re-opening this PR, and a standing "needs Tom" item
  trains the eye to skip it.
- 17 is measurably faster for some of what Immich does, but on a 621 MB
  database that is not a reason on its own.
- Landing on 17 rather than 16 pushes the *next* forced round of this
  same work from PostgreSQL 16's EOL (November 2028) to 17's
  (November 2029), for identical effort today.

Reasons to wait: none urgent. **This is a "do it on a quiet evening"
task, not a "do it now" task.** If it is deferred, note the November
2026 EOL and revisit.

## 3. Measured current state

All figures taken 2026-09-26, not estimated.

| | |
|---|---|
| Server | PostgreSQL **14.19** (Debian 14.19-1.pgdg12+1) |
| Target | PostgreSQL **17.6** (Debian 17.6-1.pgdg12+1), image `17-vectorchord0.4.3-pgvector0.8.0` |
| Database size | **621 MB** |
| Workload | `Deployment/immich-postgres`, 1 replica, `Recreate` |
| Data PVC | `immich-postgres-data-nvme`, `local-hostpath` 20 Gi (node NVMe) |
| Old PVC | `immich-postgres-data`, `gsks0` 20 Gi — retained rollback from the 2026-09-18 NVMe move, still Bound |
| Node headroom | 1,671 GB free of 1,997 GB — a second 20 Gi volume is nothing |
| Logical dumps | `immich-postgres-dumps` PVC on `gsks1` (TrueNAS), nightly 02:30, `pg_dump -Fc`, 7 retained, each run ~30 s |
| Volsync | `immich-postgres-data` ReplicationSource, 03:00 daily, last 2026-09-26T03:00:22Z |
| Flux | Kustomizations `postgres-immich` (DB) and `immich` (app, `dependsOn: postgres-immich`); **both `prune: true`** |

Extensions, live vs. what the v17 image ships (verified by running the
v17 image as a throwaway pod, not read off the tag):

| Extension | Live on 14 | On the 17 image | |
|---|---|---|---|
| `vchord` | 0.4.3 | 0.4.3 | identical — this is the one that matters |
| `vector` | 0.8.1 | **0.8.0** | one patch *back*, see below |
| `cube` | 1.5 | 1.5 | identical |
| `pg_trgm` | 1.6 | 1.6 | identical |
| `unaccent` | 1.1 | 1.1 | identical |
| `uuid-ossp` | 1.1 | 1.1 | identical |
| `earthdistance` | 1.1 | **1.2** | forward, trivial |
| `plpgsql` | 1.0 | 1.0 | built in |
| `vectors` (pgvecto.rs) | not installed | **absent from the image** | unused, see below |

**`vchord` does not move**, which is the important one: it owns both
vector indexes. Because 0.4.3 is on both sides, none of Immich's
"`ALTER EXTENSION vchord UPDATE;` then reindex" guidance applies — that
is for changing the *extension* version, which this does not.

**`vector` goes backwards by one patch, 0.8.1 → 0.8.0, and that is
fine.** The 17 line simply has no `-pgvector0.8.1` build yet; at
vectorchord 0.4.3 it offers only `17-vectorchord0.4.3` and
`17-vectorchord0.4.3-pgvector0.8.0`. pgvector 0.8.1 was a maintenance
release — Postgres 18 rc1 build support and a `binary_quantize`
performance fix — and **added no SQL objects at all**. Nothing in a
0.8.1 dump can therefore reference anything 0.8.0 lacks, and `pg_dump`
emits `CREATE EXTENSION vector` with no version pin, so the restore
installs 0.8.0 cleanly. Verify it anyway in the Phase 1 rehearsal;
that is what the rehearsal is for.

**`vectors` (pgvecto.rs) is absent from the 17 image entirely**, and
this costs nothing: it is present but *not installed* on the current
14 image — `pg_extension` lists only `vchord` and `vector`. Immich
moved from pgvecto.rs to VectorChord some releases ago and this
database already reflects that.

Note the tag lineage changes shape, from
`14-vectorchord0.4.3-pgvectors0.2.0` to
`17-vectorchord0.4.3-pgvector0.8.0` — dropping the dead pgvecto.rs
component and naming pgvector explicitly. Renovate pins by digest, so
it will simply track the new tag pattern from then on.

`earthdistance` 1.1 → 1.2 is the only other change. `pg_dump` emits
`CREATE EXTENSION` without a version pin, so the restore installs 1.2.
It is a trivial catalogue change used only by Immich's geo queries;
treat it as expected, not as a surprise.

The two vector indexes are ordinary index definitions with no external
state, so `pg_restore` rebuilds them from DDL:

```sql
CREATE INDEX clip_index ON public.smart_search USING vchordrq (embedding vector_cosine_ops)
  WITH (options='… lists = [1] … build_threads = 4 …')   -- 90 MB
CREATE INDEX face_index ON public.face_search USING vchordrq (embedding vector_cosine_ops)
  WITH (options='… lists = [1] … build_threads = 4 …')   -- 85 MB
```

**Rebuilding these two indexes is the long pole of the whole migration**
and the one number this plan cannot predict. Phase 1 exists to measure it.

Row-count baseline to compare against afterwards:

```
asset_file 81236   asset_ocr 73322   asset 32822   asset_exif 32820
asset_job_status 32819   smart_search 31893   face_search 30224   asset_face 30224
```

## 4. Approach

**Logical dump and restore onto a second, new PVC**, leaving the v14
volume untouched.

Why not `pg_upgrade`: it needs the 14 *and* 17 binaries present in one
filesystem. `ghcr.io/immich-app/postgres` ships exactly one major
version, so using it would mean building a custom image carrying both
plus matching `vchord`/`vector` builds for each. That is more work and
more risk than a dump/restore of 621 MB.

Why a new PVC rather than wiping the existing one: it makes rollback a
one-line `claimName` revert instead of a restore, and it is the same
pattern that made the 2026-09-18 NVMe move safe. Disk is free here.

Collation is a non-issue: both images are `pgdg12` (Debian 12,
same glibc), and a dump/restore rebuilds every index from DDL anyway, so
the text-sort-order hazard that bites `pg_upgrade` across glibc versions
does not arise.

## 5. Phase 1 — rehearsal — **DONE 2026-09-26, passed**

Ran against the real 02:30 dump on a throwaway 17.6 instance. Nothing
production was touched; the live 14 pod kept its 8-day uptime and 0
restarts throughout.

### Result

| | |
|---|---|
| Source dump | `immich-20260926-0230.dump`, 190 MB compressed, 513 TOC entries |
| `pg_restore` | **27 s** |
| `ANALYZE` | **3 s** |
| **Total** | **30 s** |
| Restored size | 596 MB (vs 621 MB live — no bloat, as expected of a fresh restore) |

**The vchordrq rebuild is not a long pole.** It was the one unknown in
this plan and the answer is that it disappears into the 27 s. Both
indexes came back valid at byte-identical sizes to production —
`clip_index` 90 MB, `face_index` 85 MB, `indisvalid = t`.

Everything else predicted in §3 held exactly: PostgreSQL 17.6,
`vchord 0.4.3`, `vector 0.8.0`, `earthdistance 1.2`, the rest
unchanged. **All 66 tables matched the live database by real
`count(*)`** — not one row out.

Both vector indexes serve live ANN queries, which is the check that
matters, since a valid-but-unused index looks perfect until someone
searches:

```
Index Scan using clip_index on smart_search   (actual rows=5)  4.8 ms
Index Scan using face_index on face_search    (actual rows=5)
```

**The pgvector 0.8.1 → 0.8.0 downgrade is confirmed inert**, as §3
reasoned — the restore installed 0.8.0 and every vector operation
works.

### Two bugs the rehearsal caught, both since fixed in this document

1. **`time` does not exist in this image's `/bin/sh`.** The restore Job
   below originally read `time pg_restore …`; `/bin/sh` is dash, which
   has no `time` builtin and the image has no `/usr/bin/time`. The Job
   died with `/bin/sh: 6: time: not found` **before restoring
   anything**. In Phase 2 that would have burned a maintenance window
   on a shell typo. Step 8 now uses epoch arithmetic.
2. **`n_live_tup` is not a row count.** The original §7 check compared
   `pg_stat_user_tables.n_live_tup` between old and new. On the freshly
   `ANALYZE`d copy those are accurate; on the live 14 database they
   were badly stale — it reported `album = 0` against a true 21, and 26
   of 66 tables "differed". Comparing real `count(*)` showed all 66
   identical. Verifying with `n_live_tup` would have manufactured a
   panic mid-window. §7 now uses `count(*)`.

### How it was run, for repeating it

Restore **last night's dump** into a throwaway v17 instance:

Restore **last night's dump** into a throwaway v17 instance:

1. Create a scratch PVC (`local-hostpath`, 20 Gi) and a scratch
   Deployment running the v17 image with its own Service, in the
   `immich` namespace but with different labels so it does not join the
   `immich-postgres` Service selector. **Apply by hand, not through
   Flux** — it must never enter a Kustomization's inventory, or prune
   will chase it later.
2. Run a restore Job (see §6 step 8) pointed at the scratch Service,
   using the newest file in `immich-postgres-dumps`.
3. **Time it.** Record wall-clock for `pg_restore` and note when
   `clip_index` / `face_index` finish.
4. Verify against §7 on the scratch instance.
5. Tear down: delete the Deployment, Service and scratch PVC.

Carry the measured restore time into the maintenance-window estimate in
§9 and replace the guess there.

## 6. Phase 2 — the migration

Downtime starts at step 3 and ends at step 11.

1. **Announce it.** Immich is family-visible. Mobile apps will fail to
   sync for the window and recover on their own.

2. **Suspend Flux for both Kustomizations**, so it cannot fight the
   manual scaling or re-apply a half-finished state:
   ```bash
   flux suspend kustomization immich -n flux-system
   flux suspend kustomization postgres-immich -n flux-system
   ```

3. **Stop the writers.** Postgres stays up; only its clients go away:
   ```bash
   kubectl scale -n immich deploy/immich-server --replicas=0
   kubectl scale -n immich deploy/immich-machine-learning --replicas=0
   kubectl wait -n immich --for=delete pod -l app.kubernetes.io/name=immich --timeout=3m
   ```
   Confirm nothing is still connected:
   ```bash
   kubectl exec -n immich deploy/immich-postgres -- \
     psql -U immich -d immich -At -c \
     "select count(*) from pg_stat_activity where datname='immich' and pid<>pg_backend_pid();"
   ```
   Expect `0`. Anything else, find it before continuing.

4. **Take the migration dump — with the v17 client.** PostgreSQL's own
   guidance is to dump with the *newer* `pg_dump`, which is the opposite
   of what `pgdump.yaml` does day to day (it deliberately pins the
   client to the server version). Run a one-off Job using the **v17**
   image against the still-running v14 server, writing to the same
   dumps PVC with a distinct name, e.g. `immich-pg17-migration.dump`.

5. **Verify the dump before destroying anything.** Not just that the
   file exists:
   ```bash
   pg_restore --list /dumps/immich-pg17-migration.dump | wc -l   # non-trivial count
   ```
   A dump you have not listed is not a backup.

6. **Commit the change.** In one commit:
   - `postgres.yaml`: add PVC `immich-postgres-data-nvme-pg17`
     (`local-hostpath`, 20 Gi); change the container image to the v17
     digest; change `claimName` to the new PVC.
   - `pgdump.yaml`: change the image to the v17 digest.
   - **Leave the `immich-postgres-data-nvme` PVC declared in git.**
     Removing it in the same commit would have Flux prune it and destroy
     the rollback. It comes out later, in Phase 5.

7. **Resume Flux and let the new pod start:**
   ```bash
   flux resume kustomization postgres-immich -n flux-system
   flux reconcile kustomization postgres-immich -n flux-system --with-source
   ```
   The new PVC is `WaitForFirstConsumer`, so it binds when the pod
   mounts it. The pod runs `initdb` on the empty volume — with
   `--data-checksums`, from the existing `POSTGRES_INITDB_ARGS` — and
   creates an empty `immich` database from the secret's
   `DB_DATABASE_NAME`. Wait for `pg_isready`.

8. **Restore.** One-shot Job, applied by hand (not via Flux):
   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata: {name: immich-pg17-restore, namespace: immich}
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: restore
             image: ghcr.io/immich-app/postgres:17-vectorchord0.4.3-pgvector0.8.0@sha256:51f6abbfc720dde5cad9a39133d1c5247da8f073a449004da781c07b2cd9ee9c
             env:
               - {name: PGHOST, value: immich-postgres.immich.svc.cluster.local}
               - {name: PGUSER,     valueFrom: {secretKeyRef: {name: immich-postgres-secret, key: DB_USERNAME}}}
               - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: immich-postgres-secret, key: DB_PASSWORD}}}
               - {name: PGDATABASE, valueFrom: {secretKeyRef: {name: immich-postgres-secret, key: DB_DATABASE_NAME}}}
             command: ["/bin/sh","-c"]
             args:
               - |
                 set -eu
                 # NOT `time pg_restore` -- /bin/sh here is dash, which has
                 # no time builtin, and the image ships no /usr/bin/time.
                 # That cost a failed rehearsal run on 2026-09-26.
                 t0=$(date +%s)
                 pg_restore --no-owner --no-privileges --exit-on-error \
                   -d "$PGDATABASE" /dumps/immich-pg17-migration.dump
                 t1=$(date +%s); echo "pg_restore: $((t1-t0))s"
                 psql -d "$PGDATABASE" -q -c 'ANALYZE;'
                 echo "ANALYZE: $(($(date +%s)-t1))s"
             volumeMounts: [{name: dumps, mountPath: /dumps}]
         volumes:
           - name: dumps
             persistentVolumeClaim: {claimName: immich-postgres-dumps}
   ```
   Notes: this file is applied directly, so shell `$` is written once —
   the `$$` escaping in `pgdump.yaml` exists only because Flux runs
   envsubst over it. `--exit-on-error` is deliberate: a restore that
   half-succeeds is worse than one that stops. Follow with
   `kubectl logs -n immich -f job/immich-pg17-restore`.

9. **`ANALYZE` is not optional** and is easy to forget — it is folded
   into the Job above. `pg_restore` does not carry planner statistics
   across, and without them Immich's first hours are mysteriously slow
   in a way that looks like the upgrade made things worse.

10. **Verify** — §7, before letting anyone back in.

11. **Bring Immich back:**
    ```bash
    flux resume kustomization immich -n flux-system
    kubectl scale -n immich deploy/immich-server --replicas=1
    kubectl scale -n immich deploy/immich-machine-learning --replicas=1
    ```
    Flux restores the declared replica counts on the next reconcile;
    the explicit scale just avoids waiting for it.

12. **Delete the restore Job** once its logs are read.

## 7. Verification

Do all of these. The first three are cheap and the last two are the ones
that actually matter to a user.

```bash
PG=$(kubectl get pods -n immich -l app=immich-postgres -o name | head -1)

# 1. It really is 17, and on the new volume
kubectl exec -n immich ${PG#pod/} -- psql -U immich -At -c 'select version();'
kubectl get deploy -n immich immich-postgres \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}{"\n"}'

# 2. Extensions: expect vchord 0.4.3 / vector 0.8.0 / earthdistance 1.2
#    vector 0.8.0 (not 0.8.1) is correct here - see the extension table
kubectl exec -n immich ${PG#pod/} -- psql -U immich -d immich \
  -c 'select extname, extversion from pg_extension order by 1;'

# 3. Row counts -- REAL counts, not n_live_tup. Planner statistics are
#    stale on a long-running server (the live 14 reported album=0
#    against a true 21 during the rehearsal) and would invent a crisis.
#    Run this against BOTH old and new and diff the output.
kubectl exec -n immich ${PG#pod/} -- psql -U immich -d immich -At -c "
  select relname||'|'||(xpath('/row/cnt/text()',
    query_to_xml(format('select count(*) as cnt from %I.%I', schemaname, relname),
                 false, true, '')))[1]::text
  from pg_stat_user_tables order by relname;" | sort

# 4. Both vchordrq indexes exist and are valid
kubectl exec -n immich ${PG#pod/} -- psql -U immich -d immich -At -F'|' -c "
  select i.relname, am.amname, x.indisvalid, pg_size_pretty(pg_relation_size(i.oid))
  from pg_index x join pg_class i on i.oid=x.indexrelid
  join pg_am am on am.oid=i.relam where am.amname='vchordrq';"
```

Then, in the Immich UI:

- **Smart search** for something textual ("beach", "dog"). This is the
  only thing that exercises `clip_index`; if the vector index did not
  rebuild, search returns nothing while everything else looks perfect.
  To check it from SQL instead, **`vchordrq.probes` must be set first**
  or the query errors with `need 1 probes, but 0 probes provided` —
  Immich sets it per query, `psql` does not:
  ```sql
  SET vchordrq.probes = 1;
  EXPLAIN ANALYZE SELECT "assetId" FROM smart_search
    ORDER BY embedding <=> (SELECT embedding FROM smart_search LIMIT 1) LIMIT 5;
  ```
  Expect `Index Scan using clip_index`. A `Seq Scan` means the index
  is not being used even though it exists.
- **People / faces** view loads and a person's photos open — exercises
  `face_index`.
- A map view loads (that is `earthdistance` 1.2 in use).
- Upload one photo from a phone and confirm it appears.

Finally, confirm the nightly dump still works on the new version rather
than waiting to find out:
```bash
kubectl create job -n immich --from=cronjob/immich-postgres-dump pg17-dumptest
```

## 8. Rollback

Cheap and fast, at any point up to Phase 5, because the v14 volume is
never written to.

1. `git revert` the Phase 2 commit (image back to the v14 digest,
   `claimName` back to `immich-postgres-data-nvme`), push.
2. `flux reconcile kustomization postgres-immich -n flux-system --with-source`
3. Scale `immich-server` and `immich-machine-learning` back up.

Immich returns on the v14 database exactly as it was at step 3, losing
only whatever the window would have contained — nothing, since the
writers were stopped first.

If the v14 volume itself is somehow lost as well, the fallbacks are the
nightly logical dumps on `gsks1` (different failure domain from the
node) and the Volsync/restic snapshots of the old PVC. That is three
independent copies before this starts.

## 9. Time and downtime

| Step | Time | Source |
|---|---|---|
| Scale down, confirm no connections | 1–2 min | estimate |
| Migration dump (v17 client) | ~30 s | nightly measured at 29–31 s |
| Commit, reconcile, `initdb`, pod ready | 2–3 min | rehearsal pod was ready in 10 s; Flux reconcile dominates |
| `pg_restore` incl. vchordrq rebuild | **27 s** | **measured, Phase 1** |
| `ANALYZE` | **3 s** | **measured, Phase 1** |
| Verification | 5–10 min | §7, mostly the UI checks |

**Realistic window: 15 minutes, of which about 30 seconds is the
database.** Budget half an hour and expect to be idle in it.

The feared long pole — rebuilding two vchordrq indexes over 175 MB of
embeddings — turned out to be a non-event at this data size. The
dominant costs are now Kubernetes and human: pod scheduling, Flux
reconcile, and clicking through Immich to confirm search works.

This is comfortably a quiet-evening task. It does not need a
maintenance window in any formal sense; it needs twenty minutes when
nobody is mid-upload.

## 10. Gotchas specific to this cluster

- **Do not remove the old PVC in the same commit.** Flux computes
  pruning by diffing the previous inventory, so dropping
  `immich-postgres-data-nvme` from `postgres.yaml` deletes the volume —
  and with it the rollback. Same hazard, same shape, as the
  `gotk-components.yaml` handover on 2026-09-25.
- **Suspend both Kustomizations, not just one.** `immich` depends on
  `postgres-immich`; leaving the app one active means Flux keeps trying
  to reconcile a deployment whose database is mid-migration.
- **Probes are deliberately slack** (`timeoutSeconds: 10`,
  `failureThreshold: 6`) because `pg_isready` on this single-replica pod
  used to blow past a 1 s default under load and get the pod pulled from
  the Service mid-request. Do not "tidy" them while in this file.
- **The restore Job is hand-applied, so write shell `$` once.** The
  `$$` doubling in `pgdump.yaml` is there only because Flux runs
  envsubst across everything it renders.
- **`pgdump.yaml`'s image must move with the server.** Its comment says
  the client is pinned to the server version on purpose; leaving it at
  14 after the server is 17 means the nightly dump starts failing, and
  it would fail quietly into a CronJob nobody reads.
- **Close PR #960 rather than merging it, ever.** It targets 16, which
  is no longer the destination, and merging it at any point starts a
  16.10 binary on a 14 data directory. The symptom is
  `immich-postgres` crash-looping with the incompatible-data-directory
  FATAL; reverting the image brings it straight back. Renovate will
  re-raise a 17 or 18 PR later — that one is equally un-mergeable on
  its own, for the same reason. **No image bump to this Deployment is
  ever a merge; it is always this runbook.**

## 11. Phase 5 — cleanup, a week after

Only once Immich has been in normal use for several days:

- Remove the `immich-postgres-data-nvme` PVC from `postgres.yaml` and
  let Flux prune it.
- Remove the pre-existing `immich-postgres-data` PVC (`gsks0`, the
  rollback from the 2026-09-18 NVMe move) if it is still around — it is
  already an open item in `CLUSTER.md` and will by then be two
  migrations stale.
- Point the Volsync `ReplicationSource` at the new PVC. **Check this
  during Phase 2, not here** — `immich-postgres-data` currently has
  `sourcePVC: immich-postgres-data-nvme`, so it silently keeps backing
  up the *old* volume the moment the claim name changes, and the new
  database would go unprotected until someone noticed.

## 12. Open questions

1. ~~How long does the vchordrq rebuild actually take?~~ **Answered
   2026-09-26: 27 s for the entire restore, rebuild included.**
2. ~~Is a maintenance window needed?~~ **No.** Fifteen minutes on a
   quiet evening. See §9.
3. ~~16 or 17?~~ **Resolved 2026-09-26: 17.** Identical work, three
   more years of runway. The only cost found was pgvector 0.8.1 → 0.8.0,
   which is inert (no SQL objects changed between those releases).
   Phase 1 must therefore rehearse against **17**, not 16.
4. ~~Does the pgvector patch downgrade restore cleanly in practice?~~
   **Yes, verified 2026-09-26.** 0.8.0 installed, all 66 tables
   restored to identical `count(*)`, and both vector indexes serve ANN
   queries.

**No open questions remain. Phase 2 is ready to run whenever there is
a quiet twenty minutes.**
