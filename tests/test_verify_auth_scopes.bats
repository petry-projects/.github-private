#!/usr/bin/env bats
# Unit tests for scripts/verify-auth-scopes.sh
#
# Run with: bats tests/test_verify_auth_scopes.bats

SCRIPT="$(dirname "$BATS_TEST_FILENAME")/../scripts/verify-auth-scopes.sh"

setup() {
  STUB_DIR="$(mktemp -d)"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# Creates a gh stub that returns the given auth status output and exit code.
make_gh_stub() {
  local output_file="$STUB_DIR/gh_output"
  local exit_code_file="$STUB_DIR/gh_exit_code"
  printf '%s\n' "$1" > "$output_file"
  printf '%s\n' "${2:-0}" > "$exit_code_file"
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
STUB_DIR="$(dirname "$0")"
if [[ "$*" == *"auth status"* ]]; then
  cat "$STUB_DIR/gh_output"
  exit "$(cat "$STUB_DIR/gh_exit_code")"
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# Fine-grained PAT detection via github_pat_ prefix
# ---------------------------------------------------------------------------

@test "fine-grained PAT (github_pat_11 prefix) exits 0 with notice" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Git operations protocol: https
- Token: github_pat_11CDFSYKQ0_***"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fine-grained PAT detected"* ]]
  [[ "$output" == *"::notice::"* ]]
}

@test "fine-grained PAT notice does not contain ::error::" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: github_pat_11ABCXYZ_***"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Fine-grained PAT detection via absent Token scopes line
# ---------------------------------------------------------------------------

@test "token with no Token scopes line exits 0 with warning" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Git operations protocol: https
- Token: ghp_someToken_***"
  # Note: no 'Token scopes:' line — simulates gh auth status for a token whose
  # scopes gh cannot determine.

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "auth status with 'cannot determine' in output exits 0 with warning" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token scopes: cannot determine"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — repo + read:org (passes)
# ---------------------------------------------------------------------------

@test "classic PAT with repo and read:org exits 0" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'repo', 'read:org', 'workflow'"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — repo without read:org (fails)
# ---------------------------------------------------------------------------

@test "classic PAT with repo but missing read:org exits 1" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'repo', 'workflow'"

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing 'read:org'"* ]]
}

@test "classic PAT missing read:org emits actionable error guidance" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'repo'"

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"read:org"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — minimal scopes: contents + pull_requests (passes)
# ---------------------------------------------------------------------------

@test "classic PAT with contents and pull_requests exits 0" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'contents', 'pull_requests'"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

@test "token with granular scopes containing permission suffixes (e.g. GITHUB_TOKEN) exits 0" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghs_someActionToken_***
- Token scopes: 'contents:read', 'pull_requests:write'"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error::"* ]]
}

# ---------------------------------------------------------------------------
# Classic PAT — missing required minimal scopes (fails)
# ---------------------------------------------------------------------------

@test "classic PAT missing contents scope exits 1" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'pull_requests'"

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required scope: contents"* ]]
}

@test "classic PAT missing pull_requests scope exits 1" {
  make_gh_stub "✓ Logged in to github.com account donpetry-bot (GH_TOKEN)
- Active account: true
- Token: ghp_classicToken_***
- Token scopes: 'contents'"

  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required scope: pull_requests"* ]]
}

# ---------------------------------------------------------------------------
# gh auth status failure
# ---------------------------------------------------------------------------

@test "gh auth status failure exits non-zero" {
  make_gh_stub "error: not logged in" 1

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh auth status failed"* ]]
}
