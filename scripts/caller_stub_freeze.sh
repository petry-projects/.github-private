#!/usr/bin/env bash
set -euo pipefail
# caller_stub_freeze.sh — stub-freeze drift guard for the ring-0 self-host caller
# stubs (#1052, Part B). Backstops Part A (validate-caller-inputs.sh) for the two
# stubs whose `with:` forwarding actually broke in #1034: pr-review-trigger.yml
# and dev-lead.yml. It treats each stub's INPUT-FORWARDING block (the reusable
# `uses:` ref plus its `with:` block) like a template stub — it must stay
# byte-identical to a committed baseline, so any edit to the forwarding fails CI
# unless the baseline is updated in the same diff (an intentional, reviewed
# channel change).
#
# Scope note: only the `uses:` + `with:` forwarding block is frozen — NOT the
# `on:` triggers. dev-lead.yml's header explicitly allows repo-specific trigger
# edits, so freezing triggers would fight that documented allowance. #1034 was a
# `with:` forwarding change on a channel-pinned stub, and that is exactly what
# this freezes.
#
# It REUSES the byte-identity model from fleet_stub_drift.sh:
#   classify_stub_drift <expected_sha> <live_sha> -> ALIGNED|DRIFTED|MISSING
#   stub_drift_row <file> <expected_sha> <live_sha>
# "expected" is the git blob SHA of the committed baseline block; "live" is the
# blob SHA of the block extracted from the current stub. Equal ⇒ unchanged.
#
# All helpers are PURE (no network): they read local files and write to stdout.
# To regenerate a baseline after an intentional channel change:
#   scripts/caller_stub_freeze.sh --emit .github/workflows/pr-review-trigger.yml \
#     > tests/fixtures/caller-stub-freeze/pr-review-trigger.block

CSF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CSF_ROOT="$(cd "$CSF_DIR/.." && pwd)"

# shellcheck source=scripts/fleet_stub_drift.sh
source "${CSF_DIR}/fleet_stub_drift.sh"

# ── Frozen-stub manifest ──────────────────────────────────────────────────────
# Each row: "stub_path|baseline_block_path". The baseline holds the canonical
# forwarding block (see extract_forwarding_block). Add a stub here only for a
# ring-0 self-host caller whose forwarding must not silently change.
readonly -a CALLER_STUB_FREEZE_FILES=(
  ".github/workflows/pr-review-trigger.yml|tests/fixtures/caller-stub-freeze/pr-review-trigger.block"
  ".github/workflows/dev-lead.yml|tests/fixtures/caller-stub-freeze/dev-lead.block"
)

# extract_forwarding_block <stub_file> — print the normalized input-forwarding
# block: the reusable `uses:` line plus its `with:` block. Comments and blank
# lines are stripped and trailing CRs removed so benign doc edits don't trip the
# guard while any change to the forwarded ref/keys/values does. Pure: reads a
# local file, writes stdout.
extract_forwarding_block() {
  awk '
    function rstrip(s){ sub(/\r$/,"",s); return s }
    {
      raw=rstrip($0)
      if (raw ~ /^[[:space:]]*#/) next
      if (raw ~ /^[[:space:]]*$/) next
      t=raw; sub(/[^ ].*/,"",t); ind=length(t)
      if (phase==0) {
        if (raw ~ /uses:[[:space:]]*[^[:space:]]+\/\.github\/workflows\/[^[:space:]]+\.yml@/) {
          print raw; phase=1; uses_ind=ind
        }
        next
      }
      if (phase==1) {
        if (ind < uses_ind) { exit }
        if (ind==uses_ind && raw ~ /^[[:space:]]*with:([[:space:]]|$)/) { print raw; phase=2; with_ind=ind; next }
        next
      }
      if (phase==2) {
        if (ind <= with_ind) { exit }
        print raw
        next
      }
    }
  ' "$1"
}

# _csf_blob_sha <file> — git blob SHA of a file (empty if the file is absent).
_csf_blob_sha() {
  [ -f "$1" ] || { printf ''; return 0; }
  git hash-object "$1"
}

# _csf_block_sha <stub_file> — git blob SHA of the stub's extracted forwarding
# block (empty if the stub is absent or has no reusable call).
_csf_block_sha() {
  local block
  [ -f "$1" ] || { printf ''; return 0; }
  block="$(extract_forwarding_block "$1")"
  [ -n "$block" ] || { printf ''; return 0; }
  printf '%s\n' "$block" | git hash-object --stdin
}

# caller_stub_freeze_annotate <tsv_file> — emit a `::error::` per DRIFTED row and
# a `::warning::` per MISSING (a stub or baseline that could not be read). Returns
# 1 if any row is DRIFTED, 0 otherwise. Pure: reads the TSV, writes stdout.
# TSV format (reused): 1:stub  2:status  3:live_sha  4:expected_sha
caller_stub_freeze_annotate() {
  local f="${1:-}" file status live expected drifted=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  while IFS=$'\t' read -r file status live expected; do
    [ -n "$file" ] || continue
    case "$status" in
      DRIFTED)
        drifted=1
        printf '::error file=%s::Caller stub %s forwarding block has DRIFTED from its frozen baseline (block blob %s != baseline %s). This is the #1034 class: a channel-pinned stub whose forwarding changed. If this is an intentional, reviewed channel change, regenerate the baseline in the SAME diff: scripts/caller_stub_freeze.sh --emit %s > its .block file. See AGENTS.md "Caller-stub input forwarding across channel pins".\n' \
          "$file" "$file" "${live:0:12}" "${expected:0:12}" "$file"
        ;;
      MISSING)
        printf '::warning file=%s::Caller stub %s or its baseline could not be read (block blob %s, baseline %s) — freeze check skipped for it.\n' \
          "$file" "$file" "${live:0:12}" "${expected:0:12}"
        ;;
    esac
  done < "$f"
  [ "$drifted" -eq 0 ]
}

# ── CLI driver (no network) ───────────────────────────────────────────────────
main() {
  command -v git >/dev/null 2>&1 || { echo "::error::git is required but not installed." >&2; return 1; }

  # --emit <stub_file>: print the current forwarding block (to regenerate a baseline).
  if [ "${1:-}" = "--emit" ]; then
    [ -n "${2:-}" ] || { echo "usage: $0 --emit <stub_file>" >&2; return 2; }
    extract_forwarding_block "$2"
    return 0
  fi

  local tsv row stub baseline live expected
  tsv="$(mktemp)"
  trap 'rm -f "$tsv"' EXIT

  echo "Caller-stub freeze check — forwarding block vs committed baseline:"
  for row in "${CALLER_STUB_FREEZE_FILES[@]}"; do
    IFS='|' read -r stub baseline <<< "$row"
    live="$(_csf_block_sha "${CSF_ROOT}/${stub}")"
    expected="$(_csf_blob_sha "${CSF_ROOT}/${baseline}")"
    stub_drift_row "$stub" "$expected" "$live" >> "$tsv"
  done

  cat "$tsv"
  local rc=0
  caller_stub_freeze_annotate "$tsv" || rc=$?
  return "$rc"
}

# Source-guard: tests source this to exercise the pure helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
