#!/usr/bin/env bats
# Unit tests for scripts/lib/addressed-claim-verify.sh (#1692, epic #1621 story 2).
#
# The addressed-marker used to be an unverified assertion: resolve_addressed_bot_threads
# resolved a bot thread the moment its last reply carried `<!-- dev-lead:addressed -->`
# from our account, never checking whether the fix existed in the pushed diff (the
# PR #1044 byte-identical-functions defect). This lib is the pure verifier that makes
# the marker a *claim* checked against the diff, and scans ALL comments for a standing
# maintainer disposition. These tests exercise the pure helpers in isolation; the
# wiring into the harness is covered in test_fix_reviews.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib/addressed-claim-verify.sh"

SHA40="3cc4132fd4b4692aa20865f8b68ea8e21de604b8"

setup() {
  # shellcheck source=scripts/lib/addressed-claim-verify.sh
  source "$LIB"
}

# ---------------------------------------------------------------------------
# Sourcing safety
# ---------------------------------------------------------------------------

@test "addressed-claim-verify.sh is safe to source under set -euo pipefail" {
  run bash -c "set -euo pipefail; source '$LIB'"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ---------------------------------------------------------------------------
# acv_parse_claim — extraction + field contract
# ---------------------------------------------------------------------------

@test "acv_parse_claim: valid claim returns 0 and echoes canonical JSON" {
  local body="Fixed in scripts/lib/auto-merge.sh: added guard.

<!-- dev-lead:addressed -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"scripts/lib/auto-merge.sh\",\"tests/auto_merge.bats\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .sha)" == "$SHA40" ]]
  [[ "$(echo "$output" | jq -r '.files|length')" == "2" ]]
}

@test "acv_parse_claim: no claim comment (pre-migration marker only) -> no-claim, non-zero" {
  local body="Applied the fix.

<!-- dev-lead:addressed -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-claim" ]]
}

@test "acv_parse_claim: empty body -> no-claim, non-zero" {
  run acv_parse_claim ""
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-claim" ]]
}

@test "acv_parse_claim: two claim comments -> multiple-claims (never take the last)" {
  local body="Fixed it.
<!-- dev-lead:addressed -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"a\"]} -->
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"b\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "multiple-claims" ]]
}

@test "acv_parse_claim: malformed JSON -> malformed-json" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1, not json} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "malformed-json" ]]
}

@test "acv_parse_claim: unrecognised schema version -> bad-version (never assume v1)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":2,\"sha\":\"$SHA40\",\"files\":[\"a\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-version" ]]
}

@test "acv_parse_claim: abbreviated sha -> bad-sha (exact 40-char lookup only)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"3cc4132\",\"files\":[\"a\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-sha" ]]
}

@test "acv_parse_claim: empty files array -> bad-files" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "bad-files" ]]
}

@test "acv_parse_claim: a file path containing a space is preserved (JSON array, not IFS split)" {
  local body="Fixed it.
<!-- dev-lead:claim {\"v\":1,\"sha\":\"$SHA40\",\"files\":[\"dir with space/a.sh\"]} -->"
  run acv_parse_claim "$body"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r '.files[0]')" == "dir with space/a.sh" ]]
}

# ---------------------------------------------------------------------------
# acv_verify_intersection — non-empty diff + file intersection (AC2/AC3)
# ---------------------------------------------------------------------------

@test "acv_verify_intersection: named commit's own diff touches a claimed file -> own" {
  run acv_verify_intersection '["scripts/foo.sh","x/y.bats"]' $'scripts/foo.sh\nunrelated.md' $'other.txt'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "own" ]]
}

@test "acv_verify_intersection: only the cumulative range touches a claimed file -> cumulative" {
  run acv_verify_intersection '["scripts/foo.sh"]' $'unrelated.md' $'scripts/foo.sh\nother.txt'
  [[ "$status" -eq 0 ]]
  [[ "$output" == "cumulative" ]]
}

@test "acv_verify_intersection: empty diff in both ranges -> empty-diff (fail closed)" {
  run acv_verify_intersection '["scripts/foo.sh"]' '' ''
  [[ "$status" -ne 0 ]]
  [[ "$output" == "empty-diff" ]]
}

@test "acv_verify_intersection: diff touches no claimed file (PR #1044 shape) -> no-file-intersection" {
  run acv_verify_intersection '["scripts/foo.sh"]' $'scripts/bar.sh\nREADME.md' $'scripts/bar.sh\nREADME.md'
  [[ "$status" -ne 0 ]]
  [[ "$output" == "no-file-intersection" ]]
}

