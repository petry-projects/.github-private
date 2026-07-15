#!/usr/bin/env bash
set -euo pipefail
# fleet_stub_remediate.sh — pure remediation-plan builder for the Actions Fleet
# Monitor stub-drift remediation (#1149, epic #1148). Sourced (not executed) so
# bats can exercise the pure helpers, mirroring fleet_stub_drift.sh.
#
# The Fleet Monitor emits the DRIFTED enrolled-repo set as fleet_stub_drift.json
# (see stub_drift_alert_json / fleet_monitor.sh): an array of objects
#   { repo, status, repo_sha, canonical_sha, stub, stub_file }
# where `stub` is the stub label and `stub_file` is the per-repo thin-caller
# path. This module derives a network-free remediation PLAN from that set: for
# each DRIFTED entry it names the consumer repo, the stub, the per-repo
# stub_file, and the canonical source of record (CANONICAL_STUB_REPO + the
# stub's canonical_path from STUB_REGISTRY) — the exact bytes the detector
# compared against. The two tracked fleet stubs are deployed VERBATIM from that
# canonical path, so the canonical bytes ARE the remediation content (they must
# NOT be routed through seed-repo-template.sh --emit-workflow, whose manifest is
# the repo-template baseline set and which repins caller refs).
#
# ALIGNED and MISSING entries are excluded (only DRIFTED is remediable), and a
# never-overwrite REMEDIATION_ALLOWLIST drops intentionally-customized files so
# the remediation step can never overwrite them — mirroring template_stub_drift.sh's
# TEMPLATE_DRIFT_ALLOWLIST + its recorded-rationale rule.
#
# The plan-building helpers here are PURE (no network): they take a JSON file /
# SHAs and write to stdout. The Phase-2 network driver (#1150) is co-located
# below the pure section — reading canonical bytes and opening PRs — reached only
# from main() on a direct run, mirroring how seed-repo-template.sh co-locates
# pure helpers with a network main().
#
# Remediation plan format — a JSON array of objects:
#   { repo, stub, stub_file, canonical_repo, canonical_path }

# Canonical source of record for the tracked fleet stubs, mirroring
# fleet_monitor.sh. Kept here (rather than sourced from fleet_monitor.sh) because
# fleet_monitor.sh is the network driver — it executes on source and cannot be
# sourced purely. Each STUB_REGISTRY entry is TAB-separated:
#   name <TAB> label <TAB> stub_path <TAB> canonical_path
#     name           — slug used in log lines
#     label          — the `stub` value carried in fleet_stub_drift.json
#     stub_path      — the `stub_file` value carried in fleet_stub_drift.json
#     canonical_path — org-template path under $CANONICAL_STUB_REPO
CANONICAL_STUB_REPO="${CANONICAL_STUB_REPO:-petry-projects/.github}"
STUB_REGISTRY=(
  $'initiative-planner\tInitiative-planner\t.github/workflows/initiative-planner.yml\tstandards/workflows/initiative-planner.yml'
  $'initiative-driver\tInitiative-driver\t.github/workflows/initiative-driver.yml\tstandards/workflows/initiative-driver.yml'
)

# ── Never-overwrite allowlist (AC #3) ─────────────────────────────────────────
# Files that the remediation step must NEVER re-sync, because a consumer repo has
# intentionally customized them. An allowlisted entry never appears in the plan
# output, so the remediation can never touch it — mirroring template_stub_drift.sh's
# TEMPLATE_DRIFT_ALLOWLIST. Each entry is either:
#   "owner/repo"            — never remediate ANY tracked stub in that repo, or
#   "owner/repo|stub_file"  — never remediate that one stub_file in that repo.
# Add an entry ONLY with a recorded rationale (the same recorded-rationale rule
# AGENTS.md applies to the template ci.yml exception): name the repo/file and why
# the customization is deliberate, so the never-overwrite decision stays auditable.
# It is intentionally empty until a first deliberate customization is recorded —
# by default every DRIFTED fleet stub is a verbatim deployment and IS remediable.
REMEDIATION_ALLOWLIST=()

# remediation_allowlisted <repo> <stub_file> — return 0 if the repo (whole-repo
# entry) or the specific repo+stub_file is on the never-overwrite allowlist.
remediation_allowlisted() {
  local repo="${1:-}" stub_file="${2:-}" a
  for a in "${REMEDIATION_ALLOWLIST[@]}"; do
    if [ "$a" = "$repo" ] || [ "$a" = "${repo}|${stub_file}" ]; then
      return 0
    fi
  done
  return 1
}

