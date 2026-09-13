# Cluster Doc Update — 2026-09-12

## Immich — Google Takeout stage complete (both accounts)

Stage 2 of `docs/photo-storage-strategy-research.md`, planned in
`docs/photo-migration-google-takeout-plan.md`. Both Google Photos
libraries are now in Immich.

**Result: 16,310 assets (15,727 images, 583 videos), 21 albums,
116 GB of 1.7 TB. Zero errors on the final runs of both accounts.**

| | Tom | Shawna |
|---|---|---|
| Takeout archives | 6 zips, 55 GB | 5 zips, 48 GB |
| Assets discovered | 4,657 | 12,135 |
| Uploaded | ~4,230 | 11,721 |
| Missing JSON sidecar | 1 | 0 |
| Google Trash excluded | 10 | 63 |

Shawna's library is 2.6x the file count in 13% less space — hers
starts in 2013, and older photos are much smaller. That shape matters:
the bottleneck on `gsks0` is IOPS, not throughput, so her import took
substantially longer despite being smaller.

### The real work: two probe misconfigurations, found in sequence

Tom's import failed three times with `502 Bad Gateway` before
completing. The cause was not load, not the network, and not Immich.

**First, `immich-server`.** The bjw-s common chart defaults to
`timeoutSeconds: 1`, `failureThreshold: 3`. Under bulk write load
against `gsks0` (HDD mirror, ~78 IOPS) `/api/server/ping`
intermittently took longer than a second. Three misses marked the
**single-replica** pod NotReady, kubernetes pulled it from the Service
endpoints, and nginx was left with no upstream at all - `502`, even
though the server answered normally seconds later. `immich-go`'s
default `--on-errors stop` then aborted the whole run. Fixed to 10s/6
in the HelmRelease (`584e7f8e`).

**Then, Postgres.** After that fix the server held at zero restarts -
but `502`s continued. `immich-postgres`'s probes omitted
`timeoutSeconds` entirely, inheriting the same 1s default, and
`pg_isready` as an exec probe on NFS is just as susceptible. When
Postgres was pulled from its endpoints, `immich-server` lost its
database mid-request, surfacing identically at the ingress. Fixed to
10s/6 (`0d1499d0`). The 7 assets still failing at that point were all
`.dng` RAW files - the largest single writes in the set - and all
uploaded cleanly on a re-run afterward.

Worth remembering as a pattern: **fixing the obvious layer exposed the
real one underneath**, and the symptom was identical both times. The
generalized gotcha is in `CLUSTER.md`; it applies to any
single-replica app on this storage, not just Immich.

Validation: Shawna's 11,721-file import - a harder workload than
Tom's - ran with **zero `502`s and zero pod restarts**, and every pod
is still at 0 restarts 24h later. Before the fixes, Tom's import
produced `502`s within minutes.

### `gsfarmctl` is memory-constrained, and it stopped an import

The control host has **5.7 GB of RAM** and already runs a UniFi
controller (`java` ~765 MB + `mongod` ~358 MB). With `immich-go`
holding an index of 12,135 assets on top of that, free memory fell to
~360 MB and Shawna's first import was killed at 53%.

No data was lost - `immich-go` dedups against the server, so re-running
resumes rather than duplicates. But this will recur on the Amazon
stage. Options, in rough order of effort: add RAM; move the UniFi
controller off the cluster's control host (it is ~30% of memory in use
and arguably does not belong there); or split imports so `immich-go`
never indexes 12,000 assets at once (at the cost of splitting albums
that span archives).

A second run then stopped at 78% with no error, no summary, and no OOM
in `kern.log`. It coincided to the second with SSH sessions dropping
when the laptop slept - but it was running under a tmux pty, which
should have insulated it. **Cause never established.** If it recurs,
run fully detached instead: `setsid nohup immich-go ... &`, which
leaves no controlling terminal at all (verify with `ps -o tty` showing
`?`).

### Corrected assumption: the two clouds barely overlap

The research doc expected substantial duplication between Google and
Amazon, and between the two accounts via partner sharing. For Google,
that was wrong: of Shawna's 12,135 assets, only **32** were already on
the server after Tom's entire library had been imported.

This matters for planning the Amazon stage. The "realistic unique
total: roughly 180-230 GB" estimate assumed overlap that has not
materialized so far, so budget for the higher end or beyond. It also
weakens - but does not remove - the argument that Amazon is mostly
redundant with Google; that assumption should be tested with a dry run
before committing to a full Amazon export.

### Operational notes

- **Run imports from `gsfarmctl`, not the Mac.** Confirmed good: the
  LAN path to `nginx-internal` was used throughout (verified in the
  ingress logs), with none of stage 1's macOS Local Network privacy,
  Cloudflare body-size cap, or WAN hairpin.
- **Keep the API key out of the process table.** Passing
  `--api-key "$(cat ...)"` expands before exec, leaving the key visible
  in `ps` to any local user. `immich-go` supports neither env vars nor
  a flat config file for this - the format is nested under `upload:`.
  There is now a `~/immich-go.yaml` (mode 600) holding `server` and
  `api-key`; run from `~` and neither flag is needed. **Do not reuse a
  `--save-config` file blindly** - the one it generates includes
  `dry-run: true`, which would silently no-op every later import.
- **Verify transfers by byte count, not just zip structure.** One of
  Shawna's archives arrived 1.11 GB short via `scp` (which has no
  resume). `unzip -l` catches truncation cheaply; `unzip -t` does a
  full CRC check but is slow on 10 GB files.
- **Expect a long background backlog.** The completed import left
  ~38,000 metadataExtraction jobs queued, several hours' work. The
  library is browsable throughout.

### Still outstanding in the migration

- **Amazon Photos** - no Takeout equivalent, no API, no direct
  transfer; web UI caps downloads at 1,000 files / 5 GB, so the
  desktop app is the practical route. Scope to Shawna's pre-2022
  history first.
- **Apple Photos** - via `Photos.app → File → Export → Export
  Unmodified Originals`, never by pointing a scanner at the
  `.photoslibrary` package (see 2026-09-08).
- **`~/Downloads` on the Mac** - hand-pick, do not blanket-scan.
- **`immich-postgres` had 19 restarts** before the probe fix reset the
  counter. The fix plausibly explains them, but that was never
  confirmed - if the counter starts climbing again, it is a separate
  problem.