# ---------------------------------------------------------------------------
# acv_latest_maintainer_disposition — scan ALL comments (AC4)
# ---------------------------------------------------------------------------

@test "acv_latest_maintainer_disposition: no maintainer disposition -> rc1, empty" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_maintainer_disposition: marker-less human 'required before merge' -> rc0 with its date" {
  local comments='[
    {"author":{"login":"a-maintainer","__typename":"User"},"body":"ACCEPTED — required before merge","createdAt":"2026-09-02T12:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Fixed. <!-- dev-lead:addressed -->","createdAt":"2026-09-02T13:00:00Z"}
  ]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-02T12:00:00Z" ]]
}

@test "acv_latest_maintainer_disposition: an agent-marker comment is never a maintainer disposition" {
  # Body says 'required' but carries our marker -> agent-authored -> ignored.
  local comments='[{"author":{"login":"don-petry","__typename":"User"},"body":"This was required. <!-- dev-lead:addressed -->","createdAt":"2026-09-02T12:00:00Z"}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}

@test "acv_latest_maintainer_disposition: disposition with unparseable date -> rc2 (fail closed)" {
  local comments='[{"author":{"login":"a-maintainer","__typename":"User"},"body":"changes required","createdAt":""}]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "unparseable" ]]
}

@test "acv_latest_maintainer_disposition: multiple dispositions -> latest date wins" {
  local comments='[
    {"author":{"login":"m1","__typename":"User"},"body":"REQUIRED","createdAt":"2026-09-01T00:00:00Z"},
    {"author":{"login":"m2","__typename":"User"},"body":"blocking issue here","createdAt":"2026-09-05T00:00:00Z"}
  ]'
  run acv_latest_maintainer_disposition "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2026-09-05T00:00:00Z" ]]
}

# ---------------------------------------------------------------------------
# acv_latest_marker_index — find our addressed-marker reply anywhere in the thread (#1735 AC1)
# ---------------------------------------------------------------------------

@test "acv_latest_marker_index: our marker reply as the only comment -> index 0" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "0" ]]
}

@test "acv_latest_marker_index: marker reply after a bot finding -> its index (not comments(last:1))" {
  local comments='[
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Potential issue here.","createdAt":"2026-09-01T09:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "1" ]]
}

@test "acv_latest_marker_index: marker NOT the latest comment (bot ack follows) -> still found" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Customized review instruction saved!","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "0" ]]
}

@test "acv_latest_marker_index: multiple of our markers -> latest index wins" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"First. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"still an issue","createdAt":"2026-09-01T11:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Second. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T12:00:00Z"}
  ]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "2" ]]
}

@test "acv_latest_marker_index: no marker anywhere -> rc1 (unchanged no-marker behavior)" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Looked into it, no change.","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_marker_index: marker from another account -> rc1 (not ours)" {
  local comments='[{"author":{"login":"someone-else","__typename":"User"},"body":"Applied. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_latest_marker_index "$comments" "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

@test "acv_latest_marker_index: empty array -> rc1" {
  run acv_latest_marker_index '[]' "donpetry-bot"
  [[ "$status" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# acv_bot_comment_is_acknowledgement — ack / finding / undeterminable (#1735 AC2/AC4)
# ---------------------------------------------------------------------------

@test "acv_bot_comment_is_acknowledgement: codeant 'Customized review instruction saved' -> rc0 (ack)" {
  run acv_bot_comment_is_acknowledgement "✅ Customized review instruction saved!"
  [[ "$status" -eq 0 ]]
}

@test "acv_bot_comment_is_acknowledgement: 'Acknowledged, will not flag this again' -> rc0 (ack)" {
  run acv_bot_comment_is_acknowledgement "Acknowledged. We will not flag this pattern again."
  [[ "$status" -eq 0 ]]
}

@test "acv_bot_comment_is_acknowledgement: a new finding -> rc1 (blocks)" {
  run acv_bot_comment_is_acknowledgement "Potential issue: this introduces a race condition on shutdown."
  [[ "$status" -eq 1 ]]
}

@test "acv_bot_comment_is_acknowledgement: ack phrasing mixed with a new finding -> rc1 (finding wins, fail toward blocking)" {
  run acv_bot_comment_is_acknowledgement "Instruction saved, but there is a new issue: unhandled null."
  [[ "$status" -eq 1 ]]
}

@test "acv_bot_comment_is_acknowledgement: undeterminable chatter -> rc2 (fail closed)" {
  run acv_bot_comment_is_acknowledgement "Interesting perspective on the tradeoffs here."
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: empty body -> rc2 (fail closed)" {
  run acv_bot_comment_is_acknowledgement ""
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: negated 'cannot acknowledge this' -> rc2 (not an ack, fail closed)" {
  run acv_bot_comment_is_acknowledgement "I cannot acknowledge this refutation as valid."
  [[ "$status" -eq 2 ]]
}

@test "acv_bot_comment_is_acknowledgement: negated 'unable to fully acknowledge' -> rc2 (not an ack, fail closed)" {
  run acv_bot_comment_is_acknowledgement "We are unable to fully acknowledge the change."
  [[ "$status" -eq 2 ]]
}

# ---------------------------------------------------------------------------
# acv_post_marker_clear — nothing unaddressed since our marker (#1735 AC2/AC3/AC4)
# ---------------------------------------------------------------------------

@test "acv_post_marker_clear: nothing after the marker -> clear rc0" {
  local comments='[{"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"}]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: bot acknowledgement after our marker -> clear rc0 (AC2)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"✅ Customized review instruction saved!","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: bot NEW finding after our marker -> blocks rc1 (AC2)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Potential issue: new race condition on shutdown.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "bot-finding" ]]
}

@test "acv_post_marker_clear: human comment after our marker ALWAYS blocks regardless of content -> rc1 (AC3, preserves #1415)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"a-maintainer","__typename":"User"},"body":"Looks fine to me, thanks.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 1 ]]
  [[ "$output" == "human" ]]
}

