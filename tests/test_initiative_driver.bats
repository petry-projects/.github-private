#!/usr/bin/env bats
# Unit tests for scripts/initiative-driver.sh
# Covers has_label regex safety, gate label, MAX_IN_FLIGHT cap, and blocked_by evaluation.
# Mocks the gh CLI to avoid network calls.
#
# Run with: bats tests/test_initiative_driver.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/initiative-driver.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  GH_LOG="$(mktemp)"
  export GH_LOG
  export PATH="$MOCK_BIN:$PATH"
  export REPO="owner/repo"
  export EPIC="1"
  export CLOSED_ISSUE=""
  export DRY_RUN="false"
  export MAX_IN_FLIGHT="2"
  export GH_TOKEN="tok"
}

teardown() {
  rm -rf "${MOCK_BIN:-}"
  rm -f "${GH_LOG:-}"
}

# ── has_label: fixed-string matching ─────────────────────────────────────────

@test "has_label matches an exact label name" {
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'initiative:auto\nother-label' 'initiative:auto'
  [ "$status" -eq 0 ]
}

@test "has_label with -F does not match regex dot against a different label" {
  # Before the fix, grep -qx 'a.b' would match 'axb' (dot = any char in regex).
  # With -F the pattern is literal, so 'a.b' must not match 'axb'.
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'axb\nother' 'a.b'
  [ "$status" -ne 0 ]
}

@test "has_label returns non-zero when label is absent" {
  has_label() { printf '%s\n' "$1" | grep -qxF "$2"; }
  run has_label $'foo\nbar' 'not-present'
  [ "$status" -ne 0 ]
}

# ── gate: epic must carry initiative:auto ────────────────────────────────────

@test "gate: exits 0 with no-op when epic lacks initiative:auto" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# labels_of epic: return empty (no labels)
if [[ "$*" == *"issues/1 --jq"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "gate: proceeds past gate when epic carries initiative:auto" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# Epic labels: initiative:auto
if [[ "$*" == *"issues/1 --jq"* ]] && [[ "$*" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# No sub-issues
if [[ "$*" == *"sub_issues"* ]]; then printf ''; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sub-issues"* ]]
}

# ── MAX_IN_FLIGHT cap ─────────────────────────────────────────────────────────

@test "cap: does not label new issues when in-flight equals MAX_IN_FLIGHT" {
  export MAX_IN_FLIGHT="2"
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Sub-issues (all states and open): issues 2 and 3
if [[ "$args" == *"sub_issues"* ]]; then printf '2\n3'; exit 0; fi
# Both issues already carry dev-lead (in-flight = 2)
if [[ "$args" == *"issues/2 --jq"* ]] || [[ "$args" == *"issues/3 --jq"* ]]; then
  printf 'dev-lead'; exit 0
fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in-flight=2"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

# ── blocked_by evaluation ─────────────────────────────────────────────────────

@test "blocked_by: does not label an issue that has an open blocker" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Sub-issues: only issue 2
if [[ "$args" == *"sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has no dev-lead yet
if [[ "$args" == *"issues/2 --jq"* ]]; then printf ''; exit 0; fi
# Issue 2 has an open blocker (issue 99)
if [[ "$args" == *"issues/2/dependencies/blocked_by"* ]]; then printf '99'; exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked by open"* ]]
  ! grep -qF "issue edit" "$GH_LOG"
}

@test "blocked_by: labels a sub-issue when all blockers are closed" {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args="$*"
# Epic labels: initiative:auto
if [[ "$args" == *"issues/1 --jq"* ]] && [[ "$args" != *"sub_issues"* ]]; then
  printf 'initiative:auto'; exit 0
fi
# Sub-issues: only issue 2
if [[ "$args" == *"sub_issues"* ]]; then printf '2'; exit 0; fi
# Issue 2 has no dev-lead yet
if [[ "$args" == *"issues/2 --jq"* ]]; then printf ''; exit 0; fi
# No open blockers
if [[ "$args" == *"issues/2/dependencies/blocked_by"* ]]; then printf ''; exit 0; fi
# Label application succeeds
if [[ "$args" == "issue edit"* ]]; then exit 0; fi
printf '[]'
EOF
  chmod +x "$MOCK_BIN/gh"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASED"* ]]
  grep -qF "issue edit" "$GH_LOG"
}
