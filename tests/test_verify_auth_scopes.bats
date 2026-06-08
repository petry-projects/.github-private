#!/usr/bin/env bats
# Unit tests for scripts/verify-auth-scopes.sh
#
# Run with: bats tests/test_verify_auth_scopes.bats
# Install bats: https://github.com/bats-core/bats-core

SCRIPT="$(dirname "$BATS_TEST_FILENAME")/../scripts/verify-auth-scopes.sh"

# ---------------------------------------------------------------------------
# Fine-grained PAT — no "Token scopes:" line in gh auth status output.
# Must exit 0 and emit a warning, not an error.
# ---------------------------------------------------------------------------

@test "fine-grained PAT: no Token scopes line exits 0 with warning" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Git operations protocol: https
- Token: github_pat_11CDFSYKQ0w50IHawIgb0w_***
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
}

@test "fine-grained PAT: output does not contain '::error::'" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: github_pat_11CDFSYKQ0w50IHawIgb0w_***
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

@test "undetermined scopes without github_pat_ prefix exits 1 with error" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ghp_***
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — full repo + read:org. Must exit 0.
# ---------------------------------------------------------------------------

@test "classic PAT repo+read:org exits 0" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_***
- Token scopes: 'gist', 'read:org', 'repo', 'workflow'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "classic PAT repo+read:org emits no error lines" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'read:org', 'repo'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — repo scope present but read:org missing. Must exit 1.
# ---------------------------------------------------------------------------

@test "classic PAT repo-only (missing read:org) exits 1" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'repo', 'workflow'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "classic PAT repo-only error message mentions read:org" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'repo'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"read:org"* ]]
}

# ---------------------------------------------------------------------------
# No repo scope, but contents + pull_requests present (fine-grained-style permissions)
# ---------------------------------------------------------------------------

@test "no-repo token with contents+pull_requests exits 0" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'contents', 'pull_requests'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "GITHUB_TOKEN with contents:read and pull_requests:write exits 0" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ***
- Token scopes: 'contents:read', 'pull_requests:write'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Token scopes line present, but neither repo nor the required minimal permissions are present
# ---------------------------------------------------------------------------

@test "token missing required scopes exits 1" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'gist'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "token missing scopes error message names the missing scope" {
  export AUTH_STATUS="$(cat <<'EOF'
✓ Logged in to github.com account bot (GH_TOKEN)
- Token: ghp_***
- Token scopes: 'gist'
EOF
  )"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
}
