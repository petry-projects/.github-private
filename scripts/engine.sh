#!/usr/bin/env bash
set -euo pipefail
# Engine abstraction layer for LLM invocations.
# Supports: claude, gemini, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>           — no-tool tier (review-one-pr.sh only)
#   run_agentic <prompt_file> <model>  — full-tool tier (review-one-pr.sh only)
#   run_duck <prompt_file> <model>     — adversarial cross-engine (review-one-pr.sh only)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review
#
# Sourced by dev-lead scripts — provides:
#   model_for_intent <intent>          — select model tier by intent complexity
#   run_writer <prompt_file> [model]   — write-capable agent run
#   run_writer_with_fallback <prompt_file> [model]  — run with engine fallback

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

# _setup_engine_vars <engine>
# Sets all ENGINE_* model vars for the given engine name.
# Called once at source time and again by run_writer_with_fallback when
# switching engines mid-fallback, so each invocation gets compatible model IDs.
_setup_engine_vars() {
  local eng="${1:-$REVIEW_ENGINE}"
  case "$eng" in
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
      ENGINE_TRIAGE_MODEL="gemini-2.0-flash"
      ENGINE_DEEP_MODEL="gemini-1.5-pro"
      ENGINE_AUDIT_MODEL="gemini-1.5-pro"
      ENGINE_ACTION_MODEL="gemini-1.5-pro"
      ENGINE_SINGLE_MODEL="gemini-1.5-pro"
      ENGINE_LABEL="triage: gemini-2.0-flash → deep: gemini-1.5-pro + duck: sonnet 4.6 → audit: gemini-1.5-pro"
      ENGINE_SINGLE_LABEL="single-reviewer mode: gemini-1.5-pro"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      ;;
    copilot)
      ENGINE_TRIAGE_MODEL="o4-mini"
      ENGINE_DEEP_MODEL="o4-mini"
      ENGINE_AUDIT_MODEL="o4-mini"
      ENGINE_ACTION_MODEL="o4-mini"
      ENGINE_SINGLE_MODEL="o4-mini"
      # GitHub Models API model identifier — must match a model available at
      # https://models.github.ai (see GitHub Models marketplace).
      # Override via COPILOT_API_MODEL env var if the default is unavailable.
      # openai/o4-mini is the April-2025 o4-generation reasoning model; it is
      # not a typo for o1-mini or gpt-4o-mini.
      COPILOT_API_MODEL="${COPILOT_API_MODEL:-openai/o4-mini}"
      export COPILOT_API_MODEL
      ENGINE_LABEL="triage: o4-mini → deep: o4-mini + duck: sonnet 4.6 → audit: o4-mini (GitHub Models API)"
      ENGINE_SINGLE_LABEL="single-reviewer mode: o4-mini (GitHub Models API)"
      # Cross-engine rubber duck: always the opposite engine
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      ;;
    *)
      echo "::error::Unknown REVIEW_ENGINE='$eng' (expected: claude, gemini, or copilot)"
      return 1
      ;;
  esac
  export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
  export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  export ENGINE_LABEL ENGINE_SINGLE_LABEL
  export DUCK_ENGINE DUCK_MODEL
}

_setup_engine_vars "$REVIEW_ENGINE" || exit 1
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
  _pat="hit your limit|rate[ -]?limit|resets [0-9]+(am|pm)"           # soft cap / throttle
  _pat="$_pat|usage limit|quota exceeded|too many requests|exceeded.*quota"
  _pat="$_pat|([^0-9]|^)429([^0-9]|$)"                               # HTTP 429
  _pat="$_pat|out of.*token|token.*exhaust"                            # token depletion
  _pat="$_pat|overloaded_error|service.*overload|overload.*error"      # service overload
  _pat="$_pat|([^0-9]|^)529([^0-9]|$)"                               # HTTP 529
  _pat="$_pat|claude.*usage|usage.*claude"                             # Claude-specific cap
  _pat="$_pat|plan.*limit|subscription.*limit|billing.*limit|daily.*limit|monthly.*limit"
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

