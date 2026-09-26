#!/usr/bin/env bash
set -euo pipefail
# model-ab-dispatch.sh — the workflow_dispatch runner's testable wrapper around
# scripts/evals/model-ab.sh (#1950, epic #1895; unblocks #1899 and #1901).
#
# Usage:
#   model-ab-dispatch.sh --candidate M --incumbent M \
#     [--sets "triage deep-review"] [--runs N] [--evals-dir DIR] [--out FILE]
#     [--validate-only]
#
# --validate-only runs the offline input checks (clamp + set validation) and exits
# WITHOUT invoking any arm — the workflow calls it before the paid probe so an
# invalid dispatch spends zero model tokens (#1952).
#
# .github/workflows/model-ab.yml is deliberately thin; the two pieces of logic
# that MUST be exercised offline (before a live run spends tokens) live here and
# are unit-tested in tests/test_model_ab_dispatch.bats:
#
#   1. Input validation / clamping (AC #1):
#      * `runs` is clamped to the epic cost cap 1..3 (default 1). A non-integer,
#        empty, zero, or negative value degrades to 1 — never an unbounded run.
#      * every requested set must have an evals/<set>/holdout directory; an unknown
#        set is a hard error (exit 2) raised BEFORE any arm runs, so a fat-fingered
#        input fails fast instead of burning budget.
#
#   2. Retry policy (AC #2):
#      * model-ab.sh classifies its verdict by exit code — 0 accept, 1 regression
#        (both SCORED), 2 infra/un-scored. This wrapper re-runs model-ab.sh ONLY
#        when the previous attempt exited 2, up to `runs` attempts total, and
#        NEVER re-runs a scored verdict (a scored number is final — re-running to
#        "get a better number" is exactly what the maintainer decision forbids).
#      * the workflow's exit status is model-ab.sh's final verdict, unchanged.
#
# The generator/judge pinning, held-out immutability guard, and per-set scoring
# all remain in model-ab.sh — this wrapper adds no scoring logic and forwards the
# arms verbatim (candidate incumbent sets…). The evidence JSON model-ab.sh emits
# is passed through unchanged (and to --out when given) for the summary + #1899.
#
# Env overrides (so the bats suite stays network-free):
#   MODEL_AB_CMD  command that runs the A/B (default: bash <dir>/model-ab.sh).
#                 Set TOKEN_LOG_FILE / AB_JUDGE_MODEL etc. in the environment; they
#                 pass through to model-ab.sh untouched.
#   EVALS_DIR     held-out cases root (default: <repo>/evals); --evals-dir wins.
#
# Exit codes (model-ab.sh's, propagated):
#   0  accept — candidate did not regress on any set
#   1  regression — BLOCKING
#   2  infra/un-scored after exhausting retries, OR a usage/validation hard error

# ── pure logic (unit-tested in tests/test_model_ab_dispatch.bats) ─────────────

MAD_RUNS_MIN=1
MAD_RUNS_MAX=3
# Upper bound on the number of distinct sets a single dispatch may request. Even
# distinct sets multiply live cost (a candidate/incumbent pair per set), so the
# `runs` clamp alone does not bound per-attempt spend — the set count is an
# independent multiplier. Cap it (comfortably above the two documented sets) so a
# fat-fingered or adversarial input can never fan out to an unbounded matrix (#1952).
MAD_MAX_SETS=8

