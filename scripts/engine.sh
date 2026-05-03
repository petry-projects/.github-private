#!/usr/bin/env bash
set -euo pipefail
# Engine abstraction layer for LLM invocations.
# Supports: claude, gemini, copilot
#
# Sourced by review-one-pr.sh — provides:
#   run_triage <prompt_file>       — no-tool tier (stdout capture)
#   run_agentic <prompt_file> <model> [tier]  — full-tool tier (stdout)
#   run_duck <prompt_file> <model>     — cross-engine adversarial (stdout)
#   ENGINE_* env vars for model names and labels
#   DUCK_ENGINE / DUCK_MODEL for rubber-duck cross-engine review
#
# Rate-limit fallback (two layers, applied in order):
#   1. In-Claude model fallback — per-tier CLAUDE_*_MODEL_CHAIN walks alternate
#      Claude models (e.g. sonnet → opus) before declaring the provider
#      rate-limited. Each Claude model has its own TPM/RPM bucket, so swapping
#      models often recovers without leaving the provider. Does NOT help when
#      the daily subscription cap is exhausted (cap is shared across all Claude
#      models — see issue #206 for the proactive headroom guard).
#   2. Cross-provider fallback — run_writer_with_fallback / review-batch.sh
#      walk claude → gemini → copilot only after the in-engine chain is fully
#      rate-limited (exit code 2 from the engine-layer call).
#
# Token logging (opt-in):
#   Set TOKEN_LOG_FILE=<path> to capture per-call JSONL token records.
#   TOKEN_WORKFLOW — workflow label for records (default: "unknown").
#   Records are written via scripts/lib/token-metrics.sh (estimate-based).
#   Unset → zero overhead, zero behaviour change.

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
      # Cross-engine rubber duck: use Copilot when Claude is primary
      DUCK_ENGINE="copilot"
      DUCK_MODEL="o4-mini"
      # Per-tier in-Claude model fallback chains (comma-separated).
      # On rate-limit, the chain is walked left-to-right before the cross-provider
      # fallback (claude → gemini → copilot) kicks in. Per-model TPM/RPM buckets
      # are independent, so swapping models within Claude often recovers without
      # leaving the provider. (Daily subscription cap is shared — see issue #206.)
      # Override per workflow via env to tune cost/capability trade-offs.
      CLAUDE_TRIAGE_MODEL_CHAIN="${CLAUDE_TRIAGE_MODEL_CHAIN:-claude-haiku-4-5-20251001,claude-sonnet-4-6}"
      CLAUDE_DEEP_MODEL_CHAIN="${CLAUDE_DEEP_MODEL_CHAIN:-claude-sonnet-4-6,claude-opus-4-7}"
      CLAUDE_AUDIT_MODEL_CHAIN="${CLAUDE_AUDIT_MODEL_CHAIN:-claude-opus-4-7,claude-sonnet-4-6}"
      CLAUDE_ACTION_MODEL_CHAIN="${CLAUDE_ACTION_MODEL_CHAIN:-claude-sonnet-4-6,claude-opus-4-7}"
      CLAUDE_SINGLE_MODEL_CHAIN="${CLAUDE_SINGLE_MODEL_CHAIN:-claude-opus-4-7,claude-sonnet-4-6}"
      ;;
    gemini)
      ENGINE_TRIAGE_MODEL="gemini-2.0-flash"
      ENGINE_DEEP_MODEL="gemini-2.5-pro"
      ENGINE_AUDIT_MODEL="gemini-2.5-pro"
      ENGINE_ACTION_MODEL="gemini-2.5-pro"
      ENGINE_SINGLE_MODEL="gemini-2.5-pro"
      ENGINE_LABEL="triage: gemini-2.0-flash → deep: gemini-2.5-pro + duck: sonnet 4.6 → audit: gemini-2.5-pro"
      ENGINE_SINGLE_LABEL="single-reviewer mode: gemini-2.5-pro"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      # No in-engine chain for Gemini — only one production model in use today.
      CLAUDE_TRIAGE_MODEL_CHAIN=""
      CLAUDE_DEEP_MODEL_CHAIN=""
      CLAUDE_AUDIT_MODEL_CHAIN=""
      CLAUDE_ACTION_MODEL_CHAIN=""
      CLAUDE_SINGLE_MODEL_CHAIN=""
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
      ENGINE_LABEL="triage: o4-mini → deep: o4-mini + duck: gemini-2.0-flash → audit: o4-mini (GitHub Models API)"
      ENGINE_SINGLE_LABEL="single-reviewer mode: o4-mini (GitHub Models API)"
      # Cross-engine rubber duck: use Gemini when Copilot is primary
      DUCK_ENGINE="gemini"
      DUCK_MODEL="gemini-2.0-flash"
      # No in-engine chain for Copilot — single GitHub Models endpoint.
      CLAUDE_TRIAGE_MODEL_CHAIN=""
      CLAUDE_DEEP_MODEL_CHAIN=""
      CLAUDE_AUDIT_MODEL_CHAIN=""
      CLAUDE_ACTION_MODEL_CHAIN=""
      CLAUDE_SINGLE_MODEL_CHAIN=""
      ;;
    *)
      echo "::error::Unknown REVIEW_ENGINE='$REVIEW_ENGINE' (expected: claude, gemini, or copilot)"
      exit 1
      ;;
  esac

  export ENGINE_TRIAGE_MODEL ENGINE_DEEP_MODEL ENGINE_AUDIT_MODEL
  export ENGINE_ACTION_MODEL ENGINE_SINGLE_MODEL
  export ENGINE_LABEL ENGINE_SINGLE_LABEL
  export DUCK_ENGINE DUCK_MODEL COPILOT_API_MODEL
  export CLAUDE_TRIAGE_MODEL_CHAIN CLAUDE_DEEP_MODEL_CHAIN
  export CLAUDE_AUDIT_MODEL_CHAIN CLAUDE_ACTION_MODEL_CHAIN
  export CLAUDE_SINGLE_MODEL_CHAIN
}

