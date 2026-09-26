#!/usr/bin/env bash
set -euo pipefail
# model-ab-dispatch.sh — the workflow_dispatch runner's testable wrapper around
# scripts/evals/model-ab.sh (#1950, epic #1895; unblocks #1899 and #1901).
#
# Usage:
#   model-ab-dispatch.sh --candidate M --incumbent M \
#     [--sets "triage deep-review"] [--runs N] [--evals-dir DIR] [--out FILE]
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

# mad_clamp_runs <value> — print the run budget clamped to [1,3]. A value that is
# not a positive integer (empty, non-numeric, fractional, <=0) degrades to the
# floor (1) so a bad input can never trigger an unbounded — or zero — run.
mad_clamp_runs() {
  local v="${1:-}"
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$MAD_RUNS_MIN"
    return 0
  fi
  # Strip leading zeros safely; base-10 arithmetic on the validated integer.
  local n=$((10#$v))
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
  local evals_dir="${EVALS_DIR:-$repo_root/evals}" out_file=""
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
      -h|--help)   grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *)  die "unexpected argument: $1" ;;
    esac
  done

  [ -n "$candidate" ] || die "usage: model-ab-dispatch.sh --candidate M --incumbent M [--sets S] [--runs N]"
  [ -n "$incumbent" ] || die "usage: model-ab-dispatch.sh --candidate M --incumbent M [--sets S] [--runs N]"
  [ -n "$evals_dir" ] || die "evals_dir is empty — would check root directory; set EVALS_DIR or use --evals-dir"

  # Split the whitespace-delimited sets input into an array (the workflow passes a
  # single string, e.g. "triage deep-review").
  local sets=()
  read -ra sets <<<"$sets_raw"

  # Fail fast on an unknown set BEFORE any arm runs (AC #1) — no token is spent.
  local bad
  if ! bad="$(mad_validate_sets "$evals_dir" "${sets[@]}")"; then
    if [ "$bad" = "no sets requested" ]; then
      die "no sets requested — expected one or more of the evals/<set>/holdout sets"
    fi
    die "unknown set '$bad' — no evals/$bad/holdout under $evals_dir (frozen held-out sets only)"
  fi

  local runs; runs="$(mad_clamp_runs "$runs_raw")"

  # The A/B command. Default to the real model-ab.sh; tests override MODEL_AB_CMD.
  local ab_cmd="${MODEL_AB_CMD:-bash $script_dir/model-ab.sh}"

  # Retry loop: re-run ONLY on infra (exit 2), up to `runs` attempts; a scored
  # verdict (0 accept / 1 regression) is final and is never re-run.
  local attempt=0 rc=0 out=""
  while [ "$attempt" -lt "$runs" ]; do
    attempt=$((attempt + 1))
    rc=0
    # shellcheck disable=SC2086 # ab_cmd is an intentional command+args split
    out="$($ab_cmd "$candidate" "$incumbent" "${sets[@]}")" || rc=$?
    if [ "$rc" -ne 2 ]; then
      break            # scored verdict (accept/regression) — final, do not retry
    fi
    if [ "$attempt" -lt "$runs" ]; then
      echo "::warning::model-ab-dispatch: attempt $attempt classed infra (exit 2) — retrying (up to $runs)" >&2
    fi
  done

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
