#!/usr/bin/env bash
# lsp_pilot_emit.sh — turn ONE real pr-review (running under the pilot) into ONE
# pilot-schema record on TOKEN_LOG_FILE (#844, epic #839, issue #960).
#
# Where #952's standalone lsp_pilot_run.sh re-runs a SIMPLIFIED review to produce
# pilot records, this rides the PRODUCTION review: scripts/engine.sh captures the
# deep/audit/rubber-duck claude tiers' stream-json transcripts (gated on
# LSP_PILOT_ENABLED) into a per-PR stream dir, and scripts/review-one-pr.sh calls
# emit_record here when the review exits. So every auto-review under the flag is a
# free LSP-off ("A") sample, and flipping the LSP MCP on yields the matching
# LSP-on ("B") sample through the SAME pipeline — apples-to-apples, no synthetic
# input.
#
# Contract (mirrors lsp_pilot_run.sh's run_variant semantics so both sides join
# and render via scripts/lsp_pilot_compare.sh UNCHANGED):
#   variant     the explicit LSP_PILOT_VARIANT (on|off, #1031) when set, else
#               lsp-on when the LSP MCP is wired (REVIEW_MCP_CONFIG → readable
#               file, as setup-lsp-pilot.sh sets it), else lsp-off.
#   candidate   agent-lsp (override: LSP_CANDIDATE) on the lsp-on leg; baseline
#               on the lsp-off leg.
#   pr          "<owner/repo>#<number>@<head_sha>" — the immutable join key.
#
# The record is produced by scripts/lsp_pilot_measure.sh (its schema is reused
# verbatim — NOT modified here) and then tagged with kind:"lsp_pilot_run" so
# scripts/token_report.sh keeps excluding it from cost aggregation (its filter is
# (.kind // "token_usage") == "token_usage"). emit_record is non-fatal and a
# strict no-op off-pilot: the five consumer repos that never set
# LSP_PILOT_ENABLED are wholly unaffected.
#
# Pure helpers (lpe_*) are unit-tested in tests/dev-lead/unit/test_lsp_pilot_emit.bats.

set -euo pipefail

_LPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# lpe_pilot_active — true (0) when the pilot recording flag is on. The master
# gate: off → emit_record is a no-op and no consumer repo is affected.
lpe_pilot_active() { [ "${LSP_PILOT_ENABLED:-}" = "true" ]; }

# lpe_variant — the A/B leg label. When the pipeline explicitly selects a leg via
# LSP_PILOT_VARIANT (on|off, issue #1031) that is AUTHORITATIVE — this is what
# DECOUPLES capture from LSP wiring, so a production review can emit the lsp-off
# (A) control leg even here, where engine.sh auto-defaults REVIEW_MCP_CONFIG to
# the committed .github/review-mcp.json (the unrelated GitHub review MCP) and
# review-one-pr.sh sources engine.sh — which would otherwise mislabel A as lsp-on.
# When unset/"none", fall back to detecting the wired MCP (REVIEW_MCP_CONFIG →
# readable file, the exact activation condition engine.sh's _mcp_review_flags
# uses), preserving the legacy vars.LSP_PILOT_ENABLED path and lsp_pilot_run.sh's
# run_variant() semantics.
lpe_variant() {
  case "${LSP_PILOT_VARIANT:-}" in
    on)  printf 'lsp-on\n';  return 0 ;;
    off) printf 'lsp-off\n'; return 0 ;;
  esac
  if [ -n "${REVIEW_MCP_CONFIG:-}" ] && [ -f "${REVIEW_MCP_CONFIG}" ] && [ -r "${REVIEW_MCP_CONFIG}" ]; then
    printf 'lsp-on\n'
  else
    printf 'lsp-off\n'
  fi
}

# lpe_candidate — "baseline" on the lsp-off control leg; the candidate server name
# (LSP_CANDIDATE, default agent-lsp) on the lsp-on leg — matching run_variant().
lpe_candidate() {
  if [ "$(lpe_variant)" = "lsp-on" ]; then
    printf '%s\n' "${LSP_CANDIDATE:-agent-lsp}"
  else
    printf 'baseline\n'
  fi
}

# lpe_pr_key <pr_url> <head_sha> — assemble the "<owner/repo>#<number>@<sha>" join
# key from a PR HTML URL (https://github.com/<owner>/<repo>/pull/<n>).
lpe_pr_key() {
  local url="${1:-}" sha="${2:-}" repo num
  repo="$(printf '%s' "$url" | sed -E 's#^https?://github\.com/([^/]+/[^/]+)/pull/[0-9].*#\1#')"
  num="$(printf '%s' "$url" | sed -E 's#.*/pull/([0-9]+).*#\1#')"
  printf '%s#%s@%s\n' "$repo" "$num" "$sha"
}

