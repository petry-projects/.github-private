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
      # GEMINI_*_MODEL_CHAIN is intentionally NOT cleared: it is only read by
      # _gemini_chain_invoke (i.e. when REVIEW_ENGINE=gemini), so cross-engine
      # bleed is impossible. Clearing it here would destroy user-configured
      # Gemini chains during run_writer_with_fallback's transient switch to
      # claude — when the engine flips back to gemini, the chain would be lost
      # and the staged rollout / in-engine fallback would silently degrade to
      # single-model behaviour for the rest of the session.
      ;;
    gemini)
      # Per-tier model defaults. Each can be overridden via the matching
      # GEMINI_*_MODEL env var (e.g. GEMINI_DEEP_MODEL=gemini-3.5-flash) so
      # dev-lead and pr-review workflows can pin different model IDs without
      # editing this script. See docs/engine-model-rollout.md.
      ENGINE_TRIAGE_MODEL="${GEMINI_TRIAGE_MODEL:-gemini-2.0-flash}"
      ENGINE_DEEP_MODEL="${GEMINI_DEEP_MODEL:-gemini-2.5-pro}"
      ENGINE_AUDIT_MODEL="${GEMINI_AUDIT_MODEL:-gemini-2.5-pro}"
      ENGINE_ACTION_MODEL="${GEMINI_ACTION_MODEL:-gemini-2.5-pro}"
      ENGINE_SINGLE_MODEL="${GEMINI_SINGLE_MODEL:-gemini-2.5-pro}"
      ENGINE_LABEL="triage: $ENGINE_TRIAGE_MODEL → deep: $ENGINE_DEEP_MODEL + duck: sonnet 4.6 → audit: $ENGINE_AUDIT_MODEL"
      ENGINE_SINGLE_LABEL="single-reviewer mode: $ENGINE_SINGLE_MODEL"
      # Cross-engine rubber duck: use Claude for diversity
      DUCK_ENGINE="claude"
      DUCK_MODEL="claude-sonnet-4-6"
      # CLAUDE_*_MODEL_CHAIN is intentionally NOT cleared: it is only read by
      # _claude_chain_invoke (i.e. when REVIEW_ENGINE=claude), so cross-engine
      # bleed is impossible. Clearing it here would destroy user-configured
      # Claude chains during run_writer_with_fallback's transient switch to
      # gemini, dropping the staged rollout / in-engine fallback for the rest
      # of the session once the engine flips back to claude.
      # Per-tier Gemini in-engine chains (comma-separated). Empty by default so
      # the engine behaves as a single-model invocation; set e.g.
      # GEMINI_DEEP_MODEL_CHAIN=gemini-3.5-flash,gemini-2.5-pro to enable a
      # staged rollout that walks left-to-right on rate-limit. Pattern mirrors
      # CLAUDE_*_MODEL_CHAIN.
      GEMINI_TRIAGE_MODEL_CHAIN="${GEMINI_TRIAGE_MODEL_CHAIN:-}"
      GEMINI_DEEP_MODEL_CHAIN="${GEMINI_DEEP_MODEL_CHAIN:-}"
      GEMINI_AUDIT_MODEL_CHAIN="${GEMINI_AUDIT_MODEL_CHAIN:-}"
      GEMINI_ACTION_MODEL_CHAIN="${GEMINI_ACTION_MODEL_CHAIN:-}"
      GEMINI_SINGLE_MODEL_CHAIN="${GEMINI_SINGLE_MODEL_CHAIN:-}"
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
      # CLAUDE_*_MODEL_CHAIN / GEMINI_*_MODEL_CHAIN are intentionally NOT
      # cleared here: each is read only by its own engine's chain-invoke
      # helper, so cross-engine bleed is impossible. Clearing them would
      # destroy user-configured chains during run_writer_with_fallback's
      # transient switch to copilot, silently disabling staged rollout once
      # the engine flips back to claude or gemini.
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
  export GEMINI_TRIAGE_MODEL_CHAIN GEMINI_DEEP_MODEL_CHAIN
  export GEMINI_AUDIT_MODEL_CHAIN GEMINI_ACTION_MODEL_CHAIN
  export GEMINI_SINGLE_MODEL_CHAIN
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
  local _cc_last_resort_rl_output=""
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
      # mktemp failure (one or both) — clean up partial temps and try fixed
      # /tmp fallback paths so we can still capture output for rate-limit
      # detection and continue walking the chain. Without this, a 429 in
      # the degraded branch exits immediately and skips remaining chain models.
      [ -n "$stdout_tmp" ] && rm -f "$stdout_tmp"
      [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
      [ -n "$final_stdout" ] && rm -f "$final_stdout"
      [ -n "$final_stderr" ] && rm -f "$final_stderr"
      stdout_tmp=""
      stderr_tmp=""
      final_stdout=""
      final_stderr=""
      # _CLAUDE_CHAIN_FB_PREFIX is a private hook for tests (mirrors the
      # Gemini equivalent); production always uses /tmp/claude-chain.
      local _ccfb_prefix="${_CLAUDE_CHAIN_FB_PREFIX:-/tmp/claude-chain}"
      local _ccfb_stdout _ccfb_stderr
      # Use mktemp with a template so fallback filenames are non-predictable.
      # If that also fails, _ccfb_stdout/_ccfb_stderr are empty and the
      # condition below is false, falling through to the in-memory last-resort.
      # Dropping to a deterministic PID-based name would reintroduce a
      # symlink-clobbering risk that mktemp -t XXXXXX is designed to prevent.
      _ccfb_stdout="$(mktemp "${_ccfb_prefix}-stdout-XXXXXX" 2>/dev/null)" || _ccfb_stdout=""
      _ccfb_stderr="$(mktemp "${_ccfb_prefix}-stderr-XXXXXX" 2>/dev/null)" || _ccfb_stderr=""
      if [[ -n "$_ccfb_stdout" && -n "$_ccfb_stderr" ]]; then
        timeout "$timeout_sec" claude --print --model "$model" "${extra_args[@]}" \
          < "$prompt_file" > "$_ccfb_stdout" 2> "$_ccfb_stderr" || rc=$?
        stdout_tmp="$_ccfb_stdout"
        stderr_tmp="$_ccfb_stderr"
        # Fall through to common chain-tracking logic below
      else
        # Even /tmp is unavailable — capture combined output in a bash variable
        # for last-resort rate-limit detection so the chain can continue rather
        # than returning early and skipping remaining models.
        rm -f "$_ccfb_stdout" "$_ccfb_stderr" 2>/dev/null || true
        local _cc_last_resort=""
        _cc_last_resort="$(timeout "$timeout_sec" claude --print --model "$model" "${extra_args[@]}" \
          < "$prompt_file" 2>&1)" || rc=$?
        _CLAUDE_CHAIN_MODEL_USED="$model"
        export _CLAUDE_CHAIN_MODEL_USED
        if is_rate_limited "$_cc_last_resort"; then
          parse_reset_time "$_cc_last_resort" || true
          _cc_last_resort_rl_output="$_cc_last_resort"
          echo "::warning::[claude] model $model throttled (rc=$rc) — trying next in chain" >&2
          continue
        fi
        printf '%s\n' "$_cc_last_resort"
        return "$rc"
      fi
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
    # Guard against calling parse_reset_time_files with empty strings: when all
    # models used the last-resort (in-memory) branch, final_stdout/final_stderr
    # are empty; passing them would clobber the timestamp parse_reset_time
    # already wrote inside the loop for each throttled response.
    if [ -n "$final_stdout" ] || [ -n "$final_stderr" ]; then
      parse_reset_time_files "$final_stdout" "$final_stderr"
    fi
    final_rc=2
  fi

  # Emit the final attempt's captured output. In JSON-usage mode, parse the usage
  # block and emit the extracted .result text; fall back to the raw payload if
  # extraction yields nothing or the call failed (preserves error/rate-limit text
  # for downstream detection). Degraded paths (mktemp failure) already ran without
  # fmt_args so their output is plain text regardless of _usage_json.
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

  # When all models were throttled via the last-resort (in-memory) branch, no
  # output reached final_stdout/final_stderr. Emit the final throttled response
  # so callers scanning stdout for rate-limit text can detect this case and
  # trigger the cross-provider engine fallback rather than reporting a hard
  # cascade failure.
  if [ "$final_rc" -eq 2 ] && [ -z "$final_stdout" ] && [ -z "$final_stderr" ] && \
     [ -n "$_cc_last_resort_rl_output" ]; then
    printf '%s\n' "$_cc_last_resort_rl_output"
  fi

  _CLAUDE_CHAIN_MODEL_USED="$final_model"
  export _CLAUDE_CHAIN_MODEL_USED
  return "$final_rc"
}

