#!/usr/bin/env bats
# SC2 regression guard (#1624, the automatable half of #503 / epic #495).
#
# Safe Release SC2: a deliberately-broken in-development version of this repo's
# agentic review/merge duty MUST NOT be able to block the PR that fixes its own
# breakage. The structural property that guarantees this for `.github-private`'s
# dev/merge duty is that `dev-lead.yml` — although this repo sits in ring `next`
# — pins its dev-lead reusable to a **stable-tier** channel (`@dev-lead/v1-stable`).
# A broken `next` therefore cannot, by construction, gate its own fix.
#
# This is currently a documented-but-untested property: nothing stops a
# well-meaning "fix the ring drift flagged by pinned-version-report" PR from
# repinning dev-lead to `@dev-lead/v1-next` and silently restoring the
# self-hosting circular dependency. This test asserts it stays pinned to a
# stable tier, parsing the tier from the stub's `uses:` pin (never a hardcoded
# version), so cutting a new release does not break it.
#
# All assertions are PURE: helper unit tests use fixture stubs, and the live
# guard reads the committed workflow files. No network.
#
# Run: bats tests/test_sc2_self_review_channel.bats

setup() {
  # shellcheck source=scripts/lib/self-review-channel.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/self-review-channel.sh"
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures/self-review-channel"
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
}

# ---------------------------------------------------------------------------
# src_channel_tier — map a `@<agent>/<channel>` ref to its tier (AC #2).
# Treat "stable-tier" as the channel TIER, not a literal string: both the
# major-scoped `v1-stable` and the legacy bare `stable` qualify.
# ---------------------------------------------------------------------------

@test "channel tier: major-scoped v1-stable is the stable tier" {
  run src_channel_tier "dev-lead/v1-stable"
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

@test "channel tier: legacy bare stable is the stable tier" {
  run src_channel_tier "dev-lead/stable"
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

@test "channel tier: v1-next is the next tier (not stable)" {
  run src_channel_tier "dev-lead/v1-next"
  [ "$status" -eq 0 ]
  [ "$output" = "next" ]
}

@test "channel tier: v2-ring0 is a ring tier (not stable)" {
  run src_channel_tier "dev-lead/v2-ring0"
  [ "$status" -eq 0 ]
  [ "$output" = "ring0" ]
}

@test "channel tier: a bare channel with no agent prefix still classifies" {
  run src_channel_tier "v1-stable"
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

@test "channel tier: @main is not a channel tier (fails)" {
  run src_channel_tier "main"
  [ "$status" -ne 0 ]
}

@test "channel tier: a bare commit SHA is not a channel tier (fails)" {
  run src_channel_tier "abcdef1234567890abcdef1234567890abcdef12"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# src_is_stable_tier — the stable/not-stable predicate.
# ---------------------------------------------------------------------------

@test "is_stable_tier: stable-tier refs pass" {
  run src_is_stable_tier "dev-lead/v1-stable"
  [ "$status" -eq 0 ]
  run src_is_stable_tier "dev-lead/stable"
  [ "$status" -eq 0 ]
}

@test "is_stable_tier: next / ring / main / sha all fail" {
  run src_is_stable_tier "dev-lead/v1-next"
  [ "$status" -ne 0 ]
  run src_is_stable_tier "dev-lead/v2-ring1"
  [ "$status" -ne 0 ]
  run src_is_stable_tier "main"
  [ "$status" -ne 0 ]
  run src_is_stable_tier "abcdef1234567890abcdef1234567890abcdef12"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# src_stub_uses_ref — parse the pin from the stub's `uses:` line, ignoring the
# trailing `# NOSONAR ...` inline comment (AC #2).
# ---------------------------------------------------------------------------

@test "stub_uses_ref: parses the channel ref, dropping the inline NOSONAR comment" {
  run src_stub_uses_ref "${FIXTURES}/stub-stable.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v1-stable" ]
}

@test "stub_uses_ref: parses a next-pinned fixture" {
  run src_stub_uses_ref "${FIXTURES}/stub-next.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v1-next" ]
}

@test "stub_uses_ref: parses a bare @main pin" {
  run src_stub_uses_ref "${FIXTURES}/stub-main.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ---------------------------------------------------------------------------
# src_stub_agent_ref — parse the `agent_ref:` input (the ref dev-lead's own
# scripts are checked out from), dropping any inline comment.
# ---------------------------------------------------------------------------

@test "stub_agent_ref: parses the agent_ref value from a stable stub" {
  run src_stub_agent_ref "${FIXTURES}/stub-stable.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v1-stable" ]
}

@test "stub_agent_ref: parses a mismatched next agent_ref" {
  run src_stub_agent_ref "${FIXTURES}/stub-agent-next.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v1-next" ]
}

@test "stub_agent_ref: a stub with no agent_ref input returns non-zero" {
  run src_stub_agent_ref "${FIXTURES}/stub-no-agent-ref.yml"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# src_assert_self_review_stable — the end-to-end guard + its SC2 message (AC #3).
# ---------------------------------------------------------------------------

@test "assert: a stable-tier stub passes" {
  run src_assert_self_review_stable "${FIXTURES}/stub-stable.yml" "dev-lead.yml"
  [ "$status" -eq 0 ]
}

@test "assert: a legacy bare-stable stub passes (tier, not literal)" {
  run src_assert_self_review_stable "${FIXTURES}/stub-bare-stable.yml" "dev-lead.yml"
  [ "$status" -eq 0 ]
}

@test "assert: a next-pinned stub FAILS with a message naming SC2 and the regression" {
  run src_assert_self_review_stable "${FIXTURES}/stub-next.yml" "dev-lead.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2"* ]]
  [[ "$output" == *"circular dependency"* ]]
  # It must tell a "fix the ring drift" contributor the constraint, not just fail.
  [[ "$output" == *"pinned-version-report"* ]]
  [[ "$output" == *"DO NOT repin"* || "$output" == *"do not repin"* ]]
  # The offending ref/tier are named so the failure is actionable.
  [[ "$output" == *"dev-lead/v1-next"* ]]
  [[ "$output" == *"next"* ]]
}

@test "assert: a stable uses: with a next agent_ref FAILS (the SC2 bypass)" {
  run src_assert_self_review_stable "${FIXTURES}/stub-agent-next.yml" "dev-lead.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2"* ]]
  [[ "$output" == *"circular dependency"* ]]
  # The offending agent_ref is named so the failure is actionable.
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"dev-lead/v1-next"* ]]
}

