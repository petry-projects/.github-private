#!/usr/bin/env bats
# Tests for scripts/lib/partial-evidence-marker.sh — records advisory-gate timeout
# approvals on the PR (issue #1596) so the deterministic miss-rate metric can count
# partial_evidence_approvals, and so an approval issued on PARTIAL advisory evidence
# (a timeout fallback where fewer than all registered bots reported) is never
# silently read as "all reviewers agreed".
#
# The helper is composed alongside advisory-review-gate.sh (which provides the
# log_* helpers it calls), exactly as scripts/review-one-pr.sh sources both.
#
# Run locally: bats tests/dev-lead/unit/test_partial_evidence_marker.bats

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  # Gate first (defines log_info/log_warn), then the helper under test.
  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  source "$SCRIPT_DIR/lib/partial-evidence-marker.sh"
}

teardown() {
  unset SCRIPT_DIR
}

@test "Partial-evidence: marker string carries sha, counts and reason" {
  run advisory_partial_evidence_marker "deadbeef" 2 3 "head-age-timeout"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!-- pr-review-agent partial-evidence v1 sha=deadbeef"* ]]
  [[ "$output" == *"submitted=2"* ]]
  [[ "$output" == *"required=3"* ]]
  [[ "$output" == *"reason=head-age-timeout"* ]]
  [[ "$output" == *"-->"* ]]
}

@test "Partial-evidence: marker is detected by the miss-rate partial regex" {
  source "$SCRIPT_DIR/lib/pr-review-miss-rate.sh"
  local marker; marker="$(advisory_partial_evidence_marker "abc123" 1 3 "quiescence-timeout")"
  echo "$marker" | grep -qE "$PR_REVIEW_PARTIAL_RE"
}

@test "Partial-evidence: maybe_post is a no-op (no gh call) without pr_url/head_sha" {
  run maybe_post_partial_evidence_marker "" "" 0 3 "head-age-timeout" "{}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
}

@test "Partial-evidence: maybe_post skips re-posting when a marker already exists at head" {
  # comments_json already carries a partial-evidence marker at this head → no gh call.
  local cj='{"comments":[{"body":"<!-- pr-review-agent partial-evidence v1 sha=deadbeef submitted=2 required=3 reason=head-age-timeout -->"}]}'
  run maybe_post_partial_evidence_marker "https://x/pull/1" "deadbeef" 2 3 "head-age-timeout" "$cj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
}

# ── #1874: defer the announcement until the approval is verified ─────────────
# The gate proceeds on a timeout fallback BEFORE the approval write happens, so
# posting the announcement inside the gate claims an approval that may never land
# (the #1874 strand). When the caller sets PARTIAL_EVIDENCE_STATE_FILE, the gate
# must RECORD the facts to that file and post NOTHING — post-pr-review.sh posts
# the marker only after it verifies the review object exists.

@test "Partial-evidence: _record_partial_evidence defers to the state file (no gh call) when opted in" {
  local statefile; statefile="$(mktemp)"
  # A gh stub that fails loudly if invoked — proves the deferral makes no network call.
  local ghdir; ghdir="$(mktemp -d)"
  cat > "$ghdir/gh" <<'GH'
#!/usr/bin/env bash
echo "UNEXPECTED gh call: $*" >&2
exit 77
GH
  chmod +x "$ghdir/gh"
  PATH="$ghdir:$PATH" \
    PARTIAL_EVIDENCE_STATE_FILE="$statefile" \
    PR_URL="https://github.com/o/r/pull/1" PR_HEAD_SHA="deadbeef" PR_SNAPSHOT='{}' \
    run _record_partial_evidence 4 6 "head-age-timeout"
  [ "$status" -eq 0 ]
  # The facts are recorded for the deferred post.
  run cat "$statefile"
  [[ "$output" == *"4"* ]]
  [[ "$output" == *"6"* ]]
  [[ "$output" == *"head-age-timeout"* ]]
  rm -rf "$ghdir" "$statefile"
}
