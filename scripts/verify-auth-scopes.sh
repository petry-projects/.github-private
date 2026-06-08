#!/usr/bin/env bash
# verify-auth-scopes.sh — validate GH_TOKEN scopes for pr-review.
#
# Called by the "Verify auth scopes" step in .github/workflows/pr-review.yml.
# Tests: tests/test_verify_auth_scopes.bats
#
# Inject AUTH_STATUS env var to override `gh auth status` (used in unit tests).
set -euo pipefail

if [ -z "${AUTH_STATUS:-}" ]; then
  if auth_status="$(gh auth status 2>&1)"; then
    :
  else
    auth_rc=$?
    printf '%s\n' "$auth_status" | grep -v '- Token:' || true
    echo "::error::gh auth status failed"
    exit "$auth_rc"
  fi
else
  auth_status="$AUTH_STATUS"
fi

printf '%s\n' "$auth_status" | grep -v '- Token:' || true
scopes_line="$(printf '%s\n' "$auth_status" | grep 'Token scopes:' || true)"
normalized_scopes="$(printf '%s' "$scopes_line" | sed "s/[',]/ /g")"

# Fine-grained PATs don't expose OAuth-style scopes in `gh auth status` —
# the CLI omits the "Token scopes:" line or reports it cannot determine
# scopes. Skip validation in that case (emit a warning only).
# For classic PATs, validate both 'repo' and 'read:org':
#   - 'repo' alone is insufficient: `gh pr view --json reviewRequests`
#     hard-fails on PRs with team reviewers when 'read:org' is absent.
if [ -z "$normalized_scopes" ] || printf '%s' "$auth_status" | grep -qiE '(cannot determine|fine.grained)'; then
  if printf '%s' "$auth_status" | grep -q 'github_pat_'; then
    echo "::warning::Token scopes could not be determined (fine-grained PAT). Skipping scope validation."
    echo "::warning::Ensure the token has: contents:read and pull_requests:write (fine-grained), or repo + read:org (classic PAT)."
  else
    echo "::error::Token scopes could not be determined and the token does not appear to be a fine-grained PAT (github_pat_ prefix not found)."
    echo "::error::Ensure the token has either 'repo' + 'read:org' scopes (classic) or 'contents' + 'pull_requests' (fine-grained)."
    exit 1
  fi
elif grep -qE "(^|[[:space:]])repo([[:space:]]|$)" <<< "$normalized_scopes"; then
  # Classic PAT with repo scope — also require read:org for team reviewer support
  if ! grep -qE "(^|[[:space:]])read:org([[:space:]]|$)" <<< "$normalized_scopes"; then
    echo "::error::GH_TOKEN has 'repo' scope but is missing 'read:org'."
    echo "::error::PRs with team-based reviewers will fail at 'gh pr view --json reviewRequests'."
    echo "::error::Edit the classic PAT and check the 'read:org' box (no regeneration needed)."
    exit 1
  fi
else
  # Minimal-scope token — verify required scopes, allowing optional :permission suffixes
  for required_scope in contents pull_requests; do
    if ! grep -qE "(^|[[:space:]])${required_scope}(:[^[:space:]]*)?(([[:space:]])|$)" <<< "$normalized_scopes"; then
      echo "::error::GH_TOKEN is missing required scope: ${required_scope}"
      echo "::error::Token must have either 'repo' + 'read:org' scopes (classic) or 'contents' + 'pull_requests' (fine-grained)"
      exit 1
    fi
  done
fi
