#!/usr/bin/env bats
# Tests for scripts/token_report.sh — pure aggregation + Markdown rendering.
# Network I/O (collect_org_jsonl / main) is not exercised here.
# Run locally: bats tests/token_report.bats

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/token_jsonl"

setup() {
  # shellcheck source=scripts/token_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/token_report.sh"
}

# ---------------------------------------------------------------------------
# _fmt_int
# ---------------------------------------------------------------------------

@test "_fmt_int: adds thousands separators" {
  run _fmt_int 1234567
  [ "$output" = "1,234,567" ]
}

@test "_fmt_int: leaves small numbers untouched" {
  run _fmt_int 42
  [ "$output" = "42" ]
}

@test "_fmt_int: handles zero" {
  run _fmt_int 0
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# aggregate_by_workflow
# ---------------------------------------------------------------------------

@test "aggregate_by_workflow: groups by workflow/tier/model" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'; aggregate_by_workflow '$FIXTURES' | jq length"
  [ "$output" = "3" ]
}

@test "aggregate_by_workflow: sums calls and et within a group" {
  # dev-lead/writer/sonnet appears in both fixture files: 2 calls, et 9600+4200=13800
  result="$(aggregate_by_workflow "$FIXTURES" | jq -r '.[] | select(.workflow=="dev-lead") | "\(.calls) \(.et)"')"
  [ "$result" = "2 13800" ]
}

@test "aggregate_by_workflow: sorted by ET descending (opus first)" {
  first="$(aggregate_by_workflow "$FIXTURES" | jq -r '.[0].model')"
  [ "$first" = "claude-opus-4-7" ]
}

# ---------------------------------------------------------------------------
# aggregate_by_repo
# ---------------------------------------------------------------------------

@test "aggregate_by_repo: groups by repo and sorts by ET" {
  result="$(aggregate_by_repo "$FIXTURES" | jq -r '.[0] | "\(.repo) \(.calls) \(.et)"')"
  [ "$result" = "petry-projects/markets 2 89850" ]
}

# ---------------------------------------------------------------------------
# render_token_report
# ---------------------------------------------------------------------------

@test "render_token_report: includes totals" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  # Total ET = 80250 + 13800 + 800 = 94850
  [[ "$output" == *"Total ET:** 94,850"* ]]
  [[ "$output" == *"LLM calls:** 4"* ]]
}

@test "render_token_report: has both summary tables" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [[ "$output" == *"Top cost drivers (workflow / tier / model)"* ]]
  [[ "$output" == *"By repository"* ]]
}

@test "render_token_report: computes ET percentage share" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  # opus share: 80250/94850 = 84.6% -> floor 84%
  [[ "$output" == *"84%"* ]]
}

@test "render_token_report: empty dir yields a no-data message" {
  empty="$(mktemp -d)"
  run render_token_report "$empty" 7 0 0 2026-06-07
  rmdir "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No token-usage records found"* ]]
}

# ---------------------------------------------------------------------------
# collect_org_jsonl — error-handling (gh is stubbed; no network)
# ---------------------------------------------------------------------------

@test "collect_org_jsonl: emits ERROR and returns non-zero when org repo listing fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() { return 1; }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=7
    collect_org_jsonl '${tmpdir}' 2>&1
  "
  rm -rf "$tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "collect_org_jsonl: emits WARN and continues when per-repo artifact listing fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() {
      case \"\$2\" in
        orgs/*/repos*) echo 'petry-projects/test-repo'; return 0;;
        repos/*/actions/artifacts*) return 1;;
        *) return 1;;
      esac
    }
    export -f gh
    source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'
    export ORG=petry-projects LOOKBACK_DAYS=7
    collect_org_jsonl '${tmpdir}' 2>&1
  "
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
}
