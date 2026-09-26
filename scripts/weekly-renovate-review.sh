#!/usr/bin/env bash
# weekly-renovate-review.sh
#
# Helper for the "Weekly Renovate Review" workflow documented in CLAUDE.md.
#
# This script automates the mechanical, deterministic parts of the review:
# listing open Renovate PRs, checking the auto-merge criteria that can be
# checked without human judgment (update type, CI status, forbidden paths,
# CRD changes, HelmRelease chart major-version bumps), merging an approved
# PR, and reporting Flux/pod health.
#
# It deliberately does NOT decide "auto-mergeable" vs "needs Tom" on its
# own: CLAUDE.md requires reading the PR's linked changelog/release notes
# for breaking changes, which is a judgment call for the reviewer (Tom, or
# Claude acting on Tom's behalf) to make using this script's output plus
# the changelog links it prints. A PASS from `check`/`review` means "the
# mechanical criteria are satisfied" — not "merge without reading anything".
#
# Usage:
#   weekly-renovate-review.sh [review] [--dry-run]   # default: full pass
#   weekly-renovate-review.sh list [--json]
#   weekly-renovate-review.sh check <PR_NUMBER> [--json]
#   weekly-renovate-review.sh merge <PR_NUMBER> [--force]
#   weekly-renovate-review.sh health
#   weekly-renovate-review.sh talos-drift
#   weekly-renovate-review.sh rollout-churn
#   weekly-renovate-review.sh ingress-check
#
# Requires: gh (authenticated), git, kubectl, flux, jq, python3, curl.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="tomsnj/cillflux"

FORBIDDEN_PATH_PATTERNS=(
  '^kubernetes/apps/database/'
  '^kubernetes/apps/vaultwarden/'
  '^kubernetes/apps/forgejo/'
  '^kubernetes/apps/minio/'
  '^kubernetes/apps/keycloak/'
)
# Some of the above namespaces live under other top-level app groups in
# this repo (e.g. infrastructure/keycloak) — also match by trailing
# path segment so the guardrail isn't defeated by directory layout.
FORBIDDEN_PATH_SEGMENTS=(vaultwarden forgejo minio keycloak database)

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

require_tools() {
  local missing=()
  for t in gh git kubectl flux jq python3 curl; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
}

# ---- PR data gathering -----------------------------------------------

pr_json_fields='number,title,url,labels,files,statusCheckRollup,mergeStateStatus,mergeable,body,headRefOid,baseRefName'

fetch_open_prs() {
  gh pr list --repo "$REPO_SLUG" --search "author:app/renovate" --state open \
    --json number,title,url,labels,updatedAt
}

fetch_pr() {
  # GitHub computes mergeStateStatus asynchronously — a cold request can
  # come back "UNKNOWN" even for a perfectly mergeable PR. Retry a few
  # times before accepting it as a real value.
  local pr="$1" data status attempt
  for attempt in 1 2 3 4; do
    data=$(gh pr view "$pr" --repo "$REPO_SLUG" --json "$pr_json_fields")
    status=$(jq -r '.mergeStateStatus' <<<"$data")
    [[ "$status" != "UNKNOWN" ]] && break
    [[ "$attempt" -lt 4 ]] && sleep 2
  done
  printf '%s' "$data"
}

update_type_of() {
  # Reads PR JSON on stdin, prints major|minor|patch|unknown from Renovate's
  # own type/* labels (applied by renovate.json5 packageRules).
  jq -r '
    [.labels[].name | select(startswith("type/"))][0] // "type/unknown"
    | sub("^type/"; "")
  '
}

