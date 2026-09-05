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
#
# Requires: gh (authenticated), git, kubectl, flux, jq, python3.

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
  for t in gh git kubectl flux jq python3; do
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
  local pr="$1"
  gh pr view "$pr" --repo "$REPO_SLUG" --json "$pr_json_fields"
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

# ---- check: mechanical criteria for one PR ----------------------------

check_pr() {
  local pr="$1" as_json="${2:-false}"
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
      --argjson mechanical_pass "$pass" \
      --argjson fail_reasons "$(printf '%s\n' "${fail_reasons[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
      --argjson files "$(jq -c '[.files[].path]' <<<"$data")" \
      --argjson changelog_links "$(printf '%s\n' "$links" | jq -R . | jq -s 'map(select(length>0))')" \
      '{number: ($number|tonumber), title: $title, url: $url, update_type: $update_type,
        ci: $ci, mergeStateStatus: $mergeable, mechanical_pass: $mechanical_pass,
        fail_reasons: $fail_reasons, files: $files, changelog_links: $changelog_links}'
  else
    echo "PR #$pr — $title"
    echo "  $url"
    echo "  update type: $update_type   CI: $ci   mergeState: $mergeable"
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
  # Reads a pod snapshot on stdin, prints lines not Running/Completed.
  awk '{status=$4} status != "Running" && status != "Completed" {print}'
}

cmd_merge() {
  local pr="$1"; shift || true
  local force=false
  [[ "${1:-}" == "--force" ]] && force=true

  local check_out
  check_out=$(check_pr "$pr" true)
  local mech_pass
  mech_pass=$(jq -r '.mechanical_pass' <<<"$check_out")

  if [[ "$mech_pass" != "true" && "$force" != true ]]; then
    log "PR #$pr fails mechanical criteria — refusing to merge:"
    jq -r '.fail_reasons[]' <<<"$check_out" | sed 's/^/  - /' >&2
    log "Re-run with --force only if you (Tom) have explicitly reviewed and approved this despite the failure."
    exit 1
  fi

  log "==> snapshotting pods before merge"
  local before after
  before=$(pod_snapshot)

  log "==> merging PR #$pr"
  gh pr merge "$pr" --repo "$REPO_SLUG" --squash

  log "==> flux reconcile source git cillflux"
  flux reconcile source git cillflux -n flux-system

  log "==> snapshotting pods after merge"
  sleep 5
  after=$(pod_snapshot)

  local unhealthy
  unhealthy=$(not_healthy <<<"$after")
  if [[ -n "$unhealthy" ]]; then
    echo "Pods not Running/Completed after merge of #$pr:"
    echo "$unhealthy"
    echo
    echo "(Investigate with kubectl describe / kubectl logs --previous before reporting — see"
    echo " CLAUDE.md 'Post-merge investigation'. Do not roll back or patch without Tom's go-ahead.)"
  else
    echo "PR #$pr merged. All pods Running/Completed."
  fi
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
    --dry-run) cmd_review --dry-run ;;
    -h|--help|help)
      sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"
