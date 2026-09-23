#!/usr/bin/env bats
# Opus 5.5 non-regression validation — the OFFLINE, deterministic evidence for
# issue #1897 (epic #1895, Phase 1).
#
# #1897 is a validation-only story: run the held-out model A/B, price the deep
# tier, confirm engine liveness, and probe reasoning-effort for claude-opus-5-5
# before any engine.sh swap ships. Most of that requires a LIVE model and is run
# in CI. Two of its acceptance criteria are, however, deterministic and provable
# offline — and those are the ones a durable regression test must lock so the
# go/no-go evidence cannot silently rot:
#
#   AC-2  the deep-tier per-run cost delta (opus-5-5 vs opus-4-8) is derived from
#         the frozen price row in scripts/lib/model-pricing.tsv (#1896) — DATA,
#         not a live call — so the ">=20% input/output, >=50% cache-read"
#         reduction is checkable here. If a later pricing edit erodes it, CI fails.
#
#   AC-3  the Dev Notes flag as low-risk-but-verify that opus-5-5 always returns
#         thinking blocks and asks us to confirm the existing stateless parse path
#         (_claude_chain_invoke -> extract_engine_text claude, `jq '.result'`) is
#         unaffected by them. That extraction is pure and offline, so it is locked
#         here with a JSON envelope that carries thinking content blocks.
#
# These tests stay network-free: no model is invoked, only the price table and the
# pure text-extraction helper are exercised. The live ACs (#1 A/B, #3 liveness,
# #4 effort) are recorded on the issue, never fabricated here.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../scripts/lib/model-pricing.sh
  source "$ROOT/scripts/lib/model-pricing.sh"
  # shellcheck source=../scripts/lib/token-metrics.sh
  source "$ROOT/scripts/lib/token-metrics.sh"

  CANDIDATE="claude-opus-5-5"
  INCUMBENT="claude-opus-4-8"
  # Price on a date at/after the opus-5-5 row's effective_from (2026-09-22) so the
  # effective-dated selection picks the new candidate row and the incumbent's
  # 2025-11-01 opus-4-* row.
  PRICE_DATE="2026-09-23"
}

# ── AC-2: deep-tier cost delta from the frozen pricing row ─────────────────────

@test "AC-2: opus-5-5 deep-tier per-token prices beat opus-4-8 by the required margins" {
  # price_for emits a space-joined line with no trailing newline; a here-string
  # terminates it so `read` returns 0 after assigning the fields.
  read -r c_in c_cr _c_cw c_out <<< "$(price_for "$CANDIDATE" "$PRICE_DATE")"
  read -r i_in i_cr _i_cw i_out <<< "$(price_for "$INCUMBENT" "$PRICE_DATE")"

  # Both models must resolve to a priced row (opus-5-5 landed in #1896).
  [ -n "$c_in" ]
  [ -n "$i_in" ]

  # AC-2 thresholds: >=20% input, >=20% output, >=50% cache-read reduction.
  # A reduction of exactly 20%/50% satisfies the ">=" bar.
  awk -v c="$c_in"  -v i="$i_in"  'BEGIN { exit !(i > 0 && (i - c) / i >= 0.20) }'
  awk -v c="$c_out" -v i="$i_out" 'BEGIN { exit !(i > 0 && (i - c) / i >= 0.20) }'
  awk -v c="$c_cr"  -v i="$i_cr"  'BEGIN { exit !(i > 0 && (i - c) / i >= 0.50) }'
}

@test "AC-2: a representative deep-tier run is cheaper on opus-5-5 (positive delta)" {
  # Same per-call assumptions eval-cost-estimate.sh defaults to, plus a cache-read
  # component so the cache-read reduction is reflected in the per-run figure.
  local in_tok=12000 cache_tok=8000 out_tok=1200
  local c_cost i_cost
  c_cost="$(cost_usd "$CANDIDATE" "$in_tok" "$cache_tok" "$out_tok" "$PRICE_DATE")"
  i_cost="$(cost_usd "$INCUMBENT" "$in_tok" "$cache_tok" "$out_tok" "$PRICE_DATE")"
  [ -n "$c_cost" ]
  [ -n "$i_cost" ]
  # Candidate must be strictly cheaper — a non-regression on cost.
  awk -v c="$c_cost" -v i="$i_cost" 'BEGIN { exit !(c < i) }'
}

@test "AC-2: the reduction is table-derived, not hardcoded (no row -> no price)" {
  # With the price table absent, price_for must yield nothing rather than invent a
  # rate — proving the delta above comes from the frozen data, per AGENTS.md
  # "prices are data, not code".
  PRICING_TABLE="$BATS_TEST_TMPDIR/nonexistent-pricing.tsv" \
    run price_for "$CANDIDATE" "$PRICE_DATE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── AC-3: _claude_chain_invoke parse path handles thinking blocks ──────────────

@test "AC-3: extract_engine_text claude returns .result unaffected by thinking blocks" {
  # A realistic `claude --print --output-format json` envelope for a model that
  # emits thinking: the final answer lives in .result, while thinking text lives
  # in a separate content block. The stateless parse must return ONLY .result.
  local f="$BATS_TEST_TMPDIR/opus55-thinking.json"
  cat >"$f" <<'JSON'
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "The final answer is 42.",
  "content": [
    {"type": "thinking", "thinking": "Let me reason step by step about the value..."},
    {"type": "text", "text": "The final answer is 42."}
  ],
  "usage": {"input_tokens": 100, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 30, "output_tokens": 40}
}
JSON

  run extract_engine_text claude "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "The final answer is 42." ]
  # The thinking text must NOT leak into the extracted result.
  [[ "$output" != *"reason step by step"* ]]
}

@test "AC-3: usage still parses from an envelope carrying thinking content blocks" {
  # AC-3 also asserts the JSON result parses through the invoke path's usage
  # accounting; confirm parse_engine_usage reads the usage block regardless of the
  # extra thinking content.
  local f="$BATS_TEST_TMPDIR/opus55-thinking-usage.json"
  cat >"$f" <<'JSON'
{
  "result": "ok",
  "content": [{"type": "thinking", "thinking": "..."}],
  "usage": {"input_tokens": 1234, "cache_read_input_tokens": 500, "cache_creation_input_tokens": 300, "output_tokens": 90}
}
JSON

  parse_engine_usage claude "$f"
  [ "$LAST_USAGE_OK" = "1" ]
  [ "$LAST_INPUT_TOKENS" = "1234" ]
  [ "$LAST_CACHE_READ_TOKENS" = "500" ]
  [ "$LAST_OUTPUT_TOKENS" = "90" ]
}
