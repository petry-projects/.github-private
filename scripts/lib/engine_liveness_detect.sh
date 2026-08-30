#!/usr/bin/env bash
# engine_liveness_detect.sh — the engine-token liveness DECISION layer (#1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step with
# "CLAUDE_CODE_OAUTH_TOKEN is not provided to dev-lead-reusable." — and NOTHING
# escalated to a human. Two gaps let a total engine outage run silently:
#   1. a sustained fleet-wide preflight failure only accumulated in periodic
#      health reports instead of escalating differently from a flaky check;
#   2. pr-review had no preflight, so a tokenless run failed OPEN (exit success
#      having reviewed nothing) and its green conclusion was cited as "healthy".
#
# This is a set of PURE functions: given already-gathered run/step metadata,
# decide — per repo — whether the engine-token preflight is failing, and whether
# the aggregate warrants a FLEET-level alert (the outage class this monitor
# exists to catch) vs. ISOLATED single-repo health-check reporting vs. NONE. It
# also classifies a credential's scope/expiry (GH_PAT_DON_PETRY, a classic PAT
# whose silent rotation surfaces only as an opaque 401/403 on the next run). It
# NEVER touches the network or mutates anything — the gh/jq gathering and the
# alert/report side-effects are the caller's job (scripts/engine_liveness.sh).
#
# Escalation contract (issue scope 3), all keyed on the preflight step outcome:
#   AGENTS_PAUSED=true                               -> silent, no alert (caller)
#   >=2 consecutive preflight failures in >=2 repos  -> FLEET alert
#   otherwise any single-repo preflight failure      -> ISOLATED (routine report)

# The verbatim step name both dev-lead-reusable.yml and pr-review.yml carry. A
# run that fails HERE is the outage signature; a run that fails at a LATER step
# is a different problem this monitor does not own.
readonly ENGINE_PREFLIGHT_STEP_NAME="Engine token preflight"

# Sustained-failure threshold: a repo is in OUTAGE once its most-recent runs show
# this many consecutive preflight failures. Two = "not a one-off flake".
readonly ENGINE_SUSTAINED_RUNS=2

# _el_int <value> — echo a non-negative integer, or 0 for empty/non-numeric input.
# Keeps a bad metric from breaking the integer comparisons below.
_el_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# is_preflight_step <step_name>
#   Exit 0 when the step name is the engine-token preflight (substring match, so
#   the "(#1525)" suffix and any future annotation still match).
is_preflight_step() {
  case "${1:-}" in
    *"$ENGINE_PREFLIGHT_STEP_NAME"*) return 0 ;;
    *) return 1 ;;
  esac
}

# step_is_preflight_failure <step_name> <conclusion>
#   Exit 0 only when the preflight step itself concluded "failure" — the exact
#   outage signature. A failure at any OTHER step is deliberately NOT a preflight
#   failure (the monitor must not conflate an unrelated red run with a token
#   outage), and a passing preflight is never a failure.
step_is_preflight_failure() {
  is_preflight_step "${1:-}" || return 1
  [ "${2:-}" = "failure" ]
}

# repo_liveness_state <consecutive_preflight_failures>
#   Classify one repo's caller-stub health from the number of consecutive
#   most-recent runs that failed at the preflight step:
#     >=2 -> OUTAGE (sustained; the outage class)
#      1  -> FAIL   (a single most-recent failure; not yet sustained)
#      0  -> OK
repo_liveness_state() {
  local n; n=$(_el_int "${1:-0}")
  if [ "$n" -ge "$ENGINE_SUSTAINED_RUNS" ]; then
    echo "OUTAGE"
  elif [ "$n" -ge 1 ]; then
    echo "FAIL"
  else
    echo "OK"
  fi
}

# fleet_escalation <sustained_repo_count> <any_failure_repo_count>
#   The fleet gate is about BREADTH, not depth: only a sustained (>=2 consecutive)
#   preflight failure across >=2 repos is the fleet outage class. One repo alone —
#   however many consecutive failures — is ISOLATED, routed to routine reporting.
#     sustained_repos >= 2 -> FLEET
#     else any_failure  >= 1 -> ISOLATED
#     else                    -> NONE
fleet_escalation() {
  local sustained any
  sustained=$(_el_int "${1:-0}")
  any=$(_el_int "${2:-0}")
  if [ "$sustained" -ge 2 ]; then
    echo "FLEET"
  elif [ "$any" -ge 1 ]; then
    echo "ISOLATED"
  else
    echo "NONE"
  fi
}

