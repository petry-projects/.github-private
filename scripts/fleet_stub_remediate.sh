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
# All functions here are PURE (no network): they take a JSON file / SHAs and
# write to stdout. Network (reading canonical bytes, opening PRs) lives in the
# remediation driver, not here.
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

  local tmp repo stub stub_file canonical_path
  tmp="$(mktemp)"
  while IFS=$'\t' read -r repo stub stub_file; do
    [ -n "$repo" ] || continue
    remediation_allowlisted "$repo" "$stub_file" && continue
    canonical_path="$(resolve_canonical_path "$stub_file")" || continue
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

  jq -s '.' "$tmp"
  rm -f "$tmp"
}

# ── CLI driver (pure — reads a local JSON file, no network) ────────────────────
# Sourced by tests to exercise the pure helpers; when executed directly it builds
# the plan from a fleet_stub_drift.json path (default ./fleet_stub_drift.json) and
# writes the JSON plan to stdout.
main() {
  local json="${1:-fleet_stub_drift.json}"
  command -v jq > /dev/null 2>&1 || { echo "::error::jq is required but not installed." >&2; return 1; }
  build_remediation_plan "$json"
}

# Source-guard: tests source this to exercise the pure helpers; a direct run
# drives the plan build from a local JSON file.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