# lpe_wall_seconds <start_epoch_ns> <end_epoch_ns> — float seconds, 1 dp, clamped
# >=0. Non-numeric input (e.g. %N unsupported) → 0.0; never crashes.
lpe_wall_seconds() {
  local a="${1:-0}" b="${2:-0}"
  awk -v a="$a" -v b="$b" 'BEGIN {
    if (a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/ || a == 0 || b == 0) { print "0.0"; exit }
    d = (b - a) / 1000000000.0; if (d < 0) d = 0; printf "%.1f", d
  }'
}

# lpe_emit_record <stream_dir> <pr_url> <head_sha> <wall_time_s> [token_log]
# Append exactly ONE pilot record (kind:"lsp_pilot_run") to TOKEN_LOG_FILE from
# the captured stream transcripts. Strict no-op (return 0) when: the pilot is off,
# jq is absent, TOKEN_LOG_FILE is unset, or no transcript was captured (e.g. the
# review took a skip/noop path with no claude tier call). Never aborts the review.
lpe_emit_record() {
  local stream_dir="${1:-}" pr_url="${2:-}" head_sha="${3:-}" wall="${4:-0}"
  local token_log="${5:-${TOKEN_LOG_FILE:-}}"

  lpe_pilot_active || return 0
  [ -n "$token_log" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$stream_dir" ] && [ -d "$stream_dir" ] || return 0

  # Fold every per-call transcript (deep/audit/duck) into one stream.
  # Nav tool counts are summed across all transcripts; usage is synthesized into
  # exactly ONE terminal result event (sum of all per-call result usages) so
  # lsp_pilot_measure.sh's lpm_usage_from_stream always reads a single, stable
  # result event instead of whichever stream.XXXXXX filename sorts last.
  local combined found=0 f
  combined="$(mktemp 2>/dev/null || true)"
  [ -n "$combined" ] || return 0
  for f in "$stream_dir"/*; do
    [ -f "$f" ] || continue
    cat "$f" >> "$combined" 2>/dev/null && found=1
  done
  if [ "$found" -ne 1 ] || [ ! -s "$combined" ]; then
    rm -f "$combined"
    return 0
  fi

  # Re-write combined: keep all non-result events for nav counting; replace the
  # multiple per-call result events with one synthesized event that sums all
  # usage fields and takes the model from the last result event in the stream.
  local _synth
  _synth="$(mktemp 2>/dev/null || true)"
  if [ -n "$_synth" ] && jq -cs '
    [.[] | select(type=="object")] as $all |
    ($all[] | select(.type != "result")),
    ([$all[] | select(.type=="result")] as $rs |
      if ($rs | length) == 0 then empty else
        $rs[-1] | .usage = {
          input_tokens:                ([$rs[].usage.input_tokens                // 0] | add),
          cache_read_input_tokens:     ([$rs[].usage.cache_read_input_tokens      // 0] | add),
          cache_creation_input_tokens: ([$rs[].usage.cache_creation_input_tokens  // 0] | add),
          output_tokens:               ([$rs[].usage.output_tokens                // 0] | add)
        }
      end)
  ' "$combined" > "$_synth" 2>/dev/null; then
    mv "$_synth" "$combined"
  else
    rm -f "$_synth"
  fi

  local variant candidate pr_key record
  variant="$(lpe_variant)"
  candidate="$(lpe_candidate)"
  pr_key="$(lpe_pr_key "$pr_url" "$head_sha")"

  # Reuse #952's extractor verbatim (its record schema is out of scope to change).
  # --token-log feeds it the #843 finding-verification + #846 cold-start records
  # that share TOKEN_LOG_FILE. Model is read from the stream's result event.
  if ! record="$(bash "${_LPE_DIR}/lsp_pilot_measure.sh" "$combined" \
        --pr "$pr_key" --variant "$variant" --candidate "$candidate" \
        --wall-time-s "$wall" --token-log "${token_log:-/dev/null}" 2>/dev/null)"; then
    rm -f "$combined"
    return 0
  fi
  rm -f "$combined"
  [ -n "$record" ] || return 0

  # Tag with kind so token_report.sh keeps excluding it from cost aggregation.
  # This is added to the EMITTED line only — the extractor's schema is untouched.
  jq -c '. + {kind: "lsp_pilot_run"}' <<< "$record" >> "$token_log" 2>/dev/null || true
  return 0
}

# Sourced for its helpers (review-one-pr.sh, unit tests). Direct execution is a
# usage error — this script has no standalone CLI.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "lsp_pilot_emit.sh is a sourced helper library; it has no CLI entry point." >&2
  exit 2
fi
