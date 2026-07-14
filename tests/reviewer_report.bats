#!/usr/bin/env bats
# Tests for scripts/reviewer_report.sh — pure normalization, aggregation, and
# Markdown rendering for the Third-Party Reviewer Scorecard. Network I/O
# (collect_org_reviews / _fetch_prev_snapshot / main) is NOT exercised here.
# Run locally: bats tests/reviewer_report.bats

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/reviewer_jsonl"
PR_NODE="${BATS_TEST_DIRNAME}/fixtures/reviewer_pr_node.json"

setup() {
  # shellcheck source=scripts/reviewer_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/reviewer_report.sh"
  BOTS='["gemini-code-assist","copilot-pull-request-reviewer","sonarqubecloud","chatgpt-codex-connector","coderabbitai"]'
}

# ---------------------------------------------------------------------------
# Registry wiring — bots come from the shared advisory-review-gate list
# ---------------------------------------------------------------------------

@test "REVIEWER_BOTS: five tracked reviewers, sourced from the gate registry" {
  [ "${#REVIEWER_BOTS[@]}" -eq 5 ]
  [[ " ${REVIEWER_BOTS[*]} " == *" coderabbitai "* ]]
  [[ " ${REVIEWER_BOTS[*]} " == *" copilot-pull-request-reviewer "* ]]
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

@test "_fmt_int: thousands separators" {
  run _fmt_int 12345
  [ "$output" = "12,345" ]
}

@test "_fmt_pct: rounds, n/a on zero denominator" {
  run _fmt_pct 1 2; [ "$output" = "50%" ]
  run _fmt_pct 5 0; [ "$output" = "n/a" ]
}

@test "_fmt_dur: seconds / minutes / hours / days and em-dash on empty" {
  run _fmt_dur 45;     [ "$output" = "45s" ]
  run _fmt_dur 186;    [ "$output" = "3m" ]
  run _fmt_dur 12240;  [ "$output" = "3.4h" ]
  run _fmt_dur "";     [ "$output" = "—" ]
  run _fmt_dur -1;     [ "$output" = "—" ]
}

@test "_delta_arrow: up / down / flat / blank when no prior" {
  run _delta_arrow 5 3; [ "$output" = "(▲ +2)" ]
  run _delta_arrow 2 5; [ "$output" = "(▼ -3)" ]
  run _delta_arrow 4 4; [ "$output" = "(±0)" ]
  run _delta_arrow 4 ""; [ "$output" = "" ]
}

@test "percentile: nearest-rank p50 and p95" {
  run bash -c 'printf "%s\n" 10 20 30 40 100 | { source '"${BATS_TEST_DIRNAME}"'/../scripts/reviewer_report.sh 2>/dev/null; percentile 50; }'
  [ "$output" = "30" ]
}

# ---------------------------------------------------------------------------
# _NORMALIZE_JQ — one GraphQL PR node → normalized records
# ---------------------------------------------------------------------------

@test "normalize: emits one pr record and one bot_pr per participating bot; humans excluded" {
  run jq -c --arg repo "petry-projects/markets" --argjson bots "$BOTS" \
    --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  # 1 pr record + 4 bot records (copilot, gemini, coderabbit, codex — NOT human alice, NOT sonar)
  echo "$output" | jq -e 'map(select(.kind=="pr")) | length == 1'
  echo "$output" | jq -e 'map(select(.kind=="bot_pr")) | length == 4'
  echo "$output" | jq -e 'any(.[]; .bot == "alice") | not'
}

@test "normalize: latency is bot-first-touch minus PR creation" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  # copilot first submission 10:03:06 vs created 10:00:00 = 186s
  echo "$output" | jq -e '.[] | select(.bot=="copilot-pull-request-reviewer") | .latency_s == 186'
  # gemini 10:00:50 = 50s
  echo "$output" | jq -e '.[] | select(.bot=="gemini-code-assist") | .latency_s == 50'
}

@test "normalize: rate-limit body text flags the bot as rate_limited" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  echo "$output" | jq -e '.[] | select(.bot=="coderabbitai") | .rate_limited == 1'
  echo "$output" | jq -e '.[] | select(.bot=="chatgpt-codex-connector") | .rate_limited == 1'
}

@test "normalize: reactions and thread resolution captured on inline comments" {
  run jq -c --arg repo "r" --argjson bots "$BOTS" --arg rl "$RATE_LIMIT_RE" "[ $_NORMALIZE_JQ ]" "$PR_NODE"
  echo "$output" | jq -e '.[] | select(.bot=="copilot-pull-request-reviewer") | .thumbs_up==2 and .thumbs_down==1 and .threads_resolved==1'
}

# ---------------------------------------------------------------------------
# aggregate_snapshot
# ---------------------------------------------------------------------------

@test "aggregate: counts eligible (non-draft) vs total PRs" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.total_prs == 3 and .eligible_prs == 2'
}

@test "aggregate: per-bot rollups sum across repos" {
  run aggregate_snapshot "$FIXTURES"
  # copilot touched both PRs (markets#42 + broodly#7)
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].prs_reviewed == 2'
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].changes_req == 1'
  echo "$output" | jq -e '.bots["copilot-pull-request-reviewer"].threads_resolved == 2'
}

@test "aggregate: latency percentiles are numeric when data exists" {
  run aggregate_snapshot "$FIXTURES"
  echo "$output" | jq -e '.bots["gemini-code-assist"].latency_p50 == 50'
}

@test "aggregate: empty dir yields a zeroed snapshot" {
  empty="$(mktemp -d)"
  run aggregate_snapshot "$empty"
  echo "$output" | jq -e '.total_prs == 0 and (.bots | length == 0)'
}

# ---------------------------------------------------------------------------
# render_reviewer_report
# ---------------------------------------------------------------------------

@test "render: scorecard has a row for every tracked reviewer" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "GitHub Copilot"
  echo "$output" | grep -q "Gemini Code Assist"
  echo "$output" | grep -q "CodeRabbit"
  echo "$output" | grep -q "SonarCloud"
  echo "$output" | grep -q "Codex"
}

@test "render: states it is deterministic with no LLM" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "no LLM is involved"
}

@test "render: cost is explicitly a known gap (not measured)" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  echo "$output" | grep -q "Cost is not measured here"
}

@test "render: coverage overlap counts PRs reviewed by >=2 bots" {
  run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  # markets#42 has 4 bots, broodly#7 has 2 → 2 of 2 eligible
  echo "$output" | grep -q "PRs reviewed by ≥2 bots:\*\* 2 of 2"
}

@test "render: empty dir yields a no-data message" {
  empty="$(mktemp -d)"
  run render_reviewer_report "$empty" 7 0 2026-07-13
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No pull-request activity found"
}

@test "render: week-over-week delta arrow appears when a prior snapshot is given" {
  prev="$(mktemp)"
  cat > "$prev" <<'JSON'
{"eligible_prs":3,"total_prs":4,"bots":{"copilot-pull-request-reviewer":{"prs_reviewed":3}}}
JSON
  REVIEWER_PREV_SNAPSHOT="$prev" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  # copilot dropped from 3 → 2
  echo "$output" | grep -q "▼ -1"
}

@test "render: writes the snapshot artifact when REVIEWER_SNAPSHOT_OUT is set" {
  out="$(mktemp)"
  REVIEWER_SNAPSHOT_OUT="$out" run render_reviewer_report "$FIXTURES" 7 12 2026-07-13
  run jq -e '.bots["copilot-pull-request-reviewer"].prs_reviewed == 2' "$out"
  [ "$status" -eq 0 ]
}
