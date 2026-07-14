#!/usr/bin/env bats
# Tests for advisory-review-gate.sh (non-blocking instant check)
#
# Validates instant (non-blocking) checking of advisory bot reviews
# No polling, no timeouts - just checks current state and returns immediately

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
}

teardown() {
  unset SCRIPT_DIR
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: script is executable" {
  [ -x "$SCRIPT_DIR/lib/advisory-review-gate.sh" ]
}

@test "Advisory gate: script has correct shebang" {
  head -1 "$SCRIPT_DIR/lib/advisory-review-gate.sh" | grep -q "^#!/usr/bin/env bash"
}

@test "Advisory gate: script uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# NON-BLOCKING DESIGN TESTS (NEW)
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: no polling loops (non-blocking design)" {
  ! grep -q "TIER1_WAIT\|TIER2_WAIT\|TIER3_WAIT" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: uses check_advisory_reviews (not wait_for_advisory_reviews)" {
  grep -q "check_advisory_reviews()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: returns 0 when bots submitted, 1 when waiting" {
  grep -q "return 0" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "return 1" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: no sleep/polling delays in main logic" {
  ! grep -q "POLL_INTERVAL\|sleep " "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# CONFIGURATION & FUNCTIONALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: defines all 4 advisory bots (gemini-code-assist)" {
  grep -q "gemini-code-assist" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (copilot-pull-request-reviewer)" {
  grep -q "copilot-pull-request-reviewer" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (sonarqubecloud)" {
  grep -q "sonarqubecloud" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: defines all 4 advisory bots (chatgpt-codex-connector)" {
  grep -q "chatgpt-codex-connector" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes get_advisory_bot_states function" {
  grep -q "get_advisory_bot_states()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes format_bot_status function" {
  grep -q "format_bot_status()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: handles color output (RED, YELLOW, GREEN)" {
  grep -q "RED=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "YELLOW=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "GREEN=" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: includes logging functions (log_info, log_warn, log_success)" {
  grep -q "log_info()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_warn()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "log_success()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# SAFETY & INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: PR_URL parameter validated safely" {
  grep -q 'if \[\[ -z "$pr_url" \]\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q "Usage: check_advisory_reviews" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: PR number extraction uses correct regex" {
  grep -q 'grep -oE' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: jq query selects latest bot submission (sort_by time)" {
  grep -q 'sort_by(.time)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: BASH_SOURCE check prevents source-time execution" {
  grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" = "${0}" \]\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: bot logins not duplicated — jq uses ADVISORY_BOTS keys" {
  # The jq filter must not hard-code individual bot logins; it uses inside(\$bots)
  grep -q 'inside(\$bots)' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  # And the ADVISORY_BOTS array is the single source of truth
  grep -q 'ADVISORY_BOTS\[@\]' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: get_advisory_bot_states handles gh failures" {
  grep -q 'gh pr view.*2>&1' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'log_warn "gh pr view failed' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: waits for all ADVISORY_BOTS before approving" {
  grep -q 'num_submitted.*total_advisory_bots' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'total_advisory_bots=\${#ADVISORY_BOTS' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

# ────────────────────────────────────────────────────────────────────
# INTEGRATION TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: review-one-pr.sh calls non-blocking gate" {
  grep -q "check_advisory_reviews" "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: review-one-pr.sh skips on return code 1 (waiting for bots)" {
  grep -q 'if \[ $gate_rc -eq 1 \]' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q 'exit 100' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "waiting-for-advisory-bots" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: review-one-pr.sh fails on return code 2 (API error)" {
  grep -q 'elif \[ $gate_rc -eq 2 \]' "$SCRIPT_DIR/review-one-pr.sh"
  grep -q "advisory-gate-api-error" "$SCRIPT_DIR/review-one-pr.sh"
}

@test "Advisory gate: uses subshell isolation in review-one-pr.sh" {
  # The gate runs in a true subshell ( ) — not a brace group { } — for isolation
  grep -q "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh"
  grep -B6 "source.*advisory-review-gate.sh" "$SCRIPT_DIR/review-one-pr.sh" | grep -q "^($"
}

# ────────────────────────────────────────────────────────────────────
# CODE QUALITY TESTS
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: documentation mentions non-blocking design" {
  grep -q "non-blocking\|instant check\|re-trigger" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: script is minimal (non-blocking means fewer lines)" {
  local lines
  lines=$(wc -l < "$SCRIPT_DIR/lib/advisory-review-gate.sh")
  [ "$lines" -lt 500 ]
}

# ────────────────────────────────────────────────────────────────────
# RUNTIME BEHAVIOR TESTS
# ────────────────────────────────────────────────────────────────────

_make_mock_gh_dir() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return a timestamp 30 minutes ago (well past the 20-minute push-age timeout)
  date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '2000-01-01T00:00:00Z\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

_make_mock_gh_dir_recent() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return current time (cherry-pick/commit was applied just now, within the 20-minute window)
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

# Mock for the cherry-picked commit scenario:
# A commit with an old author date was cherry-picked just now.
# committer.date (GraphQL) = now (recent) — this is what the gate must use.
# If the gate mistakenly used author.date (old), head_age_sec would be large
# and the timeout would fire immediately, bypassing the gate.
_make_mock_gh_dir_old_commit_recent_push() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # committer.date is current time — the cherry-pick was applied just now.
  # (author.date would be 2+ hours ago, but the gate uses committer.date.)
  date -u '+%Y-%m-%dT%H:%M:%SZ'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

@test "Gate runtime: returns 1 when no bots have submitted and PR is recent" {
  # Within the head-age window: absent bots may still be slow, so keep waiting.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 when no bots have submitted and head-age timeout elapsed (issue #1193)" {
  # Durable hardening: when ZERO advisory bots have produced any output on the PR
  # (bot not vendor-enabled / uninstalled / bot outage) and the head is older than
  # the head-age window, the absent bots become *missing reviews* — the gate must
  # proceed instead of blocking forever. _make_mock_gh_dir returns a committer date
  # ~30 min old, past the 1200s window.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: no bots + head time unavailable → conservative wait (issue #1193)" {
  # Graceful degradation: with no bot output AND no determinable head age (GraphQL
  # unreachable), there is no timing basis to declare bots absent, so the gate stays
  # conservative and waits — the next scheduled sweep retries once the API recovers.
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_no_head_time '{"reviews":[],"comments":[]}')
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 when all 4 bots have submitted" {
  local all_bots_json
  all_bots_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2026-06-07T10:03:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2026-06-07T10:13:00Z"},{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:17:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$all_bots_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 1 when only 1 bot submitted and PR is recent" {
  local one_bot_json
  # Use a far-future submittedAt so time_since_last_sub is always negative,
  # ensuring the quiescence fallback never fires and the test stays stable.
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 0 after timeout even with partial bot submissions" {
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: stale submission from previous HEAD does not trigger quiescence for fresh commit" {
  # Head was just pushed (recent). The only submission is from a previous HEAD
  # (year 2000), so it predates the current head push.
  # The quiescence baseline is anchored to max(head_push_time, latest_sub_time),
  # which equals the current head push time — so time_since_last_sub ≈ 0,
  # the fallback does not fire, and the gate correctly returns 1 (wait).
  local old_submission_json
  old_submission_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2000-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$old_submission_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: returns 1 for recently-pushed old cherry-picked commit" {
  # Regression test: head_age_sec must use committer.date (time the cherry-pick
  # was applied), not the commit's own author.date. An old cherry-picked commit
  # has a far-past author.date but committer.date ≈ now; using author.date would
  # make head_age_sec exceed 20 min immediately and bypass the gate.
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_old_commit_recent_push "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

# Mock where GraphQL returns the committer date directly (30 minutes ago).
# Used to verify the head-age timeout fires for PRs with partial bot coverage.
_make_mock_gh_dir_null_pushed_date() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return committer date 30 minutes ago — head-age timeout fires
  date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || printf '2000-01-01T00:00:00Z\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

# Mock for the scenario where head time is completely unavailable
# (GraphQL API returns empty — no committer date available).
# Used to verify quiescence fires from latest_sub_at alone.
_make_mock_gh_dir_no_head_time() {
  local json_reviews_comments="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"reviews,comments"* ]]; then
  printf '%s\n' '$json_reviews_comments'
elif [[ "\$args" == *"graphql"* ]]; then
  # Return empty to simulate GraphQL being unreachable / head time unavailable
  printf '\n'
fi
MOCK_EOF
  chmod +x "$tmpdir/gh"
  echo "$tmpdir"
}

@test "Gate runtime: head-age timeout fires when GraphQL returns old committer date" {
  # Regression test for issue #577: pushedDate now returns null from GitHub's GraphQL API.
  # The gate fetches the head commit's committer date directly via GraphQL so that the
  # head-age timeout fallback fires for PRs with partial bot coverage.
  local one_bot_json
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_null_pushed_date "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # GraphQL returns committer date 30 min old → head_age_sec > 1200 → timeout fires → proceed
  [ "$status" -eq 0 ]
}

@test "Gate runtime: quiescence fallback fires when head time unavailable and submissions are old" {
  # When the GraphQL API is unreachable (head_time empty), the quiescence
  # fallback must still fire from latest_sub_at alone, preventing indefinite stranding.
  local one_bot_json
  # Submission timestamp is in the past (well over 10 min ago)
  one_bot_json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z"}],"comments":[]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_no_head_time "$one_bot_json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # latest_sub_at is old (>10 min) → quiescence fires even without head time → proceed
  [ "$status" -eq 0 ]
}

@test "Gate runtime: returns 2 when gh command fails (API error, not normal wait)" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "Error: authentication required" >&2
exit 1
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  # API errors return 2 (distinct from "bots not submitted yet" = 1)
  # so the caller can fail-fast rather than treating the error as a normal wait.
  [ "$status" -eq 2 ]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMIT HANDLING TESTS (issue #657)
# ────────────────────────────────────────────────────────────────────

@test "Advisory gate: defines rate-limit markers and detects RATE_LIMITED state" {
  # get_advisory_bot_states must classify a bot's usage-limit comment as RATE_LIMITED
  grep -q 'RATE_LIMITED' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -qi 'reached your Codex usage limit\|Review limit reached\|used up its prepaid credits' \
    "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: drops rate-limited/unsupported bots from required total (effective_total)" {
  grep -q 'effective_total' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: names the absent-bot timeout windows as constants (issue #1193)" {
  grep -q 'ADVISORY_HEAD_AGE_TIMEOUT_SEC=1200' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  grep -q 'ADVISORY_QUIESCENCE_TIMEOUT_SEC=600' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Advisory gate: empty-state branch applies head-age timeout, not an unconditional wait (issue #1193)" {
  # The zero-output branch must consult head age before deciding to wait.
  grep -q '_head_age_seconds' "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "Gate runtime: rate-limited bot is classified RATE_LIMITED in gate output" {
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"You have reached your Codex usage limits for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [[ "$output" == *"RATE_LIMITED"* ]]
}

@test "Gate runtime: out-of-quota bot does not hold the gate but gate still waits for other absent bots" {
  # Two real advisory reviews + Codex signalling it is out of quota, copilot absent,
  # head + submissions recent (timeout fallbacks disarmed). The rate-limited Codex must
  # be treated as non-participating, but we must still wait for the absent Copilot.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"You have reached your Codex usage limits for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: out-of-quota bot does not hold the gate (returns 0 when all other available bots submitted)" {
  # Three real advisory reviews + Codex signalling it is out of quota, head + submissions
  # recent (timeout fallbacks disarmed). All available bots have submitted, so the gate approves.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"copilot-pull-request-reviewer"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"You have reached your Codex usage limits for code reviews.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
}

@test "Gate runtime: plain comment (no rate-limit marker) is not excluded — gate still waits" {
  # Codex posts an ordinary comment without any usage-limit marker. It must NOT be
  # treated as rate-limited, so with copilot still absent the gate keeps waiting.
  local json
  json='{"reviews":[{"author":{"login":"gemini-code-assist"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"},{"author":{"login":"sonarqubecloud"},"state":"COMMENTED","submittedAt":"2099-01-01T00:00:00Z"}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"body":"Looks good to me, nice work.","createdAt":"2099-01-01T00:00:00Z"}]}'
  local tmpdir
  tmpdir=$(_make_mock_gh_dir_recent "$json")
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    check_advisory_reviews 'https://github.com/owner/repo/pull/123'
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 1 ]
}

@test "Gate runtime: format_bot_status renders known states" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'gemini-code-assist' 'APPROVED'
  "
  [[ "$output" == *"APPROVED"* ]]
  run bash -c "
    source '$gate_script' 2>/dev/null || true
    format_bot_status 'sonarqubecloud' 'CHANGES_REQUESTED'
  "
  [[ "$output" == *"CHANGES_REQUESTED"* ]]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMIT DETECTION TESTS (issue #711)
#
# detect_advisory_rate_limit <reviews-comments-json>
#   returns 0 when a known advisory/review bot's LATEST submission body matches
#   a rate-limit phrase; 1 otherwise. The marker it arms lets pr-review-sweep
#   auto-retry once the limit resets (no manual force_review).
# ────────────────────────────────────────────────────────────────────

@test "detect_advisory_rate_limit: function exists" {
  grep -q "detect_advisory_rate_limit()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "detect_advisory_rate_limit: true when codex posts a usage-limit notice" {
  local json
  json='{"reviews":[],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T10:00:00Z","body":"You have reached your usage limit. Please try again later."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: true when coderabbit posts a rate-limit notice" {
  local json
  json='{"reviews":[{"author":{"login":"coderabbitai"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"Review skipped: rate limit exceeded. Reviews will resume after the limit resets."}],"comments":[]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: false when bot's latest submission is a real review" {
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"I found a potential null pointer dereference on line 42."}],"comments":[]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: false when a newer real review supersedes the rate-limit notice" {
  # Older comment is a rate-limit notice; newer review is a real review.
  # The latest submission per bot wins → not rate-limited.
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T11:00:00Z","body":"LGTM, no issues found."}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T10:00:00Z","body":"You have reached your usage limit."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: true when a newer rate-limit notice supersedes an older real review" {
  # Older review was real; newer comment is a rate-limit notice → rate-limited now.
  local json
  json='{"reviews":[{"author":{"login":"chatgpt-codex-connector"},"state":"COMMENTED","submittedAt":"2026-06-07T10:00:00Z","body":"Looks good overall."}],"comments":[{"author":{"login":"chatgpt-codex-connector"},"createdAt":"2026-06-07T11:00:00Z","body":"You have reached your usage limit. Try again later."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 0 ]
}

@test "detect_advisory_rate_limit: false when the rate-limit phrase comes from a non-advisory (human) author" {
  local json
  json='{"reviews":[],"comments":[{"author":{"login":"some-human"},"createdAt":"2026-06-07T10:00:00Z","body":"We should add a rate limit to this endpoint, quota exceeded errors are common."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '$json'"
  [ "$status" -eq 1 ]
}

@test "detect_advisory_rate_limit: false on empty input" {
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run bash -c "source '$gate_script'; detect_advisory_rate_limit '{\"reviews\":[],\"comments\":[]}'"
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# RATE-LIMITED MARKER POSTING TESTS (issue #711)
#
# maybe_post_rate_limited_marker <pr_url> <head_sha> <reset_iso> <comments_json>
#   posts a deduplicated marker comment so the sweep can detect the
#   withheld-due-to-rate-limit state and auto-retry after <reset_iso>.
# ────────────────────────────────────────────────────────────────────

@test "maybe_post_rate_limited_marker: function exists" {
  grep -q "maybe_post_rate_limited_marker()" "$SCRIPT_DIR/lib/advisory-review-gate.sh"
}

@test "maybe_post_rate_limited_marker: posts a marker comment when none exists at head" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmpdir/calls"
exit 0
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    maybe_post_rate_limited_marker 'https://github.com/owner/repo/pull/123' 'abc123' '2999-01-01T00:00:00Z' '{\"comments\":[]}'
  "
  local calls; calls=$(cat "$tmpdir/calls" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  # gh pr comment was invoked with the rate-limited marker for this head
  [[ "$calls" == *"pr comment"* ]]
  [[ "$calls" == *"rate-limited v1 sha=abc123"* ]]
  [[ "$calls" == *"status=rate-limited"* ]]
  [[ "$calls" == *"reset=2999-01-01T00:00:00Z"* ]]
}

@test "maybe_post_rate_limited_marker: does not re-post when a marker already exists at head" {
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "$tmpdir/gh" << MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmpdir/calls"
exit 0
MOCK_EOF
  chmod +x "$tmpdir/gh"
  local existing
  existing='{"comments":[{"body":"<!-- pr-review-agent rate-limited v1 sha=abc123 status=rate-limited reset=2999-01-01T00:00:00Z -->\n\nAdvisory bots were rate-limited."}]}'
  local gate_script="$SCRIPT_DIR/lib/advisory-review-gate.sh"
  run env PATH="$tmpdir:$PATH" bash -c "
    source '$gate_script'
    maybe_post_rate_limited_marker 'https://github.com/owner/repo/pull/123' 'abc123' '2999-01-01T00:00:00Z' '$existing'
  "
  local calls; calls=$(cat "$tmpdir/calls" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  # No new comment should be posted when a marker for this head already exists
  [[ "$calls" != *"pr comment"* ]]
}