# copilot_chat <prompt_file> [timeout_sec]
# Calls the GitHub Models REST API (OpenAI-compatible) for text completion.
#
# Replaces the broken `gh copilot suggest -p "$(cat <file>)"` invocation:
#   • The -p flag is not valid syntax in modern gh CLI versions (produces
#     "Invalid command format" and causes a non-zero exit that the session
#     circuit-breaker misclassifies as a rate-limit).
#   • gh copilot suggest is a shell-command suggestion tool; it does NOT
#     support arbitrary prompt text or return structured JSON.
#   • $(cat <file>) as a shell argument fails for large PR prompts (ARG_MAX).
#
# This function uses curl + the GitHub Models REST API instead:
#   https://models.github.ai/inference/chat/completions
# The endpoint is versioned (X-GitHub-Api-Version header) and stable against
# gh CLI version changes. Auth uses COPILOT_GITHUB_TOKEN (user PAT with a
# Copilot subscription). Model is COPILOT_API_MODEL (default: openai/o4-mini).
#
# Rate-limit responses (HTTP 429) are echoed to stdout so the caller's
# is_rate_limited() check can detect them and exit 2 for engine fallback.
copilot_chat() {
  local prompt_file="$1"
  local timeout_sec="${2:-300}"

  # Build JSON payload via python3 into a temp file — safely encodes arbitrary
  # prompt text (special chars, newlines, quotes, Unicode, large files) and
  # avoids ARG_MAX limits when passing large diffs to curl via --data-binary.
  local _body_file rc=0
  _body_file=$(mktemp) || { echo "copilot_chat: mktemp failed" >&2; return 1; }
  python3 -c "
import json, sys
prompt = open(sys.argv[1]).read()
model  = sys.argv[2]
sys.stdout.write(json.dumps({
    'model': model,
    'messages': [{'role': 'user', 'content': prompt}],
}))
" "$prompt_file" "${COPILOT_API_MODEL:-openai/o4-mini}" > "$_body_file" || {
    rm -f "$_body_file"
    echo "copilot_chat: failed to build JSON payload from $prompt_file" >&2
    return 1
  }

  # Call GitHub Models REST API. -w '\n%{http_code}' appends the HTTP status
  # on its own line so we can split body from code in pure shell.
  local raw
  raw=$(
    timeout "$timeout_sec" curl -sSL \
      -H "Authorization: Bearer ${COPILOT_GITHUB_TOKEN:?COPILOT_GITHUB_TOKEN is required for copilot engine}" \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://models.github.ai/inference/chat/completions \
      --data-binary @"$_body_file" \
      -w '\n%{http_code}'
  ) || rc=$?
  rm -f "$_body_file"

  if [ "$rc" -ne 0 ]; then
    echo "copilot_chat: curl exited $rc (timeout=${timeout_sec}s)" >&2
    return "$rc"
  fi

  # Split the appended HTTP code from the response body.
  local http_code response_body
  http_code=$(printf '%s' "$raw" | tail -n 1)
  response_body=$(printf '%s' "$raw" | head -n -1)

  # Rate-limit: echo to stdout so is_rate_limited() in review-one-pr.sh fires.
  if [ "$http_code" -eq 429 ]; then
    echo "error: GitHub Models API rate limit (HTTP 429 — quota exceeded)"
    printf '%s\n' "$response_body"
    return 1
  fi

  # Other HTTP errors: log to stderr and fail.
  if [ "$http_code" -ge 400 ]; then
    echo "copilot_chat: HTTP $http_code from GitHub Models API" >&2
    printf '%s\n' "$response_body" >&2
    return 1
  fi

  # Extract the assistant message from the JSON response.
  printf '%s' "$response_body" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print('copilot_chat: invalid JSON response: ' + str(e), file=sys.stderr)
    sys.exit(1)
if 'error' in data:
    err = data['error']
    msg = err.get('message', str(err)) if isinstance(err, dict) else str(err)
    print('copilot_chat: API error: ' + str(msg), file=sys.stderr)
    sys.exit(1)
choices = data.get('choices', [])
if not choices:
    print('copilot_chat: empty choices in response', file=sys.stderr)
    sys.exit(1)
content = choices[0].get('message', {}).get('content', '')
print(content, end='')
" || return 1
}

# run_triage <prompt_file>
# No-tool mode. The prompt file already has all PR context inlined by the
# caller (review-one-pr.sh builds it). Every tool is denied so the model
# can't wander into the working directory and discover prs.txt or other
# state.
#
# `--permission-mode plan` is intentionally NOT set — under --print it makes
# the model propose a plan and ask for approval, which surfaces as
# conversational text and breaks the JSON contract. With every tool denied,
# permission mode is moot anyway.
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
        copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" || rc=$?
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
      # Text-only completion via GitHub Models API (no tool use available).
      # Stream directly to stdout; tee to OUTPUT_FILE when set.
      if [ -n "${OUTPUT_FILE:-}" ]; then
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" | tee "$OUTPUT_FILE"
        return "${PIPESTATUS[0]}"
      else
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC"
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
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" | tee "$OUTPUT_FILE"
        return "${PIPESTATUS[0]}"
      else
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC"
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

