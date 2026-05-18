#!/usr/bin/env bash
set -euo pipefail
# Engine abstraction layer for LLM invocations.
# Supports: claude, gemini, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>       — no-tool tier (stdout capture)
#   run_agentic <prompt_file> <model>  — full-tool tier (stdout)
#   run_duck <prompt_file> <model>     — cross-engine adversarial (stdout)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review

REVIEW_ENGINE="${REVIEW_ENGINE:-claude}"
export REVIEW_ENGINE

# Per-tier timeouts (seconds). The job-level 60min cap is a backstop — without
# per-tier timeouts a single hung model invocation burns the whole hour and
# blocks every subsequent PR in the session.
TRIAGE_TIMEOUT_SEC="${TRIAGE_TIMEOUT_SEC:-300}"
DEEP_TIMEOUT_SEC="${DEEP_TIMEOUT_SEC:-600}"
AUDIT_TIMEOUT_SEC="${AUDIT_TIMEOUT_SEC:-600}"
ACTION_TIMEOUT_SEC="${ACTION_TIMEOUT_SEC:-600}"
DUCK_TIMEOUT_SEC="${DUCK_TIMEOUT_SEC:-300}"

# Retry config for transient errors. We treat exit codes that look like
# network/process flakiness (124=GNU timeout, 137/143=signal kills, plus a
# couple of generic transient codes) as retryable. Rate-limit (engine-level)
# is NOT retryable here — the workflow's engine-fallback handles that.
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-2}"   # total attempts including first
RETRY_BASE_DELAY_SEC="${RETRY_BASE_DELAY_SEC:-5}"

set_engine_config() {
  case "$REVIEW_ENGINE" in
    claude)
      ENGINE_TRIAGE_MODEL="claude-haiku-4-5-20251001"
      ENGINE_DEEP_MODEL="claude-sonnet-4-6"
      ENGINE_AUDIT_MODEL="claude-opus-4-7"
      ENGINE_ACTION_MODEL="claude-sonnet-4-6"
      ENGINE_SINGLE_MODEL="claude-opus-4-7"
      ENGINE_LABEL="triage: haiku 4.5 → deep: sonnet 4.6 + duck: o4-mini → audit: opus 4.7"
      ENGINE_SINGLE_LABEL="single-reviewer mode: opus 4.7"
      # Cross-engine rubber duck: always the opposite engine
      DUCK_ENGINE="copilot"
      DUCK_MODEL="o4-mini"
      ;;
    gemini)
      ENGINE_TRIAGE_MODEL="auto"
      ENGINE_DEEP_MODEL="auto"
      ENGINE_AUDIT_MODEL="auto"
      ENGINE_ACTION_MODEL="auto"
      ENGINE_SINGLE_MODEL="auto"
      ENGINE_LABEL="auto (Gemini 2.5/3 balanced)"
      ENGINE_SINGLE_LABEL="single-reviewer mode: auto"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      ;;
    copilot)
      ENGINE_TRIAGE_MODEL="gpt-5.4"
      ENGINE_DEEP_MODEL="gpt-5.4"
      ENGINE_AUDIT_MODEL="gpt-5.4"
      ENGINE_ACTION_MODEL="gpt-5.4"
      ENGINE_SINGLE_MODEL="gpt-5.4"
      # GitHub Copilot CLI model identifier. gpt-5.4 is a flagship model
      # with full tool support in the Copilot CLI.
      COPILOT_API_MODEL="${COPILOT_API_MODEL:-gpt-5.4}"
      export COPILOT_API_MODEL
      ENGINE_LABEL="triage: gpt-5.4 → deep: gpt-5.4 + duck: sonnet 4.6 → audit: gpt-5.4 (GitHub Copilot CLI)"
      ENGINE_SINGLE_LABEL="single-reviewer mode: gpt-5.4 (GitHub Copilot CLI)"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      ;;
    *)
      echo "::error::Unknown REVIEW_ENGINE='$REVIEW_ENGINE' (expected: claude, gemini, or copilot)"
      exit 1
      ;;
  esac

  export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
  export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  export ENGINE_LABEL ENGINE_SINGLE_LABEL
  export DUCK_ENGINE DUCK_MODEL
}

# Initial config
set_engine_config
echo "    engine: $REVIEW_ENGINE ($ENGINE_LABEL)"