@test "assert: a stable uses: with NO agent_ref FAILS closed (defaults to main)" {
  run src_assert_self_review_stable "${FIXTURES}/stub-no-agent-ref.yml" "dev-lead.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent_ref"* ]]
  [[ "$output" == *"main"* ]]
}

@test "assert: a @main pin FAILS the guard" {
  run src_assert_self_review_stable "${FIXTURES}/stub-main.yml" "dev-lead.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2"* ]]
}

@test "assert: a bare-SHA pin FAILS the guard" {
  run src_assert_self_review_stable "${FIXTURES}/stub-sha.yml" "dev-lead.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2"* ]]
}

# ---------------------------------------------------------------------------
# LIVE regression guard (AC #1) — the actual property this issue exists to
# preserve: the committed dev-lead self-review-duty stub resolves to a
# stable-tier channel. This is what fails if a future PR repins it to `next`.
# ---------------------------------------------------------------------------

@test "LIVE: .github/workflows/dev-lead.yml resolves to a stable-tier channel" {
  run src_assert_self_review_stable "${REPO_ROOT}/.github/workflows/dev-lead.yml" ".github/workflows/dev-lead.yml"
  [ "$status" -eq 0 ]
}

@test "LIVE: dev-lead.yml's parsed ref is specifically a stable tier" {
  ref="$(src_stub_uses_ref "${REPO_ROOT}/.github/workflows/dev-lead.yml")"
  run src_channel_tier "$ref"
  [ "$status" -eq 0 ]
  [ "$output" = "stable" ]
}

# ---------------------------------------------------------------------------
# pr-review-trigger.yml is the DELIBERATE ring-0 `next` canary, NOT part of the
# SC2 stable duty (its SC2 net is the break-glass, sc2-game-day.md mechanism 2).
# This guard records that intentional exclusion: it pins `next` on purpose, so
# it is correctly NOT asserted stable. If the pin ever changes, this notices —
# forcing the docs (AC #4) to be revisited rather than silently drifting.
# ---------------------------------------------------------------------------

@test "pr-review-trigger.yml is the deliberate ring-0 next canary (excluded from the stable duty)" {
  local stub="${REPO_ROOT}/.github/workflows/pr-review-trigger.yml"
  [ -f "$stub" ] || skip "pr-review-trigger.yml not present"
  ref="$(src_stub_uses_ref "$stub")"
  run src_channel_tier "$ref"
  [ "$status" -eq 0 ]
  [ "$output" = "next" ]
}