# escalation_headline <escalation>
#   One-line human summary for a level — reused in the step summary and the
#   fleet-alert issue body so both read consistently.
escalation_headline() {
  case "${1:-}" in
    FLEET)
      echo "FLEET-WIDE ENGINE-TOKEN OUTAGE — the preflight is failing on >=2 consecutive runs in >=2 repos (#1587)"
      ;;
    ISOLATED)
      echo "Isolated engine-token preflight failure — single-repo, routed to routine health-check reporting"
      ;;
    NONE)
      echo "All engine-token preflights healthy — no repo is failing at the preflight step"
      ;;
    *)
      echo "Engine-token liveness: unknown escalation state '${1:-}'"
      ;;
  esac
}

# _el_to_epoch <value>
#   Best-effort ISO/RFC parse to epoch seconds via GNU/BSD date. Empty on failure.
_el_to_epoch() {
  local v="${1:-}"
  [ -n "$v" ] || { echo ""; return 0; }
  date -u -d "$v" +%s 2>/dev/null \
    || date -u -jf "%Y-%m-%d %H:%M:%S %Z" "$v" +%s 2>/dev/null \
    || echo ""
}

# pat_expiry_state <expiration_value> [warn_days] [now_epoch]
#   Classify a PAT's expiry from the value GitHub returns in the
#   `github-authentication-token-expiration` response header:
#     empty                       -> NO_EXPIRY  (a classic PAT set to never expire)
#     unparseable                 -> UNKNOWN
#     already past now            -> EXPIRED
#     within warn_days of now      -> EXPIRING
#     else                        -> OK
#   warn_days defaults to 14; now_epoch defaults to the current time (injectable
#   so the boundary is deterministically testable).
pat_expiry_state() {
  local value warn_days now exp
  value="${1:-}"
  warn_days=$(_el_int "${2:-14}")
  [ "$warn_days" -eq 0 ] && warn_days=14
  now="${3:-$(date -u +%s)}"

  if [ -z "$value" ]; then
    echo "NO_EXPIRY"
    return 0
  fi
  exp=$(_el_to_epoch "$value")
  if [ -z "$exp" ]; then
    echo "UNKNOWN"
    return 0
  fi
  if [ "$exp" -le "$now" ]; then
    echo "EXPIRED"
  elif [ "$exp" -le $(( now + warn_days * 86400 )) ]; then
    echo "EXPIRING"
  else
    echo "OK"
  fi
}

# pat_missing_scopes <scopes_csv> <required_scopes>
#   Echo (space-separated) the required scopes NOT present in <scopes_csv>. The
#   scopes string is the `x-oauth-scopes` header value ("repo, workflow, read:org");
#   required is a space-separated list. Exact-token match (no umbrella expansion).
#   Empty output means every required scope is present.
pat_missing_scopes() {
  local scopes_csv="${1:-}" required="${2:-}"
  # Normalise the CSV to space-delimited tokens for whole-word matching.
  local normalized=" ${scopes_csv//,/ } "
  local missing="" scope
  for scope in $required; do
    case "$normalized" in
      *" $scope "*) : ;;
      *) missing="${missing:+$missing }$scope" ;;
    esac
  done
  printf '%s' "$missing"
}

# pat_scopes_ok <scopes_csv> <required_scopes>
#   Exit 0 when no required scope is missing, non-zero otherwise.
pat_scopes_ok() {
  local missing
  missing=$(pat_missing_scopes "$@")
  [ -z "$missing" ]
}

# render_liveness_table <rows_tsv_file>
#   Render the per-repo markdown table from a TSV whose rows are
#   repo <TAB> stub <TAB> state <TAB> consecutive_preflight_failures.
#   An empty/missing file prints an explicit all-clear line and no table, so a
#   clean run still emits a signal (same shape as the health-check reports).
render_liveness_table() {
  local f="${1:-}"
  if [ -z "$f" ] || [ ! -s "$f" ]; then
    printf 'No engine-token preflight failure detected across the monitored caller stubs.\n'
    return 0
  fi
  printf '| Repo | Stub | State | Consecutive preflight failures |\n'
  printf '|---|---|---|---|\n'
  local repo stub state consec
  while IFS=$'\t' read -r repo stub state consec; do
    [ -n "$repo" ] || continue
    printf '| %s | `%s` | %s | %s |\n' "$repo" "$stub" "$state" "$consec"
  done < "$f"
}
