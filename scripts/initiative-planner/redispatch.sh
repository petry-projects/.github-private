#!/usr/bin/env bash
# redispatch.sh — bridge a `discussion [labeled]` event to a supported event.
#
# The initiative planner's documented primary trigger is a maintainer adding
# `idea:approved` to an Ideas Discussion, which fires `on: discussion [labeled]`.
# But the planner's "Plan the initiative" step uses claude-code-action, which
# only recognizes issues / pull_request / issue_comment / workflow_dispatch event
# contexts and aborts on a `discussion` event:
#
#   Action failed with error: Unsupported event type: discussion
#
# So on the discussion event we DON'T plan inline; we resolve the discussion
# number and re-invoke the SAME workflow via workflow_dispatch, under which the
# action runs cleanly. The `idea:approved` label stays the human gate; the
# re-dispatch is an invisible bridge.
#
# IMPORTANT — the re-dispatch requires a PAT, not GITHUB_TOKEN:
#   GitHub does not start new workflow runs from events created with the default
#   GITHUB_TOKEN (loop prevention). A workflow_dispatch fired with GITHUB_TOKEN
#   would be accepted but would NEVER start a run, so the caller MUST provide a
#   PAT (GH_PAT_WORKFLOWS) as GH_TOKEN. This is the same constraint documented in
#   scripts/initiative-driver.sh for the dev-lead label trigger.
#
# Env:
#   REPO               owner/repo (required)
#   DISCUSSION_NUMBER  Ideas Discussion number to plan (required)
#   WORKFLOW_FILE      workflow to dispatch (default: initiative-planner.yml)
#   GH_TOKEN           a PAT with workflow scope (required at the call site)
set -euo pipefail

REPO="${REPO:?REPO required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:?DISCUSSION_NUMBER required}"
WORKFLOW_FILE="${WORKFLOW_FILE:-initiative-planner.yml}"

# Validate before the value reaches the gh command line.
[[ "$DISCUSSION_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "::error::DISCUSSION_NUMBER must be a positive integer, got: '$DISCUSSION_NUMBER'" >&2
  exit 1
}

echo "Discussion event → re-dispatching ${WORKFLOW_FILE} for discussion #${DISCUSSION_NUMBER} via workflow_dispatch."
gh workflow run "$WORKFLOW_FILE" --repo "$REPO" \
  -f discussion="$DISCUSSION_NUMBER" \
  -f dry_run=false
echo "Dispatched ${WORKFLOW_FILE} (discussion=${DISCUSSION_NUMBER}, dry_run=false)."