# Initial config
set_engine_config
echo "    engine: $REVIEW_ENGINE ($ENGINE_LABEL)"

# Load token metrics library unconditionally (non-fatal).
# emit_token_record and friends are no-ops when TOKEN_LOG_FILE is unset.
_TOKEN_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/token-metrics.sh"
# shellcheck source=lib/token-metrics.sh
[ -f "$_TOKEN_LIB" ] && source "$_TOKEN_LIB" 2>/dev/null || true
unset _TOKEN_LIB

# _rate_limit_pattern
# Single source of truth for the rate-limit regex used by both is_rate_limited
# (text) and is_rate_limited_files (paths). Patterns intentionally excluded to
# prevent false positives:
#   - bare "exhausted" (too broad: matches "retry attempts exhausted", OS errors, etc.)
#     Retained as "token.*exhaust" / "out of.*token" for the specific token-depletion case.
#   - CLI syntax errors ("Invalid command format", "unknown flag", etc.) — see is_cli_error.
_rate_limit_pattern() {
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
  _pat="$_pat|RESOURCE_EXHAUSTED"                                      # Google billing-exhausted status
  _pat="$_pat|credits.*depleted"         # Gemini billing depletion
  printf '%s' "($_pat)"
}

# is_rate_limited <text>
# Returns 0 (true) if the text looks like a provider usage/rate-limit block —
# API-level (429), subscription/billing caps (plan limit, out of tokens, HTTP 402),
# or service overload acting as a hard block (529).
# review-one-pr.sh exits with code 2 when this fires so the caller can switch engines.
#
# Prefer is_rate_limited_files for large LLM-output captures — it scans files
# directly with grep instead of materializing the contents in a shell variable,
# which avoids OOM and shell-substitution length limits on big payloads.
is_rate_limited() {
  local text="$1"
  printf '%s\n' "$text" | grep -qiE "$(_rate_limit_pattern)"
}

# is_rate_limited_files <file>...
# File-aware variant of is_rate_limited. Returns 0 if any of the given files
# matches the rate-limit pattern. Empty paths are skipped silently so callers
# can pass optional tmp files without pre-checks.
is_rate_limited_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 1
  grep -qiE "$(_rate_limit_pattern)" "${files[@]}"
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

  # Avoid ARG_MAX by using -p with the file content. On Linux, ARG_MAX is
  # typically ~2MB, which is enough for most PR diffs and metadata.
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

# _gemini_invoke <prompt_file> <timeout_sec> <model> [extra_args...]
# Runs the gemini CLI and emits the model's text to stdout (stderr passes through
# so callers that merge it for rate-limit detection still work). When token
# logging is on (and ENGINE_USAGE_JSON != 0) it runs with --output-format json,
# captures real usage into the LAST_* globals, and emits the extracted text;
# otherwise it uses --output-format text (estimate path). Robust fallback: if the
# JSON result text is empty or the call fails, the raw payload is emitted.
_gemini_invoke() {
  local prompt_file="$1" timeout_sec="$2" model="$3"
  shift 3
  local extra_args=("$@")

  declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage

  local _usage_json=0
  if [ -n "${TOKEN_LOG_FILE:-}" ] && [ "${ENGINE_USAGE_JSON:-1}" != "0" ] \
     && declare -f parse_engine_usage >/dev/null 2>&1; then
    _usage_json=1
  fi

  if [ "$_usage_json" -eq 1 ]; then
    local _json_tmp; _json_tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$_json_tmp" ]; then
      local rc=0
      # stderr intentionally NOT redirected — flows to caller for rate-limit checks.
      timeout "$timeout_sec" gemini --prompt "" --model "$model" "${extra_args[@]}" \
        --output-format json < "$prompt_file" > "$_json_tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then
        parse_engine_usage gemini "$_json_tmp" || true
        local _txt; _txt="$(extract_engine_text gemini "$_json_tmp")"
        if [ -n "$_txt" ]; then printf '%s\n' "$_txt"; else cat "$_json_tmp"; fi
      else
        cat "$_json_tmp"   # emit raw payload so downstream/rate-limit logic sees it
      fi
      rm -f "$_json_tmp"
      return "$rc"
    fi
  fi

  # Estimate path (logging off, or mktemp failed): plain text output.
  timeout "$timeout_sec" gemini --prompt "" --model "$model" "${extra_args[@]}" \
    --output-format text < "$prompt_file"
}

