#!/usr/bin/env bash
# self-review-channel.sh — SC2 self-review-duty channel-tier guard (#1624).
#
# Safe Release SC2 (epic #495 / story #503): a deliberately-broken in-development
# version of this repo's agentic review/merge duty must NOT be able to block the
# PR that fixes its own breakage. For `.github-private`'s dev/merge duty the
# structural property that guarantees this is that `dev-lead.yml` pins its
# reusable to a **stable-tier** channel (`@dev-lead/v1-stable`) even though this
# repo sits in ring `next` — so a broken `next` cannot, by construction, gate its
# own fix. This is the sanctioned SC2 exception the `pinned-version-report`
# ring-mismatch flag calls out (see docs/release/versioning.md,
# docs/initiatives/agentic-release-strategy.md).
#
# These are pure helpers with no side effects and no network: they parse the
# `uses:` channel pin from a caller stub and classify its TIER. "stable-tier"
# means the channel tier, not a literal string — both the major-scoped
# `v1-stable` and the legacy bare `stable` qualify; `v1-next`, `next`, `ring0`,
# `@main`, and bare SHAs do not.
#
# Sourced by tests/test_sc2_self_review_channel.bats. This file defines functions
# only (no top-level `set -euo pipefail`), matching the repo's sourceable-lib
# convention (e.g. scripts/lib/holdout-guard.sh).

# src_stub_uses_ref <stub_file>
#   Echo the ref of the first reusable-workflow caller pin — the token after the
#   final `@` on a `uses: …/<workflow>.yml@<ref>` line — with the trailing inline
#   `# NOSONAR …` comment and surrounding whitespace stripped. Returns non-zero
#   if the file has no such pin.
src_stub_uses_ref() {
  local file="$1" line stripped ref content
  [ -f "$file" ] || return 1
  content="$(grep -E '^[[:space:]]*uses:[[:space:]]*[^[:space:]#]+\.yml@' "$file")" || true
  line="${content%%$'\n'*}"               # first matching line, no pipe to head (avoids SIGPIPE under pipefail)
  [ -n "$line" ] || return 1
  stripped="${line%%#*}"                 # drop any inline comment
  read -r ref <<<"${stripped##*@}"       # token after the last @, whitespace-trimmed
  [ -n "$ref" ] || return 1
  printf '%s\n' "$ref"
}

# src_channel_tier <ref>
#   Map a channel ref to its tier and echo it. Accepts either the full
#   `<agent>/<channel>` form (e.g. `dev-lead/v1-stable`) or a bare `<channel>`
#   (e.g. `v1-stable`). The tier is the suffix of a major-scoped
#   `v<MAJOR>-<tier>` channel, or a bare `<tier>` (pre-#1184 legacy form).
#   Recognised tiers: stable | next | ring<N>. Returns non-zero for anything
#   that is not a channel tier at all (`main`, a bare commit SHA, …).
src_channel_tier() {
  local ref="$1" chan tier
  chan="${ref##*/}"                      # channel token (drop any agent/ prefix)
  if [[ "$chan" =~ ^v[0-9]+-(stable|next|ring[0-9]+)$ ]]; then
    tier="${BASH_REMATCH[1]}"
  elif [[ "$chan" =~ ^(stable|next|ring[0-9]+)$ ]]; then
    tier="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  printf '%s\n' "$tier"
}

# src_is_stable_tier <ref>
#   Return 0 iff <ref>'s channel tier is `stable`.
src_is_stable_tier() {
  local ref="$1" tier
  tier="$(src_channel_tier "$ref")" || return 1
  [ "$tier" = "stable" ]
}

# src_assert_self_review_stable <stub_file> [<label>]
#   The end-to-end SC2 guard: parse the stub's channel pin and assert it is a
#   stable tier. On failure emit a message that NAMES SC2 and explains why a
#   `next` pin here is a regression — so a future contributor "fixing the ring
#   drift" is told the constraint rather than deleting the guard.
src_assert_self_review_stable() {
  local file="$1" label="${2:-$1}" ref tier
  if ! ref="$(src_stub_uses_ref "$file")"; then
    printf '::error::SC2 self-review guard: could not parse a reusable `uses:` channel pin from %s\n' "$file" >&2
    return 1
  fi
  if src_is_stable_tier "$ref"; then
    printf 'SC2 self-review guard: %s pins a stable-tier channel (%s) — OK\n' "$label" "$ref"
    return 0
  fi
  tier="$(src_channel_tier "$ref" 2>/dev/null)" || tier="not-a-channel"
  {
    printf '::error::SC2 REGRESSION: %s pins the self-review/dev duty to a non-stable channel (ref="%s", tier="%s").\n' "$label" "$ref" "$tier"
    printf 'This repo (.github-private) sits in ring `next`, but its dev-lead review/merge duty MUST pin a STABLE-tier channel so a\n'
    printf 'broken in-development version cannot block the PR that fixes its own breakage — restoring a non-stable pin here silently\n'
    printf 're-arms the self-hosting circular dependency (Safe Release SC2, epic #495 / story #503).\n'
    printf 'If you are "fixing the ring drift" flagged by pinned-version-report: DO NOT repin to `next` — pinned-version-report is\n'
    printf 'correct from the ring-rollout view and this stable pin is correct from the SC2 view; the stable pin is the DELIBERATE SC2\n'
    printf 'exception. See docs/release/versioning.md and docs/initiatives/agentic-release-strategy.md.\n'
  } >&2
  return 1
}
