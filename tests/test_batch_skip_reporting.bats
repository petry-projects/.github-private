#!/usr/bin/env bats
# Regression tests for accurate exit-100 skip reporting in scripts/review-batch.sh
# (issue #898).
#
# The reviewer (review-one-pr.sh) returns exit 100 for *every* no-op/skip: an
# already-reviewed head, a CI-pending deferral, a CI-failing deferral, a
# human-changes-requested skip, an escalation skip, etc. The batch driver used
# to collapse all of these into a single "No-op (already reviewed)" line. That
# message is actively misleading for a CI-pending deferral — it claims a review
# already happened at the current head when in fact the PR is *owed* a review
# once CI goes green. That mislabelling is what made the #892 "deadlock" look
# like a stuck idempotency marker.
#
# These tests assert the batch reports the *reason* behind an exit-100 skip:
#   - a ci-pending skip must NOT claim "already reviewed" and must surface as a
#     deferral ("Deferred" / "CI still pending"),
#   - an already-reviewed-at-head skip must still say "already reviewed",
#   - a batch with at least one CI deferral must note "deferred" in the summary
#     so an operator scanning the run knows a review is still owed.
#
# Run with: bats tests/test_batch_skip_reporting.bats

setup() {
  export TEST_DIR="$BATS_TMPDIR/batch-skip-report-test"
  mkdir -p "$TEST_DIR/scripts"
  mkdir -p "$TEST_DIR/bin"
  cd "$TEST_DIR"

  export PRS_FILE="prs.txt"
  echo "https://github.com/fake/pull/1" > "$PRS_FILE"
  export CANDIDATE_LIMIT=1
  export MAX_PRS=1
  export REVIEW_ENGINE="claude"
  export PATH="$TEST_DIR/bin:$PATH"

  cp "$BATS_TEST_DIRNAME/../scripts/review-batch.sh" "scripts/"

  cat > "scripts/validate-engines.sh" <<'EOF'
validate_engines() {
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="true"
  export COPILOT_AVAILABLE="true"
}
EOF

  cat > "scripts/engine.sh" <<'EOF'
export COPILOT_API_MODEL="openai/o4-mini"
EOF

  cat > "$TEST_DIR/bin/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$TEST_DIR/bin/gh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# review-one-pr.sh stub that emits a CI-pending skip exactly like the real
# reviewer's non-force ci-pending gate: a human-readable line plus a JSON
# verdict carrying reason=ci-pending, then exit 100.
_stub_ci_pending() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "    skip: CI checks still in progress for $1"
echo '{"pr":"'"$1"'","decision":"skip","reason":"ci-pending"}'
exit 100
EOF
  chmod +x "scripts/review-one-pr.sh"
}

_stub_already_reviewed() {
  cat > "scripts/review-one-pr.sh" <<'EOF'
#!/bin/bash
echo "    noop: already reviewed at deadbeef"
echo '{"pr":"'"$1"'","decision":"skip","reason":"already-reviewed-at-head"}'
exit 100
EOF
  chmod +x "scripts/review-one-pr.sh"
}

@test "batch: ci-pending skip is not reported as 'already reviewed'" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  # The defect: a CI-pending deferral was mislabelled as an already-reviewed
  # no-op. The batch must NOT claim the PR was already reviewed.
  [[ "$output" != *"already reviewed"* ]]
}

@test "batch: ci-pending skip is reported as a deferral" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deferred"* ]]
  [[ "$output" == *"CI"* ]]
}

@test "batch: ci-pending deferral is surfaced in the session summary" {
  _stub_ci_pending

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"deferred"* ]]
}

@test "batch: already-reviewed-at-head skip still reports 'already reviewed'" {
  _stub_already_reviewed

  run bash scripts/review-batch.sh
  echo "$output" >&2

  [ "$status" -eq 0 ]
  [[ "$output" == *"already reviewed"* ]]
  # An already-reviewed no-op is genuinely done — it is NOT a CI deferral.
  [[ "$output" != *"deferred"* ]]
}