# is_rate_limited <text>
# Returns 0 (true) if the text looks like a provider usage/rate-limit block —
# API-level (429), subscription/billing caps (plan limit, out of tokens, HTTP 402),
# or service overload acting as a hard block (529).
# review-one-pr.sh exits with code 2 when this fires so the caller can switch engines.
#
# Patterns intentionally excluded to prevent false positives:
#   - bare "exhausted" (too broad: matches "retry attempts exhausted", OS errors, etc.)
#     Retained as "token.*exhaust" / "out of.*token" for the specific token-depletion case.
#   - CLI syntax errors ("Invalid command format", "unknown flag", etc.) — see is_cli_error.
is_rate_limited() {
  local text="$1"
  # Build pattern in segments for readability — one category per line.
  local _pat
  _pat="hit your limit|rate[ -]?limit|resets [0-9]+(am|pm)|reached.*limit" # soft cap / throttle
  _pat="$_pat|usage limit|quota exceeded|too many requests|exceeded.*quota"
  _pat="$_pat|([^0-9]|^)429([^0-9]|$)"                               # HTTP 429
  _pat="$_pat|out of.*token|token.*exhaust"                            # token depletion
  _pat="$_pat|overloaded_error|service.*overload|overload.*error"      # service overload
  _pat="$_pat|([^0-9]|^)529([^0-9]|$)"                               # HTTP 529
  _pat="$_pat|claude.*usage|usage.*claude"                             # Claude-specific cap
  _pat="$_pat|plan.*limit|subscription.*limit|billing.*limit|daily.*limit|monthly.*limit|weekly.*limit"
  _pat="$_pat|([^0-9]|^)402([^0-9]|$)"                               # HTTP 402 (payment)
  _pat="$_pat|tokens_limit_reached|body too large|([^0-9]|^)413([^0-9]|$)" # Context / Request size
  printf '%s\n' "$text" | grep -qiE "($_pat)"
}

# is_cli_error <text>
# Returns 0 (true) if the text looks like a CLI invocation error —
# bad flags, wrong syntax, or a missing command.
# These are NOT rate limits: callers must exit with code 1 (per-PR failure),
# NOT code 2 (rate-limit / engine fallback), so the session can continue
# processing the remaining PR queue rather than aborting entirely.
is_cli_error() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE \
    "(invalid command format|invalid (flag|argument|option|command)|unknown (flag|command|option|argument)|command not found|no such command|did you mean:|unrecognized (command|flag|argument|option)|bad (flag|argument|option))"
}

# is_transient_failure <exit_code>
# Returns 0 (true) for exit codes suggesting a flaky network/process state:
# 124 (GNU timeout) and 137/143 (signal kills). JSON parse failures and
# generic exit-1s are NOT retried — those are deterministic problems.
is_transient_failure() {
  local rc="$1"
  case "$rc" in
    124|137|143) return 0 ;;
    *)           return 1 ;;
  esac
}

# copilot_chat <prompt_file> [timeout_sec] [extra_flags...]
# Calls the GitHub Copilot CLI for completions and agentic actions.
#
# Supports tool usage via the --yolo flag (passed in extra_flags).
# Uses COPILOT_API_MODEL (default: openai/gpt-4o).
#
# Rate-limit responses from the CLI are echoed to stdout/stderr so the caller's
# is_rate_limited() check can detect them and exit 2 for engine fallback.
copilot_chat() {
  local prompt_file="$1"
  local timeout_sec="${2:-300}"
  shift 2 || true

  # Ensure GH_TOKEN is set for gh copilot. It falls back to COPILOT_GITHUB_TOKEN.
  export GH_TOKEN="${COPILOT_GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -z "$GH_TOKEN" ]; then
    echo "copilot_chat: GH_TOKEN or COPILOT_GITHUB_TOKEN is required for copilot engine" >&2
    return 1
  fi

  # Avoid ARG_MAX by using an env var for the prompt if possible, or attachment.
  # The Copilot CLI supports COPILOT_PROMPT env var as an alternative to -p.
  # (Assuming this in 2026 based on common patterns).
  # If not, we'll just use -p with the file content but very carefully.
  local prompt_text
  prompt_text=$(cat "$prompt_file")
  
  echo "    [copilot] calling gh copilot (model=$COPILOT_API_MODEL, timeout=${timeout_sec}s, flags=$*)" >&2

  # We use -p for the prompt. Redirect /dev/null to stdin to ensure
  # non-interactive mode.
  timeout "$timeout_sec" gh copilot \
    --model "$COPILOT_API_MODEL" \
    -p "$prompt_text" \
    -s "$@" < /dev/null
}

