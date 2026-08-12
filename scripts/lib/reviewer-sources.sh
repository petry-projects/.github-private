#!/usr/bin/env bash
# reviewer-sources.sh — sourced lookup helper for the reviewer-source registry (#1425).
#
# Owns reads of scripts/lib/reviewer-sources.tsv, the single source of truth for
# every third-party review bot the org recognizes. Three consumers project from it
# so their lists can never drift again (the 2026-08-02 graphite-app deadlock):
#   * dev-lead's trust check      — scripts/dev-lead-intent.sh (TRUSTED_BOTS)
#   * the advisory approval gate   — scripts/lib/advisory-review-gate.sh
#   * the reviewer scorecard       — scripts/reviewer_report.sh
#
# THE #1425 INVARIANT: (creates_threads=yes) ⇒ (dev_lead_trusted=yes). A bot that
# posts inline review comments creates a blocking review thread; if dev-lead may
# not act on it, no automation can clear it. reviewer_sources_assert_invariant
# enforces this; tests/test_reviewer_sources.bats runs it in CI.
#
# Usage: source this file, then call one of the reviewer_sources_* functions.
# Manifest path is resolved relative to this file; override with
# REVIEWER_SOURCES_MANIFEST for tests.

set -euo pipefail

# Resolve the manifest path once, relative to this file (works when sourced from
# anywhere). Honor an override so callers/tests can point elsewhere.
if [ -z "${REVIEWER_SOURCES_MANIFEST:-}" ]; then
  REVIEWER_SOURCES_MANIFEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reviewer-sources.tsv"
fi

# _reviewer_sources_manifest_or_die <caller>
#   Guards manifest existence; prints a diagnostic naming the caller.
_reviewer_sources_manifest_or_die() {
  [ -f "$REVIEWER_SOURCES_MANIFEST" ] && return 0
  echo "$1: manifest file not found at $REVIEWER_SOURCES_MANIFEST" >&2
  return 1
}

# reviewer_sources_version
#   Prints the manifest's schema_version (from its `# schema_version: N` comment).
#   Returns non-zero if absent so a malformed manifest is detected loudly.
reviewer_sources_version() {
  _reviewer_sources_manifest_or_die reviewer_sources_version || return 1
  local v
  v=$(awk '/^#[[:space:]]*schema_version:/ { gsub(/[^0-9]/, "", $0); print; exit }' \
        "$REVIEWER_SOURCES_MANIFEST") || true
  [ -n "$v" ] || { echo "reviewer_sources_version: no schema_version in $REVIEWER_SOURCES_MANIFEST" >&2; return 1; }
  printf '%s\n' "$v"
}

# reviewer_sources_logins
#   Every registered source login (column 1), one per line.
reviewer_sources_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_trusted_logins
#   Logins with dev_lead_trusted=yes (column 3), one per line.
reviewer_sources_trusted_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_trusted_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $3 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_thread_creator_logins
#   Logins with creates_threads=yes (column 2), one per line.
reviewer_sources_thread_creator_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_thread_creator_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $2 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_advisory_gate_logins
#   Logins with advisory_gate=yes (column 4), one per line.
reviewer_sources_advisory_gate_logins() {
  _reviewer_sources_manifest_or_die reviewer_sources_advisory_gate_logins || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $4 == "yes" { print $1 }' "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_trusted_bots_csv
#   dev-lead's webhook-facing trusted set: each trusted login with a "[bot]"
#   suffix, joined by commas. This is exactly the TRUSTED_BOTS default.
reviewer_sources_trusted_bots_csv() {
  local login csv=""
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    csv="${csv:+$csv,}${login}[bot]"
  done < <(reviewer_sources_trusted_logins)
  printf '%s\n' "$csv"
}

# reviewer_sources_invariant_violations
#   Prints each login that violates the #1425 invariant
#   (creates_threads=yes but dev_lead_trusted=no), one per line. Empty output
#   means the registry is sound.
reviewer_sources_invariant_violations() {
  _reviewer_sources_manifest_or_die reviewer_sources_invariant_violations || return 1
  awk -F'\t' '!/^[[:space:]]*#/ && $1 != "" && $2 == "yes" && $3 != "yes" { print $1 }' \
    "$REVIEWER_SOURCES_MANIFEST"
}

# reviewer_sources_assert_invariant
#   Exits 0 if the registry satisfies the #1425 invariant; otherwise prints the
#   offending logins and returns non-zero. This is the CI guard.
reviewer_sources_assert_invariant() {
  local violations
  violations="$(reviewer_sources_invariant_violations)" || return 1
  [ -z "$violations" ] && return 0
  echo "reviewer_sources: #1425 invariant violated — thread-creating sources that are not dev-lead-trusted:" >&2
  printf '%s\n' "$violations" >&2
  return 1
}
