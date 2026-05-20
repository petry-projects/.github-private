#!/usr/bin/env bash
# Run the cascading review against every PR listed in $PRS_FILE (default
# prs.txt). One PR per line. Empty input is a no-op.
#
# Env (passed through from the workflow):
#   PRS_FILE          — path to candidate list (default: prs.txt)
#   MAX_PRS           — stop after this many actual reviews (no-ops don't count)
#   CANDIDATE_LIMIT   — hard cap on candidates inspected (timeout backstop)
#   REVIEW_ENGINE     — primary engine (claude|gemini|copilot); may follow
#                       fallback chain claude -> gemini -> copilot
#   GH_TOKEN          — workflow auth (set at job level)
#
# Exit:
#   0 — finished cleanly (zero or more reviews posted)
#   1 — session aborted early (a non-skip failure on some PR; remaining
#       candidates are deferred to the next scheduled run)

set -euo pipefail

PRS_FILE="${PRS_FILE:-prs.txt}"
MAX_PRS="${MAX_PRS:-10}"
CANDIDATE_LIMIT="${CANDIDATE_LIMIT:-100}"

# Pre-flight: validate engine availability before touching any PR.
# Sets CLAUDE_AVAILABLE, GEMINI_AVAILABLE, COPILOT_AVAILABLE and emits
# ::warning:: annotations + job-summary table for any unavailable engine.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-engines.sh
source "$SCRIPT_DIR/validate-engines.sh"
validate_engines

# ---------------------------------------------------------------------------
# Copilot REST API smoke test (only when Copilot is the primary engine).
#
# Verifies GitHub Models API connectivity and auth BEFORE reviewing any PRs,
# so format/auth errors surface as a clear setup failure rather than being
# mis-classified as rate-limit hits mid-run.
# ---------------------------------------------------------------------------
if [ "${REVIEW_ENGINE:-claude}" = "copilot" ]; then
  echo "==> Copilot engine pre-flight: testing GitHub Models API"

  _smoke_model="${COPILOT_API_MODEL:-}"
  if [ -z "$_smoke_model" ]; then
    # shellcheck source=engine.sh
    source "$SCRIPT_DIR/engine.sh" > /dev/null || {
      echo "::error::Copilot pre-flight: failed to source engine.sh — check REVIEW_ENGINE and file path" >&2
      exit 1
    }
    _smoke_model="${COPILOT_API_MODEL:-openai/o4-mini}"
  fi

  _smoke_payload_file=$(mktemp) || { echo "::error::Copilot pre-flight: mktemp failed" >&2; exit 1; }
  python3 -c "
