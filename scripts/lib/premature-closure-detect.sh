#!/usr/bin/env bash
# premature-closure-detect.sh — the premature-closure DETECTION net (issue #1077).
#
# #1077: the dev-lead agent closed tracking issues as `completed` without the fix
# actually landing on `main` — the issue closed, but the problem it described was
# still present, with NO merged PR that resolved it. The mechanical families were
# genuinely fixed; the harder families were closed on task-attempt rather than on
# a merged, verifying change. The org SonarCloud open-finding count was unchanged
# even after all the tracking issues closed as `state_reason = completed`.
#
# This is a set of PURE functions: given an issue's already-gathered close
# metadata, decide whether it is a premature-closure CANDIDATE. It never mutates
# an issue — surfacing/routing (report, re-open, re-label) is the caller's job
# (scripts/premature-closure-audit.sh).
#
#   premature_closure_reasons <state_reason> <minutes_open> <has_merged_closing_pr>
#     Prints one human-readable reason line when the issue is a candidate;
#     nothing otherwise. This is the unit under test.
#   is_premature_closure <state_reason> <minutes_open> <has_merged_closing_pr>
#     Exit 0 when a candidate, 1 otherwise.
#   minutes_between <iso_from> <iso_to>
#     Whole minutes between two ISO-8601 timestamps (clamped at 0, deterministic).
#   generate_premature_closure_report <candidates_tsv_file>
#     Renders the markdown report section from a candidates TSV.
#
# A candidate is the CONJUNCTION of three conditions (recommended action #3),
# chosen so a normal human close does NOT false-positive:
#   1. state_reason == completed        (closed as "done", not "not planned")
#   2. NO merged closing PR              (nothing actually landed the fix)
#   3. closed within N minutes of open   (the fast task-attempt tell)
# The window N is a SOFT, env-overridable threshold (strict <, matching the
# "within N minutes of open" wording).

# Soft threshold — an issue must have closed within this many minutes of opening
# to count as the fast dev-lead task-attempt close. Env-overridable.
readonly _PC_THRESHOLD_DEFAULT=30
: "${PC_MAX_OPEN_MINUTES:=$_PC_THRESHOLD_DEFAULT}"   # closed < this many minutes after open

# _pc_int <value>
#   Echo the value as a non-negative integer, or 0 for empty/non-numeric input.
#   Keeps a bad metric from breaking the integer comparisons below.
_pc_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# _pc_threshold <value> <default>
#   Like _pc_int but falls back to <default> instead of 0 for empty/non-numeric
#   input, so a bad env override can never silently set the window to 0 and
#   suppress every flag.
_pc_threshold() {
  local val="${1:-}" default="${2:-0}"
  case "$val" in
    ''|*[!0-9]*) echo "$default" ;;
    *) echo "$val" ;;
  esac
}

# _pc_is_truthy <value>
#   Exit 0 when <value> denotes "yes" (true/1/yes, case-insensitive), 1 otherwise.
#   Used to interpret the has_merged_closing_pr flag. Anything else (false/0/no/
#   empty/unknown) is NOT truthy — but note the caller must fail SAFE (treat an
#   undeterminable PR state as "has merged PR") so the audit never re-opens on a
#   lookup it could not resolve.
_pc_is_truthy() {
  local v="${1:-}"
  case "${v,,}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

# premature_closure_reasons <state_reason> <minutes_open> <has_merged_closing_pr>
#   Print a reason line when all three candidate conditions hold; empty otherwise.
premature_closure_reasons() {
  local state_reason minutes has_pr max_minutes
  state_reason="${1:-}"
  state_reason="${state_reason,,}"
  minutes=$(_pc_int "${2:-0}")
  has_pr="${3:-}"
  max_minutes=$(_pc_threshold "${PC_MAX_OPEN_MINUTES}" "$_PC_THRESHOLD_DEFAULT")

  # 1. Only a "completed" close is premature; "not_planned"/other are legitimate.
  [ "$state_reason" = "completed" ] || return 0
  # 2. A merged closing PR means the fix actually landed — not premature.
  if _pc_is_truthy "$has_pr"; then
    return 0
  fi
  # 3. Must be the fast task-attempt close (strict <, matching "within N minutes").
  [ "$minutes" -lt "$max_minutes" ] || return 0

  printf 'closed as completed %sm after open with no merged closing PR (<%sm window)\n' \
    "$minutes" "$max_minutes"
  return 0
}

# is_premature_closure <state_reason> <minutes_open> <has_merged_closing_pr>
#   Exit 0 when the issue is a premature-closure candidate, 1 otherwise.
is_premature_closure() {
  local reasons
  reasons=$(premature_closure_reasons "$@")
  [ -n "$reasons" ]
}

# minutes_between <iso_from> <iso_to>
#   Whole minutes between two ISO-8601 timestamps. Negative intervals clamp to 0;
#   unparseable input yields 0. Deterministic — no reliance on the current time.
minutes_between() {
  local from="${1:-}" to="${2:-}" from_epoch to_epoch
  from_epoch=$(date -u -d "$from" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$from" +%s 2>/dev/null || true)
  to_epoch=$(date -u -d "$to" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$to" +%s 2>/dev/null || true)
  if [ -z "$from_epoch" ] || [ -z "$to_epoch" ]; then
    echo 0
    return 0
  fi
  local diff=$(( to_epoch - from_epoch ))
  [ "$diff" -lt 0 ] && diff=0
  echo $(( diff / 60 ))
}

# generate_premature_closure_report <candidates_tsv_file>
#   Render the "Premature-Closure Candidates" markdown section for the audit
#   report. Input TSV rows: issue_number <TAB> html_url <TAB> title <TAB> reason.
#   An empty/missing file prints an all-clear line and no table, so a clean run
#   still gets an explicit signal.
generate_premature_closure_report() {
  local f="${1:-}"
  local max_minutes
  max_minutes=$(_pc_threshold "${PC_MAX_OPEN_MINUTES}" "$_PC_THRESHOLD_DEFAULT")

  printf '## Premature-Closure Candidates\n\n'
  printf 'Issues closed as `completed` within %sm of opening with **no merged closing PR** ' "$max_minutes"
  printf '(the fix never landed on the default branch). See #1077 — dev-lead should '
  printf 'leave such issues open and labeled `dev-lead:needs-human`, not close them as done.\n\n'

  if [ -z "$f" ] || [ ! -s "$f" ]; then
    printf 'No prematurely-closed issue detected in the audited window.\n'
    return 0
  fi

  printf '| Issue | Title | Why flagged |\n'
  printf '|---|---|---|\n'
  local num url title reason
  while IFS=$'\t' read -r num url title reason; do
    [ -n "$num" ] || continue
    title=${title//$'|'/'\|'}
    title=${title//$'\n'/ }
    reason=${reason//$'|'/'\|'}
    reason=${reason//$'\n'/ }
    printf '| [#%s](%s) | %s | %s |\n' "$num" "$url" "$title" "$reason"
  done < "$f"
}
