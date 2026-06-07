#!/usr/bin/env bats
# Tests for scripts/token_report.sh — pure annotation + Markdown rendering with USD cost.
# Network I/O (collect_org_jsonl / main) is not exercised here.
# Run locally: bats tests/token_report.bats

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/token_jsonl"

setup() {
  # shellcheck source=scripts/token_report.sh
  source "${BATS_TEST_DIRNAME}/../scripts/token_report.sh"
}

# ---------------------------------------------------------------------------
# _fmt_int / _fmt_usd
# ---------------------------------------------------------------------------

@test "_fmt_int: adds thousands separators" {
  run _fmt_int 1234567
  [ "$output" = "1,234,567" ]
}

@test "_fmt_int: handles zero" {
  run _fmt_int 0
  [ "$output" = "0" ]
}

@test "_fmt_usd: renders dollars to 4 decimals" {
  run _fmt_usd 1.0548
  [ "$output" = "\$1.0548" ]
}

# ---------------------------------------------------------------------------
# annotate_records — date-accurate cost + table-derived ET
# ---------------------------------------------------------------------------

@test "annotate_records: one enriched row per call" {
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/token_report.sh'; annotate_records '$FIXTURES' | wc -l"
  [ "$output" -eq 4 ]
}

@test "annotate_records: prices opus at \$5 input / \$25 output (cost & known flag)" {
  # opus-4-7 1000/500/200 → (1000*5 + 500*0.5 + 200*25)/1e6 = 0.010250
  result="$(annotate_records "$FIXTURES" | awk -F'\t' '$4=="claude-opus-4-7"{print $8, $10}')"
  [ "$result" = "0.010250 1" ]
}

@test "annotate_records: recomputes ET from table (opus m=5, ignores stored et=80250)" {
  # ET = 5 * (1000 + 0.1*500 + 4*200) = 5*1850 = 9250
  result="$(annotate_records "$FIXTURES" | awk -F'\t' '$4=="claude-opus-4-7"{print $9}')"
  [ "$result" = "9250.0000" ]
}

@test "annotate_records: unknown model → cost sentinel -1 and known=0" {
  tmp="$(mktemp -d)"
  printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","workflow":"x","tier":"y","model":"mystery-model-v9","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' > "$tmp/u.jsonl"
  result="$(annotate_records "$tmp" | awk -F'\t' '{print $8, $10}')"
  rm -rf "$tmp"
  [ "$result" = "-1.000000 0" ]
}

# ---------------------------------------------------------------------------
# render_token_report
# ---------------------------------------------------------------------------

@test "render_token_report: total cost sums priced calls" {
  # 0.010250 + 0.010500 + 0.004500 + 0.000850 = 0.026100
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total cost:** \$0.0261"* ]]
}

@test "render_token_report: has cost columns and a cost-per-PR section" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  [[ "$output" == *"| Cost | % of \$ | ET |"* ]]
  [[ "$output" == *"Most expensive PRs"* ]]
}

@test "render_token_report: by-repo sorted by cost (markets first)" {
  run render_token_report "$FIXTURES" 7 2 2 2026-06-07
  repos="$(printf '%s\n' "$output" | grep -oE 'petry-projects/(markets|broodly)' | head -2 | tr '\n' ' ')"
  [ "$repos" = "petry-projects/markets petry-projects/broodly " ]
}

@test "render_token_report: flags unpriced calls" {
  tmp="$(mktemp -d)"
  printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","workflow":"x","tier":"y","model":"mystery-model-v9","input_tokens":100,"output_tokens":50,"repo":"r","context":""}' > "$tmp/u.jsonl"
  run render_token_report "$tmp" 7 1 1 2026-06-07
  rm -rf "$tmp"
  [[ "$output" == *"had no price"* ]]
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

@test "collect_org_jsonl: emits WARN and continues when artifact zip download fails" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  run bash -c "
    gh() {
      case \"\$2\" in
        orgs/*/repos*) echo 'petry-projects/test-repo'; return 0;;
        repos/*/actions/artifacts/*/zip) return 1;;
        repos/*/actions/artifacts*)
          printf '{\"artifacts\":[{\"name\":\"token-usage-x\",\"id\":999,\"expired\":false,\"created_at\":\"2099-01-01T00:00:00Z\"}]}'
          return 0;;
        *) return 0;;
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
  [[ "$output" == *"download failed"* ]]
}