@test "acv_post_marker_clear: undeterminable bot comment after our marker -> fail closed rc2 (AC4)" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"codeant-ai[bot]","__typename":"Bot"},"body":"Interesting.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 2 ]]
  [[ "$output" == "bot-ambiguous" ]]
}

@test "acv_post_marker_clear: our own later note after the marker is ours -> clear rc0" {
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Rebased onto latest main.","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

@test "acv_post_marker_clear: a post-marker comment carrying our marker is ours by the shared discriminator -> clear rc0" {
  # A User comment that carries one of our automation markers is agent-authored per
  # review_thread_is_agent_authored, so it is never treated as a human finding (#1735 AC3).
  local comments='[
    {"author":{"login":"donpetry-bot","__typename":"User"},"body":"Refuted. <!-- dev-lead:addressed -->","createdAt":"2026-09-01T10:00:00Z"},
    {"author":{"login":"don-petry","__typename":"User"},"body":"Follow-up note. <!-- dev-lead -->","createdAt":"2026-09-01T11:00:00Z"}
  ]'
  run acv_post_marker_clear "$comments" 0 "donpetry-bot"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "clear" ]]
}

# ---------------------------------------------------------------------------
# acv_gather_commit_facts — the impure gatherer, against a real git repo
# ---------------------------------------------------------------------------

@test "acv_gather_commit_facts: reports on_head + own/cumulative files for a real commit" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0
  echo two > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c1
  local mid
  mid="$(git -C "$repo" rev-parse HEAD)"
  echo three > "$repo/c.txt"
  git -C "$repo" add c.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c2

  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts '$mid'"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .on_head)" == "true" ]]
  [[ "$(echo "$output" | jq -r '.own_files[0]')" == "b.txt" ]]
  # cumulative mid^..HEAD covers b.txt (mid) and c.txt (the later commit).
  [[ "$(echo "$output" | jq -c '.cumulative_files|sort')" == '["b.txt","c.txt"]' ]]
  # commit_date must be a Z-terminated UTC ISO-8601 instant (same shape as
  # GitHub's createdAt) so jq's fromdateiso8601 and the lexicographic disposition
  # comparison both accept it — a `%cI` `+00:00` offset would break both.
  local cdate
  cdate="$(echo "$output" | jq -r .commit_date)"
  [[ -n "$cdate" ]]
  [[ "$cdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  run bash -c "source '$LIB' && _acv_is_iso8601 '$cdate'"
  [[ "$status" -eq 0 ]]
}

@test "acv_gather_commit_facts: a sha absent from the repo -> on_head false, fail closed" {
  local repo="$BATS_TEST_TMPDIR/repo2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  echo one > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" -c user.email=t@t -c user.name=T commit -q -m c0

  run bash -c "cd '$repo' && source '$LIB' && acv_gather_commit_facts 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'"
  [[ "$status" -eq 0 ]]
  [[ "$(echo "$output" | jq -r .on_head)" == "false" ]]
  [[ "$(echo "$output" | jq -c .own_files)" == "[]" ]]
}
