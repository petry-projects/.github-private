#!/usr/bin/env bash
# verify-auth-scopes.sh — Validates GH_TOKEN has the scopes required by the
# PR review workflow.  Handles both classic PATs (OAuth scope list) and
# fine-grained PATs (no scope list exposed by gh auth status).
#
# Exit 0 = token is acceptable; exit 1 = token is missing a required scope.
set -euo pipefail

if auth_status="$(gh auth status 2>&1)"; then
  :
else
  auth_rc=$?
  printf '%s\n' "$auth_status"
  echo "::error::gh auth status failed"
  exit "$auth_rc"
fi
printf '%s\n' "$auth_status"

# ── Fine-grained PAT detection (prefix-based, most explicit check) ────────
# Fine-grained PATs begin with 'github_pat_' and do not expose OAuth-style
# scope strings in 'gh auth status'.  They also fail at addPullRequestReview
# ('gh pr review --approve') so they are not a supported token type for this
# workflow.  Fail fast before the expensive review steps run.
if grep -qi 'Token:.*github_pat_' <<< "$auth_status"; then
  echo "::error::Fine-grained PAT detected — this workflow requires a classic PAT."
  echo "::error::Fine-grained PATs fail at 'gh pr review --approve' (addPullRequestReview)."
  echo "::error::Replace DON_PETRY_BOT_GH_PAT with a classic PAT that has 'repo' + 'read:org' scopes."
  exit 1
fi

# ── Fallback: empty / indeterminate scope list ─────────────────────────────
# If 'gh auth status' did not emit a 'Token scopes:' line at all (e.g. an
# older gh version or a token type that does not surface scopes), or if it
# explicitly reports it cannot determine them, treat the token as acceptable
# and emit a warning so operators know validation was skipped.
scopes_line="$(grep 'Token scopes:' <<< "$auth_status" || true)"
normalized_scopes="${scopes_line//,/ }"
normalized_scopes="${normalized_scopes//$'\''/ }"

if [ -z "$normalized_scopes" ] || grep -qiE '(cannot determine|fine.grained)' <<< "$auth_status"; then
  echo "::warning::Token scopes could not be determined. Skipping scope validation."
  echo "::warning::Ensure the token has: contents:read and pull_requests:write (fine-grained), or repo + read:org (classic PAT)."
  exit 0
fi

# ── Classic PAT scope validation ───────────────────────────────────────────
# 'repo' is the broad classic scope covering all repository access.  When
# present, also require 'read:org' — PRs with team-based reviewers will hard-
# fail at 'gh pr view --json reviewRequests' without it.
if grep -qE "(^|[[:space:]])repo([[:space:]]|$)" <<< "$normalized_scopes"; then
  if ! grep -qE "(^|[[:space:]])read:org([[:space:]]|$)" <<< "$normalized_scopes"; then
    echo "::error::GH_TOKEN has 'repo' scope but is missing 'read:org'."
    echo "::error::PRs with team-based reviewers will fail at 'gh pr view --json reviewRequests'."
    echo "::error::Edit the classic PAT and check the 'read:org' box (no regeneration needed)."
    exit 1
  fi
else
  # Classic PAT without the broad 'repo' scope: verify the minimum granular
  # scopes needed for the review workflow to function.
  if ! grep -qE "(^|[[:space:]])contents(:[^[:space:]]+)?([[:space:]]|$)" <<< "$normalized_scopes"; then
    echo "::error::GH_TOKEN is missing required scope: contents"
    echo "::error::Token must have either 'repo' + 'read:org' (classic) or 'contents' + 'pull_requests' (fine-grained)"
    exit 1
  fi
  # pull_requests:read is insufficient — the workflow submits reviews and
  # comments, which requires write access.  Accept the bare scope (classic PAT)
  # or the explicit :write suffix (GITHUB_TOKEN / fine-grained); reject :read.
  if ! grep -qE "(^|[[:space:]])pull_requests(:write)?([[:space:]]|$)" <<< "$normalized_scopes"; then
    echo "::error::GH_TOKEN is missing required scope: pull_requests with write access"
    echo "::error::Token must have either 'repo' + 'read:org' (classic) or 'contents' + 'pull_requests:write' (fine-grained)"
    exit 1
  fi
fi