# _claude_chain_invoke <chain_csv> <prompt_file> <timeout_sec> [extra_args...]
# Walks a comma-separated list of Claude models, invoking `claude --print --model X`
# with the given extra arguments. The first model whose run does NOT trigger
# is_rate_limited() wins: its captured stdout is written to fd1, stderr to fd2,
# and its exit code is returned. Rate-limited attempts are discarded and the
# next model is tried. If every model in the chain rate-limits, returns 2 and
# writes the parsed reset time to /tmp/dev-lead-rate-limit-reset.
#
# Empty chain → no-op return 0 (callers should fall back to the single-model
# legacy path; this is only used when CLAUDE_*_MODEL_CHAIN is set).
#
# Sets _CLAUDE_CHAIN_MODEL_USED to the model that produced the final output
# (success or last attempt) so callers can log which model actually ran.
_claude_chain_invoke() {
  local chain_csv="$1" prompt_file="$2" timeout_sec="$3"
  shift 3
  local extra_args=("$@")

  if [ -z "$chain_csv" ]; then
    echo "::error::_claude_chain_invoke called with empty chain" >&2
    return 1
  fi

  # When token logging is on, capture real usage by running claude with
  # --output-format json and emitting the extracted .result text to the caller.
  # Gated by ENGINE_USAGE_JSON (default on) so it can be disabled without a code
  # change. Falls back to raw output if extraction yields nothing.
  declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage
  local _usage_json=0 fmt_args=()
  if [ -n "${TOKEN_LOG_FILE:-}" ] && [ "${ENGINE_USAGE_JSON:-1}" != "0" ] \
     && declare -f parse_engine_usage >/dev/null 2>&1; then
    _usage_json=1
    fmt_args=(--output-format json)
  fi

  local saved_ifs="$IFS"
  IFS=',' read -ra models <<< "$chain_csv"
  IFS="$saved_ifs"

  local stdout_tmp="" stderr_tmp=""
  local final_stdout="" final_stderr="" final_model="" final_rc=0
  local rc=0 attempted=0 all_rl=1
  local model

  for model in "${models[@]}"; do
    # Trim whitespace
    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    [ -z "$model" ] && continue

    attempted=$((attempted + 1))
    stdout_tmp="$(mktemp 2>/dev/null)" || stdout_tmp=""
    stderr_tmp="$(mktemp 2>/dev/null)" || stderr_tmp=""
    rc=0

    if [ -n "$stdout_tmp" ] && [ -n "$stderr_tmp" ]; then
      timeout "$timeout_sec" claude --print --model "$model" "${fmt_args[@]}" "${extra_args[@]}" \
        < "$prompt_file" > "$stdout_tmp" 2> "$stderr_tmp" || rc=$?
    else
      # mktemp failure (one or both) — clean up the partial tmp before degrading
      # to direct stdout/stderr passthrough so we don't leak a half-allocated fd.
      [ -n "$stdout_tmp" ] && rm -f "$stdout_tmp"
      [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
      [ -n "$final_stdout" ] && rm -f "$final_stdout"
      [ -n "$final_stderr" ] && rm -f "$final_stderr"
      timeout "$timeout_sec" claude --print --model "$model" "${extra_args[@]}" \
        < "$prompt_file" || rc=$?
      _CLAUDE_CHAIN_MODEL_USED="$model"
      export _CLAUDE_CHAIN_MODEL_USED
      return "$rc"
    fi

    # Drop any previous final-attempt buffers (we keep only the latest)
    [ -n "$final_stdout" ] && rm -f "$final_stdout"
    [ -n "$final_stderr" ] && rm -f "$final_stderr"
    final_stdout="$stdout_tmp"
    final_stderr="$stderr_tmp"
    final_model="$model"

    if [ "$rc" -eq 0 ]; then
      final_rc=0
      all_rl=0
      break
    fi
    # File-based rate-limit detection — avoids loading large agent output into
    # a shell variable via $(cat ...) (OOM risk on big captures).
    if ! is_rate_limited_files "$stdout_tmp" "$stderr_tmp"; then
      # Non-rate-limit failure — propagate immediately, do not try next model.
      final_rc="$rc"
      all_rl=0
      break
    fi
    # Rate-limited; record diagnosis and try the next model.
    # Phrasing intentionally avoids "rate-limit"/"429"/"quota" etc. — those
    # tokens match is_rate_limited()/_rate_limit_pattern, and downstream
    # callers (e.g. review-one-pr.sh) that scan our stderr would then
    # misclassify a successful chain fallback as a provider rate-limit.
    echo "::warning::[claude] model $model throttled (rc=$rc) — trying next in chain" >&2
  done

  # Empty/whitespace-only chain → configuration error, not a rate-limit. Returning
  # 2 here would trigger the cross-provider fallback as if quotas were exhausted.
  if [ "$attempted" -eq 0 ]; then
    echo "::error::_claude_chain_invoke: chain '$chain_csv' had no valid model entries" >&2
    return 1
  fi

  # If every attempt was rate-limited, parse the last reset time and return 2.
  if [ "$all_rl" -eq 1 ]; then
    parse_reset_time_files "$final_stdout" "$final_stderr"
    final_rc=2
  fi

  # Emit the final attempt's captured output to the caller. In JSON-usage mode,
  # parse the usage block and emit the extracted .result text (so consumers still
  # receive plain text); fall back to the raw payload if extraction is empty or
  # the call failed (preserves error/rate-limit text for downstream detection).
  if [ -n "$final_stdout" ]; then
    if [ "$_usage_json" -eq 1 ] && [ "$final_rc" -eq 0 ]; then
      parse_engine_usage claude "$final_stdout" || true
      local _txt
      _txt="$(extract_engine_text claude "$final_stdout")"
      if [ -n "$_txt" ]; then
        printf '%s\n' "$_txt"
      else
        cat "$final_stdout"
      fi
    else
      cat "$final_stdout"
    fi
    rm -f "$final_stdout"
  fi
  if [ -n "$final_stderr" ]; then
    cat "$final_stderr" >&2
    rm -f "$final_stderr"
  fi

  _CLAUDE_CHAIN_MODEL_USED="$final_model"
  export _CLAUDE_CHAIN_MODEL_USED
  return "$final_rc"
}

# _record_engine_tokens <tier> <engine> <model> <prompt_file> [output_file]
# Writes one token record to TOKEN_LOG_FILE using estimate_tokens_from_file.
# No-op when TOKEN_LOG_FILE is unset or the token-metrics library is not loaded.
# Always succeeds (non-fatal): token logging must never abort a real workflow.
_record_engine_tokens() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0
  declare -f emit_token_record >/dev/null 2>&1 || return 0

  local tier="$1" engine="$2" model="$3" prompt_file="$4" output_file="${5:-}"
  local workflow="${TOKEN_WORKFLOW:-unknown}" context="${PR_URL:-}"
  local input_tokens cache_read_tokens cache_write_tokens output_tokens
  local _have_usage=0

  # Prefer real usage captured by the engine. It is read from the sidecar file
  # (written even when the engine ran inside a `cmd | tee` subshell); the LAST_*
  # globals are a secondary source for non-piped callers.
  local _uf=""
  declare -f _engine_usage_sidecar >/dev/null 2>&1 && _uf="$(_engine_usage_sidecar)"
  if [ -n "$_uf" ] && [ -s "$_uf" ]; then
    IFS=$'\t' read -r input_tokens cache_read_tokens cache_write_tokens output_tokens < "$_uf"
    rm -f "$_uf" 2>/dev/null || true
    case "${input_tokens}${cache_read_tokens}${cache_write_tokens}${output_tokens}" in
      ''|*[!0-9]*) _have_usage=0 ;;
      *)           _have_usage=1 ;;
    esac
  elif [ "${LAST_USAGE_OK:-0}" = "1" ]; then
    input_tokens="${LAST_INPUT_TOKENS:-0}"
    cache_read_tokens="${LAST_CACHE_READ_TOKENS:-0}"
    cache_write_tokens="${LAST_CACHE_WRITE_TOKENS:-0}"
    output_tokens="${LAST_OUTPUT_TOKENS:-0}"
    _have_usage=1
  fi

  if [ "$_have_usage" -ne 1 ]; then
    # Fallback: estimate from byte counts (engine reported no usage, e.g. copilot
    # or text-mode). Cache figures are unknown → 0.
    input_tokens=$(estimate_tokens_from_file "$prompt_file")
    output_tokens=$(estimate_tokens_from_file "$output_file")
    cache_read_tokens=0
    cache_write_tokens=0
  fi

  emit_token_record "$workflow" "$tier" "$engine" "$model" \
    "$input_tokens" "$cache_read_tokens" "$output_tokens" "$context" "$cache_write_tokens" || true
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

  # Avoid ARG_MAX by using -p with the file content. On Linux, ARG_MAX is
  # typically ~2MB, which is enough for most PR diffs and metadata.
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
  # Capture output for token estimation when logging is enabled (tee is a no-op otherwise).
  local _tok_tmp=""
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
    rc=0
    [ -n "$_tok_tmp" ] && : > "$_tok_tmp"
    case "$REVIEW_ENGINE" in
      claude)
        local _triage_chain="${CLAUDE_TRIAGE_MODEL_CHAIN:-$ENGINE_TRIAGE_MODEL}"
        if [ -n "$_tok_tmp" ]; then
          _claude_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
            | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          _claude_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --disallowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,WebSearch,Task,TodoWrite,NotebookEdit" \
            || rc=$?
        fi
        ;;
      gemini)
        if [ -n "$_tok_tmp" ]; then
          _gemini_invoke "$prompt_file" "$TRIAGE_TIMEOUT_SEC" "$ENGINE_TRIAGE_MODEL" \
            --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          _gemini_invoke "$prompt_file" "$TRIAGE_TIMEOUT_SEC" "$ENGINE_TRIAGE_MODEL" \
            --approval-mode auto_edit || rc=$?
        fi
        ;;
      gemini)
        if [ -n "$_tok_tmp" ]; then
          timeout "$TRIAGE_TIMEOUT_SEC" gemini --prompt "" \
            --model "$ENGINE_TRIAGE_MODEL" \
            --approval-mode auto_edit \
            --output-format text \
            < "$prompt_file" | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          _gemini_invoke "$prompt_file" "$TRIAGE_TIMEOUT_SEC" "$ENGINE_TRIAGE_MODEL" \
            --approval-mode auto_edit || rc=$?
        fi
        ;;
      copilot)
        # In triage mode, we deny all tools to keep it fast and restricted.
        if [ -n "$_tok_tmp" ]; then
          copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" --deny-tool "*" | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          copilot_chat "$prompt_file" "$TRIAGE_TIMEOUT_SEC" --deny-tool "*" || rc=$?
        fi
        ;;
    esac
    if [ "$rc" -eq 0 ]; then
      local _triage_used="${_CLAUDE_CHAIN_MODEL_USED:-$ENGINE_TRIAGE_MODEL}"
      _record_engine_tokens "triage" "$REVIEW_ENGINE" "$_triage_used" "$prompt_file" "$_tok_tmp"
      [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
      return 0
    fi
    if [ "$attempt" -lt "$RETRY_MAX_ATTEMPTS" ] && is_transient_failure "$rc"; then
      local delay=$(( RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)) ))
      echo "    [triage] transient failure (exit $rc), retrying in ${delay}s (attempt $((attempt + 1))/$RETRY_MAX_ATTEMPTS)" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
    return "$rc"
  done
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# run_agentic <prompt_file> <model> [tier]
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
  local tier="${3:-deep}"
  local _tok_tmp="" rc=0
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  case "$REVIEW_ENGINE" in
    claude)
      # Resolve the in-Claude model chain for this tier. The chain is the
      # cascade tried on rate-limit (e.g. sonnet → opus). If the caller
      # passed a model that does NOT match the tier's default ENGINE_*_MODEL,
      # treat it as an explicit pin: honor it as a single-element chain so
      # callers can still force a specific model when they need to (the
      # documented `[model]` parameter on this function). The chain is only
      # applied when the caller used the default model for the tier.
      local _agentic_chain _tier_default=""
      case "$tier" in
        deep)   _tier_default="${ENGINE_DEEP_MODEL:-}"
                _agentic_chain="${CLAUDE_DEEP_MODEL_CHAIN:-$model}"   ;;
        audit)  _tier_default="${ENGINE_AUDIT_MODEL:-}"
                _agentic_chain="${CLAUDE_AUDIT_MODEL_CHAIN:-$model}"  ;;
        action) _tier_default="${ENGINE_ACTION_MODEL:-}"
                _agentic_chain="${CLAUDE_ACTION_MODEL_CHAIN:-$model}" ;;
        single) _tier_default="${ENGINE_SINGLE_MODEL:-}"
                _agentic_chain="${CLAUDE_SINGLE_MODEL_CHAIN:-$model}" ;;
        *)      _agentic_chain="$model" ;;
      esac
      if [ -n "$_tier_default" ] && [ "$model" != "$_tier_default" ]; then
        _agentic_chain="$model"
      fi
      if [ -n "$_tok_tmp" ]; then
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          || rc=$?
      fi
      ;;
    gemini)
      if [ -n "$_tok_tmp" ]; then
        _gemini_invoke "$prompt_file" "$DEEP_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$DEEP_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    gemini)
      if [ -n "$_tok_tmp" ]; then
        timeout "$DEEP_TIMEOUT_SEC" gemini --prompt "" \
          --model "$model" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$DEEP_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      # Full tool support via GitHub Copilot CLI agentic mode (--yolo).
      # Do NOT tee stdout to OUTPUT_FILE: the prompt instructs the model to
      # write the verdict JSON directly to $OUTPUT_FILE via the Bash tool.
      # Teeing stdout (which includes assistant text and tool transcripts)
      # would overwrite that file and corrupt the JSON.
      if [ -n "$_tok_tmp" ]; then
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$DEEP_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    local _agentic_used="$model"
    if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
      _agentic_used="$_CLAUDE_CHAIN_MODEL_USED"
    fi
    _record_engine_tokens "$tier" "$REVIEW_ENGINE" "$_agentic_used" "$prompt_file" "$_tok_tmp"
  fi
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
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
# DUCK_ENGINE is set by engine.sh init: claude→copilot, gemini→claude, copilot→gemini.
# All three engine branches (claude, gemini, copilot) are reachable — the gemini
# branch executes when REVIEW_ENGINE=copilot (copilot primary → gemini duck).
# Output to stdout. Strips non-selected engine credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  local _tok_tmp="" rc=0
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    unset _ENGINE_USAGE_OUT
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      # Route through the chain helper so real token usage (incl. cache) is captured
      # when logging is on; a single-model "chain" preserves prior behaviour.
      if [ -n "$_tok_tmp" ]; then
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          || rc=$?
      fi
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      if [ -n "$_tok_tmp" ]; then
        _gemini_invoke "$prompt_file" "$DUCK_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$DUCK_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      # Do NOT tee stdout to OUTPUT_FILE — same rationale as run_agentic copilot
      # branch: the prompt writes verdict JSON directly via the Bash tool.
      if [ -n "$_tok_tmp" ]; then
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
      return 1
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    _record_engine_tokens "duck" "$DUCK_ENGINE" "$model" "$prompt_file" "$_tok_tmp"
  fi
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# _emit_reset_iso <hhmm_with_meridiem>
# Shared helper: converts e.g. "11:20pm" into an ISO-8601 UTC timestamp
# (writing to /tmp/dev-lead-rate-limit-reset), advancing to tomorrow if the
# computed time is already in the past for today.
_emit_reset_iso() {
  local hhmm="$1"
  if [ -z "$hhmm" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local today iso
  today=$(date -u +%Y-%m-%d)
  iso=$(date -u -d "${today} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [ -n "$iso" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$iso" +%s 2>/dev/null || echo 0)" ]; then
    local tomorrow
    tomorrow=$(date -u -d "tomorrow" +%Y-%m-%d)
    iso=$(date -u -d "${tomorrow} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  fi
  printf '%s' "${iso:-}" > /tmp/dev-lead-rate-limit-reset
}

# parse_reset_time <text>
# Extracts the rate-limit reset time from engine output and writes an ISO-8601
# UTC timestamp to /tmp/dev-lead-rate-limit-reset for callers to embed in
# status=rate-limited markers. Pattern: "resets H:MMam/pm (UTC)" or
# "resets H:MM(am|pm) UTC".
# Writes empty string if no reset time is found (caller treats as unknown).
#
# Prefer parse_reset_time_files for large captures — same OOM rationale as
# is_rate_limited / is_rate_limited_files above.
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
  _emit_reset_iso "$hhmm"
}

# parse_reset_time_files <file>...
# File-aware variant of parse_reset_time. Scans each non-empty existing file
# for the first "resets H:MMam/pm" match and writes the ISO timestamp via
# _emit_reset_iso. Uses grep directly on files to avoid loading large LLM
# outputs into a shell variable.
parse_reset_time_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local time_str
  time_str=$(grep -hoiE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' "${files[@]}" 2>/dev/null | head -1 || true)
  if [ -z "$time_str" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local hhmm
  hhmm=$(printf '%s' "$time_str" | grep -oiE '[0-9]{1,2}:[0-9]{2}(am|pm)$' || true)
  _emit_reset_iso "$hhmm"
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
  unset _ENGINE_USAGE_OUT
  _tmp="$(mktemp 2>/dev/null || true)"
  # Per-call usage-sidecar key (see run_triage); unique mktemp path shared with
  # the engine subshell via export.
  [[ -n "$_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tmp}.usage"

  case "$REVIEW_ENGINE" in
    claude)
      # See run_agentic — honor caller's explicit model pin when it differs
      # from the tier default. Chain only applies when the caller used the
      # default action model for this engine.
      local _writer_chain="${CLAUDE_ACTION_MODEL_CHAIN:-$model}"
      if [ -n "${ENGINE_ACTION_MODEL:-}" ] && [ "$model" != "$ENGINE_ACTION_MODEL" ]; then
        _writer_chain="$model"
      fi
      if [ -n "$_tmp" ]; then
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          || rc=$?
      fi
      ;;
    gemini)
      if [ -n "$_tmp" ]; then
        _gemini_invoke "$prompt_file" "$ACTION_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit 2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$ACTION_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      # Self-sufficient write support via gh copilot --yolo
      if [ -n "$_tmp" ]; then
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo 2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
  esac

  # Map rate-limit to exit code 2 for caller to detect; parse reset time for
  # marker embedding. Use the file-based helpers to avoid OOM on large captures.
  if [ "$rc" -ne 0 ] && [ -n "$_tmp" ] && is_rate_limited_files "$_tmp"; then
    parse_reset_time_files "$_tmp"
    [ -n "$_tmp" ] && rm -f "$_tmp"
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    local _writer_used="$model"
    if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
      _writer_used="$_CLAUDE_CHAIN_MODEL_USED"
    fi
    _record_engine_tokens "writer" "$REVIEW_ENGINE" "$_writer_used" "$prompt_file" "$_tmp"
  fi
  if [ -n "$_tmp" ]; then
    # Redact once: write secret-scrubbed content to the persisted path, then
    # use that redacted file as the source for the step summary so credentials
    # cannot leak via /tmp persistence or the public run summary. Patterns
    # kept in sync with scripts/dev-lead-fix-reviews.sh:redact_secrets.
    rm -f /tmp/dev-lead-session-output.txt
    if ! sed -E \
      -e 's/(gh[opsu]|ghr)_[A-Za-z0-9_]{20,}/***REDACTED-GH-TOKEN***/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED-GH-PAT***/g' \
      -e 's/sk-(ant-)?[A-Za-z0-9_-]{20,}/***REDACTED-API-KEY***/g' \
      -e 's/AKIA[A-Z0-9]{16}/***REDACTED-AWS-KEY***/g' \
      -e 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' \
      -e 's|ya29\.[A-Za-z0-9_-]+|***REDACTED-GOOGLE-OAUTH***|g' \
      -e 's/[Bb]earer [A-Za-z0-9._-]{20,}/Bearer ***REDACTED***/g' \
      -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***REDACTED-PRIVATE-KEY***' \
      "$_tmp" > /tmp/dev-lead-session-output.txt; then
      : > /tmp/dev-lead-session-output.txt 2>/dev/null || true
      echo "::warning::Failed to redact/persist /tmp/dev-lead-session-output.txt" >&2
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      # HTML-escape the redacted log so literal </details> or </summary> in
      # the agent output cannot break the wrapping <details> block on the run
      # summary page.
      {
        echo "## Dev-Lead session output"
        echo "<details><summary>Click to expand session logs</summary>"
        echo ""
        echo "<pre>"
        sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g' /tmp/dev-lead-session-output.txt
        echo "</pre>"
        echo ""
        echo "</details>"
      } >> "$GITHUB_STEP_SUMMARY" || \
        echo "::warning::Failed to append session output to GITHUB_STEP_SUMMARY" >&2
    fi
    rm -f "$_tmp"
  fi
  return "$rc"
}

# run_writer_with_fallback <prompt_file>
# Tries primary engine, falls back through claude → gemini → copilot on rate-limit.
# Only rate-limit (exit 2) triggers fallback; other failures propagate immediately.
run_writer_with_fallback() {
  local prompt_file="$1"
  local engines=("$REVIEW_ENGINE")

  for e in claude gemini copilot; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  local any_rate_limited=0
  local any_missing=0
  for engine in "${engines[@]}"; do
    if [ "$engine" = "copilot" ] && [[ "${COPILOT_GITHUB_TOKEN:-}" == ghp_* ]]; then
      echo "::warning::Skipping copilot fallback: classic PAT in COPILOT_GITHUB_TOKEN is unsupported" >&2
      continue
    fi
    if [ "$engine" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ]; then
      echo "::warning::Skipping gemini fallback: GEMINI_API_KEY or GOOGLE_API_KEY not configured" >&2
      continue
    fi

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
    if [ "$rc" -eq 2 ] || [ "$rc" -eq 127 ]; then
      # exit 2: rate-limited or text-only engine unavailable for writes
      # exit 127: engine binary not installed in this environment (also returned by
      #           GNU timeout when the command is not found — treated as a missing
      #           binary rather than a retryable quota error so that infra failures
      #           surface loudly instead of being masked as rate-limit retries).
      echo "::warning::$engine unavailable (exit $rc), trying next engine" >&2
      [ "$rc" -eq 2 ] && any_rate_limited=1
      [ "$rc" -eq 127 ] && any_missing=1
      continue
    fi
    return "$rc"
  done

  echo "::error::All engines rate-limited or unavailable" >&2
  # If any engine binary was missing (exit 127), return 1 (hard infra failure) so
  # downstream handlers do not post rate-limit retry markers for what is really a
  # configuration/environment problem.  Only return 2 when every failure was a
  # genuine quota/rate-limit so callers know a later retry may succeed.
  [ "$any_missing" -eq 1 ] && return 1
  [ "$any_rate_limited" -eq 1 ] && return 2
  return 1
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
# DUCK_ENGINE is set by engine.sh init: claude→copilot, gemini→claude, copilot→gemini.
# All three engine branches (claude, gemini, copilot) are reachable — the gemini
# branch executes when REVIEW_ENGINE=copilot (copilot primary → gemini duck).
# Output to stdout. Strips non-selected engine credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  local _tok_tmp="" rc=0
  if [ -n "${TOKEN_LOG_FILE:-}" ]; then
    _tok_tmp="$(mktemp 2>/dev/null || true)"
    # Per-call usage-sidecar key: a unique mktemp path, exported so the engine's
    # pipeline subshell and _record_engine_tokens agree on it. Unique per call →
    # concurrent run_agentic/run_duck (review-one-pr.sh) never collide.
    [[ -n "$_tok_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tok_tmp}.usage"
  fi
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      # Route through the chain helper so real token usage (incl. cache) is captured
      # when logging is on; a single-model "chain" preserves prior behaviour.
      if [ -n "$_tok_tmp" ]; then
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$model" "$prompt_file" "$DUCK_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          || rc=$?
      fi
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      if [ -n "$_tok_tmp" ]; then
        _gemini_invoke "$prompt_file" "$DUCK_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$DUCK_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset GOOGLE_API_KEY 2>/dev/null || true
      if [ -n "${OUTPUT_FILE:-}" ]; then
        if [ -n "$_tok_tmp" ]; then
          copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$OUTPUT_FILE" "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$OUTPUT_FILE" || rc=${PIPESTATUS[0]}
        fi
      else
        if [ -n "$_tok_tmp" ]; then
          copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          copilot_chat "$prompt_file" "$DUCK_TIMEOUT_SEC" --yolo || rc=$?
        fi
      fi
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
      return 1
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    _record_engine_tokens "duck" "$DUCK_ENGINE" "$model" "$prompt_file" "$_tok_tmp"
  fi
  [ -n "$_tok_tmp" ] && rm -f "$_tok_tmp"
  return "$rc"
}

# _emit_reset_iso <hhmm_with_meridiem>
# Shared helper: converts e.g. "11:20pm" into an ISO-8601 UTC timestamp
# (writing to /tmp/dev-lead-rate-limit-reset), advancing to tomorrow if the
# computed time is already in the past for today.
_emit_reset_iso() {
  local hhmm="$1"
  if [ -z "$hhmm" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local today iso
  today=$(date -u +%Y-%m-%d)
  iso=$(date -u -d "${today} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [ -n "$iso" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$iso" +%s 2>/dev/null || echo 0)" ]; then
    local tomorrow
    tomorrow=$(date -u -d "tomorrow" +%Y-%m-%d)
    iso=$(date -u -d "${tomorrow} ${hhmm} UTC" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  fi
  printf '%s' "${iso:-}" > /tmp/dev-lead-rate-limit-reset
}

# parse_reset_time <text>
# Extracts the rate-limit reset time from engine output and writes an ISO-8601
# UTC timestamp to /tmp/dev-lead-rate-limit-reset for callers to embed in
# status=rate-limited markers. Pattern: "resets H:MMam/pm (UTC)" or
# "resets H:MM(am|pm) UTC".
# Writes empty string if no reset time is found (caller treats as unknown).
#
# Prefer parse_reset_time_files for large captures — same OOM rationale as
# is_rate_limited / is_rate_limited_files above.
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
  _emit_reset_iso "$hhmm"
}

# parse_reset_time_files <file>...
# File-aware variant of parse_reset_time. Scans each non-empty existing file
# for the first "resets H:MMam/pm" match and writes the ISO timestamp via
# _emit_reset_iso. Uses grep directly on files to avoid loading large LLM
# outputs into a shell variable.
parse_reset_time_files() {
  local files=()
  local f
  for f in "$@"; do
    [ -n "$f" ] && [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local time_str
  time_str=$(grep -hoiE 'resets [0-9]{1,2}:[0-9]{2}(am|pm)' "${files[@]}" 2>/dev/null | head -1 || true)
  if [ -z "$time_str" ]; then
    printf '' > /tmp/dev-lead-rate-limit-reset
    return 0
  fi
  local hhmm
  hhmm=$(printf '%s' "$time_str" | grep -oiE '[0-9]{1,2}:[0-9]{2}(am|pm)$' || true)
  _emit_reset_iso "$hhmm"
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
  unset _ENGINE_USAGE_OUT
  _tmp="$(mktemp 2>/dev/null || true)"
  # Per-call usage-sidecar key (see run_triage); unique mktemp path shared with
  # the engine subshell via export.
  [[ -n "$_tmp" ]] && local -x _ENGINE_USAGE_OUT="${_tmp}.usage"

  case "$REVIEW_ENGINE" in
    claude)
      # See run_agentic — honor caller's explicit model pin when it differs
      # from the tier default. Chain only applies when the caller used the
      # default action model for this engine.
      local _writer_chain="${CLAUDE_ACTION_MODEL_CHAIN:-$model}"
      if [ -n "${ENGINE_ACTION_MODEL:-}" ] && [ "$model" != "$ENGINE_ACTION_MODEL" ]; then
        _writer_chain="$model"
      fi
      if [ -n "$_tmp" ]; then
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          || rc=$?
      fi
      ;;
    gemini)
      if [ -n "$_tmp" ]; then
        _gemini_invoke "$prompt_file" "$ACTION_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit 2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        _gemini_invoke "$prompt_file" "$ACTION_TIMEOUT_SEC" "$model" \
          --approval-mode auto_edit || rc=$?
      fi
      ;;
    copilot)
      # Self-sufficient write support via gh copilot --yolo
      if [ -n "$_tmp" ]; then
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo 2>&1 | tee "$_tmp" || rc=${PIPESTATUS[0]}
      else
        copilot_chat "$prompt_file" "$ACTION_TIMEOUT_SEC" --yolo || rc=$?
      fi
      ;;
  esac

  # Map rate-limit to exit code 2 for caller to detect; parse reset time for
  # marker embedding. Use the file-based helpers to avoid OOM on large captures.
  if [ "$rc" -ne 0 ] && [ -n "$_tmp" ] && is_rate_limited_files "$_tmp"; then
    parse_reset_time_files "$_tmp"
    [ -n "$_tmp" ] && rm -f "$_tmp"
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    local _writer_used="$model"
    if [ "$REVIEW_ENGINE" = "claude" ] && [ -n "${_CLAUDE_CHAIN_MODEL_USED:-}" ]; then
      _writer_used="$_CLAUDE_CHAIN_MODEL_USED"
    fi
    _record_engine_tokens "writer" "$REVIEW_ENGINE" "$_writer_used" "$prompt_file" "$_tmp"
  fi
  if [ -n "$_tmp" ]; then
    # Redact once: write secret-scrubbed content to the persisted path, then
    # use that redacted file as the source for the step summary so credentials
    # cannot leak via /tmp persistence or the public run summary. Patterns
    # kept in sync with scripts/dev-lead-fix-reviews.sh:redact_secrets.
    rm -f /tmp/dev-lead-session-output.txt
    if ! sed -E \
      -e 's/(gh[opsu]|ghr)_[A-Za-z0-9_]{20,}/***REDACTED-GH-TOKEN***/g' \
      -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED-GH-PAT***/g' \
      -e 's/sk-(ant-)?[A-Za-z0-9_-]{20,}/***REDACTED-API-KEY***/g' \
      -e 's/AKIA[A-Z0-9]{16}/***REDACTED-AWS-KEY***/g' \
      -e 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' \
      -e 's|ya29\.[A-Za-z0-9_-]+|***REDACTED-GOOGLE-OAUTH***|g' \
      -e 's/[Bb]earer [A-Za-z0-9._-]{20,}/Bearer ***REDACTED***/g' \
      -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***REDACTED-PRIVATE-KEY***' \
      "$_tmp" > /tmp/dev-lead-session-output.txt; then
      : > /tmp/dev-lead-session-output.txt 2>/dev/null || true
      echo "::warning::Failed to redact/persist /tmp/dev-lead-session-output.txt" >&2
    fi
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      # HTML-escape the redacted log so literal </details> or </summary> in
      # the agent output cannot break the wrapping <details> block on the run
      # summary page.
      {
        echo "## Dev-Lead session output"
        echo "<details><summary>Click to expand session logs</summary>"
        echo ""
        echo "<pre>"
        sed 's|&|\&amp;|g; s|<|\&lt;|g; s|>|\&gt;|g' /tmp/dev-lead-session-output.txt
        echo "</pre>"
        echo ""
        echo "</details>"
      } >> "$GITHUB_STEP_SUMMARY" || \
        echo "::warning::Failed to append session output to GITHUB_STEP_SUMMARY" >&2
    fi
    rm -f "$_tmp"
  fi
  return "$rc"
}

# run_writer_with_fallback <prompt_file>
# Tries primary engine, falls back through claude → gemini → copilot on rate-limit.
# Only rate-limit (exit 2) triggers fallback; other failures propagate immediately.
run_writer_with_fallback() {
  local prompt_file="$1"
  local engines=("$REVIEW_ENGINE")

  for e in claude gemini copilot; do
    [ "$e" != "$REVIEW_ENGINE" ] && engines+=("$e")
  done

  for engine in "${engines[@]}"; do
    if [ "$engine" = "copilot" ] && [[ "${COPILOT_GITHUB_TOKEN:-}" == ghp_* ]]; then
      echo "::warning::Skipping copilot fallback: classic PAT in COPILOT_GITHUB_TOKEN is unsupported" >&2
      continue
    fi

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
# Always uses the OPPOSITE engine from REVIEW_ENGINE. Output to stdout.
# Strips the opposing engine's credentials to prevent cross-engine leakage.
run_duck() {
  local prompt_file="$1"
  local model="$2"
  case "$DUCK_ENGINE" in
    claude)
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      timeout "$DUCK_TIMEOUT_SEC" claude --print \
        --model "$model" \
        --permission-mode acceptEdits \
        --allowed-tools "Bash,Read,Grep,Glob" \
        --max-turns 25 \
        < "$prompt_file"
      ;;
    copilot)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      # gh copilot is now a built-in; auth via GH_PAT (user token with Copilot subscription).
      ( export GH_TOKEN="$COPILOT_GITHUB_TOKEN"
        timeout "$DUCK_TIMEOUT_SEC" gh copilot suggest "$(cat "$prompt_file")" --target shell
      )
      ;;
    *)
      echo "::error::Unknown DUCK_ENGINE='$DUCK_ENGINE'" >&2
      return 1
      ;;
  esac
}