# run_triage <prompt_file>
# No-tool mode. The prompt file already has all PR context inlined by the
# caller (review-one-pr.sh builds it). Every tool is denied so the model
# can't wander into the working directory and discover prs.txt or other
# state.
#
# Wrapped in a transient-retry loop because the caller captures stdout via
# $(...), so re-running on a timeout/kill is safe — the variable receives only
# the last attempt's output. Per-tier timeout from TRIAGE_TIMEOUT_SEC.
run_triage() {
  local prompt_file="$1"
  local attempt=1 rc=0
  while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
    rc=0
    case "$REVIEW_ENGINE" in
      claude)
        timeout "$TRIAGE_TIMEOUT_SEC" claude --print \
          --model "$ENGINE_TRIAGE_MODEL" \
          --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
          < "$prompt_file" || rc=$?
        ;;
      gemini)
        timeout "$TRIAGE_TIMEOUT_SEC" gemini --prompt "" \
          --model "$ENGINE_TRIAGE_MODEL" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" || rc=$?
        ;;
      copilot)
        # In triage mode, we deny all tools to keep it fast and restricted.
        copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" --deny-tool "*" || rc=$?
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if [ "$attempt" -lt "$RETRY_MAX_ATTEMPTS" ] && is_transient_failure "$rc"; then
      local delay=$(( RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)) ))
      echo "    [triage] transient failure (exit $rc), retrying in ${delay}s (attempt $((attempt + 1))/$RETRY_MAX_ATTEMPTS)" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    return "$rc"
  done
  return "$rc"
}

# run_agentic <prompt_file> <model>
# Full tool access (Bash, Read, Grep, Glob). Output to stdout.
#
# No retry here: callers redirect stdout to a file, so a retry inside this
# function would append the second attempt's output to a partial first-attempt
# file. Transient failures here become session-fatal via the workflow circuit
# breaker — that's the intended trade-off for the long, expensive tier.
# Per-tier timeout from DEEP_TIMEOUT_SEC (also applies to action/audit calls;
# they're all the same agentic shape and similarly priced).
run_agentic() {
  local prompt_file="$1"
  local model="$2"
  case "$REVIEW_ENGINE" in
    claude)
      timeout "$DEEP_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        < "$prompt_file"
      ;;
    gemini)
      timeout "$DEEP_TIMEOUT_SEC" gemini --prompt "" \
        --model "$model" \
        --approval-mode auto_edit \
        --output-format text \
        < "$prompt_file"
      ;;
    copilot)
      # Full tool support via GitHub Copilot CLI agentic mode (--yolo).
      # Stream directly to stdout; tee to OUTPUT_FILE when set.
      if [ -n "${OUTPUT_FILE:-}" ]; then
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo | tee "$OUTPUT_FILE"
        return "${PIPESTATUS[0]}"
      else
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo
      fi
      ;;
  esac
}

# extract_verdict_json <raw_file> <dest_file>
# Resolves the verdict JSON from an agentic run, handling two output styles:
#   1. Agent wrote JSON to $dest via Bash tool (dest already valid — use it as-is).
#   2. Agent printed JSON to stdout captured in raw_file (scan for first valid
#      JSON object containing a 'decision' field, ignoring preamble text).
extract_verdict_json() {
  local raw="$1" dest="$2"
  # Style 1: agent wrote to $dest via Bash tool (our stdout redirect didn't clobber it).
  if jq empty "$dest" 2>/dev/null; then
    return 0
  fi
  # Style 2: agent printed JSON to stdout.
  if jq empty "$raw" 2>/dev/null; then
    cp "$raw" "$dest"
    return 0
  fi
  python3 -c "
import sys, json
text = open(sys.argv[1]).read()
decoder = json.JSONDecoder()
pos = text.find('{')
while pos >= 0:
    try:
        obj, _ = decoder.raw_decode(text, pos)
        if isinstance(obj, dict) and 'decision' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except Exception:
        pass
    pos = text.find('{', pos + 1)
sys.exit(1)
" "$raw" > "$dest" 2>/dev/null
}

# run_duck <prompt_file> <model>
# Cross-engine adversarial "rubber duck" review.
# Always uses a different model family from REVIEW_ENGINE. Output to stdout.
# Strips the opposing engine's credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      timeout "$DUCK_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        --max-turns 25 \
        < "$prompt_file"
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      timeout "$DUCK_TIMEOUT_SEC" gemini --prompt "" \
        --model "$model" \
        --approval-mode auto_edit \
        --output-format text \
        < "$prompt_file"
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      if [ -n "${OUTPUT_FILE:-}" ]; then
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$OUTPUT_FILE"
        return "${PIPESTATUS[0]}"
      else
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo
      fi
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      return 1
      ;;
  esac
}