import json, sys
sys.stdout.write(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': 'Reply with the single word: ready'}],
    'max_tokens': 5,
    'temperature': 0,
}))
" "$_smoke_model" > "$_smoke_payload_file" || {
    rm -f "$_smoke_payload_file"
    echo "::error::Copilot pre-flight: failed to build smoke-test JSON payload" >&2
    exit 1
  }

  _smoke_rc=0
  _smoke_raw=$(
    timeout 30 curl -sSL \
      -H "Authorization: Bearer ${COPILOT_GITHUB_TOKEN:?COPILOT_GITHUB_TOKEN not set for copilot engine}" \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://models.github.ai/inference/chat/completions \
      --data-binary @"$_smoke_payload_file" \
      -w '\n%{http_code}'
  ) || _smoke_rc=$?
  rm -f "$_smoke_payload_file"

  if [ "$_smoke_rc" -ne 0 ]; then
    echo "::error::Copilot pre-flight failed: curl exited $_smoke_rc — check COPILOT_GITHUB_TOKEN and network connectivity"
    exit 1
  fi

  _smoke_http=$(printf '%s' "$_smoke_raw" | tail -n 1)
  _smoke_body=$(printf '%s' "$_smoke_raw" | head -n -1)

  if [ "$_smoke_http" -ge 400 ]; then
    echo "::error::Copilot pre-flight failed: GitHub Models API returned HTTP $_smoke_http for model '${_smoke_model}'"
    echo "  Response: $_smoke_body"
    echo "  Check COPILOT_GITHUB_TOKEN permissions and that model '${_smoke_model}' is available."
    echo "  Override the model via the COPILOT_API_MODEL env var if needed."
    exit 1
  fi

  _smoke_text=$(printf '%s' "$_smoke_body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('choices', [{}])[0].get('message', {}).get('content', '(empty)'))
" 2>/dev/null || echo "(parse failed)")
  echo "::notice::Copilot pre-flight passed — model=${_smoke_model} response='${_smoke_text}'"
  unset _smoke_model _smoke_payload_file _smoke_rc _smoke_raw _smoke_http _smoke_body _smoke_text
fi

if [ ! -s "$PRS_FILE" ]; then
  echo "::notice::No candidate PRs to review."
  exit 0
fi

actual=0
skipped_noops=0
failed=0
engine_fallbacks=0
fallback_engines=""
processed=0
session_aborted=0
abort_pr=""
abort_reason=""
total_candidates=$(grep -c . "$PRS_FILE" || true)

while IFS= read -r pr_url; do
  [ -z "$pr_url" ] && continue
  processed=$((processed + 1))

  if [ "$processed" -gt "$CANDIDATE_LIMIT" ]; then
    echo "::notice::Hit CANDIDATE_LIMIT=$CANDIDATE_LIMIT, stopping batch"
    break
  fi
  if [ "$actual" -ge "$MAX_PRS" ]; then
    echo "::notice::Reached MAX_PRS=$MAX_PRS actual reviews, stopping batch"
    break
  fi

  echo "::group::Reviewing $pr_url"
  rc=0
  bash scripts/review-one-pr.sh "$pr_url" || rc=$?

  # Treat known engine-unavailable setup/runtime errors as fallback-eligible
  if [ "$rc" -eq 55 ] || [ "$rc" -eq 127 ]; then
    echo "::warning::Engine ${REVIEW_ENGINE:-claude} unavailable at runtime (exit $rc) — treating as fallback-eligible"
    rc=2
  fi

  # Exit code 2 = engine rate-limited.
  # Fallback chain: claude -> gemini -> copilot
  if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE:-claude}" = "claude" ]; then
    # Use the availability flag set by validate_engines() at startup.
    if [ "${GEMINI_AVAILABLE:-false}" = "true" ]; then
      echo "::warning::Claude rate limit hit — switching to Gemini engine for remaining PRs"
      export REVIEW_ENGINE=gemini
      engine_fallbacks=$((engine_fallbacks + 1))
      fallback_engines="${fallback_engines:+$fallback_engines, }gemini"
      rc=0
      bash scripts/review-one-pr.sh "$pr_url" || rc=$?
      
      # Handle Gemini engine-unavailable setup/runtime errors post-fallback
      if [ "$rc" -eq 55 ] || [ "$rc" -eq 127 ]; then
        echo "::warning::Gemini engine unavailable at runtime (exit $rc) — falling through to Copilot"
        rc=2
      fi
    else
      # Derive the specific reason so the warning is actionable without docs.
      _gemini_miss=""
      command -v gemini >/dev/null 2>&1 || _gemini_miss="Gemini CLI not installed (fix: npm install -g @google/gemini-cli)"
      [ -n "${GOOGLE_API_KEY:-}" ] || _gemini_miss="${_gemini_miss:+$_gemini_miss; }GOOGLE_API_KEY secret not set"
      echo "::warning::Claude rate limit hit but Gemini fallback unavailable (${_gemini_miss}) — falling through to Copilot"
      rc=2
      export REVIEW_ENGINE=gemini # Set to gemini so the next block catches it
    fi
  fi

  if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE}" = "gemini" ]; then
    if ! gh extension list 2>/dev/null | grep -q copilot && ! gh copilot --version > /dev/null 2>&1; then
      echo "::warning::Copilot fallback engine unavailable — skipping $pr_url and continuing batch"
      failed=$((failed + 1))
      echo "::endgroup::"
      continue
    fi
    echo "::warning::Gemini rate limit hit — switching to Copilot engine for remaining PRs"
    export REVIEW_ENGINE=copilot
    engine_fallbacks=$((engine_fallbacks + 1))
    fallback_engines="${fallback_engines:+$fallback_engines, }copilot"
    rc=0
    bash scripts/review-one-pr.sh "$pr_url" || rc=$?
  fi

  case "$rc" in
    0)
      actual=$((actual + 1))
      echo "::notice::Review posted ($actual/$MAX_PRS)"
      ;;
    100)
      skipped_noops=$((skipped_noops + 1))
      echo "::notice::No-op (already reviewed)"
      ;;
    2)
      failed=$((failed + 1))
      echo "::error::Rate limit hit on $REVIEW_ENGINE engine, no fallback available for $pr_url"
      session_aborted=1
      abort_pr="$pr_url"
      abort_reason="rate-limit on fallback engine"
      ;;
    *)
      # Per-PR failure — log and continue. Remaining candidates still run.
      # Accumulated failures surface in the session summary.
      failed=$((failed + 1))
      echo "::error::Review failed for $pr_url (exit code $rc)"
      ;;
  esac

  echo "::endgroup::"
  [ "$session_aborted" -eq 1 ] && break
done < "$PRS_FILE"

remaining=$((total_candidates - processed))
summary="Summary: $actual reviews posted, $skipped_noops no-ops skipped, $failed failures"
[ "$engine_fallbacks" -gt 0 ] && summary="$summary, $engine_fallbacks engine fallback(s) to $fallback_engines"
summary="$summary (processed $processed/$total_candidates candidates)"

if [ "$session_aborted" -eq 1 ]; then
  echo "::error::Session aborted early after failure on $abort_pr ($abort_reason). Skipped $remaining remaining candidate(s); will retry on next scheduled run."
  echo "$summary [SESSION ABORTED EARLY]"
  exit 1
fi

echo "$summary"
[ "$failed" -gt 0 ] && exit 1
exit 0