# resolve_canonical_path <stub_file> — echo the canonical_path from STUB_REGISTRY
# for the registered stub whose per-repo stub_path equals <stub_file>. Returns 1
# (no output) for an unrecognized stub_file, so the plan builder can skip an
# entry it cannot map to a canonical source.
resolve_canonical_path() {
  local stub_file="${1:-}" entry stub_path canonical_path
  for entry in "${STUB_REGISTRY[@]}"; do
    # Fields 1-2 (name, label) are unused by the resolver — discard them.
    IFS=$'\t' read -r _ _ stub_path canonical_path <<< "$entry"
    if [ "$stub_path" = "$stub_file" ]; then
      printf '%s\n' "$canonical_path"
      return 0
    fi
  done
  return 1
}

# build_remediation_plan <json_file> — PURE. Reads a fleet_stub_drift.json array
# and emits the remediation plan as a JSON array. For each DRIFTED entry
# (ALIGNED/MISSING excluded, AC #2) that is NOT allowlisted (AC #3) and whose
# stub_file resolves to a canonical source (AC #1), emits an object naming the
# consumer repo, the stub, the per-repo stub_file, and the canonical source
# (CANONICAL_STUB_REPO + canonical_path). An empty/absent file yields "[]".
build_remediation_plan() {
  local json="${1:-}"
  if [ -z "$json" ] || [ ! -s "$json" ]; then
    echo "[]"
    return 0
  fi

  # Fail loud on malformed input. If the driving jq below can't parse "$json",
  # the read loop sees nothing and the function would emit an empty plan with
  # exit 0 — silently reading as "nothing to remediate" and hiding real drift.
  if ! jq -e 'type == "array"' "$json" > /dev/null 2>&1; then
    echo "::error::fleet_stub_remediate: input is not a readable JSON array: $json" >&2
    return 1
  fi

  local tmp repo stub stub_file canonical_path
  tmp="$(mktemp)"
  while IFS=$'\t' read -r repo stub stub_file; do
    [ -n "$repo" ] || continue
    remediation_allowlisted "$repo" "$stub_file" && continue
    if ! canonical_path="$(resolve_canonical_path "$stub_file")"; then
      # Unrecognized stub_file: intentionally skipped (only registered stubs are
      # remediable), but warn so a registry gap is auditable rather than silent.
      echo "::warning::fleet_stub_remediate: no canonical source for stub_file '$stub_file' in $repo — skipping" >&2
      continue
    fi
    jq -n \
      --arg repo "$repo" \
      --arg stub "$stub" \
      --arg stub_file "$stub_file" \
      --arg canonical_repo "$CANONICAL_STUB_REPO" \
      --arg canonical_path "$canonical_path" \
      '{repo: $repo, stub: $stub, stub_file: $stub_file,
        canonical_repo: $canonical_repo, canonical_path: $canonical_path}' \
      >> "$tmp"
  done < <(jq -r '
    .[]
    | select(.status == "DRIFTED")
    | [.repo, (.stub // ""), (.stub_file // "")]
    | @tsv' "$json")

  # Guarantee temp cleanup regardless of the final jq's exit, and propagate its
  # status rather than swallowing it.
  local out status
  out="$(jq -s '.' "$tmp")"; status=$?
  rm -f "$tmp"
  [ "$status" -eq 0 ] || return "$status"
  printf '%s\n' "$out"
}

# ══════════════════════════════════════════════════════════════════════════════
# Network driver (Phase 2, #1150). Everything above is PURE; everything below
# performs network I/O and is only reached from main() on a direct run. The
# driver consumes the plan from build_remediation_plan, groups entries by repo,
# and — per repo — creates a branch, PUTs the canonical bytes, verifies
# byte-identity, and opens exactly one PR. It mirrors seed-repo-template.sh's
# cross-repo machinery (_is_dry, branch + contents PUT + a single gh pr create).
# ══════════════════════════════════════════════════════════════════════════════

# DRY_RUN defaults to true (#1150 AC #2): the first wiring is inert. A write only
# happens when DRY_RUN=false AND an explicit repo scope is supplied (AC #7).
DRY_RUN="${DRY_RUN:-true}"
# Explicit repo scope (AC #7): a space/comma-separated allowlist of consumer
# repos the driver may write to. Empty means "no scope" — live writes are refused
# (fail-closed); dry-run logs the whole plan regardless.
REMEDIATE_REPOS="${REMEDIATE_REPOS:-}"

_is_dry() { [ "$DRY_RUN" = "true" ]; }

# _scope_list — echo the normalized repo scope, one repo per line (may be empty).
_scope_list() {
  printf '%s' "$REMEDIATE_REPOS" | tr ', ' '\n\n' | grep -v '^$' || true
}

# _in_scope <repo> — 0 if <repo> is within scope. An empty scope means every repo
# in the plan is in scope (used by dry-run, which never writes).
_in_scope() {
  local repo="$1" s
  [ -z "$(_scope_list)" ] && return 0
  while IFS= read -r s; do [ "$s" = "$repo" ] && return 0; done < <(_scope_list)
  return 1
}

# _canonical_bytes <canonical_repo> <canonical_path> — echo the decoded bytes of
# the canonical stub (the source of record the SHA drift was measured against).
# Mirrors fleet_monitor.sh's canonical read: contents API .content, base64 -d.
_canonical_bytes() {
  gh api "repos/${1}/contents/${2}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

# _canonical_sha <canonical_repo> <canonical_path> — echo the canonical git blob
# SHA (the byte-identity target for the post-PUT verify, AC #5).
_canonical_sha() {
  gh api "repos/${1}/contents/${2}" --jq '.sha' 2>/dev/null || true
}

# _blob_sha <repo> <path> <ref> — echo the git blob SHA of <path> on <ref>.
_blob_sha() {
  gh api "repos/${1}/contents/${2}?ref=${3}" --jq '.sha' 2>/dev/null || true
}

# _put_file <repo> <path> <content> <branch> <message> — write <content> to
# <path> on <branch> via the contents PUT, passing the existing file SHA when
# overwriting. Mirrors seed-repo-template.sh's _put_file.
_put_file() {
  local repo="$1" path="$2" content="$3" branch="$4" msg="$5" sha encoded
  local -a sha_arg=()
  sha="$(_blob_sha "$repo" "$path" "$branch")"
  [ -n "$sha" ] && [ "$sha" != "null" ] && sha_arg=(--field "sha=${sha}")
  encoded="$(printf '%s' "$content" | base64 -w 0 2>/dev/null || printf '%s' "$content" | base64)"
  gh api "repos/${repo}/contents/${path}" --method PUT \
    --field "message=${msg}" --field "content=${encoded}" --field "branch=${branch}" \
    "${sha_arg[@]}" --silent 2>/dev/null \
    || { echo "::error::cannot write ${path} on ${repo}" >&2; return 1; }
  echo "  [remediate] wrote ${path}"
}

# _remediate_repo <repo> <entries_tsv> — remediate one consumer repo. <entries_tsv>
# is newline-separated "stub_file<TAB>canonical_repo<TAB>canonical_path<TAB>stub"
# lines (all of this repo's DRIFTED, non-allowlisted stubs). Creates one branch,
# PUTs each stub's canonical bytes, verifies byte-identity, and opens one PR.
_remediate_repo() {
  local repo="$1" entries="$2"
  local branch default_branch base_sha
  branch="fleet-stub-remediate/$(date -u +%Y-%m-%d)"

  local stub_files
  stub_files="$(printf '%s\n' "$entries" | cut -f1 | paste -sd' ' -)"
  echo "[remediate] target repo: ${repo} (stubs:${stub_files:+ }${stub_files})"

  if _is_dry; then
    local sf cr cp
    while IFS=$'\t' read -r sf cr cp _; do
      [ -n "$sf" ] || continue
      echo "[remediate] [dry-run] would fetch ${cr}/${cp} and write ${sf}"
    done <<< "$entries"
    echo "[remediate] [dry-run] would create branch ${branch} on ${repo}, PUT the above,"
    echo "       and open one PR against the default branch. No writes made."
    echo "[remediate] PASS (dry-run) — ${repo}"
    return 0
  fi

  # Idempotent skip (AC #3): an already-open remediation PR for this head means
  # the proposal exists — do not create a second branch/PR. Mirrors
  # seed-repo-template.sh's gh pr list --head check.
  local existing_pr
  existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [ -n "$existing_pr" ]; then
    echo "[remediate] PR #${existing_pr} already open for branch ${branch} on ${repo} — skipping (idempotent)"
    return 0
  fi

  default_branch="$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo main)"
  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default_branch}" --jq '.object.sha' 2>/dev/null || true)"
  if [ -z "$base_sha" ]; then
    echo "::error::cannot read ${default_branch} head on ${repo}" >&2
    return 1
  fi
  # Create the branch, or reuse it if it already exists (AC #3: never re-create).
  gh api "repos/${repo}/git/refs" --method POST \
    --field "ref=refs/heads/${branch}" --field "sha=${base_sha}" --silent 2>/dev/null \
    || gh api "repos/${repo}/git/ref/heads/${branch}" --silent 2>/dev/null \
    || { echo "::error::cannot create branch ${branch} on ${repo}" >&2; return 1; }

  local sf cr cp stub content canon_sha written_sha
  while IFS=$'\t' read -r sf cr cp stub; do
    [ -n "$sf" ] || continue
    content="$(_canonical_bytes "$cr" "$cp")"
    if [ -z "$content" ]; then
      echo "::error::could not fetch canonical bytes ${cr}/${cp} for ${repo} — failing repo" >&2
      return 1
    fi
    canon_sha="$(_canonical_sha "$cr" "$cp")"
    if [ -z "$canon_sha" ]; then
      echo "::error::could not read canonical blob SHA ${cr}/${cp} for ${repo} — cannot verify byte-identity; failing repo" >&2
      return 1
    fi
    _put_file "$repo" "$sf" "$content" "$branch" "chore: remediate drifted stub ${sf} from ${cr}/${cp}" || return 1
    # Byte-identity verify (AC #5): the written blob SHA must equal the canonical
    # blob SHA. On mismatch, fail the repo BEFORE opening a misleading PR.
    written_sha="$(_blob_sha "$repo" "$sf" "$branch")"
    if [ "$written_sha" != "$canon_sha" ]; then
      echo "::error::byte-identity mismatch on ${repo}:${sf} — wrote ${written_sha}, canonical ${canon_sha}; not opening a PR" >&2
      return 1
    fi
    echo "  [remediate] verified ${sf} == canonical (${canon_sha})"
  done <<< "$entries"

  # One PR per repo (AC #1, #4): a proposal against the default branch citing the
  # canonical source and the drifted stubs — never a direct push to default.
  local title body
  title="chore: remediate drifted workflow stub(s) — ${repo}"
  body="$(printf 'Auto-remediates fleet stub drift by deploying the canonical bytes verbatim.\n\nCanonical source of record: %s\nStubs remediated:\n%s\n\nContent is byte-identical to canon (blob SHA verified); opened as a proposal by fleet_stub_remediate.sh (#1150).\n' \
    "$(printf '%s\n' "$entries" | awk -F'\t' 'NF{print "- "$2"/"$3}' | sort -u | paste -sd'; ' -)" \
    "$(printf '%s\n' "$entries" | awk -F'\t' 'NF{print "- "$1}')")"
  gh pr create --repo "$repo" --head "$branch" --base "$default_branch" \
    --title "$title" --body "$body" 2>/dev/null \
    || { echo "::error::cannot open PR on ${repo}" >&2; return 1; }
  echo "[remediate] PASS — ${repo} (1 PR opened against ${default_branch})"
}

# run_remediation <json> — build the plan, group by repo, apply the fail-closed
# scope gate, and remediate each in-scope repo (one branch + one PR per repo).
run_remediation() {
  local json="$1" plan repo entries failed=0

  # Fail-closed blast-radius bound (AC #7): live operation requires an explicit
  # repo scope. With none, refuse to write — stay dry-run and warn.
  if ! _is_dry && [ -z "$(_scope_list)" ]; then
    echo "::warning::fleet_stub_remediate: DRY_RUN=false but no repo scope (REMEDIATE_REPOS/--repo) — refusing live writes; staying dry-run (fail-closed blast-radius bound)."
    DRY_RUN=true
  fi

  plan="$(build_remediation_plan "$json")" || return 1
  if [ "$(printf '%s' "$plan" | jq 'length')" -eq 0 ]; then
    echo "[remediate] no remediable drift — nothing to do."
    return 0
  fi

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if ! _in_scope "$repo"; then
      echo "[remediate] ${repo} not in scope — skipping"
      continue
    fi
    entries="$(printf '%s' "$plan" | jq -r --arg r "$repo" \
      '.[] | select(.repo == $r) | [.stub_file, .canonical_repo, .canonical_path, .stub] | @tsv')"
    _remediate_repo "$repo" "$entries" || failed=1
  done < <(printf '%s' "$plan" | jq -r '[.[].repo] | unique | .[]')

  return "$failed"
}

# ── CLI ───────────────────────────────────────────────────────────────────────
main() {
  local cmd
  for cmd in gh jq base64; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; return 1; }
  done

  local json="fleet_stub_drift.json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)     [ $# -ge 2 ] || { echo "::error::--repo needs a value" >&2; return 2; }
                  REMEDIATE_REPOS="${REMEDIATE_REPOS:+$REMEDIATE_REPOS }$2"; shift 2; continue ;;
      --repo=*)   REMEDIATE_REPOS="${REMEDIATE_REPOS:+$REMEDIATE_REPOS }${1#--repo=}"; shift; continue ;;
      --dry-run)  DRY_RUN=true; shift; continue ;;
      -h|--help)  sed -n '2,31p' "$0"; return 0 ;;
      --*)        echo "::error::unknown argument: $1" >&2; return 2 ;;
      *)          json="$1"; shift; continue ;;
    esac
  done

  run_remediation "$json"
}

# Source-guard: tests source this to exercise the pure helpers; a direct run
# drives the network remediation from a local fleet_stub_drift.json.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
