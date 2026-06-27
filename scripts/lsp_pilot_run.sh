#!/usr/bin/env bash
# lsp_pilot_run.sh — execute the LSP pilot A/B on real PRs and render the comparison
# (#844, epic #839). The CI-side driver that ties the pieces together:
#
#   for each PR:  fetch diff  ─┬─►  claude review LSP-OFF  ─►  lsp_pilot_measure ─► baseline.jsonl
#                              └─►  claude review LSP-ON   ─►  lsp_pilot_measure ─► candidate.jsonl
#   then:         lsp_pilot_compare.sh baseline.jsonl candidate.jsonl  ─►  $GITHUB_STEP_SUMMARY
#
# Both sides are measured LIVE on the same real PRs with the same prompt and model —
# only the toolset differs (LSP-off navigates with Grep/Glob/Read/Bash; LSP-on adds
# the mcp__lsp__* navigation allowlist + the pinned MCP config). Generating both
# sides live means the comparison does NOT depend on the frozen synthetic baseline:
# it is a real, self-contained A/B.
#
# Honest scope: this is a navigation-COST probe (nav_tokens, tool_calls, cold-start,
# ET/USD), not the full review pipeline. The quality proxy (findings/false_positives)
# is only populated when the verification step runs (scripts/review-one-pr.sh, story
# #843); a bare claude invocation emits no finding_verification records, so those
# fields are 0 here and the cost metrics are the signal.
#
# Requires (provided by the CI job): claude (authed via CLAUDE_CODE_OAUTH_TOKEN), gh
# (authed via GH_TOKEN), jq, and — for the LSP-ON leg — agent-lsp + bash-language-
# server already installed by scripts/setup-lsp-pilot.sh (which also wrote the
# lsp_cold_start record to TOKEN_LOG_FILE).
#
# Pure helpers (lpr_*) are unit-tested in tests/dev-lead/unit/test_lsp_pilot_run.bats;
# the claude/gh calls live only in run_variant()/main() and are exercised in CI.

set -euo pipefail

_LPR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SLUG="${REPO_SLUG:-petry-projects/.github-private}"
MODEL="${LSP_PILOT_MODEL:-claude-sonnet-4-6}"   # cheaper tier by default to bound smoke cost
CANDIDATE="${LSP_CANDIDATE:-agent-lsp}"
LSP_MCP_CONFIG="${LSP_PILOT_CONFIG:-.github/mcp/lsp.json}"
DEEP_TIMEOUT_SEC="${LSP_PILOT_TIMEOUT_SEC:-600}"
OUTDIR="${LSP_PILOT_OUTDIR:-lsp-pilot-out}"

# Navigation allowlists. Off = the textual-navigation baseline; On = base + the
# pilot's read-only LSP navigation tools (sourced from setup-lsp-pilot.sh so the two
# stay in lockstep — never hand-duplicated).
LPR_BASE_TOOLS="Bash,Read,Grep,Glob"

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# lpr_on_tools — base navigation tools + the pilot LSP allowlist (comma-joined).
lpr_on_tools() {
  local nav
  nav="$(bash "${_LPR_DIR}/setup-lsp-pilot.sh" print-allowed-tools 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$nav" ]; then printf '%s,%s' "$LPR_BASE_TOOLS" "$nav"; else printf '%s' "$LPR_BASE_TOOLS"; fi
}

# lpr_build_prompt <pr_number> <diff_file> — the navigation-heavy review prompt.
# Deliberately steers the model to VERIFY cross-file claims (the work LSP nav
# replaces grep for), so the run actually exercises navigation.
lpr_build_prompt() {
  local pr="$1" diff_file="$2"
  cat <<PROMPT
You are reviewing pull request #${pr} of ${REPO_SLUG}, checked out in the current
working directory. Below is its diff.

Your job: verify every CROSS-FILE claim the diff implies, using your tools to
navigate the codebase — do NOT guess from the diff alone. Specifically check:
  * If a changed shell function's signature/behavior changed, find its callers and
    state whether they break.
  * If a function or variable is removed as "unused", confirm it has no remaining
    references.
  * If the diff references a symbol, confirm where it is defined.
Prefer precise navigation over broad reading. Then output a concise bulleted list of
findings (each: file:line — claim — verified/▲risk). Keep it under 200 words.

----- DIFF -----
$(cat "$diff_file" 2>/dev/null)
----- END DIFF -----
PROMPT
}

# lpr_wall_seconds <start_epoch_ns> <end_epoch_ns> — float seconds, 1 dp, clamped >=0.
# Falls back gracefully if nanoseconds are unavailable (the literal N survives).
lpr_wall_seconds() {
  local a="${1:-0}" b="${2:-0}"
  awk -v a="$a" -v b="$b" 'BEGIN {
    if (a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/) { print "0.0"; exit }
    d = (b - a) / 1000000000.0; if (d < 0) d = 0; printf "%.1f", d
  }'
}

