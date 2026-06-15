#!/usr/bin/env bash
set -euo pipefail
# notify-eval-health.sh — surface the daily Skill Eval outcome as a single,
# de-duplicated tracking issue (issue #747, epic #581).
#
# The Skill Eval Report (skill-eval-report.yml) runs the deterministic holdout
# scorer daily and is intentionally NON-BLOCKING: a regression or a scorer
# hard-error never fails the workflow. Before this script its only output was a
# step summary / artifact / annotation — effectively invisible. This notifier
# makes the outcome visible WITHOUT making it blocking:
#
#   outcome=regression | error -> open OR update a single `eval-health` tracking
#                                 issue (idempotent: the same issue is rewritten
#                                 in place, never a new one per day).
#   outcome=pass               -> if a tracking issue is currently open, comment
#                                 + close it (recovery); otherwise do NOTHING
#                                 (a healthy run must create zero noise).
#
# De-dup key: the single open issue carrying $EVAL_HEALTH_LABEL whose title
# matches the stable per-skill title below. Stable title => one issue, rewritten.
#
# This script only adds visibility; it never changes the scorer's pass/fail
# decision or gates any merge.
#
# Env:
#   REPO               owner/repo (required)
#   OUTCOME            pass | regression | error (required)
#   SKILL              skill whose holdout was scored (default: triage)
#   REPORT_PATH        eval-report.json from the scorer (default: ./eval-report.json)
#   RUN_URL            link back to the workflow run (optional but recommended)
#   EVAL_HEALTH_LABEL  tracking-issue label (default: eval-health)
#   DRY_RUN            "1"/"true" => render + log intent, never mutate via gh
#
# Exit codes: 0 success (including the no-op healthy path); 1 bad usage / gh error.

REPO="${REPO:?REPO required}"
OUTCOME="${OUTCOME:?OUTCOME required (pass|regression|error)}"
SKILL="${SKILL:-triage}"
REPORT_PATH="${REPORT_PATH:-eval-report.json}"
RUN_URL="${RUN_URL:-}"
EVAL_HEALTH_LABEL="${EVAL_HEALTH_LABEL:-eval-health}"

case "$OUTCOME" in
  pass|regression|error) ;;
  *) echo "::error::notify-eval-health: unknown OUTCOME '$OUTCOME' (expected pass|regression|error)" >&2; exit 1 ;;
esac

# Stable, per-skill title so the lookup always lands on the same issue.
TITLE="Skill eval health — \`${SKILL}\` (holdout)"

_is_dry_run() { [[ "${DRY_RUN:-0}" == "1" || "${DRY_RUN:-0}" == "true" ]]; }

# Locate the single open tracking issue (scoped by label) whose title matches.
# gh emits the candidate list as JSON; system jq does the title de-dup so the
# expression is unambiguous (no reliance on gh's embedded jq arg passing).
find_existing() {
  if _is_dry_run; then
    printf '%s' "${DRY_RUN_EXISTING:-}"
    return 0
  fi
  gh issue list --repo "$REPO" --label "$EVAL_HEALTH_LABEL" --state open \
    --json number,title 2>/dev/null \
    | jq -r --arg t "$TITLE" 'map(select(.title == $t)) | (.[0].number // "")' 2>/dev/null \
    || true
}

# Render the tracking-issue body for a regression/error outcome to stdout.
render_body() {
  echo "## Skill eval health — \`${SKILL}\` (holdout)"
  echo ""
  if [ "$OUTCOME" = "error" ]; then
    echo "**Outcome:** \`error\` — the scorer hard-errored (bad usage / missing tooling)."
    echo ""
    echo "_The eval run could not produce a score. This is report-only (Phase 1): it does not block any merge — but it does mean the held-out set is currently un-scored and needs a look._"
  else
    echo "**Outcome:** \`regression\` — at least one held-out case regressed."
    echo ""
    echo "_Report-only (Phase 1): a regression does not fail CI or block any merge._"
  fi
  echo ""

  if jq -e . "$REPORT_PATH" >/dev/null 2>&1; then
    local score passed total failed
    score=$(jq -r '.score // "N/A"' "$REPORT_PATH")
    passed=$(jq -r '.passed // "0"' "$REPORT_PATH")
    total=$(jq -r '.total // "0"' "$REPORT_PATH")
    failed=$(jq -r '.failed // "0"' "$REPORT_PATH")
    echo "| skill | score | passed | failed | total |"
    echo "|-------|-------|--------|--------|-------|"
    echo "| \`${SKILL}\` | ${score} | ${passed} | ${failed} | ${total} |"
    if [ "${failed}" != "0" ]; then
      echo ""
      echo "### Regressed cases"
      jq -r '(.cases | select(type == "array") // []) | .[] | select(.pass | not) | "- `\(.id // \"unknown\")` — expected \(.expected|tojson), got \(.actual|tojson)"' "$REPORT_PATH"
    fi
  else
    echo "Scorer produced no parseable JSON report (outcome: \`${OUTCOME}\`)."
  fi

  echo ""
  if [ -n "$RUN_URL" ]; then
    echo "[View the workflow run](${RUN_URL})"
  fi
  echo ""
  echo "<sub>Auto-managed by \`notify-eval-health.sh\` — this issue is updated in place each run and closed automatically on recovery.</sub>"
}

existing="$(find_existing)"

case "$OUTCOME" in
  pass)
    if [ -z "$existing" ]; then
      echo "eval health pass: no open tracking issue — nothing to do."
      exit 0
    fi
    comment="$(mktemp)"
    trap 'rm -f "$comment"' EXIT
    {
      echo "✅ **Recovered** — the \`${SKILL}\` holdout eval passed; all held-out cases are green again."
      echo ""
      [ -n "$RUN_URL" ] && echo "[View the workflow run](${RUN_URL})"
    } >"$comment"
    if _is_dry_run; then
      echo "[dry-run] would comment on and close eval-health issue #${existing}"
      exit 0
    fi
    gh issue comment "$existing" --repo "$REPO" --body-file "$comment" >/dev/null
    gh issue close "$existing" --repo "$REPO" >/dev/null
    echo "closed eval-health issue #${existing} (recovered)"
    ;;

  regression|error)
    body="$(mktemp)"
    trap 'rm -f "$body"' EXIT
    render_body >"$body"
    if _is_dry_run; then
      echo "[dry-run] would $( [ -n "$existing" ] && echo "update #${existing}" || echo "create" ) eval-health issue '${TITLE}'"
      exit 0
    fi
    if [ -n "$existing" ]; then
      gh issue edit "$existing" --repo "$REPO" --body-file "$body" >/dev/null
      echo "updated eval-health issue #${existing}"
    else
      # Ensure the label exists (ignore failure if it already does).
      gh label create "$EVAL_HEALTH_LABEL" --repo "$REPO" \
        --description "Skill-eval holdout health tracking" --color d93f0b 2>/dev/null || true
      url="$(gh issue create --repo "$REPO" --title "$TITLE" \
        --label "$EVAL_HEALTH_LABEL" --body-file "$body")"
      echo "created eval-health issue ${url}"
    fi
    ;;
esac