# mad_clamp_runs <value> — print the run budget clamped to [1,3]. A value that is
# not a positive integer (empty, non-numeric, fractional, <=0) degrades to the
# floor (1) so a bad input can never trigger an unbounded — or zero — run.
mad_clamp_runs() {
  local v="${1:-}"
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$MAD_RUNS_MIN"
    return 0
  fi
  # Strip leading zeros so "003" is decimal 3 (not octal) and an all-zero string
  # collapses to "0" (clamped to the floor below).
  local stripped="${v#"${v%%[!0]*}"}"
  [ -z "$stripped" ] && stripped="0"
  # Overflow guard (#1952): a digit-only value with MORE digits than MAD_RUNS_MAX
  # can only exceed the cap, so clamp WITHOUT arithmetic. `$((10#$v))` on a value
  # beyond the 64-bit range aborts the shell — crashing instead of degrading to the
  # documented max. Comparing digit-length first sidesteps that entirely.
  if [ "${#stripped}" -gt "${#MAD_RUNS_MAX}" ]; then
    printf '%s\n' "$MAD_RUNS_MAX"
    return 0
  fi
  local n=$((10#$stripped))
  if [ "$n" -lt "$MAD_RUNS_MIN" ]; then n="$MAD_RUNS_MIN"; fi
  if [ "$n" -gt "$MAD_RUNS_MAX" ]; then n="$MAD_RUNS_MAX"; fi
  printf '%s\n' "$n"
}

# mad_validate_sets <evals_dir> <set…> — return 0 iff at least one set is given
# and every set has an <evals_dir>/<set>/holdout directory. On failure prints the
# offending set (or the empty-list reason) so the caller can name it in the error.
mad_validate_sets() {
  local evals_dir="${1:-}"; shift || true
  if [ "$#" -eq 0 ]; then
    echo "no sets requested"
    return 1
  fi
  local set
  for set in "$@"; do
    if [ -z "$set" ] || [ ! -d "$evals_dir/$set/holdout" ]; then
      echo "$set"
      return 1
    fi
  done
  return 0
}

# mad_incompatible_set <evals_dir> <set> — return 1 (and print the set) unless the
# set can be faithfully A/B'd by model-ab.sh. model-ab.sh pins ONLY the triage model
# chain (CLAUDE_TRIAGE_MODEL_CHAIN) and drives every arm through run_triage, so ONLY
# a triage-tier set is comparable: a `engine: persona` set is scored on the DEEP
# model chain the arm pin does NOT vary — both arms would run the same default model
# and the "non-regression" verdict would be meaningless (#1952). An absent scorer.json
# / absent engine defaults to the triage tier (matching run-eval.sh's `.engine //
# "triage"`), which IS compatible. Every OTHER case must be rejected OFFLINE too:
# a malformed/unreadable scorer.json (jq fails) or an unknown engine value ("foo")
# is neither triage nor persona, so run-eval.sh would reject it (exit 2) only AFTER
# both paid probe calls have run — so fail validation now unless the parsed engine
# is EXACTLY "triage" (#1952, codex P2). Note the `.engine // "triage"` default only
# fires on absent/null; a jq PARSE failure prints nothing, which we capture as the
# empty string below so it is rejected rather than silently degraded to triage.
mad_incompatible_set() {
  local evals_dir="${1:-}" set="${2:-}" scorer engine
  scorer="$evals_dir/$set/scorer.json"
  [ -f "$scorer" ] || return 0
  if ! engine="$(jq -r '.engine // "triage"' "$scorer" 2>/dev/null)"; then
    engine=""
  fi
  if [ "$engine" != "triage" ]; then
    printf '%s\n' "$set"
    return 1
  fi
  return 0
}

# ── I/O orchestration ─────────────────────────────────────────────────────────

die() {
  # stdout (not stderr) so the reason is visible in workflow logs and capturable
  # by tests; the ::error:: prefix still renders as a GitHub annotation.
  echo "::error::model-ab-dispatch: $1"
  exit 2
}

main() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/../.." && pwd)"

  command -v jq >/dev/null 2>&1 || die "jq is required but not installed"

  local candidate="" incumbent="" sets_raw="triage deep-review" runs_raw="1"
  local evals_dir="${EVALS_DIR:-$repo_root/evals}" out_file="" validate_only=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Explicit arity check + die (exit 2), NOT ${2:?…}: the :? expansion aborts
      # with status 1, which would collide with model-ab.sh's "regression" exit.
      --candidate) [ "$#" -ge 2 ] || die "--candidate needs a value"; candidate="$2"; shift 2 ;;
      --incumbent) [ "$#" -ge 2 ] || die "--incumbent needs a value"; incumbent="$2"; shift 2 ;;
      --sets)      [ "$#" -ge 2 ] || die "--sets needs a value";      sets_raw="$2";  shift 2 ;;
      --runs)      [ "$#" -ge 2 ] || die "--runs needs a value";      runs_raw="$2";  shift 2 ;;
      --evals-dir) [ "$#" -ge 2 ] || die "--evals-dir needs a directory"; evals_dir="$2"; shift 2 ;;
      --out)       [ "$#" -ge 2 ] || die "--out needs a file";        out_file="$2";  shift 2 ;;
      --validate-only) validate_only=true; shift ;;
      -h|--help)   grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *)  die "unexpected argument: $1" ;;
    esac
  done

  [ -n "$candidate" ] || die "usage: model-ab-dispatch.sh --candidate M --incumbent M [--sets S] [--runs N]"
  [ -n "$incumbent" ] || die "usage: model-ab-dispatch.sh --candidate M --incumbent M [--sets S] [--runs N]"
  [ -n "$evals_dir" ] || die "evals_dir is empty — would check root directory; set EVALS_DIR or use --evals-dir"

  # Each arm must name EXACTLY ONE model. A value with a comma or whitespace is
  # forwarded verbatim to model-ab.sh as CLAUDE_TRIAGE_MODEL_CHAIN, where
  # _claude_chain_invoke reads it as a FALLBACK CHAIN — a throttled candidate would
  # then be silently scored on a fallback model while the evidence still labels the
  # arm with the requested string, so the "non-regression" verdict would compare the
  # wrong models (#1952, codex P1). Reject multi-model values before any token is spent.
  case "$candidate" in
    *,* | *[[:space:]]*) die "candidate '$candidate' must name exactly one model — no commas or whitespace (a comma/space is read as a fallback chain, not a single model)" ;;
  esac
  case "$incumbent" in
    *,* | *[[:space:]]*) die "incumbent '$incumbent' must name exactly one model — no commas or whitespace (a comma/space is read as a fallback chain, not a single model)" ;;
  esac

  # Candidate and incumbent must differ: comparing a model against itself spends
  # both arms' tokens on two nondeterministic runs of ONE model, and the score delta
  # is reported as accept OR regression despite providing no replacement evidence
  # (#1952, codex P2). Fail offline before either paid probe.
  [ "$candidate" != "$incumbent" ] || die "candidate and incumbent are identical ('$candidate') — an A/B must compare two different models"

  # Reject multiline input outright: `read -ra <<<"$sets_raw"` consumes only the
  # FIRST line, so a value like $'triage\ndeep-review' would silently validate and
  # score just `triage` yet return an accept verdict for the WHOLE request (#1952).
  # The workflow passes a single-line space-separated string; anything multiline is
  # a malformed dispatch — fail fast rather than score a partial matrix.
  case "$sets_raw" in
    *$'\n'*) die "multiline --sets is not accepted — pass a single space-separated line" ;;
  esac

  # Split the whitespace-delimited sets input into an array (the workflow passes a
  # single string, e.g. "triage deep-review").
  local sets=()
  read -ra sets <<<"$sets_raw"

  # Reject duplicate set names: a repeated set (e.g. "triage triage") would run a
  # full candidate/incumbent pair PER occurrence, so `runs` would no longer bound
  # per-attempt spend — input length would (#1952). Reject-on-dup keeps the cost cap
  # meaningful and surfaces the fat-fingered input.
  local i j
  for (( i = 0; i < ${#sets[@]}; i++ )); do
    for (( j = i + 1; j < ${#sets[@]}; j++ )); do
      [ "${sets[i]}" = "${sets[j]}" ] && die "duplicate set '${sets[i]}' in --sets — list each set at most once"
    done
  done

  # Bound the set matrix even for distinct names (#1952).
  if [ "${#sets[@]}" -gt "$MAD_MAX_SETS" ]; then
    die "too many sets (${#sets[@]} > $MAD_MAX_SETS) — narrow the --sets list"
  fi

  # Fail fast on an unknown set BEFORE any arm runs (AC #1) — no token is spent.
  local bad
  if ! bad="$(mad_validate_sets "$evals_dir" "${sets[@]}")"; then
    if [ "$bad" = "no sets requested" ]; then
      die "no sets requested — expected one or more of the evals/<set>/holdout sets"
    fi
    die "unknown set '$bad' — no evals/$bad/holdout under $evals_dir (frozen held-out sets only)"
  fi

  # Reject sets model-ab.sh cannot faithfully compare: a persona-engine set is
  # scored on the deep chain the triage-chain arm pin does not vary (#1952).
  local s incompat
  for s in "${sets[@]}"; do
    if ! incompat="$(mad_incompatible_set "$evals_dir" "$s")"; then
      die "incompatible set '$incompat' — its scorer.json must declare a triage-tier engine (model-ab.sh pins only the triage model chain; a persona, unknown, or malformed/unreadable engine cannot be faithfully A/B'd per arm — triage-engine sets only)"
    fi
  done

  local runs; runs="$(mad_clamp_runs "$runs_raw")"

  # --validate-only: the input checks above ARE the whole job. The workflow runs
  # this before the paid liveness/effort probe so an invalid dispatch spends zero
  # model tokens (#1952). Everything above has passed by here.
  if [ "$validate_only" = true ]; then
    echo "model-ab-dispatch: inputs valid (sets: ${sets[*]}; runs: $runs)"
    return 0
  fi

  # The A/B command as an ARRAY so a script_dir containing spaces is never
  # word-split at invocation (#1952, Graphite). Default to the real model-ab.sh;
  # tests override with MODEL_AB_CMD, a single string we intentionally split on
  # whitespace into command+args.
  local -a ab_cmd_array
  if [ -n "${MODEL_AB_CMD:-}" ]; then
    read -ra ab_cmd_array <<<"$MODEL_AB_CMD"
  else
    ab_cmd_array=(bash "$script_dir/model-ab.sh")
  fi

  # Per-attempt token log rotation: when a retried infra attempt has already made
  # some model calls, model-ab.sh -> run-eval.sh -> engine.sh APPEND per-call
  # records to TOKEN_LOG_FILE, and those records carry no attempt identifier. A
  # single shared file would therefore BLEND an abandoned attempt's partial calls
  # with the final attempt's, over- or asymmetrically counting the per-model cost
  # the workflow uploads as identical-input evidence (#1952, codex P2). Give each
  # attempt its OWN log; after the loop, promote ONLY the final attempt's file to
  # the canonical TOKEN_LOG_FILE the workflow uploads.
  local token_log="${TOKEN_LOG_FILE:-}" attempt_log=""

  # Retry loop: re-run ONLY on infra (exit 2), up to `runs` attempts; a scored
  # verdict (0 accept / 1 regression) is final and is never re-run.
  local attempt=0 rc=0 out=""
  while [ "$attempt" -lt "$runs" ]; do
    attempt=$((attempt + 1))
    rc=0
    set +e
    # Forward the SAME evals_dir we validated against to model-ab.sh (it reads
    # EVALS_DIR from the env, default <repo>/evals). Without this, a `--evals-dir`
    # dispatch would validate one corpus but score another — the child would fall
    # back to its own default, so the accept/regression verdict would describe a
    # different held-out set than the one we checked (#1952, codeant nitpick).
    if [ -n "$token_log" ]; then
      attempt_log="${token_log}.attempt${attempt}"
      : >"$attempt_log"
      out="$(EVALS_DIR="$evals_dir" TOKEN_LOG_FILE="$attempt_log" "${ab_cmd_array[@]}" "$candidate" "$incumbent" "${sets[@]}")"
    else
      out="$(EVALS_DIR="$evals_dir" "${ab_cmd_array[@]}" "$candidate" "$incumbent" "${sets[@]}")"
    fi
    rc=$?
    set -e
    if [ "$rc" -ne 2 ]; then
      break            # scored verdict (accept/regression) — final, do not retry
    fi
    # Exit 2 is overloaded in model-ab.sh: a genuine INFRA verdict emits its
    # evidence JSON on stdout, whereas a deterministic hard/usage error (die():
    # missing tool, bad usage, held-out immutability violation) emits an `::error::`
    # line and NO JSON. Retry ONLY the transient infra verdict — re-running a hard
    # error just burns budget on a guaranteed-identical failure (#1952, codex P2).
    if ! jq -e . >/dev/null 2>&1 <<<"$out"; then
      break
    fi
    if [ "$attempt" -lt "$runs" ]; then
      echo "::warning::model-ab-dispatch: attempt $attempt classed infra (exit 2) — retrying (up to $runs)" >&2
    fi
  done

  # Promote ONLY the final attempt's token log to the canonical path the workflow
  # uploads, so the identical-inputs cost artifact reflects exactly the scored (or
  # last infra) attempt and never double-counts calls from an abandoned retry
  # (#1952, codex P2). The per-attempt files are left in place for inspection; the
  # upload step globs only the canonical TOKEN_LOG_FILE. Skip an empty final log so
  # a run that logged nothing leaves no spurious (empty) artifact.
  if [ -n "$token_log" ] && [ -n "$attempt_log" ] && [ -s "$attempt_log" ]; then
    cp -f "$attempt_log" "$token_log"
  fi

  # Pass the final evidence JSON through unchanged (stdout + optional --out).
  if [ -n "$out_file" ]; then
    printf '%s\n' "$out" >"$out_file"
  fi
  printf '%s\n' "$out"

  return "$rc"
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
