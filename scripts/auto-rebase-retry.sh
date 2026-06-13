#!/usr/bin/env bash
set -euo pipefail
# auto-rebase-retry.sh — self-heal a failed Auto-rebase workflow run.
#
# The Auto-rebase workflow handles *merge conflicts* gracefully (it posts a
# sentinel comment that dev-lead's `rebase` intent then resolves). But when the
# run itself fails — a transient GitHub API error, a rate-limit, an infra
# hiccup — no sentinel is posted and nothing retries it. This handler closes
# that gap: on a failed run it re-runs the failed jobs, bounded by the run's
# attempt counter so a deterministically-broken run cannot loop forever. When
# the attempt cap is reached it stops retrying and surfaces a warning so a
# human can intervene.
#
# Bounding works without external state: `gh run rerun --failed` increments the
# run's attempt counter, and each completed re-run fires another workflow_run
# event, so RUN_ATTEMPT naturally climbs toward MAX_ATTEMPTS. (Chaining past the
# first retry requires GH_PAT_WORKFLOWS — re-runs requested via the default
# GITHUB_TOKEN do not re-fire workflow_run events.)
#
# Env inputs:
#   CONCLUSION    — github.event.workflow_run.conclusion
#   RUN_ID        — github.event.workflow_run.id
#   RUN_ATTEMPT   — github.event.workflow_run.run_attempt (defaults to 1)
#   WORKFLOW_NAME — github.event.workflow_run.name (logging only)
#   HTML_URL      — github.event.workflow_run.html_url (logging only)
#   REPO          — owner/repo (defaults to GITHUB_REPOSITORY)
#   MAX_ATTEMPTS  — give up after this many attempts (default: 3)
#   DRY_RUN       — if "true", log intent but do not call gh (default: false)
#   GITHUB_STEP_SUMMARY — path for the run summary (optional)
#
# Always exits 0: a handler failure would itself be noise. Outcomes are surfaced
# via ::notice:: / ::warning:: annotations and the step summary instead.

CONCLUSION="${CONCLUSION:-}"
RUN_ID="${RUN_ID:-}"
RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Auto-rebase}"
HTML_URL="${HTML_URL:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
DRY_RUN="${DRY_RUN:-false}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

summary() { echo "$1" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true; }

# Default any non-integer attempt to 1 so a malformed payload still retries once
# rather than silently skipping or crashing under `set -e`.
if ! [[ "$RUN_ATTEMPT" =~ ^[0-9]+$ ]]; then
  echo "::notice::RUN_ATTEMPT '${RUN_ATTEMPT}' is not an integer — defaulting to 1"
  RUN_ATTEMPT=1
fi
if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$MAX_ATTEMPTS" -lt 1 ]; then
  MAX_ATTEMPTS=3
fi

# ── guard: only act on failed runs ────────────────────────────────────────────
if [[ "$CONCLUSION" != "failure" ]]; then
  echo "::notice::${WORKFLOW_NAME} run concluded '${CONCLUSION:-unknown}' (not failure) — nothing to retry"
  exit 0
fi

# ── guard: need a run id to retry ─────────────────────────────────────────────
if [ -z "$RUN_ID" ]; then
  echo "::warning::No RUN_ID provided — cannot retry the failed ${WORKFLOW_NAME} run"
  exit 0
fi

# ── give up once the attempt cap is reached ───────────────────────────────────
if [ "$RUN_ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
  echo "::warning::${WORKFLOW_NAME} run ${RUN_ID} failed after ${RUN_ATTEMPT} attempt(s) (cap ${MAX_ATTEMPTS}) — giving up, manual intervention required"
  summary "### Auto-rebase retry exhausted"
  summary ""
  summary "Run [\`${RUN_ID}\`](${HTML_URL}) failed after **${RUN_ATTEMPT}** attempt(s) (cap ${MAX_ATTEMPTS}). Automated retries are exhausted — a maintainer should investigate manually."
  exit 0
fi

next_attempt=$(( RUN_ATTEMPT + 1 ))
echo "::notice::${WORKFLOW_NAME} run ${RUN_ID} failed on attempt ${RUN_ATTEMPT} — re-running failed jobs (attempt ${next_attempt}/${MAX_ATTEMPTS})"

if [ "$DRY_RUN" = "true" ]; then
  echo "  [dry-run] would run: gh run rerun ${RUN_ID} --failed (repo ${REPO})"
  summary "### Auto-rebase retry (dry-run)"
  summary "Would re-run failed jobs of run \`${RUN_ID}\` (attempt ${next_attempt}/${MAX_ATTEMPTS})."
  exit 0
fi

if gh run rerun "$RUN_ID" --failed ${REPO:+--repo "$REPO"}; then
  echo "::notice::Re-run of run ${RUN_ID} requested (attempt ${next_attempt}/${MAX_ATTEMPTS})"
  summary "### Auto-rebase retry dispatched"
  summary "Re-ran failed jobs of run [\`${RUN_ID}\`](${HTML_URL}) — attempt ${next_attempt}/${MAX_ATTEMPTS}."
else
  echo "::warning::Failed to request re-run of run ${RUN_ID} — manual intervention may be required"
  summary "### Auto-rebase retry failed to dispatch"
  summary "Could not re-run run [\`${RUN_ID}\`](${HTML_URL}). A maintainer should re-run it manually."
fi

exit 0