# _gemini_chain_invoke <chain_csv> <prompt_file> <timeout_sec> [approval_mode] [extra_args...]
# Walks a comma-separated list of Gemini models, invoking
# `gemini --prompt "" --model X --approval-mode <approval_mode> --output-format text`
# with the given extra arguments. approval_mode defaults to "auto_edit" for
# write/agentic tiers; triage callers pass "plan" to deny workspace edits and
# prevent prompt-injected triage responses from auto-approving file changes.
# Same control flow as _claude_chain_invoke:
# the first model whose run does NOT trigger is_rate_limited() wins; its
# captured stdout is written to fd1, stderr to fd2, and its exit code is
# returned. Rate-limited attempts are discarded and the next model is tried.
# If every model in the chain rate-limits, returns 2 and writes the parsed
# reset time to /tmp/dev-lead-rate-limit-reset.
#
# Empty/whitespace-only chain → config error rc=1, NOT rate-limit rc=2.
# Returning 2 for a misconfiguration would otherwise trigger an unnecessary
# cross-provider fallback as though quotas were exhausted.
#
# Sets _GEMINI_CHAIN_MODEL_USED to the model that produced the final output
# (success or last attempt) so callers can log which model actually ran.
_gemini_chain_invoke() {
  local chain_csv="$1" prompt_file="$2" timeout_sec="$3" approval_mode="${4:-auto_edit}"
  local extra_args=()
  if [ $# -gt 4 ]; then
    extra_args=("${@:5}")
  fi

  # Trim whitespace so a whitespace-only chain is caught here with a clear
  # error rather than slipping through to the per-entry filter below.
  chain_csv="$(echo "$chain_csv" | xargs)"

  if [ -z "$chain_csv" ]; then
    echo "::error::_gemini_chain_invoke called with empty chain" >&2
    return 1
  fi

  # When token logging is on, capture real usage by running gemini with
  # --output-format json and emitting the extracted text to the caller.
  # Gated by ENGINE_USAGE_JSON (default on) so it can be disabled without a code
  # change. Falls back to raw output if extraction yields nothing. Degraded paths
  # (/tmp fallback, last-resort in-memory) keep --output-format text because
  # parse_engine_usage requires a well-formed JSON file.
  declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage
  local _usage_json=0 fmt_args=(--output-format text)
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
  local _last_resort_rl_output=""
  local model
  local _best_reset="" _cur_reset=""  # preserve last non-empty reset time across throttled attempts

  for model in "${models[@]}"; do
    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    [ -z "$model" ] && continue

    attempted=$((attempted + 1))
    stdout_tmp="$(mktemp 2>/dev/null)" || stdout_tmp=""
    stderr_tmp="$(mktemp 2>/dev/null)" || stderr_tmp=""
    rc=0

    if [ -n "$stdout_tmp" ] && [ -n "$stderr_tmp" ]; then
      timeout "$timeout_sec" gemini --prompt "" \
        --model "$model" \
        --approval-mode "$approval_mode" \
        "${fmt_args[@]}" \
        "${extra_args[@]}" \
        < "$prompt_file" > "$stdout_tmp" 2> "$stderr_tmp" || rc=$?
    else
      # mktemp failure (one or both) — clean up partial tmps and fall back to
      # fixed /tmp paths so we can still capture output for rate-limit
      # detection. Without this scan, a 429 in the degraded branch would
      # surface as a generic non-zero exit and the cross-provider fallback
      # (claude → gemini → copilot) would never trigger.
      [ -n "$stdout_tmp" ] && rm -f "$stdout_tmp"
      [ -n "$stderr_tmp" ] && rm -f "$stderr_tmp"
      stdout_tmp=""
      stderr_tmp=""
      # Also clean up any final_stdout/final_stderr from prior iterations so
      # the last-resort early-return path (success or non-RL error) doesn't
      # leak those files; the common chain-tracking code below handles the
      # fixed-path fallback case.
      [ -n "$final_stdout" ] && rm -f "$final_stdout"
      [ -n "$final_stderr" ] && rm -f "$final_stderr"
      final_stdout=""
      final_stderr=""
      # _GEMINI_CHAIN_FB_PREFIX is a private hook for tests to point the
      # fallback paths at an unwritable directory and exercise the
      # last-resort branch below; production always uses /tmp/gemini-chain.
      local _fb_prefix="${_GEMINI_CHAIN_FB_PREFIX:-/tmp/gemini-chain}"
      # Use mktemp with a template so fallback filenames are non-predictable.
      # If that also fails, leave the variable empty and fall through to the
      # in-memory last-resort below. Dropping to a deterministic PID-based
      # name would reintroduce a symlink-clobbering risk that mktemp -t XXXXXX
      # is designed to prevent — mirrors the same rule in _claude_chain_invoke.
      local _fb_stdout _fb_stderr
      _fb_stdout="$(mktemp "${_fb_prefix}-stdout-XXXXXX" 2>/dev/null)" || _fb_stdout=""
      _fb_stderr="$(mktemp "${_fb_prefix}-stderr-XXXXXX" 2>/dev/null)" || _fb_stderr=""
      if [ -n "$_fb_stdout" ] && [ -n "$_fb_stderr" ] && \
         { [ -f "$_fb_stdout" ] || : > "$_fb_stdout" 2>/dev/null; } && \
         { [ -f "$_fb_stderr" ] || : > "$_fb_stderr" 2>/dev/null; }; then
        timeout "$timeout_sec" gemini --prompt "" \
          --model "$model" \
          --approval-mode "$approval_mode" \
          --output-format text \
          "${extra_args[@]}" \
          < "$prompt_file" > "$_fb_stdout" 2> "$_fb_stderr" || rc=$?
        # Route through the common chain-tracking path so the loop continues
        # to the next model on rate-limit rather than returning early, honoring
        # the chain contract (return 2 only when all models are exhausted).
        stdout_tmp="$_fb_stdout"
        stderr_tmp="$_fb_stderr"
      else
        # Even /tmp is unavailable — capture combined stdout+stderr in a bash
        # variable so rate-limit detection still fires and the cross-provider
        # fallback can trigger. We lose stdout/stderr separation here, but for
        # this last-resort path that tradeoff is acceptable; without the scan a
        # 429 would surface as a generic non-zero exit and engine fallback
        # would never trigger.
        local _last_resort_output=""
        _last_resort_output="$(timeout "$timeout_sec" gemini --prompt "" \
          --model "$model" \
          --approval-mode "$approval_mode" \
          --output-format text \
          "${extra_args[@]}" \
          < "$prompt_file" 2>&1)" || rc=$?
        _GEMINI_CHAIN_MODEL_USED="$model"
        export _GEMINI_CHAIN_MODEL_USED
        if is_rate_limited "$_last_resort_output"; then
          # parse_reset_time writes to /tmp; in this degraded branch the write
          # may fail. Continue to the next model rather than returning early,
          # honoring the chain contract (return 2 only when all models exhausted).
          # Rate-limit detection is output-based (not gated on rc != 0) so that
          # a provider returning rc=0 with rate-limit text is still caught and
          # triggers the cross-provider fallback via exit code 2.
          parse_reset_time "$_last_resort_output" || true
          _cur_reset="$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)"
          [ -n "$_cur_reset" ] && _best_reset="$_cur_reset"
          _last_resort_rl_output="$_last_resort_output"
          echo "::warning::[gemini] model $model throttled (rc=$rc) — trying next in chain" >&2
          continue
        fi
        printf '%s\n' "$_last_resort_output"
        return "$rc"
      fi
    fi

    [ -n "$final_stdout" ] && rm -f "$final_stdout"
    [ -n "$final_stderr" ] && rm -f "$final_stderr"
    final_stdout="$stdout_tmp"
    final_stderr="$stderr_tmp"
    final_model="$model"

    # When rc=0 accept the output unconditionally — a valid review response
    # can legitimately contain "429", "quota exceeded", or other rate-limit
    # terms in its findings (e.g. a review of HTTP error-handling code).
    # Scanning rc=0 output would discard valid reviews as false throttles.
    # Rate-limit detection is reserved for non-zero exits where the output
    # is likely an error body, not review content.
    if [ "$rc" -eq 0 ]; then
      final_rc=0
      all_rl=0
      break
    fi
    if ! is_rate_limited_files "$stdout_tmp" "$stderr_tmp"; then
      final_rc="$rc"
      all_rl=0
      break
    fi
    # Capture the reset time for this throttled attempt; keep the last non-empty
    # value seen so a later attempt with no reset timestamp does not overwrite
    # an earlier one (which would cause the retry cron to treat the limit as
    # already cleared and re-dispatch before the quota actually resets).
    parse_reset_time_files "$stdout_tmp" "$stderr_tmp"
    _cur_reset="$(cat /tmp/dev-lead-rate-limit-reset 2>/dev/null || true)"
    [ -n "$_cur_reset" ] && _best_reset="$_cur_reset"
    # Phrasing avoids "rate-limit"/"429"/"quota" so downstream callers that
    # scan our stderr (e.g. review-one-pr.sh triage) don't misclassify a
    # successful chain fallback as a provider rate-limit. Mirrors the same
    # rule applied in _claude_chain_invoke.
    echo "::warning::[gemini] model $model throttled (rc=$rc) — trying next in chain" >&2
  done

  if [ "$attempted" -eq 0 ]; then
    echo "::error::_gemini_chain_invoke: chain '$chain_csv' had no valid model entries" >&2
    return 1
  fi

  if [ "$all_rl" -eq 1 ]; then
    # Write back the best reset time from any throttled attempt. Each iteration
    # already called parse_reset_time_files (file-based) or parse_reset_time
    # (last-resort) and updated _best_reset with the last non-empty result.
    # Writing it here preserves an earlier attempt's reset time even when the
    # final attempt's output carries no reset timestamp, preventing the retry
    # cron from treating the quota as cleared and re-dispatching too early.
    printf '%s' "$_best_reset" > /tmp/dev-lead-rate-limit-reset || true
    final_rc=2
  fi

  # Emit the final attempt's captured output. In JSON-usage mode (happy path
  # where mktemp succeeded), parse the usage block and emit the extracted text;
  # fall back to the raw payload if extraction yields nothing or the call failed.
  # Degraded paths (/tmp fallback, last-resort in-memory) ran with --output-format
  # text, so their output is plain text regardless of _usage_json.
  if [ -n "$final_stdout" ]; then
    if [ "$_usage_json" -eq 1 ] && [ "$final_rc" -eq 0 ]; then
      parse_engine_usage gemini "$final_stdout" || true
      local _txt
      _txt="$(extract_engine_text gemini "$final_stdout")"
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

  # When all models were throttled via the last-resort (in-memory) branch, no
  # output reached final_stdout/final_stderr. Emit the final throttled response
  # so callers scanning stdout for rate-limit text can detect this case and
  # trigger the cross-provider engine fallback rather than reporting a hard
  # cascade failure.
  if [ "$final_rc" -eq 2 ] && [ -z "$final_stdout" ] && [ -z "$final_stderr" ] && \
     [ -n "$_last_resort_rl_output" ]; then
    printf '%s\n' "$_last_resort_rl_output"
  fi

  _GEMINI_CHAIN_MODEL_USED="$final_model"
  export _GEMINI_CHAIN_MODEL_USED
  return "$final_rc"
}

# _record_engine_tokens <tier> <engine> <model> <prompt_file> [output_file]
# Writes one token record to TOKEN_LOG_FILE. Prefers real usage from the engine
# sidecar (populated by parse_engine_usage inside chain_invoke) or LAST_* globals;
# falls back to byte-count estimates when no usage block was captured (e.g. copilot
# or degraded/text-mode runs). No-op when TOKEN_LOG_FILE is unset or the
# token-metrics library is not loaded. Always succeeds (non-fatal).
_record_engine_tokens() {
  [ -n "${TOKEN_LOG_FILE:-}" ] || return 0
  declare -f emit_token_record >/dev/null 2>&1 || return 0

  local tier="$1" engine="$2" model="$3" prompt_file="$4" output_file="${5:-}"
  local workflow="${TOKEN_WORKFLOW:-unknown}" context="${PR_URL:-}"
  local input_tokens cache_read_tokens cache_write_tokens output_tokens
  local _have_usage=0

  # Prefer real usage captured by the engine. Read from the sidecar file first
  # (written by parse_engine_usage even when the engine ran inside a subshell);
  # fall back to LAST_* globals for non-piped callers.
  # Inline the sidecar path rather than calling _engine_usage_sidecar() via $()
  # so BASHPID here matches the BASHPID used by parse_engine_usage, which also
  # runs in the same shell (file-redirect pattern, not tee-pipeline).
  local _uf=""
  [ -n "${TOKEN_LOG_FILE:-}" ] && _uf="${TOKEN_LOG_FILE}.last-usage.${BASHPID}"
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
        local _triage_chain="${GEMINI_TRIAGE_MODEL_CHAIN:-$ENGINE_TRIAGE_MODEL}"
        if [ -n "$_tok_tmp" ]; then
          _gemini_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
            --approval-mode auto_edit | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
        else
          _gemini_chain_invoke "$_triage_chain" "$prompt_file" "$TRIAGE_TIMEOUT_SEC" \
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
      local _triage_used="${_CLAUDE_CHAIN_MODEL_USED:-${_GEMINI_CHAIN_MODEL_USED:-$ENGINE_TRIAGE_MODEL}}"
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
    _tok_tmp="$(mktemp 2>/dev/null || true)"
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
        # Redirect stdout to file rather than using a tee pipeline so that
        # _CLAUDE_CHAIN_MODEL_USED exported inside _claude_chain_invoke is
        # visible in the current process (not lost in a pipeline subshell),
        # allowing _record_engine_tokens to log the model that actually ran.
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          > "$_tok_tmp" || rc=$?
        cat "$_tok_tmp"
      else
        _claude_chain_invoke "$_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          || rc=$?
      fi
      ;;
    gemini)
      # Mirror the claude pin-vs-chain semantics: when the caller passed the
      # tier default model, expand the configured GEMINI_*_MODEL_CHAIN (if any)
      # for staged rollout; otherwise honor the caller's explicit pin as a
      # one-element chain.
      local _gemini_agentic_chain _gemini_tier_default=""
      case "$tier" in
        deep)   _gemini_tier_default="${ENGINE_DEEP_MODEL:-}"
                _gemini_agentic_chain="${GEMINI_DEEP_MODEL_CHAIN:-$model}"   ;;
        audit)  _gemini_tier_default="${ENGINE_AUDIT_MODEL:-}"
                _gemini_agentic_chain="${GEMINI_AUDIT_MODEL_CHAIN:-$model}"  ;;
        action) _gemini_tier_default="${ENGINE_ACTION_MODEL:-}"
                _gemini_agentic_chain="${GEMINI_ACTION_MODEL_CHAIN:-$model}" ;;
        single) _gemini_tier_default="${ENGINE_SINGLE_MODEL:-}"
                _gemini_agentic_chain="${GEMINI_SINGLE_MODEL_CHAIN:-$model}" ;;
        *)      _gemini_agentic_chain="$model" ;;
      esac
      if [ -n "$_gemini_tier_default" ] && [ "$model" != "$_gemini_tier_default" ]; then
        _gemini_agentic_chain="$model"
      fi
      if [ -n "$_tok_tmp" ]; then
        # Redirect stdout to file rather than using a tee pipeline so that
        # _GEMINI_CHAIN_MODEL_USED exported inside _gemini_chain_invoke is
        # visible in the current process (not lost in a pipeline subshell),
        # allowing _record_engine_tokens to log the model that actually ran.
        # Stderr is NOT redirected here — ::warning:: throttle messages from
        # chain fallbacks must stay on stderr and must not be mixed into the
        # stdout that callers capture for agentic output parsing.
        _gemini_chain_invoke "$_gemini_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          > "$_tok_tmp" || rc=$?
        cat "$_tok_tmp"
      else
        _gemini_chain_invoke "$_gemini_agentic_chain" "$prompt_file" "$DEEP_TIMEOUT_SEC" \
          || rc=$?
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
    elif [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${_GEMINI_CHAIN_MODEL_USED:-}" ]; then
      _agentic_used="$_GEMINI_CHAIN_MODEL_USED"
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
  # When TOKEN_LOG_FILE is active and parse_engine_usage is loaded, capture
  # engine output as JSON so _record_engine_tokens gets real usage counts
  # (input, cache_read, cache_write, output) rather than byte estimates.
  # Mirrors the _usage_json flag in _claude_chain_invoke/_gemini_chain_invoke.
  local _duck_usage_json=0
  if [ -n "${TOKEN_LOG_FILE:-}" ] && [ "${ENGINE_USAGE_JSON:-1}" != "0" ] \
     && declare -f parse_engine_usage >/dev/null 2>&1; then
    _duck_usage_json=1
  fi
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
      if [ -n "$_tok_tmp" ] && [ "$_duck_usage_json" -eq 1 ]; then
        # Redirect stdout (JSON) to file so parse_engine_usage can populate the
        # sidecar for _record_engine_tokens. stderr flows to the caller — do not
        # merge (2>&1) or it corrupts the JSON usage block in the file.
        declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage
        timeout "$DUCK_TIMEOUT_SEC" claude --print \
          --model "$model" \
          --output-format json \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          < "$prompt_file" > "$_tok_tmp" || rc=$?
        if [ "$rc" -eq 0 ]; then
          parse_engine_usage claude "$_tok_tmp" || true
          local _txt
          _txt="$(extract_engine_text claude "$_tok_tmp")"
          if [ -n "$_txt" ]; then printf '%s\n' "$_txt"; else cat "$_tok_tmp"; fi
        else
          cat "$_tok_tmp"
        fi
      elif [ -n "$_tok_tmp" ]; then
        timeout "$DUCK_TIMEOUT_SEC" claude --print \
          --model "$model" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          < "$prompt_file" | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        timeout "$DUCK_TIMEOUT_SEC" claude --print \
          --model "$model" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Grep,Glob" \
          --max-turns 25 \
          < "$prompt_file" || rc=$?
      fi
      ;;
    gemini)
      unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
      unset COPILOT_GITHUB_TOKEN 2>/dev/null || true
      if [ -n "$_tok_tmp" ] && [ "$_duck_usage_json" -eq 1 ]; then
        declare -f reset_engine_usage >/dev/null 2>&1 && reset_engine_usage
        timeout "$DUCK_TIMEOUT_SEC" gemini --prompt "" \
          --model "$model" \
          --approval-mode auto_edit \
          --output-format json \
          < "$prompt_file" > "$_tok_tmp" || rc=$?
        if [ "$rc" -eq 0 ]; then
          parse_engine_usage gemini "$_tok_tmp" || true
          local _txt
          _txt="$(extract_engine_text gemini "$_tok_tmp")"
          if [ -n "$_txt" ]; then printf '%s\n' "$_txt"; else cat "$_tok_tmp"; fi
        else
          cat "$_tok_tmp"
        fi
      elif [ -n "$_tok_tmp" ]; then
        timeout "$DUCK_TIMEOUT_SEC" gemini --prompt "" \
          --model "$model" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" | tee "$_tok_tmp" || rc=${PIPESTATUS[0]}
      else
        timeout "$DUCK_TIMEOUT_SEC" gemini --prompt "" \
          --model "$model" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" || rc=$?
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
  _tmp="$(mktemp 2>/dev/null || true)"

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
        # Redirect to file (2>&1 combined) rather than tee pipeline so that
        # _CLAUDE_CHAIN_MODEL_USED exported inside _claude_chain_invoke is
        # visible to _record_engine_tokens in the parent process. stderr is
        # merged with stdout (2>&1) so is_rate_limited_files can scan both
        # streams for rate-limit text from either stdout or stderr.
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          > "$_tmp" 2>&1 || rc=$?
        cat "$_tmp"
      else
        _claude_chain_invoke "$_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob,WebFetch" \
          || rc=$?
      fi
      ;;
    gemini)
      # Honor explicit model pin when caller passed something other than the
      # action default (same contract as the claude branch above); otherwise
      # expand GEMINI_ACTION_MODEL_CHAIN for staged rollout on rate-limit.
      local _gemini_writer_chain="${GEMINI_ACTION_MODEL_CHAIN:-$model}"
      if [ -n "${ENGINE_ACTION_MODEL:-}" ] && [ "$model" != "$ENGINE_ACTION_MODEL" ]; then
        _gemini_writer_chain="$model"
      fi
      if [ -n "$_tmp" ]; then
        # Redirect to file rather than using a tee pipeline so that
        # _GEMINI_CHAIN_MODEL_USED exported inside _gemini_chain_invoke is
        # visible in the current process (not lost in a pipeline subshell),
        # allowing _record_engine_tokens to log the model that actually ran.
        _gemini_chain_invoke "$_gemini_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          > "$_tmp" 2>&1 || rc=$?
        cat "$_tmp"
      else
        _gemini_chain_invoke "$_gemini_writer_chain" "$prompt_file" "$ACTION_TIMEOUT_SEC" \
          || rc=$?
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
    elif [ "$REVIEW_ENGINE" = "gemini" ] && [ -n "${_GEMINI_CHAIN_MODEL_USED:-}" ]; then
      _writer_used="$_GEMINI_CHAIN_MODEL_USED"
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