ci_status_of() {
  # Reads PR JSON on stdin. Prints "green", "red", or "pending".
  jq -r '
    (.statusCheckRollup // []) as $c
    | if ($c | length) == 0 then "pending"
      elif ($c | any(.conclusion == "FAILURE" or .conclusion == "ERROR" or .conclusion == "CANCELLED")) then "red"
      elif ($c | all(.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL")) then "green"
      else "pending"
      end
  '
}

flux_diff_present_of() {
  jq -r '[.statusCheckRollup[]?.name | select(test("flux.?diff"; "i"))] | length > 0'
}

forbidden_paths_hit_of() {
  # Reads PR JSON on stdin, prints one hit file per line (empty if none).
  local paths
  paths=$(jq -r '.files[].path' <<<"$1")
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    for seg in "${FORBIDDEN_PATH_SEGMENTS[@]}"; do
      if [[ "$p" == *"/$seg/"* || "$p" == "$seg/"* ]]; then
        printf '%s\n' "$p"
        break
      fi
    done
  done <<<"$paths"
}

crd_touched_of() {
  local pr="$1" files="$2"
  local hit=false
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == *"/crds/"* ]] && { hit=true; break; }
  done <<<"$files"
  if [[ "$hit" == false ]]; then
    if gh pr diff "$pr" --repo "$REPO_SLUG" 2>/dev/null | grep -q '^\+kind: CustomResourceDefinition'; then
      hit=true
    fi
  fi
  echo "$hit"
}

# Compares chart.spec.version between main and the PR head for every
# changed helmrelease*.yaml file. Prints one "path old->new" line per file
# where the major version number changed.
chart_major_bump_files_of() {
  local files="$2"
  local head_sha="$1"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$(basename "$f")" == helmrelease*.y*ml ]] || continue
    local base_content head_content
    base_content=$(git show "origin/main:$f" 2>/dev/null || true)
    head_content=$(git show "$head_sha:$f" 2>/dev/null || true)
    [[ -z "$base_content" || -z "$head_content" ]] && continue
    local base_major head_major
    base_major=$(chart_version_major "$base_content")
    head_major=$(chart_version_major "$head_content")
    if [[ -n "$base_major" && -n "$head_major" && "$base_major" != "$head_major" ]]; then
      printf '%s (v%s -> v%s)\n' "$f" "$base_major" "$head_major"
    fi
  done <<<"$files"
}

chart_version_major() {
  python3 - "$1" <<'PY'
import re, sys
content = sys.argv[1]
m = re.search(r'chart:\s*\n\s*spec:\s*\n(?:.*\n)*?\s*version:\s*["\']?([0-9]+)', content)
print(m.group(1) if m else "")
PY
}

changelog_links_of() {
  # Extracts the "[package](link)" markdown from the Renovate PR body's
  # update table — these are the changelog/source links to read.
  jq -r '.body' <<<"$1" | grep -oP '\[[^]]+\]\(https?://[^)]+\)' | sort -u
}

# ---- reviewed-head tracking ---------------------------------------------

# On 2026-09-26 PR #974 was reviewed as "kube-prometheus-stack v91.5.3"
# (a patch) and merged, minutes later, as "v91.6.0" -- a minor. Renovate
# had force-updated the branch in between. Nothing caught it: `merge`
# re-runs the mechanical check against the *live* head, so the new head
# was independently green, CLEAN and non-major and sailed through. The
# mechanical criteria were never the problem. What was missing is any
# link between the head whose CHANGELOG a human actually read and the
# head that gets merged -- and reading the changelog is the one
# criterion in CLAUDE.md that cannot be automated.
#
# So `check` now records the head SHA it evaluated, and `merge` refuses
# if the branch has moved since. The upgrade was harmless that day; the
# next one might not be.
REVIEW_STATE_FILE="${REVIEW_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/weekly-renovate-review/reviewed.json}"

record_review() {
  # pr sha title update_type. Best-effort: never fail a review because
  # the state file could not be written.
  local pr="$1" sha="$2" title="$3" ut="$4" tmp existing
  mkdir -p "$(dirname "$REVIEW_STATE_FILE")" 2>/dev/null || return 0
  # || true: on the first ever run this file does not exist, and a bare
  # failing $(cat ...) assignment aborts the whole script under set -e.
  existing=$(cat "$REVIEW_STATE_FILE" 2>/dev/null) || true
  [[ -n "$existing" ]] || existing='{}'
  jq -e . >/dev/null 2>&1 <<<"$existing" || existing='{}'
  tmp=$(mktemp) || return 0
  if jq --arg pr "$pr" --arg sha "$sha" --arg title "$title" --arg ut "$ut" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.[$pr] = {sha: $sha, title: $title, update_type: $ut, at: $at}' \
        <<<"$existing" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$REVIEW_STATE_FILE"
  else
    rm -f "$tmp"
  fi
  return 0
}

reviewed_field() {
  # pr field -> value on stdout, non-zero if there is no record.
  [[ -s "$REVIEW_STATE_FILE" ]] || return 1
  jq -er --arg pr "$1" --arg f "$2" '.[$pr][$f] // empty' "$REVIEW_STATE_FILE" 2>/dev/null
}

# ---- check: mechanical criteria for one PR ----------------------------

check_pr() {
  # $3: record this head SHA as "reviewed" (default true). cmd_merge
  # passes false -- otherwise its own pre-merge check would overwrite
  # the record it is about to verify against, and the guard would
  # always pass.
  local pr="$1" as_json="${2:-false}" record="${3:-true}"
  local data files update_type ci flux_diff forbidden crd chart_bumps head_sha
  data=$(fetch_pr "$pr") || die "could not fetch PR #$pr"
  files=$(jq -r '.files[].path' <<<"$data")
  update_type=$(update_type_of <<<"$data")
  ci=$(ci_status_of <<<"$data")
  flux_diff=$(flux_diff_present_of <<<"$data")
  forbidden=$(forbidden_paths_hit_of "$data")
  head_sha=$(jq -r '.headRefOid' <<<"$data")
  crd=$(crd_touched_of "$pr" "$files")
  git fetch -q origin main 2>/dev/null || true
  chart_bumps=$(chart_major_bump_files_of "$head_sha" "$files")
  local mergeable
  mergeable=$(jq -r '.mergeStateStatus' <<<"$data")

  if [[ "$record" == "true" ]]; then
    record_review "$pr" "$head_sha" "$(jq -r '.title' <<<"$data")" "$update_type"
  fi

  local -a fail_reasons=()
  [[ "$update_type" == "major" ]] && fail_reasons+=("update type is major")
  [[ "$update_type" == "unknown" ]] && fail_reasons+=("no type/* label found")
  [[ "$ci" != "green" ]] && fail_reasons+=("CI status is $ci")
  [[ "$flux_diff" == "true" ]] || fail_reasons+=("no Flux Diff check found on this PR")
  [[ -z "$forbidden" ]] || fail_reasons+=("touches guarded path(s): $(tr '\n' ',' <<<"$forbidden" | sed 's/,$//')")
  [[ "$crd" == "true" ]] && fail_reasons+=("touches a CustomResourceDefinition")
  [[ -z "$chart_bumps" ]] || fail_reasons+=("HelmRelease chart major version bump: $(tr '\n' ';' <<<"$chart_bumps" | sed 's/;$//')")
  [[ "$mergeable" == "CLEAN" ]] || fail_reasons+=("mergeStateStatus is $mergeable, not CLEAN")

  local pass=true
  ((${#fail_reasons[@]} == 0)) || pass=false

  local title url links
  title=$(jq -r '.title' <<<"$data")
  url=$(jq -r '.url' <<<"$data")
  links=$(changelog_links_of "$data")

  if [[ "$as_json" == "true" ]]; then
    jq -n \
      --arg number "$pr" --arg title "$title" --arg url "$url" \
      --arg update_type "$update_type" --arg ci "$ci" --arg mergeable "$mergeable" \
      --arg head_sha "$head_sha" \
      --argjson mechanical_pass "$pass" \
      --argjson fail_reasons "$(printf '%s\n' "${fail_reasons[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      --argjson files "$(jq -c '[.files[].path]' <<<"$data")" \
      --argjson changelog_links "$(printf '%s\n' "$links" | jq -R . | jq -s 'map(select(length>0))')" \
      '{number: ($number|tonumber), title: $title, url: $url, update_type: $update_type,
        ci: $ci, mergeStateStatus: $mergeable, head_sha: $head_sha,
        mechanical_pass: $mechanical_pass,
        fail_reasons: $fail_reasons, files: $files, changelog_links: $changelog_links}'
  else
    echo "PR #$pr — $title"
    echo "  $url"
    echo "  update type: $update_type   CI: $ci   mergeState: $mergeable"
    echo "  head: ${head_sha:0:9} (recorded as reviewed; merge refuses if it moves)"
    if [[ "$pass" == true ]]; then
      echo "  MECHANICAL: PASS (still read the changelog links below before merging)"
    else
      echo "  MECHANICAL: FAIL"
      for r in "${fail_reasons[@]}"; do echo "    - $r"; done
    fi
    if [[ -n "$links" ]]; then
      echo "  changelog / source links:"
      while IFS= read -r l; do [[ -n "$l" ]] && echo "    - $l"; done <<<"$links"
    fi
    echo "  files:"
    while IFS= read -r f; do [[ -n "$f" ]] && echo "    - $f"; done <<<"$files"
    echo
  fi
}

# ---- list --------------------------------------------------------------

cmd_list() {
  local as_json=false
  [[ "${1:-}" == "--json" ]] && as_json=true
  local prs
  prs=$(fetch_open_prs)
  if [[ "$as_json" == true ]]; then
    echo "$prs"
  else
    jq -r '.[] | "#\(.number)\t\(.title)"' <<<"$prs"
  fi
}

# ---- review (default): sync + list + check every open PR --------------

cmd_review() {
  local dry_run=false
  [[ "${1:-}" == "--dry-run" ]] && dry_run=true

  if [[ "$dry_run" == false ]]; then
    log "==> git pull --ff-only"
    git -C "$REPO_ROOT" pull --ff-only
  else
    log "==> --dry-run: skipping git pull"
  fi

  local prs numbers
  prs=$(fetch_open_prs)
  numbers=$(jq -r '.[].number' <<<"$prs")

  if [[ -z "$numbers" ]]; then
    echo "No open Renovate PRs."
    return 0
  fi

  echo "Open Renovate PRs: $(wc -l <<<"$numbers" | tr -d ' ')"
  echo

  local pass_list=() fail_list=()
  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    local out
    out=$(check_pr "$pr" false)
    echo "$out"
    if grep -q 'MECHANICAL: PASS' <<<"$out"; then
      pass_list+=("#$pr")
    else
      fail_list+=("#$pr")
    fi
  done <<<"$numbers"

  echo "=================================================================="
  echo "Mechanically eligible (still read changelogs above): ${pass_list[*]:-none}"
  echo "Needs Tom (mechanical criteria failed):               ${fail_list[*]:-none}"
  echo
  echo "Next steps: read each eligible PR's changelog link for breaking"
  echo "changes, then run: $0 merge <PR_NUMBER> for the ones you approve."
}

# ---- merge --------------------------------------------------------------

pod_snapshot() { kubectl get pods -A --no-headers 2>/dev/null; }

not_healthy() {
  # Reads a pod snapshot on stdin, prints every pod that is not fully
  # ready. STATUS alone is NOT sufficient: a pod can be Running with
  # 0/1 containers ready and be completely unavailable. That blind spot
  # reported "all pods Running" on 2026-09-23 while cluster DNS was
  # actually down mid-CoreDNS-rollout. Compare the READY column (e.g.
  # "1/1") as well. Completed pods are finished Jobs and are fine.
  awk '{split($3, r, "/")}
       $4 != "Completed" && (r[1] != r[2] || $4 != "Running") {print}'
}

cmd_merge() {
  local pr="$1"; shift || true
  local force=false
  [[ "${1:-}" == "--force" ]] && force=true

  # record=false: this check must not overwrite the reviewed-head record
  # it is about to be compared against.
  local check_out
  check_out=$(check_pr "$pr" true false)
  local mech_pass
  mech_pass=$(jq -r '.mechanical_pass' <<<"$check_out")

  if [[ "$mech_pass" != "true" && "$force" != true ]]; then
    log "PR #$pr fails mechanical criteria — refusing to merge:"
    jq -r '.fail_reasons[]' <<<"$check_out" | sed 's/^/  - /' >&2
    log "Re-run with --force only if you (Tom) have explicitly reviewed and approved this despite the failure."
    exit 1
  fi

  # Has the branch moved since its changelog was read? The mechanical
  # criteria above are re-evaluated live and will happily pass a
  # different, equally-green commit -- which is exactly how a patch
  # reviewed as v91.5.3 was merged as the minor v91.6.0 on 2026-09-26.
  local cur_sha reviewed_sha reviewed_title reviewed_type cur_title cur_type
  cur_sha=$(jq -r '.head_sha' <<<"$check_out")
  cur_title=$(jq -r '.title' <<<"$check_out")
  cur_type=$(jq -r '.update_type' <<<"$check_out")
  reviewed_sha=$(reviewed_field "$pr" sha) || reviewed_sha=""

  if [[ -z "$reviewed_sha" ]]; then
    if [[ "$force" != true ]]; then
      log "PR #$pr has no recorded review — refusing to merge."
      log "  Run:  $0 check $pr"
      log "  then read the changelog links it prints before merging."
      log "  (--force skips this, and skips the changelog criterion with it.)"
      exit 1
    fi
    log "WARNING: no recorded review for #$pr; merging anyway because --force was given."
  elif [[ "$reviewed_sha" != "$cur_sha" ]]; then
    reviewed_title=$(reviewed_field "$pr" title) || reviewed_title="(unknown)"
    reviewed_type=$(reviewed_field "$pr" update_type) || reviewed_type="(unknown)"
    log "PR #$pr has been force-updated since it was reviewed — refusing to merge."
    log "  reviewed: ${reviewed_sha:0:9}  [$reviewed_type]  $reviewed_title"
    log "  current : ${cur_sha:0:9}  [$cur_type]  $cur_title"
    log ""
    log "Renovate rewrites these branches in place, so the changelog you read"
    log "may describe a different release than the one about to merge."
    log "Re-run:  $0 check $pr    and read the changelog again."
    if [[ "$force" != true ]]; then exit 1; fi
    log "Merging anyway because --force was given."
  fi

  log "==> snapshotting pods before merge"
  local before after
  before=$(pod_snapshot)

  log "==> merging PR #$pr"
  gh pr merge "$pr" --repo "$REPO_SLUG" --squash

  # There is more than one GitRepository (flux-system and
  # home-kubernetes). Most app Kustomizations track home-kubernetes, so
  # reconciling only flux-system reports success while leaving them on
  # the previous commit. Reconcile them all.
  local src
  for src in $(kubectl get gitrepositories -n flux-system \
                 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    log "==> flux reconcile source git $src"
    flux reconcile source git "$src" -n flux-system
  done

  # A Helm upgrade can take well over a minute to even start rolling pods,
  # so an immediately-clean snapshot proves nothing -- it just means the
  # rollout has not begun. (On 2026-09-23 this declared success while
  # cilium was still at Init:0/6.) So: always sleep before the first
  # check, and require several *consecutive* clean polls before calling
  # it settled. Bail out early only if the same unhealthy set persists
  # across three polls, which means stuck rather than transient.
  log "==> waiting for pods to settle (up to 4m)"
  local prev_unhealthy="" unhealthy="" clean_streak=0 same_count=0
  local required_clean=3
  for _ in $(seq 1 16); do
    sleep 15
    after=$(pod_snapshot)
    unhealthy=$(not_healthy <<<"$after")
    if [[ -z "$unhealthy" ]]; then
      clean_streak=$((clean_streak + 1))
      same_count=0
      prev_unhealthy=""
      [[ "$clean_streak" -ge "$required_clean" ]] && break
      continue
    fi
    clean_streak=0
    if [[ "$unhealthy" == "$prev_unhealthy" ]]; then
      same_count=$((same_count + 1))
      [[ "$same_count" -ge 3 ]] && break
    else
      same_count=0
      prev_unhealthy="$unhealthy"
    fi
  done

  if [[ -n "$unhealthy" ]]; then
    echo "Pods not fully ready after merge of #$pr:"
    echo "$unhealthy"
    echo
    echo "(Investigate with kubectl describe / kubectl logs --previous before reporting — see"
    echo " CLAUDE.md 'Post-merge investigation'. Do not roll back or patch without Tom's go-ahead.)"
  else
    echo "PR #$pr merged. All pods fully ready."
    echo
    echo "NOTE: pod readiness is not proof the data path works. For network-layer"
    echo "charts (cilium, coredns, nginx, external-dns) verify the real path too:"
    echo "  for t in 10.0.10.1:443 10.0.10.2:443 10.0.10.3:9000 10.0.10.5:80; do"
    echo "    nc -z \${t%:*} \${t#*:} && echo \"\$t OPEN\"; done"
    echo "  dig +short @10.0.10.6 google.com"
    echo "(Cilium L2-announced LB IPs do not answer ICMP — use nc, not ping.)"
  fi
}

# ---- talos patch drift ----------------------------------------------------

TALOS_NODE="${TALOS_NODE:-10.0.10.10}"

talos_drift() {
  # Every patch under talos/patches/ should already be applied to the
  # node. `talosctl patch machineconfig --dry-run` is read-only and
  # reports "no changes detected" when the tracked file matches the live
  # config -- so any other result means the repo and the node disagree.
  #
  # Exit status is 0 whether or not there is a diff, so the output has to
  # be parsed. historical/ is skipped deliberately: those patches describe
  # the past and are expected not to match (patch-network.yaml would
  # renumber the node).
  local dir="$REPO_ROOT/talos/patches"
  [[ -d "$dir" ]] || { echo "No talos/patches directory - skipping."; return 0; }

  if ! command -v talosctl >/dev/null 2>&1; then
    echo "talosctl not found - skipping Talos patch drift check."
    return 0
  fi
  if ! talosctl -n "$TALOS_NODE" version --short >/dev/null 2>&1; then
    echo "Talos node $TALOS_NODE not reachable - skipping drift check."
    return 0
  fi

  local f name out drifted=() errored=() skipped=() clean=0
  for f in "$dir"/*.yaml "$dir"/*.yml; do
    [[ -e "$f" ]] || continue
    name=$(basename "$f")
    # Some patches are not idempotent -- Talos strategic-merge appends to
    # list fields rather than replacing them, so re-applying adds a
    # duplicate entry and the dry-run always shows a diff even when the
    # config is correct. Those files opt out with a
    # "# drift-check: skip - <reason>" line and must say why.
    if grep -qE '^#\s*drift-check:\s*skip' "$f"; then
      skipped+=("$name ($(grep -oE 'drift-check:\s*skip[[:space:]-]*.*' "$f" | head -1 | sed 's/drift-check:\s*skip[[:space:]-]*//'))")
      continue
    fi
    out=$(talosctl -n "$TALOS_NODE" patch machineconfig \
            --patch "@$f" --dry-run 2>&1) || true
    if grep -q 'no changes detected' <<<"$out"; then
      clean=$((clean + 1))
    elif grep -q 'Config diff:' <<<"$out"; then
      drifted+=("$name")
    else
      errored+=("$name")
    fi
  done

  local skipnote=""
  ((${#skipped[@]} > 0)) && skipnote=" (${#skipped[@]} skipped)"

  if ((${#drifted[@]} == 0 && ${#errored[@]} == 0)); then
    echo "All $clean Talos patches match the live machine config.$skipnote"
    for name in "${skipped[@]:-}"; do [[ -n "$name" ]] && echo "  skipped: $name"; done
    return 0
  fi

  if ((${#drifted[@]} > 0)); then
    echo "Talos patches that DO NOT match the live machine config:"
    for name in "${drifted[@]}"; do echo "  - $name"; done
    echo
    echo "  Either the node was changed outside git, or a tracked patch was"
    echo "  edited and never applied. See the diff with:"
    echo "    talosctl -n $TALOS_NODE patch machineconfig \\"
    echo "      --patch @talos/patches/<name> --dry-run"
    echo "  Do NOT apply anything without Tom's go-ahead - a permanent apply"
    echo "  restarts the control-plane static pods (~30s of API downtime)."
  fi
  if ((${#errored[@]} > 0)); then
    echo "Talos patches that could not be checked:"
    for name in "${errored[@]}"; do echo "  - $name"; done
  fi
  return 0
}

# ---- rollout churn --------------------------------------------------------

# Where the previous run's revision counters are kept. Deliberately
# outside the repo: this is per-host observation state, not config.
CHURN_STATE_FILE="${CHURN_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/weekly-renovate-review/rollouts.json}"
# A Deployment is flagged only if all three hold, so a single noisy
# afternoon or a brand-new workload does not trip it.
CHURN_RATE_PER_DAY="${CHURN_RATE_PER_DAY:-5}"
CHURN_MIN_ROLLOUTS="${CHURN_MIN_ROLLOUTS:-10}"
CHURN_MIN_WINDOW_DAYS="${CHURN_MIN_WINDOW_DAYS:-0.5}"

rollout_churn() {
  # Catches a Deployment being rewritten over and over -- the signature
  # of two controllers applying different specs to the same object.
  #
  # This failure mode is invisible to every other check in this script.
  # Two Kustomizations owned Flux's own controllers for 172 days, one
  # rendering cpu 2/2Gi with the concurrency patches and one rendering
  # stock 1/1Gi, both reconciling every 10m. Each apply produced a new
  # ReplicaSet and a new pod: kustomize-controller reached deployment
  # revision 142326, about 34 rollouts an hour, sustained. At every
  # instant the Deployment was 1/1 Available and every Kustomization was
  # Ready, so nothing sampling current state could see it. The fault
  # only exists in the derivative.
  #
  # Hence the state file. A raw revision counter cannot distinguish
  # "142k accumulated over six months" from "142k since Tuesday", and
  # would keep screaming for years after a fix, since the counter never
  # resets. So each run records where every Deployment's counter stood
  # and compares against last time -- at the weekly cadence of this
  # review, that is a week-over-week rate.
  #
  # First sight of a Deployment has no stored baseline, so it falls back
  # to revision 0 at creationTimestamp, i.e. the lifetime average. That
  # makes the very first run useful rather than silent, and it self-
  # corrects: once a baseline is written, history stops counting.
  #
  # Deployments only. StatefulSets and DaemonSets carry revision hashes
  # rather than a monotonic counter, so the same trick does not apply.
  local raw
  if ! raw=$(kubectl get deployments -A -o json 2>/dev/null); then
    echo "Could not list Deployments - skipping rollout churn check."
    return 0
  fi

  # The analysis reads the Deployment JSON on stdin, so the program
  # itself cannot also arrive by heredoc -- only the last stdin
  # redirection would survive.
  local script
  script=$(cat <<'PY'
import json, os, sys
from datetime import datetime, timezone

state_file = os.environ["CHURN_STATE_FILE"]
rate_limit = float(os.environ["CHURN_RATE_PER_DAY"])
min_delta  = int(os.environ["CHURN_MIN_ROLLOUTS"])
min_window = float(os.environ["CHURN_MIN_WINDOW_DAYS"])

def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))

now = datetime.now(timezone.utc)

try:
    old = json.load(open(state_file))
except (OSError, ValueError):
    old = {}
first_run = not old

items = json.load(sys.stdin).get("items", [])
new, flagged = {}, []

for d in items:
    m = d["metadata"]
    key = f'{m["namespace"]}/{m["name"]}'
    try:
        rev = int((m.get("annotations") or {}).get(
            "deployment.kubernetes.io/revision", 0))
    except ValueError:
        continue

    base = old.get(key)
    # No baseline, or the counter went backwards because the Deployment
    # was deleted and recreated: measure from creation instead.
    if not base or base.get("revision", 0) > rev:
        base = {"revision": 0, "at": m["creationTimestamp"]}

    window = (now - parse(base["at"])).total_seconds() / 86400.0
    delta  = rev - base["revision"]

    if window >= min_window:
        # Baseline advances only once the window is wide enough --
        # otherwise running this twice in an hour would reset the clock
        # forever and nothing would ever accumulate.
        new[key] = {"revision": rev, "at": now.isoformat()}
        rate = delta / window
        if delta >= min_delta and rate >= rate_limit:
            flagged.append((rate, key, delta, window, rev))
    else:
        new[key] = base

os.makedirs(os.path.dirname(state_file) or ".", exist_ok=True)
tmp = state_file + ".tmp"
with open(tmp, "w") as fh:
    json.dump(new, fh, indent=2, sort_keys=True)
os.replace(tmp, state_file)

scope = "since this Deployment was created" if first_run else "since the last run"

if not flagged:
    print(f"No Deployment rollout churn ({len(new)} tracked, measured {scope}).")
    if first_run:
        print("  Baseline written; from the next run this is a week-over-week rate.")
    raise SystemExit(0)

flagged.sort(reverse=True)
print(f"Deployments being rolled out repeatedly (measured {scope}):")
for rate, key, delta, window, rev in flagged:
    print(f"  {key}")
    print(f"    +{delta} rollouts over {window:.1f}d = {rate:.0f}/day"
          f"  (counter now at {rev})")
print()
print("  A Deployment should only roll out when someone changes it. A rate")
print("  like this almost always means two controllers are applying")
print("  different specs to the same object and overwriting each other.")
print("  Find the disagreement by diffing the competing ReplicaSet pod")
print("  templates, which is where the difference actually shows:")
print("    kubectl get rs -n <ns> -l app=<name> \\")
print("      --sort-by=.metadata.creationTimestamp")
print("    kubectl get rs -n <ns> <rs-a> -o jsonpath='{.spec.template}' > /tmp/a")
print("    kubectl get rs -n <ns> <rs-b> -o jsonpath='{.spec.template}' > /tmp/b")
print("  Then check which Kustomizations claim the object -- note that")
print("  the kustomize.toolkit.fluxcd.io/name label shows only the last")
print("  writer, so compare inventories rather than trusting it:")
print("    kubectl get kustomization -n flux-system <name> \\")
print("      -o jsonpath='{.status.inventory.entries[*].id}'")
print()
print("  Do NOT remove the losing side without staging it: Flux prunes by")
print("  diffing a Kustomization's previous inventory against the new one")
print("  and does not know another Kustomization manages the same object.")
print("  See the prune note in CLAUDE.md before touching shared resources.")
if first_run:
    print()
    print("  This is the first run, so the figures above are lifetime")
    print("  averages and may describe something already fixed. The")
    print("  baseline is now written; next run measures only new rollouts.")
PY
)
  if ! CHURN_STATE_FILE="$CHURN_STATE_FILE" \
       CHURN_RATE_PER_DAY="$CHURN_RATE_PER_DAY" \
       CHURN_MIN_ROLLOUTS="$CHURN_MIN_ROLLOUTS" \
       CHURN_MIN_WINDOW_DAYS="$CHURN_MIN_WINDOW_DAYS" \
       python3 -c "$script" <<<"$raw"; then
    echo "Rollout churn check failed - see the error above."
  fi
  return 0
}

# ---- ingress reachability -------------------------------------------------

# The only check here that leaves the cluster and speaks to the data
# path. It exists because on 2026-09-25 four internal hosts were broken
# in four different ways while every Kustomization, HelmRelease and pod
# was green: alertmanager had no Ingress at all (404), alloy pointed at
# a Service port that was never opened (503), s3 proxied plaintext to a
# TLS listener (400), and prometheus was fine but unresolvable from this
# host. None of them alerted, and none of the other checks in this
# script can see any of them.
#
# Pi-hole wildcards address=/gs-farm.net/10.0.10.1, so EVERY name under
# the domain resolves and reaches nginx. DNS success and a TCP response
# therefore prove nothing -- the status code is the only real signal.
#
# Internal class only. External-class hosts are deliberately excluded:
# from inside the LAN they resolve to the internal LB via that same
# wildcard, so testing them here would exercise the internal path under
# an external hostname and report confident nonsense.

# 401/403 are healthy: an authenticated app refusing an anonymous GET is
# working correctly. MinIO answers 403 with S3 XML, Pi-hole 403 at /.
INGRESS_OK_CODES="${INGRESS_OK_CODES:-200 301 302 303 307 308 401 403}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-20}"
# Space-separated hostnames to exclude. Add a reason next to any entry
# -- an undocumented skip is how a broken route becomes permanent.
#   gitops.gs-farm.net  # 504, known, see CLUSTER.md open issues
INGRESS_SKIP="${INGRESS_SKIP:-}"

ingress_reachability() {
  local hosts
  if ! hosts=$(kubectl get ingress -A -o jsonpath='{range .items[?(@.spec.ingressClassName=="internal")]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null); then
    echo "Could not list ingresses - skipping reachability check."
    return 0
  fi
  hosts=$(tr ' ' '\n' <<<"$hosts" | sed '/^$/d' | sort -u)
  if [[ -z "$hosts" ]]; then
    echo "No internal-class ingresses found."
    return 0
  fi

  local total=0 bad=0 skipped=0 unresolved=0 report="" skips=""
  local h code rc verdict

  while read -r h; do
    [[ -z "$h" ]] && continue
    if [[ " $INGRESS_SKIP " == *" $h "* ]]; then
      skipped=$((skipped + 1))
      skips+="  $h (skipped)"$'\n'
      continue
    fi
    total=$((total + 1))

    # Resolution is checked separately so "the control host cannot
    # resolve this" is never reported as "the app is down" -- that
    # confusion is exactly what hid the working Prometheus ingress.
    if ! getent hosts "$h" >/dev/null 2>&1; then
      unresolved=$((unresolved + 1))
      bad=$((bad + 1))
      report+="  $(printf '%-30s %s' "$h" "does not resolve")"$'\n'
      continue
    fi

    # No -k: an expired or wrong certificate should fail this check
    # rather than pass it quietly.
    code=$(curl -s -o /dev/null -w '%{http_code}' "https://$h/" \
             --max-time "$INGRESS_TIMEOUT" 2>/dev/null) && rc=0 || rc=$?

    if [[ " $INGRESS_OK_CODES " == *" $code "* ]]; then
      continue
    fi

    case "$rc" in
      28) verdict="no response within ${INGRESS_TIMEOUT}s" ;;
      35|60) verdict="TLS error (curl $rc)" ;;
      7)  verdict="connection refused" ;;
      6)  verdict="DNS failure at request time" ;;
      0)  verdict="HTTP $code" ;;
      *)  verdict="curl exit $rc (HTTP $code)" ;;
    esac
    bad=$((bad + 1))
    report+="  $(printf '%-30s %s' "$h" "$verdict")"$'\n'
  done <<<"$hosts"

  # Every host failing to resolve is a resolver problem on this host,
  # not fourteen broken ingresses. Say so rather than burying it.
  if (( unresolved > 0 && unresolved == total )); then
    echo "None of the $total internal hostnames resolve from this host."
    echo "  That is a resolver problem here, not $total broken ingresses."
    echo "  Fix with: sudo bash scripts/setup-gsfarmctl-dns.sh"
    return 0
  fi

  if (( bad == 0 )); then
    printf 'All %d internal ingresses reachable.' "$total"
    (( skipped > 0 )) && printf ' (%d skipped)' "$skipped"
    printf '\n'
    [[ -n "$skips" ]] && printf '%s' "$skips"
  else
    echo "Internal ingresses NOT serving (status code is the only real signal here):"
    printf '%s' "$report"
    printf '  %d of %d bad' "$bad" "$total"
    (( skipped > 0 )) && printf ', %d skipped' "$skipped"
    printf '\n'
    [[ -n "$skips" ]] && printf '%s' "$skips"
  fi
  return 0
}

# ---- health --------------------------------------------------------------

cmd_health() {
  log "==> git pull --ff-only"
  git -C "$REPO_ROOT" pull --ff-only

  log "==> flux get kustomizations -A"
  local out header not_ready
  out=$(flux get kustomizations -A 2>&1)
  header=$(head -1 <<<"$out")
  not_ready=$(tail -n +2 <<<"$out" | awk -F'\t' '{gsub(/ +$/,"",$5)} $5 != "True"')

  if [[ -z "$not_ready" ]]; then
    echo "All kustomizations Ready."
  else
    echo "Kustomizations NOT Ready:"
    echo "$header"
    echo "$not_ready"
  fi

  # HelmReleases are checked separately because a release can sit
  # Stalled (e.g. MissingRollbackTarget) while its Kustomization is
  # perfectly Ready and the app runs fine on its last good revision --
  # it silently refuses all further updates. Grafana hid like that for
  # nine days before 2026-09-23. Flux renders it as "Unknown", which
  # reads like a transient "reconciliation in progress", so anything
  # not True is worth a look rather than a shrug.
  log "==> flux get helmreleases -A"
  local hr_out hr_bad
  hr_out=$(flux get helmreleases -A 2>&1)
  hr_bad=$(tail -n +2 <<<"$hr_out" | awk -F'\t' '{gsub(/ +$/,"",$5)} $5 != "True"')
  if [[ -z "$hr_bad" ]]; then
    echo "All helmreleases Ready."
  else
    echo "HelmReleases NOT Ready (check for Stalled, not just in-progress):"
    head -1 <<<"$hr_out"
    echo "$hr_bad"
  fi

  log "==> pod readiness"
  local pods_bad
  pods_bad=$(not_healthy <<<"$(pod_snapshot)")
  if [[ -z "$pods_bad" ]]; then
    echo "All pods fully ready."
  else
    echo "Pods NOT fully ready:"
    echo "$pods_bad"
  fi

  # Catches the mis-indented/commented-out chart.spec.version that makes
  # Flux resolve "*" and upgrade unattended, invisible to Renovate.
  log "==> charts floating on latest"
  local floating
  floating=$(kubectl get helmcharts -A --no-headers 2>/dev/null \
               | awk '$4 == "*" {print "  " $2}')
  if [[ -z "$floating" ]]; then
    echo "No charts floating on '*'."
  else
    echo "Charts with NO pinned version (resolve '*' on every reconcile):"
    echo "$floating"
  fi

  log "==> talos patch drift"
  talos_drift

  log "==> deployment rollout churn"
  rollout_churn

  log "==> internal ingress reachability"
  ingress_reachability
}

# ---- main ----------------------------------------------------------------

main() {
  require_tools
  cd "$REPO_ROOT"

  local cmd="${1:-review}"
  case "$cmd" in
    review) shift || true; cmd_review "$@" ;;
    list) shift || true; cmd_list "$@" ;;
    check)
      shift
      local pr="${1:?usage: $0 check <PR_NUMBER> [--json]}"
      shift || true
      local as_json=false
      [[ "${1:-}" == "--json" ]] && as_json=true
      check_pr "$pr" "$as_json"
      ;;
    merge)
      shift
      local pr="${1:?usage: $0 merge <PR_NUMBER> [--force]}"
      shift || true
      cmd_merge "$pr" "$@"
      ;;
    health) shift || true; cmd_health "$@" ;;
    talos-drift) shift || true; talos_drift "$@" ;;
    rollout-churn) shift || true; rollout_churn "$@" ;;
    ingress-check) shift || true; ingress_reachability "$@" ;;
    --dry-run) cmd_review --dry-run ;;
    -h|--help|help)
      awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "${BASH_SOURCE[0]}"
      ;;
    *) die "unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"
