#!/usr/bin/env bats
# Tests for comment-disposition-verify.sh (issue #1813)
#
# The pure verifier that turns a dev-lead comment-disposition reply into a
# machine-checkable claim, and decides whether the harness may resolve (minimize
# as RESOLVED) the original PR issue comment. Mirrors addressed-claim-verify.sh
# (review-thread path) for the issue-comment path.
#
#   cdv_parse_disposition <reply_body>
#     0 + canonical JSON {id,disposition,sha,ref}   (valid single marker)
#     1 + reason token (no-disposition | multiple-dispositions | bad-id |
#                       bad-disposition | bad-sha | missing-ref)
#   cdv_authorize <disposition> <is_human> <verified>
#     0 = the harness may minimize the comment RESOLVED; 1 = leave it open
#   cdv_reply_needs_response <bot_reply_body>
#     0 = the bot's reply-to-our-disposition raises a NEW finding (answer it)
#     1 = boilerplate / acknowledgement / ambiguous (do NOT answer — loop safety)

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME%/*}")" && pwd)/../../scripts"
  LIB="$SCRIPT_DIR/lib/comment-disposition-verify.sh"
}

teardown() {
  unset SCRIPT_DIR
}

_parse() {
  run bash -c "source '$LIB'; cdv_parse_disposition \"\$1\"" _ "$1"
}

_authorize() {
  run bash -c "source '$LIB'; cdv_authorize \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}

_needs_response() {
  run bash -c "source '$LIB'; cdv_reply_needs_response \"\$1\"" _ "$1"
}

# ────────────────────────────────────────────────────────────────────
# STRUCTURAL
# ────────────────────────────────────────────────────────────────────

@test "verifier: has correct shebang" {
  head -1 "$LIB" | grep -q "^#!/usr/bin/env bash"
}

@test "verifier: uses set -euo pipefail" {
  grep -q "^set -euo pipefail" "$LIB"
}

@test "verifier: shellcheck passes" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  shellcheck --shell=bash --severity=warning "$LIB"
}

# ────────────────────────────────────────────────────────────────────
# cdv_parse_disposition
# ────────────────────────────────────────────────────────────────────

@test "parse: valid answered disposition → JSON" {
  _parse 'Answered below.
<!-- dev-lead:comment-disposition id=IC_123 disposition=answered -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "IC_123" and .disposition == "answered"'
}

@test "parse: valid fixed disposition with sha → JSON" {
  _parse 'Fixed.
<!-- dev-lead:comment-disposition id=IC_9 disposition=fixed sha=3cc4132fd4b4692aa20865f8b68ea8e21de604b8 -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.disposition == "fixed" and (.sha | length) == 40'
}

@test "parse: valid out-of-scope disposition with ref → JSON" {
  _parse 'Tracked elsewhere.
<!-- dev-lead:comment-disposition id=IC_9 disposition=out-of-scope ref=#42 -->'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.disposition == "out-of-scope" and .ref == "#42"'
}

@test "parse: no marker → no-disposition rc1" {
  _parse 'Just a plain reply with no marker.'
  [ "$status" -eq 1 ]
  [ "$output" = "no-disposition" ]
}

@test "parse: two markers → multiple-dispositions rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=answered -->
<!-- dev-lead:comment-disposition id=b disposition=invalid -->'
  [ "$status" -eq 1 ]
  [ "$output" = "multiple-dispositions" ]
}

@test "parse: unknown disposition word → bad-disposition rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=maybe -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-disposition" ]
}

@test "parse: fixed without sha → bad-sha rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=fixed -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-sha" ]
}

@test "parse: fixed with abbreviated sha → bad-sha rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=fixed sha=3cc4132 -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-sha" ]
}

@test "parse: out-of-scope without ref → missing-ref rc1" {
  _parse '<!-- dev-lead:comment-disposition id=a disposition=out-of-scope -->'
  [ "$status" -eq 1 ]
  [ "$output" = "missing-ref" ]
}

@test "parse: missing id → bad-id rc1" {
  _parse '<!-- dev-lead:comment-disposition disposition=answered -->'
  [ "$status" -eq 1 ]
  [ "$output" = "bad-id" ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_authorize  (AC4 / AC5)
# ────────────────────────────────────────────────────────────────────

@test "authorize: bot comment + any verified disposition → 0 (resolve)" {
  _authorize answered false true
  [ "$status" -eq 0 ]
}

@test "authorize: bot comment + unverified disposition → 1 (leave open)" {
  _authorize answered false false
  [ "$status" -eq 1 ]
}

# AC9(c): a fixed disposition whose sha is not on head is unverified → blocks.
@test "AC9c: fixed disposition, sha not on head (verified=false) → 1 (block)" {
  _authorize fixed false false
  [ "$status" -eq 1 ]
}

# AC5: a human maintainer comment auto-resolves ONLY on a verified fixed.
@test "AC5: human comment + verified fixed → 0 (resolve)" {
  _authorize fixed true true
  [ "$status" -eq 0 ]
}

# AC9(d): a human comment with a non-fixed disposition stays open for the human.
@test "AC9d: human comment + verified invalid → 1 (leave open for human)" {
  _authorize invalid true true
  [ "$status" -eq 1 ]
}

@test "AC9d: human comment + verified answered → 1 (leave open for human)" {
  _authorize answered true true
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_reply_needs_response  (AC7 / AC9f — loop safety)
# ────────────────────────────────────────────────────────────────────

# AC9(f): a bot's boilerplate/acknowledgement reply does not trigger another reply.
@test "AC9f: bot boilerplate ack reply → 1 (do not respond)" {
  _needs_response '✅ Customized review instruction saved!'
  [ "$status" -eq 1 ]
}

@test "AC9f: bot reply with a genuinely new finding → 0 (respond)" {
  _needs_response 'Potential issue: this introduces a SQL injection vulnerability.'
  [ "$status" -eq 0 ]
}

@test "AC9f: ambiguous bot reply → 1 (do not respond — no chain)" {
  _needs_response 'Thanks for the update.'
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────────────
# cdv_select_disposition  (issue #1992 — duplicate recovery / idempotency)
#
#   cdv_select_disposition <cid> <bot_user> <comments_json>
#     Picks, among BOT_USER-authored, non-minimized, parseable disposition
#     replies citing <cid>, the LATEST by createdAt (tie-break: node id). Emits
#     {auth_count, chosen:{id,createdAt,disposition}, superseded:[ids]} and
#     returns 0 when >=1, else emits auth_count 0 and returns 1. Pure.
# ────────────────────────────────────────────────────────────────────

_select() {
  run bash -c "source '$LIB'; cdv_select_disposition \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}

# A BOT_USER disposition reply node. $1=id $2=createdAt $3=disposition $4=target-id [$5=sha]
_mk_reply() {
  local id="$1" created="$2" disp="$3" tid="$4" sha="${5:-}"
  local marker="<!-- dev-lead:comment-disposition id=${tid} disposition=${disp}"
  [ -n "$sha" ] && marker="${marker} sha=${sha}"
  marker="${marker} -->"
  jq -n --arg id "$id" --arg c "$created" \
    --arg body "Looked into it.
${marker}" \
    '{id:$id, author:{login:"donpetry-bot", __typename:"User"}, body:$body, isMinimized:false, minimizedReason:null, createdAt:$c}'
}

@test "select: single authorized disposition → auth_count 1, chosen is it, no superseded (idempotent)" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R1" ]
  [ "$(echo "$output" | jq -r '.superseded | length')" = "0" ]
}

@test "select: three authorized dispositions → latest chosen, other two superseded (#1952)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_fixed" "2026-09-26T21:44:49Z" "fixed" "IC_X" "c03ecdac03ecdac03ecdac03ecdac03ecdac03ec") \
    <(_mk_reply "R_inv1"  "2026-09-26T21:56:53Z" "invalid" "IC_X") \
    <(_mk_reply "R_inv2"  "2026-09-26T22:16:28Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "3" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_inv2" ]
  [ "$(echo "$output" | jq -r '.chosen.disposition.disposition')" = "invalid" ]
  [ "$(echo "$output" | jq -r '.superseded | sort | join(",")')" = "R_fixed,R_inv1" ]
}

@test "select: non-BOT_USER disposition is ignored and cannot win (CWE-863)" {
  # An attacker posts a LATER disposition citing the same id; it must not win,
  # and must not even be counted — only the earlier BOT_USER reply is authorized.
  local attacker bot c
  attacker=$(jq -n '{id:"R_attack", author:{login:"mallory", __typename:"User"},
    body:"fixed it\n<!-- dev-lead:comment-disposition id=IC_X disposition=fixed sha=c03ecdac03ecdac03ecdac03ecdac03ecdac03ec -->",
    isMinimized:false, minimizedReason:null, createdAt:"2026-09-27T00:00:00Z"}')
  bot=$(_mk_reply "R_bot" "2026-09-26T21:00:00Z" "invalid" "IC_X")
  c=$(jq -s '.' <(echo "$bot") <(echo "$attacker"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_bot" ]
  [ "$(echo "$output" | jq -r '.superseded | length')" = "0" ]
}

@test "select: minimized disposition replies are excluded" {
  local minimized bot c
  minimized=$(jq -n '{id:"R_old", author:{login:"donpetry-bot", __typename:"User"},
    body:"old\n<!-- dev-lead:comment-disposition id=IC_X disposition=invalid -->",
    isMinimized:true, minimizedReason:"OUTDATED", createdAt:"2026-09-27T00:00:00Z"}')
  bot=$(_mk_reply "R_live" "2026-09-26T21:00:00Z" "answered" "IC_X")
  c=$(jq -s '.' <(echo "$minimized") <(echo "$bot"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_live" ]
}

@test "select: unparseable marker among them is ignored (fails closed, not counted)" {
  local bad bot c
  bad=$(jq -n '{id:"R_bad", author:{login:"donpetry-bot", __typename:"User"},
    body:"two markers\n<!-- dev-lead:comment-disposition id=IC_X disposition=invalid -->\n<!-- dev-lead:comment-disposition id=IC_X disposition=fixed -->",
    isMinimized:false, minimizedReason:null, createdAt:"2026-09-27T05:00:00Z"}')
  bot=$(_mk_reply "R_good" "2026-09-26T21:00:00Z" "invalid" "IC_X")
  c=$(jq -s '.' <(echo "$bad") <(echo "$bot"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_good" ]
}

@test "select: a disposition citing a DIFFERENT id does not match" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_OTHER"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "0" ]
}

@test "select: zero authorized dispositions → rc1, auth_count 0" {
  _select "IC_X" "donpetry-bot" "[]"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "0" ]
}

@test "select: equal createdAt ties broken deterministically by node id (higher wins)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_aaa" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_zzz" "2026-09-26T21:00:00Z" "answered" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_zzz" ]
  [ "$(echo "$output" | jq -r '.superseded[0]')" = "R_aaa" ]
}

@test "select: a reply with missing isMinimized is excluded (fails closed)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_ok" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_unk" "2026-09-26T22:00:00Z" "invalid" "IC_X" | jq 'del(.isMinimized)'))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_ok" ]
}

@test "select: a reply with a malformed createdAt cannot win as latest (fails closed)" {
  local c
  c=$(jq -s '.' \
    <(_mk_reply "R_ok" "2026-09-26T21:00:00Z" "invalid" "IC_X") \
    <(_mk_reply "R_bad" "zzzz-not-a-time" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.auth_count')" = "1" ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R_ok" ]
}

@test "select: matches BOT_USER given with [bot] suffix (graphql-stripped login)" {
  local c; c=$(jq -s '.' <(_mk_reply "R1" "2026-09-26T21:00:00Z" "invalid" "IC_X"))
  _select "IC_X" "donpetry-bot[bot]" "$c"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.chosen.id')" = "R1" ]
}
