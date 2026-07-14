#!/usr/bin/env bash
# finding-verification.sh — agentic iterative validation post-processor for the
# deep review tier (issue #1092, epic #1088).
#
# WHAT / WHY
#   The deep tier now attempts to *confirm* a suspected logic/correctness finding
#   by running the repo's relevant lint/test tool before it is reported, so
#   plausible-but-wrong findings stop reaching reviewers. The deep tier does the
#   repro itself (it already has a Bash tool) and records the outcome on each such
#   finding as a `verification` field:
#     - "confirmed"    the repro reproduced the bug              -> keep as-is
#     - "refuted"      the repro tool ran and did NOT reproduce  -> downgrade one
#                      severity (or drop when already `info`)
#     - "unverifiable" no runnable lint/test target maps to it   -> keep as-is
#   This function is the pure-shell discipline layer over those tags: it applies
#   the downgrade/drop, tags the message auditable, and emits one
#   kind:"finding_verification" record per processed finding (via
#   emit_verification_record in token-metrics.sh) so the false-positive-rate delta
#   is measurable. It mirrors the documented lsp-verification downgrade pattern:
#   same record kind, same downgrade discipline, so token_report.sh aggregation and
#   the FP-rate math already work.
#
# PRIVILEGE / TIMEOUT GUARD (AC #3)
#   This function runs NO external tools — it is jq-only. The actual repro happens
#   inside the deep tier's existing `run_agentic` invocation, which already runs
#   with `--allowed-tools Bash,Read,Grep,Glob` and is wrapped by `timeout
#   $DEEP_TIMEOUT_SEC` (engine.sh). Validation therefore adds ZERO new tool
#   permissions and ZERO new network/write access, and cannot hang the review
#   because it inherits the per-tier timeout. It must never run in the writer/action
#   tier (the only tier with Write) — it is wired only after the deep tier.
#
# REWARD-HACKING GUARD (AC #4)
#   Only `refuted` (the repro tool actively failed to reproduce) downgrades/drops a
#   finding. `unverifiable` (absence of a runnable target) NEVER downgrades — that
#   would let a validator that maps nothing silently drop real findings to game the
#   FP-rate. Non-logic-class findings are never touched.
#
# Usage: source this file, then call:
#   apply_finding_verification <deep_json_file> [workflow] [tier] [context]
#     - mutates <deep_json_file> in place (downgrades/drops findings)
#     - never fails: a missing/invalid file or absent jq is a clean no-op

set -euo pipefail

# Bring in emit_verification_record if the caller has not already sourced
# token-metrics.sh (review-one-pr.sh sources both; tests may source only this).
if ! declare -F emit_verification_record >/dev/null 2>&1; then
  # shellcheck source=token-metrics.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/token-metrics.sh"
fi

# The finding classes that warrant a repro attempt. Start with logic/correctness
# (AC #1). `category` is compared lower-cased.
_fv_is_logic_category() {
  case "${1:-}" in
    logic | correctness) return 0 ;;
    *) return 1 ;;
  esac
}

# _fv_downgrade_severity <severity>
#   Prints the next-lower deep-review severity. `info` prints empty (the caller
#   drops the finding). An unrecognized severity prints itself (no change) so an
#   unexpected value can never silently escalate or vanish.
_fv_downgrade_severity() {
  case "${1:-}" in
    critical) printf 'major' ;;
    major)    printf 'minor' ;;
    minor)    printf 'info' ;;
    info)     printf '' ;;
    *)        printf '%s' "${1:-}" ;;
  esac
}

# apply_finding_verification <deep_json_file> [workflow] [tier] [context]
apply_finding_verification() {
  local file="${1:-}"
  local workflow="${2:-pr-review}"
  local tier="${3:-deep}"
  local context="${4:-}"

  # Safe no-ops: missing/empty file, no jq, or unparseable JSON.
  [ -n "$file" ] && [ -s "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq empty "$file" 2>/dev/null || return 0

  local count
  count="$(jq -r '(.findings // []) | length' "$file" 2>/dev/null || printf '0')"
  case "$count" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$count" -gt 0 ] || return 0

  local kept; kept="$(mktemp)"
  : > "$kept"

  local i
  for (( i = 0; i < count; i++ )); do
    local finding category verification severity
    finding="$(jq -c ".findings[$i]" "$file" 2>/dev/null)" || finding=""
    if [ -z "$finding" ] || [ "$finding" = "null" ]; then
      continue
    fi
    category="$(printf '%s' "$finding" | jq -r '(.category // "") | ascii_downcase' 2>/dev/null || printf '')"
    verification="$(printf '%s' "$finding" | jq -r '(.verification // "") | ascii_downcase' 2>/dev/null || printf '')"
    severity="$(printf '%s' "$finding" | jq -r '.severity // ""' 2>/dev/null || printf '')"

    # Only logic/correctness findings that carry a verification tag are processed;
    # everything else passes through byte-for-byte untouched (no record).
    if ! _fv_is_logic_category "$category" || [ -z "$verification" ]; then
      printf '%s\n' "$finding" >> "$kept"
      continue
    fi

    local outcome new_severity dropped=0
    case "$verification" in
      confirmed)
        outcome="confirmed"; new_severity="$severity" ;;
      refuted)
        outcome="refuted"; new_severity="$(_fv_downgrade_severity "$severity")"
        [ -z "$new_severity" ] && dropped=1 ;;
      *)
        # unverifiable (or any unknown tag): never downgrade on absence of a repro.
        outcome="unverifiable"; new_severity="$severity" ;;
    esac

    if [ "$dropped" -eq 1 ]; then
      emit_verification_record "$workflow" "$tier" "$outcome" "$severity" "dropped" "$i" "$context"
      continue
    fi

    emit_verification_record "$workflow" "$tier" "$outcome" "$severity" "$new_severity" "$i" "$context"

    printf '%s' "$finding" | jq -c \
      --arg sev "$new_severity" --arg oc "$outcome" \
      '.severity = $sev
       | .verified = $oc
       | .message = ((.message // "") + " [auditable: repro " + $oc + "]")' \
      >> "$kept" 2>/dev/null \
      || printf '%s\n' "$finding" >> "$kept"
  done

  # Reassemble the surviving findings back into the file. On any failure, leave
  # the original file untouched (fail-open — never corrupt the verdict).
  local arr tmp; arr="$(mktemp)"; tmp="$(mktemp)"
  if jq -s '.' "$kept" > "$arr" 2>/dev/null \
    && jq --slurpfile f "$arr" '.findings = $f[0]' "$file" > "$tmp" 2>/dev/null \
    && [ -s "$tmp" ]; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
  rm -f "$kept" "$arr"
  return 0
}
