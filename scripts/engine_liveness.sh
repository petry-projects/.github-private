#!/usr/bin/env bash
# engine_liveness.sh — scheduled engine-token liveness monitor (#1587).
#
# #1587: dev-lead failed 100% of runs across 8 repos for seven days — every run
# died at the "Engine token preflight" step ("CLAUDE_CODE_OAUTH_TOKEN is not
# provided to dev-lead-reusable.") — and no alert reached a human; the fleet only
# noticed because a person went looking. This monitor is the missing escalation:
# for every repo that hosts a dev-lead or pr-review caller stub it inspects the
# most-recent run(s) of that stub and asserts they did NOT fail at the preflight
# step, then escalates a SUSTAINED, FLEET-WIDE failure differently from a flake:
#
#   AGENTS_PAUSED=true                               -> silent, no alert (a
#                                                       deliberate maintainer pause
#                                                       is never a false alarm)
#   >=2 consecutive preflight failures in >=2 repos  -> FLEET alert (the outage
#                                                       class this exists to catch)
#   otherwise any single-repo preflight failure      -> ISOLATED health-check report
#
# It also checks the GH_PAT_DON_PETRY credential's scope/expiry — a classic PAT is
# a silent single point of failure for the apply-repo-settings initiative
# (#984/#985/#1209): rotation/revocation surfaces only as an opaque 401/403 on the
# next scheduled run unless something reports it ahead of time.
#
# The DECISION logic (what counts as a preflight failure, the per-repo state, the
# fleet gate, the PAT scope/expiry classification, the report rendering) lives in
# scripts/lib/engine_liveness_detect.sh and is unit-tested there. This wrapper is
# the network layer: gh/jq gathering + report/GITHUB_ENV side-effects. It NEVER
# raises the alert itself — it emits ENGINE_LIVENESS_ESCALATION so the workflow
# can find-or-create the fleet issue only when warranted.
#
# Env vars consumed:
#   GH_TOKEN                     — org-scoped read (actions:read on target repos)
#   AGENTS_PAUSED                — "true" suppresses the monitor entirely
#   ENGINE_LIVENESS_REPOS        — optional space/comma repo override (else manifest)
#   ENGINE_LIVENESS_STUBS        — optional space/comma stub-file override
#   ENGINE_LIVENESS_MAX_RUNS     — most-recent runs to inspect per stub (default 3)
#   ENGINE_PAT_EXPIRY_WARN_DAYS  — expiry warn window in days (default 14)
#   ENGINE_PAT_REQUIRED_SCOPES   — space-separated required scopes (default "repo workflow")
#   MANIFEST_FILE                — consumer manifest path (default scripts/lib/consumer-manifest.json)
#   REPORT_FILE / ALERT_BODY_FILE — output paths (defaults below)
#   GITHUB_ENV / GITHUB_STEP_SUMMARY — written by the Actions runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/engine_liveness_detect.sh
source "${SCRIPT_DIR}/lib/engine_liveness_detect.sh"

MANIFEST_FILE="${MANIFEST_FILE:-${SCRIPT_DIR}/lib/consumer-manifest.json}"
MAX_RUNS=$(_el_int "${ENGINE_LIVENESS_MAX_RUNS:-3}")
[ "$MAX_RUNS" -ge 1 ] || MAX_RUNS=3
PAT_WARN_DAYS=$(_el_int "${ENGINE_PAT_EXPIRY_WARN_DAYS:-14}")
[ "$PAT_WARN_DAYS" -ge 1 ] || PAT_WARN_DAYS=14
PAT_REQUIRED_SCOPES="${ENGINE_PAT_REQUIRED_SCOPES:-repo workflow}"
REPORT_FILE="${REPORT_FILE:-engine_liveness_report.md}"
ALERT_BODY_FILE="${ALERT_BODY_FILE:-engine_liveness_alert.md}"
TODAY=$(date -u +%Y-%m-%d)

# Caller-stub workflow filenames to inspect in each repo. dev-lead callers use
# dev-lead.yml; pr-review callers use pr-review.yml (consumers) or
# pr-review-trigger.yml (the ring-0 self-host stub in this repo). A repo that has
# none of these under a given name is skipped silently (404 on the runs API).
DEFAULT_STUBS="dev-lead.yml pr-review.yml pr-review-trigger.yml"
STUBS="${ENGINE_LIVENESS_STUBS:-$DEFAULT_STUBS}"
STUBS="${STUBS//,/ }"

# ---------------------------------------------------------------------------
# 0. Deliberate-pause gate — never alert on a maintainer pause (#1587 scope 3).
# ---------------------------------------------------------------------------
if [ "${AGENTS_PAUSED:-false}" = "true" ]; then
  echo "::notice::engine-liveness: agent fleet deliberately paused (AGENTS_PAUSED=true) — liveness not evaluated, no alert (#1525/#1587)"
  {
    printf '# Engine-Token Liveness — %s\n\n' "$TODAY"
    printf '**Fleet paused** (`AGENTS_PAUSED=true`) — preflight liveness not evaluated and no alert raised (#1525/#1587).\n'
  } > "$REPORT_FILE"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "ENGINE_LIVENESS_PAUSED=true"
      echo "ENGINE_LIVENESS_ESCALATION=NONE"
    } >> "$GITHUB_ENV"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Enumerate the repos that host a dev-lead or pr-review caller stub.