# parse_reset_time <text>
# Extracts the rate-limit reset time from engine output and writes an ISO-8601
# UTC timestamp to /tmp/dev-lead-rate-limit-reset for callers to embed in
# status=rate-limited markers. Pattern: "resets H:MMam/pm (UTC)" or
# "resets H:MM(am|pm) UTC".
# Writes empty string if no reset time is found (caller treats as unknown).
parse_reset_time() {
  local text="$1"
  # Match "resets 11:20pm (UTC)" or "resets 11:20pm UTC"
  local time_str
  time_str=$(printf '%s\n' "$text" | grep -oiE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' | head -1 || true)
  if [ -z "$time_str" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  # Extract H:MM(am|pm) part
  local hhmm
  hhmm=$(printf '%s' "$time_str" | grep -oiE '[0-9]{1,2}:[0-9]{2}(am|pm)$' || true)
  if [ -z "$hhmm" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  # Convert to ISO-8601 UTC using today's date (rate limits reset within 24h)
  local today
  today=$(date -u +%Y-%m-%d)
  local iso
  iso=$(date -u -d "${today} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  # If reset time is in the past (already reset today), it means tomorrow
  if [ -n "$iso" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$iso" +%s 2>/dev/null || echo 0)" ]; then
    local tomorrow
    tomorrow=$(date -u -d "tomorrow" +%Y-%m-%d)
    iso=$(date -u -d "${tomorrow} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  fi
  printf '%s' "${iso:-}" > /tmp/dev-lead-rate-limit-reset
}

# run_writer <prompt_file> [model]
# Full write-access mode for applying code fixes.
# When DEV_LEAD_DRY_RUN=true: builds prompt but does NOT call engine; exits 0.
# Exit codes: 0=success, 1=non-retriable failure, 2=rate-limited
# On exit 2, writes parsed reset timestamp to /tmp/dev-lead-rate-limit-reset.
run_writer() {
  local prompt_file="$1"
  local model="${2:-$ENGINE_ACTION_MODEL}"

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "  [dry-run] run_writer: would invoke $REVIEW_ENGINE with prompt $(wc -l < "$prompt_file") lines"
    return 0
  fi

  # Capture stdout to a temp file so is_rate_limited can inspect it, while
  # still streaming output to the caller. The old approach read from
  # /tmp/dev-lead-writer-stderr which was never written (claude --print outputs
  # to stdout, not stderr), so is_rate_limited never fired and fallback engines
  # were never tried.
  local _tmp rc=0
  _tmp=$(mktemp)

  case "$REVIEW_ENGINE" in
    claude)
      timeout "$ACTION_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Write,Edit,Grep,Glob" \
        < "$prompt_file" | tee "$_tmp" || rc=${PIPESTATUS[0]}
      ;;
    gemini)
      timeout "$ACTION_TIMEOUT_SEC" gemini --prompt "" \
        --model "$model" \
        --approval-mode auto_edit \
        --output-format text \
        < "$prompt_file" | tee "$_tmp" || rc=${PIPESTATUS[0]}
      ;;
    copilot)
      # Self-sufficient write support via gh copilot --yolo
      copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo | tee "$_tmp" || rc=${PIPESTATUS[0]}
      ;;
  esac

  # Map rate-limit to exit code 2 for caller to detect; parse reset time for marker embedding
  if [ "$rc" -ne 0 ] && is_rate_limited "$(cat "$_tmp")"; then
    parse_reset_time "$(cat "$_tmp")"
    rm -f "$_tmp"
    return 2
  fi
  rm -f "$_tmp"
  return "$rc"
}

# run_writer_with_fallback <prompt_file> [model]
# Tries primary engine, falls back through claude → gemini → copilot on rate-limit.
# Only rate-limit (exit 2) triggers fallback; other failures propagate immediately.
run_writer_with_fallback() {
  local prompt_file="$1"
  local engines=("$REVIEW_ENGINE")

  for e in claude gemini copilot; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  for engine in "${engines[@]}"; do
    local saved="$REVIEW_ENGINE"
    export REVIEW_ENGINE="$engine"
    # Re-evaluate model names for the new engine
    set_engine_config
    local rc=0
    # Don't pass 'model' argument; run_writer will use the updated $ENGINE_ACTION_MODEL
    run_writer "$prompt_file" || rc=$?
    export REVIEW_ENGINE="$saved"
    # Restore original config for subsequent PRs in the same session
    set_engine_config
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ]; then
      echo "::warning::$engine rate-limited, trying next engine" >&2
      continue
    fi
    return "$rc"
  done

  echo "::error::All engines rate-limited or unavailable" >&2
  return 2
}
