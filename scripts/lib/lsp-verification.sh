#!/usr/bin/env bash
set -euo pipefail

# LSP finding-verification step — epic #839 (LSP pilot), story #843.
# Contract: docs/lsp-pilot.md §2 (find-references / diagnostics grounding).
#
# This is the one genuinely-new piece of the LSP pilot (docs/lsp-pilot.md §6):
# before a deep/audit finding that asserts a cross-file/semantic claim (e.g.
# "undefined", "breaks N callers", "unused symbol") is posted, the reviewer
# grounds it against the LSP navigation tools (find_references / get_diagnostics).
# Only the model can call the MCP `mcp__lsp__*` tools, so it annotates each such
# finding in its JSON output with an `lsp_verification` field ("verified" |
# "unverifiable"); this shell layer ENFORCES that annotation deterministically:
#
#   - A finding LSP could not ground ("unverifiable") is DOWNGRADED one severity
#     level and ANNOTATED `[lsp: unverifiable]` — never silently dropped and
#     never posted as a confident finding (AC #2).
#   - Each verified/unverifiable outcome is emitted to the Token Cost Observatory
#     JSONL so the comparison harness can compute the false-positive-rate delta
#     (AC #4) — via emit_verification_record in token-metrics.sh.
#   - The whole step is INERT (findings file byte-for-byte unchanged, nothing
#     emitted) when the LSP server is absent or degraded, so the review proceeds
#     exactly as today (AC #3). This reuses the same MCP connect/degradation
#     signal `_emit_mcp_failure_warning` keys on (scripts/engine.sh).
#
# Sourced by scripts/review-one-pr.sh after engine.sh and token-metrics.sh.

# _lsp_failure_pattern
# The MCP connection/init-failure regex used to detect a degraded LSP server.
# Prefer engine.sh's single source of truth (_mcp_failure_pattern) when this lib
# is sourced alongside it; otherwise fall back to an equivalent local pattern so
# the lib stays usable (and unit-testable) on its own.
_lsp_failure_pattern() {
  if declare -f _mcp_failure_pattern >/dev/null 2>&1; then
    _mcp_failure_pattern
    return
  fi
  local _pat
  _pat='mcp server [^[:space:]]*[[:space:]]*("[^"]*"[[:space:]]*)?(failed|error)'
  _pat="$_pat"'|failed to (connect|initialize|reconnect|start)[^.]*mcp'
  _pat="$_pat"'|mcp[^.]*(connection|initializ)[^.]*(fail|error)'
  _pat="$_pat"'|could not (connect to|start) mcp server'
  printf '%s' "$_pat"
}

# _lsp_downgrade_severity <severity>
# One step toward "info" on the info|minor|major|critical ladder. Bottoms out at
# info; unknown values collapse to info (safe — never escalates).
_lsp_downgrade_severity() {
  case "$1" in
    critical) printf 'major' ;;
    major)    printf 'minor' ;;
    *)        printf 'info'  ;;
  esac
}

# lsp_verification_active [cli_output_file...]
# Returns 0 (active) iff the LSP navigation tools are wired AND not degraded:
#   - REVIEW_MCP_CONFIG points at a readable file,
#   - REVIEW_MCP_ALLOWED_TOOLS permits at least one mcp__lsp__ tool (so this is
#     the LSP pilot, not e.g. a Context7-only run),
#   - none of the given CLI-output files show an MCP connect/init failure.
# Returns 1 (inert) otherwise. The CLI-output scan is the degradation gate: a
# server that failed to connect means "skip verification, review as today".
lsp_verification_active() {
  [ -n "${REVIEW_MCP_CONFIG:-}" ] || return 1
  [ -f "${REVIEW_MCP_CONFIG}" ] && [ -r "${REVIEW_MCP_CONFIG}" ] || return 1
  case "${REVIEW_MCP_ALLOWED_TOOLS:-}" in
    *mcp__lsp__*) : ;;
    *) return 1 ;;
  esac

  if [ "$#" -gt 0 ]; then
    local f present=()
    for f in "$@"; do [ -f "$f" ] && present+=("$f"); done
    if [ "${#present[@]}" -gt 0 ] \
       && grep -qiE "$(_lsp_failure_pattern)" "${present[@]}" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# apply_lsp_verification <findings_json> <tier> [cli_output_file...]
# Enforces the LSP finding-verification contract on a review verdict file in
# place. No-op (file untouched, nothing emitted) when verification is inert —
# LSP unwired/degraded, jq missing, or the file is not a {findings:[...]} object.
apply_lsp_verification() {
  local file="${1:-}" tier="${2:-deep}"
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi   # remaining args: CLI output files
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e 'type == "object" and (.findings | type == "array")' "$file" >/dev/null 2>&1 || return 0
  lsp_verification_active "$@" || return 0

  local workflow="${TOKEN_WORKFLOW:-unknown}" context="${PR_URL:-}"

  # Emit one verification record per annotated finding (before rewriting, so the
  # original severity is the recorded severity_before).
  if declare -f emit_verification_record >/dev/null 2>&1; then
    local idx outcome sev cat sev_after
    while IFS=$'\t' read -r idx outcome sev cat; do
      [ -n "$idx" ] || continue
      if [ "$outcome" = "unverifiable" ]; then
        sev_after="$(_lsp_downgrade_severity "$sev")"
      else
        sev_after="$sev"
      fi
      emit_verification_record "$workflow" "$tier" "$context" \
        "$idx" "$cat" "$sev" "$sev_after" "$outcome" || true
    done < <(jq -r '
      .findings | to_entries[]
      | (.value.lsp_verification // "") as $v
      | select($v == "verified" or $v == "unverifiable")
      | [ (.key | tostring), $v, (.value.severity // "info"), (.value.category // "") ]
      | @tsv
    ' "$file" 2>/dev/null)
  fi

  # Downgrade + annotate every unverifiable finding (atomic rewrite).
  local tmp; tmp="$(mktemp "${file}.lspv.XXXXXX")" || return 0
  if jq '
      def downgrade:
        if . == "critical" then "major"
        elif . == "major" then "minor"
        else "info" end;
      .findings |= map(
        if (.lsp_verification // "") == "unverifiable" then
            .severity = ((.severity // "info") | downgrade)
          | .message = ((.message // "")
              + (if (.message // "") | test("\\[lsp: unverifiable\\]")
                 then "" else " [lsp: unverifiable]" end))
        else . end
      )
    ' "$file" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
  return 0
}