# ---------------------------------------------------------------------------
enumerate_repos() {
  if [ -n "${ENGINE_LIVENESS_REPOS:-}" ]; then
    printf '%s\n' "${ENGINE_LIVENESS_REPOS//,/ }" | tr ' ' '\n' | sed '/^$/d'
    return 0
  fi
  if [ ! -f "$MANIFEST_FILE" ]; then
    echo "::warning::engine-liveness: manifest ${MANIFEST_FILE} not found and ENGINE_LIVENESS_REPOS unset — nothing to monitor" >&2
    return 0
  fi
  # Consumers whose pinned refs include the dev-lead or pr-review reusable.
  jq -r '
    .consumers[]
    | select([.refs[] | test("dev-lead-reusable\\.yml$|pr-review(-reusable)?\\.yml$")] | any)
    | .repo
  ' "$MANIFEST_FILE" 2>/dev/null | sort -u
}

# run_failed_at_preflight <repo> <run_id> — echo "yes" when any job step of the
# run is the engine-token preflight AND concluded "failure"; "no" when steps are
# readable and none match; "unknown" when the jobs API could not be read.
run_failed_at_preflight() {
  local repo="$1" run_id="$2" steps
  steps=$(gh api --paginate "repos/${repo}/actions/runs/${run_id}/jobs" \
    --jq '.jobs[].steps[]? | [(.name // ""), (.conclusion // "")] | @tsv' 2>/dev/null) \
    || { echo "unknown"; return 0; }
  [ -n "$steps" ] || { echo "no"; return 0; }
  local name concl
  while IFS=$'\t' read -r name concl; do
    if step_is_preflight_failure "$name" "$concl"; then
      echo "yes"
      return 0
    fi
  done <<< "$steps"
  echo "no"
}

# consecutive_preflight_failures <repo> <stub_file> — echo the count of leading
# (most-recent-first) COMPLETED runs of <stub_file> that failed at the preflight
# step. The streak stops at the first run that did NOT fail at preflight. Echoes
# "SKIP" when the workflow does not exist in the repo (so the stub is not counted
# as failing just because it is absent).
consecutive_preflight_failures() {
  local repo="$1" stub="$2" run_ids
  run_ids=$(gh api "repos/${repo}/actions/workflows/${stub}/runs?status=completed&per_page=${MAX_RUNS}" \
    --jq '.workflow_runs[].id' 2>/dev/null) || { echo "SKIP"; return 0; }
  [ -n "$run_ids" ] || { echo "SKIP"; return 0; }

  local streak=0 rid verdict
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    verdict=$(run_failed_at_preflight "$repo" "$rid")
    if [ "$verdict" = "yes" ]; then
      streak=$(( streak + 1 ))
    else
      # A passing/other-failure/unknown run breaks the consecutive streak.
      break
    fi
  done <<< "$run_ids"
  echo "$streak"
}

# ---------------------------------------------------------------------------
# 2. Per-repo × per-stub inspection.
# ---------------------------------------------------------------------------
rows_file=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$rows_file"' EXIT

sustained_repos=0   # repos with >=1 stub in OUTAGE (>=2 consecutive preflight failures)
failing_repos=0     # repos with >=1 stub failing at all (FAIL or OUTAGE)
inspected_stubs=0

mapfile -t REPOS < <(enumerate_repos)
echo "=== Engine-Token Liveness Monitor — #1587 ==="
echo "  Date:        $TODAY"
echo "  Repos:       ${#REPOS[@]}"
echo "  Stubs:       $STUBS"
echo "  Runs/stub:   $MAX_RUNS"
echo ""

for repo in "${REPOS[@]}"; do
  [ -n "$repo" ] || continue
  repo_worst="OK"   # OK < FAIL < OUTAGE
  for stub in $STUBS; do
    consec=$(consecutive_preflight_failures "$repo" "$stub")
    [ "$consec" = "SKIP" ] && continue
    inspected_stubs=$(( inspected_stubs + 1 ))
    state=$(repo_liveness_state "$consec")
    printf '%s\t%s\t%s\t%s\n' "$repo" "$stub" "$state" "$consec" >> "$rows_file"
    echo "  ${repo} / ${stub}: ${state} (${consec} consecutive preflight failure(s))"
    case "$state" in
      OUTAGE) repo_worst="OUTAGE" ;;
      FAIL)   [ "$repo_worst" = "OUTAGE" ] || repo_worst="FAIL" ;;
    esac
  done
  case "$repo_worst" in
    OUTAGE) sustained_repos=$(( sustained_repos + 1 )); failing_repos=$(( failing_repos + 1 )) ;;
    FAIL)   failing_repos=$(( failing_repos + 1 )) ;;
  esac