# model_for_intent <intent>
# Returns an engine-agnostic tier key: "triage", "action", or "deep".
# run_writer resolves the key to the correct model ID for the active engine
# via ENGINE_TRIAGE_MODEL / ENGINE_ACTION_MODEL / ENGINE_DEEP_MODEL, which are
# re-initialized per engine by run_writer_with_fallback so fallback engines
# always get a compatible model ID.
#   triage — human-pr, fix-bot-comment: lightweight checks, no agentic writes needed
#   action — fix-reviews, fix-ci, rebase: write operations on known-scope diffs
#   deep   — fix-issue, human: full agentic feature work
model_for_intent() {
  case "${1:-}" in
    human-pr|fix-bot-comment)   echo "triage" ;;
    fix-reviews|fix-ci|rebase)  echo "action" ;;
    fix-issue|human)            echo "deep"   ;;
    *)                          echo "action" ;;
  esac
}

# run_writer <prompt_file> [tier_or_model]
# Full write-access mode for applying code fixes.
# tier_or_model: a tier key ("triage", "action", "deep") or a literal model ID.
#   Tier keys are resolved to the current engine's model via ENGINE_*_MODEL vars,
#   which run_writer_with_fallback keeps in sync when switching engines.
# When DEV_LEAD_DRY_RUN=true: logs the prompt size but does NOT call engine; exits 0.
# Exit codes: 0=success, 1=non-retriable failure, 2=rate-limited or unavailable
# On exit 2, writes parsed reset timestamp to /tmp/dev-lead-rate-limit-reset.
run_writer() {
  local prompt_file="$1"
  local tier_or_model="${2:-action}"

  # Resolve tier key → current engine's model ID.
  local model
  case "$tier_or_model" in
    triage) model="$ENGINE_TRIAGE_MODEL" ;;
    deep)   model="$ENGINE_DEEP_MODEL"   ;;
    action) model="$ENGINE_ACTION_MODEL" ;;
    *)      model="$tier_or_model"       ;;  # pass-through for literal model strings
  esac

  if [ "${DEV_LEAD_DRY_RUN:-false}" = "true" ]; then
    echo "  [dry-run] run_writer: would invoke $REVIEW_ENGINE ($model) with prompt $(wc -l < "$prompt_file") lines"
    return 0
  fi

  # Capture stdout to a temp file so is_rate_limited can inspect it, while
  # still streaming output to the caller.
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
      # GitHub Models REST API is text-only — no Write/Edit tool access.
      # Returning exit 2 signals "write engine unavailable" so run_writer_with_fallback
      # exhausts the chain and the retry cron re-triggers when a write-capable
      # engine (claude, gemini) is available again.
      rm -f "$_tmp"
      echo "::notice::copilot engine is text-only; write operations unavailable — triggering retry" >&2
      return 2
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

# run_writer_with_fallback <prompt_file> [tier_or_model]
# Tries primary engine, falls back through claude → gemini → copilot on rate-limit (exit 2).
# Re-initializes ENGINE_* vars for each engine so model IDs are always compatible.
# Exit 2 (rate-limited) and exit 127 (engine binary not installed) both trigger fallback.
# Other non-zero exits propagate immediately as real failures.
run_writer_with_fallback() {
  local prompt_file="$1"
  local tier_or_model="${2:-action}"
  local engines=("$REVIEW_ENGINE")

  for e in claude gemini copilot; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  local orig_engine="$REVIEW_ENGINE"
  for engine in "${engines[@]}"; do
    # Re-initialize ENGINE_* vars for this engine so model tier resolution
    # in run_writer returns a compatible model ID for the active provider.
    export REVIEW_ENGINE="$engine"
    _setup_engine_vars "$engine"
    local rc=0
    run_writer "$prompt_file" "$tier_or_model" || rc=$?
    if [ "$rc" -eq 0 ]; then
      export REVIEW_ENGINE="$orig_engine"; _setup_engine_vars "$orig_engine"
      return 0
    fi
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 127 ]; then
      # exit 2: rate-limited or text-only engine unavailable for writes
      # exit 127: engine binary not installed in this environment
      echo "::warning::$engine unavailable (exit $rc), trying next engine" >&2
      continue
    fi
    export REVIEW_ENGINE="$orig_engine"; _setup_engine_vars "$orig_engine"
    return "$rc"
  done

  export REVIEW_ENGINE="$orig_engine"; _setup_engine_vars "$orig_engine"
  echo "::error::All engines rate-limited or unavailable" >&2
  return 2
}
