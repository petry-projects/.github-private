#!/usr/bin/env bats
# Unit tests for scripts/lib/pr-review-claim.sh (issue #1589, slice 1).
#
# Slice 1 is OBSERVE-ONLY: it introduces the per-PR review-claim primitive that
# makes the #1551 same-SHA re-review race visible, without arbitrating it yet
# (slice 2). The primitive is:
#   • claim key   = (head SHA, current metadata digest)
#   • claim marker = <!-- pr-review-claim v1 sha=<SHA> meta=<DIGEST> run=<TOKEN> at=<TS> -->
# These tests lock in that the marker round-trips, the key is sensitive to both
# the SHA and the digest (and only those), and that a pre-existing live claim for
# the same key posted by a DIFFERENT run is detected — the observability signal
# the race needs.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$REPO_ROOT/scripts/lib/pr-review-claim.sh"
  SHA="8203876e5b0718dd3d672fed4eec8394e5d3729d"
  DIGEST="deadbeefdeadbeef"
}

@test "claim_marker round-trips: the marker's parsed key equals claim_key" {
  local marker; marker="$(claim_marker "$SHA" "$DIGEST" "run-abc-1" "2026-08-31T04:11:00Z")"
  [[ "$marker" == "<!-- pr-review-claim v1 sha=$SHA meta=$DIGEST run=run-abc-1 at=2026-08-31T04:11:00Z -->" ]]
  run claim_marker_key "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "$(claim_key "$SHA" "$DIGEST")" ]
}

@test "claim_marker_run extracts the run token" {
  local marker; marker="$(claim_marker "$SHA" "$DIGEST" "run-xyz-9" "2026-08-31T04:11:00Z")"
  run claim_marker_run "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "run-xyz-9" ]
}

@test "claim_key changes when the SHA changes" {
  local a b
  a="$(claim_key "$SHA" "$DIGEST")"
  b="$(claim_key "ffffffffffffffffffffffffffffffffffffffff" "$DIGEST")"
  [ "$a" != "$b" ]
}

@test "claim_key changes when the digest changes" {
  local a b
  a="$(claim_key "$SHA" "$DIGEST")"
  b="$(claim_key "$SHA" "0000000000000000")"
  [ "$a" != "$b" ]
}

@test "claim_key is stable when neither SHA nor digest changes" {
  [ "$(claim_key "$SHA" "$DIGEST")" = "$(claim_key "$SHA" "$DIGEST")" ]
}

@test "claim_marker_key is empty for a non-claim body" {
  run claim_marker_key '<!-- pr-review-agent v1 sha=abc123 decision=approved risk=LOW -->'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- concurrent_claim_present ---------------------------------------------

# Build a comments JSON array whose bodies are the given claim markers.
_comments_json() {
  local arr='[]'
  local b
  for b in "$@"; do
    arr="$(jq -c --arg body "$b" '. + [{body:$body}]' <<< "$arr")"
  done
  printf '%s' "$arr"
}

@test "concurrent_claim_present detects a live claim on the same key from a different run" {
  local other; other="$(claim_marker "$SHA" "$DIGEST" "run-OTHER" "2026-08-31T04:10:00Z")"
  local mine;  mine="$(claim_marker "$SHA" "$DIGEST" "run-MINE" "2026-08-31T04:11:00Z")"
  local comments; comments="$(_comments_json "$other" "$mine")"
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" "$comments"
  [ "$status" -eq 0 ]
}

@test "concurrent_claim_present is false when only our own claim exists" {
  local mine; mine="$(claim_marker "$SHA" "$DIGEST" "run-MINE" "2026-08-31T04:11:00Z")"
  local comments; comments="$(_comments_json "$mine")"
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" "$comments"
  [ "$status" -ne 0 ]
}

@test "concurrent_claim_present ignores a claim for a different key (different SHA)" {
  local other_sha="ffffffffffffffffffffffffffffffffffffffff"
  local other; other="$(claim_marker "$other_sha" "$DIGEST" "run-OTHER" "2026-08-31T04:10:00Z")"
  local comments; comments="$(_comments_json "$other")"
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" "$comments"
  [ "$status" -ne 0 ]
}

@test "concurrent_claim_present ignores a claim for a different key (different digest)" {
  local other; other="$(claim_marker "$SHA" "0000000000000000" "run-OTHER" "2026-08-31T04:10:00Z")"
  local comments; comments="$(_comments_json "$other")"
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" "$comments"
  [ "$status" -ne 0 ]
}

@test "concurrent_claim_present is false on an empty / claim-free comment set" {
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" '[]'
  [ "$status" -ne 0 ]
  local noise; noise="$(_comments_json '<!-- pr-review-agent v1 sha=abc decision=approved -->')"
  run concurrent_claim_present "run-MINE" "$SHA" "$DIGEST" "$noise"
  [ "$status" -ne 0 ]
}