done

escalation=$(fleet_escalation "$sustained_repos" "$failing_repos")
echo ""
echo "Inspected ${inspected_stubs} stub(s); sustained-outage repos: ${sustained_repos}; failing repos: ${failing_repos}."
echo "Escalation: ${escalation}"

# ---------------------------------------------------------------------------
# 3. GH_PAT_DON_PETRY scope/expiry (#1587 scope 4).
# ---------------------------------------------------------------------------
pat_scope_state="UNKNOWN"
pat_missing=""
pat_expiry="UNKNOWN"
pat_scopes_seen=""
pat_expiry_raw=""
if resp=$(gh api -i user 2>/dev/null); then
  pat_scopes_seen=$(printf '%s\n' "$resp" | grep -i '^x-oauth-scopes:' | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  pat_expiry_raw=$(printf '%s\n' "$resp" | grep -i '^github-authentication-token-expiration:' | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  pat_missing=$(pat_missing_scopes "$pat_scopes_seen" "$PAT_REQUIRED_SCOPES")
  if [ -z "$pat_missing" ]; then
    pat_scope_state="OK"
  else
    pat_scope_state="MISSING"
  fi
  pat_expiry=$(pat_expiry_state "$pat_expiry_raw" "$PAT_WARN_DAYS")
else
  echo "::warning::engine-liveness: could not read GH_PAT identity (gh api user) — PAT scope/expiry not evaluated"
fi
echo "  GH_PAT_DON_PETRY scopes: '${pat_scopes_seen:-<none/fine-grained>}' -> ${pat_scope_state}${pat_missing:+ (missing: ${pat_missing})}"
echo "  GH_PAT_DON_PETRY expiry: '${pat_expiry_raw:-<none>}' -> ${pat_expiry}"

# ---------------------------------------------------------------------------
# 4. Render report + fleet-alert body + GITHUB_ENV flags.
# ---------------------------------------------------------------------------
{
  printf '# Engine-Token Liveness — %s\n\n' "$TODAY"
  printf '**Escalation:** `%s` — %s\n\n' "$escalation" "$(escalation_headline "$escalation")"
  printf '**Repos monitored:** %s | **Stubs inspected:** %s | **Sustained-outage repos:** %s | **Failing repos:** %s\n\n' \
    "${#REPOS[@]}" "$inspected_stubs" "$sustained_repos" "$failing_repos"
  printf '## Per-repo caller-stub preflight liveness\n\n'
  render_liveness_table "$rows_file"
  printf '\n## Credential — GH_PAT_DON_PETRY (#1587 scope 4)\n\n'
  printf '| Check | Value | State |\n|---|---|---|\n'
  printf '| Scopes | `%s` | %s |\n' "${pat_scopes_seen:-<none/fine-grained>}" "$pat_scope_state${pat_missing:+ (missing: ${pat_missing})}"
  printf '| Expiry | `%s` | %s |\n' "${pat_expiry_raw:-<none>}" "$pat_expiry"
} > "$REPORT_FILE"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"

# Fleet-alert body (only meaningful when escalation == FLEET; the workflow gates
# the actual issue create/update on ENGINE_LIVENESS_ESCALATION).
{
  printf '## %s\n\n' "$(escalation_headline "$escalation")"
  printf 'The engine-token preflight is failing on **>=%s consecutive runs in >=2 repos** — ' "$ENGINE_SUSTAINED_RUNS"
  printf 'the fleet-outage class from #1587. A job `success` conclusion elsewhere is **not** '
  printf 'evidence the engine is healthy. This is distinct from routine health-check output.\n\n'
  printf 'To pause deliberately, set `AGENTS_PAUSED=true` instead of withholding the secret '
  printf '(this monitor stays silent on a deliberate pause). Otherwise restore '
  printf '`CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) in the affected repos/org.\n\n'
  render_liveness_table "$rows_file"
} > "$ALERT_BODY_FILE"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "ENGINE_LIVENESS_PAUSED=false"
    echo "ENGINE_LIVENESS_ESCALATION=${escalation}"
    echo "ENGINE_LIVENESS_SUSTAINED_REPOS=${sustained_repos}"
    echo "ENGINE_LIVENESS_FAILING_REPOS=${failing_repos}"
    echo "ENGINE_LIVENESS_PAT_SCOPE_STATE=${pat_scope_state}"
    echo "ENGINE_LIVENESS_PAT_EXPIRY_STATE=${pat_expiry}"
  } >> "$GITHUB_ENV"
fi

echo ""
echo "Report written to ${REPORT_FILE} ($(wc -c < "$REPORT_FILE") bytes)"
echo "=== Engine-token liveness monitor complete ==="