# lpr_now_ns — epoch nanoseconds (mawk-safe; %N intact ⇒ "0" tail is harmless to the
# clamp). Isolated so tests can stub timing.
lpr_now_ns() { date +%s%N 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Impure: one variant of one PR (claude + gh). CI-only.
# ---------------------------------------------------------------------------

# run_variant <pr_number> <pr_key> <variant> <diff_file> <outdir>
# Runs one claude review (stream-json), measures it, and APPENDS the pilot record to
# <outdir>/<baseline|candidate>.jsonl. Echoes the record path.
run_variant() {
  local pr="$1" pr_key="$2" variant="$3" diff_file="$4" outdir="$5"
  local stream prompt tools record t0 t1 wall rc=0
  stream="${outdir}/${pr}.${variant}.stream.jsonl"
  prompt="${outdir}/${pr}.${variant}.prompt.txt"
  lpr_build_prompt "$pr" "$diff_file" > "$prompt"

  local -a mcp_flags=()
  if [ "$variant" = "lsp-on" ]; then
    tools="$(lpr_on_tools)"
    mcp_flags=(--mcp-config "$LSP_MCP_CONFIG" --strict-mcp-config)
  else
    tools="$LPR_BASE_TOOLS"
  fi

  t0="$(lpr_now_ns)"
  timeout "$DEEP_TIMEOUT_SEC" claude --print --model "$MODEL" \
    --output-format stream-json --verbose \
    --permission-mode acceptEdits \
    --allowed-tools "$tools" \
    ${mcp_flags[@]+"${mcp_flags[@]}"} \
    < "$prompt" > "$stream" 2>"${stream}.err" || rc=$?
  t1="$(lpr_now_ns)"
  wall="$(lpr_wall_seconds "$t0" "$t1")"
  if [ "$rc" -ne 0 ]; then
    echo "::warning::[lsp-pilot] claude ${variant} for PR #${pr} exited ${rc} (see ${stream}.err) — measuring partial transcript" >&2
  fi

  local out_file cand
  if [ "$variant" = "lsp-on" ]; then out_file="${outdir}/candidate.jsonl"; cand="$CANDIDATE"
  else out_file="${outdir}/baseline.jsonl"; cand="baseline"; fi

  record="$(bash "${_LPR_DIR}/lsp_pilot_measure.sh" "$stream" \
    --pr "$pr_key" --variant "$variant" --candidate "$cand" --model "$MODEL" \
    --wall-time-s "$wall" --token-log "${TOKEN_LOG_FILE:-/dev/null}")"
  printf '%s\n' "$record" >> "$out_file"
  printf '%s\n' "$out_file"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local prs="${1:-${LSP_PILOT_PRS:-}}"
  if [ -z "$prs" ]; then
    echo "usage: $0 <comma-separated-PR-numbers>   (or set LSP_PILOT_PRS)" >&2
    exit 2
  fi
  command -v claude >/dev/null 2>&1 || { echo "::error::claude CLI not found" >&2; exit 1; }
  command -v gh     >/dev/null 2>&1 || { echo "::error::gh CLI not found" >&2; exit 1; }

  mkdir -p "$OUTDIR"
  : > "${OUTDIR}/baseline.jsonl"
  : > "${OUTDIR}/candidate.jsonl"

  local pr head_sha pr_key diff_file
  IFS=',' read -ra _prs <<< "$prs"
  for pr in "${_prs[@]}"; do
    pr="$(printf '%s' "$pr" | tr -d '[:space:]')"
    [ -n "$pr" ] || continue
    echo "[lsp-pilot] === PR #${pr} ==="
    head_sha="$(gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
    [ -n "$head_sha" ] || { echo "::warning::[lsp-pilot] could not resolve head SHA for PR #${pr} — skipping" >&2; continue; }
    pr_key="${REPO_SLUG}#${pr}@${head_sha}"
    diff_file="${OUTDIR}/${pr}.diff"
    if ! gh pr diff "$pr" --repo "$REPO_SLUG" > "$diff_file" 2>/dev/null; then
      echo "::warning::[lsp-pilot] could not fetch diff for PR #${pr} — skipping" >&2; continue
    fi
    run_variant "$pr" "$pr_key" "lsp-off" "$diff_file" "$OUTDIR" >/dev/null
    run_variant "$pr" "$pr_key" "lsp-on"  "$diff_file" "$OUTDIR" >/dev/null
  done

  echo "[lsp-pilot] rendering comparison"
  # Capture the harness's exit code instead of masking it with `|| true`: the
  # comparison FAILS LOUD (non-zero) when a candidate PR has no baseline counterpart,
  # and the CI step must surface that — while still writing the summary either way.
  local report compare_rc=0
  report="$(bash "${_LPR_DIR}/lsp_pilot_compare.sh" "${OUTDIR}/baseline.jsonl" "${OUTDIR}/candidate.jsonl" "$CANDIDATE")" || compare_rc=$?
  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"; fi
  return "$compare_rc"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
