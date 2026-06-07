#!/usr/bin/env bash
# token_report.sh — org-wide Token Cost Observatory report.
#
# Collects per-call token-usage JSONL artifacts (emitted by scripts/lib/token-metrics.sh
# via the pr-review and dev-lead agents) from EVERY non-archived repo in the org, then
# renders a Markdown report aggregated by workflow/tier/model and by repository.
#
# Why org-wide: the agents run as reusable workflows in each *caller* repo, so their
# token-usage artifacts land in those repos — not in .github-private. A single-repo scan
# (the original fleet-monitor inline step) saw only a few percent of real org spend.
#
# Layout:
#   * The render_* functions are PURE — they read a directory of JSONL files and write
#     Markdown to stdout. They are unit-tested in tests/token_report.bats (no network).
#   * main() does the network I/O: repo discovery, artifact download, extraction.
#
# Usage:
#   ORG=petry-projects LOOKBACK_DAYS=7 GH_TOKEN=<pat> bash scripts/token_report.sh > report.md
#
# Environment:
#   ORG            — GitHub org to scan (default: petry-projects)
#   LOOKBACK_DAYS  — rolling window of artifact history to include (default: 7)
#   GH_TOKEN       — PAT with actions:read across the org (artifacts are per-repo)
#   TOKEN_REPORT_OUT — optional path; when set, the report is written there in addition
#                      to stdout.
#
# ET formula (GitHub's framework): ET = m × (1.0×I + 0.1×C + 4.0×O)
# The `et` field is precomputed per call by token-metrics.sh; this script only sums it.

set -euo pipefail

ORG="${ORG:-petry-projects}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# ---------------------------------------------------------------------------
# Pure rendering helpers (unit-tested)
# ---------------------------------------------------------------------------

# _fmt_int <number>
# Renders an integer with thousands separators (e.g. 1234567 → 1,234,567).
_fmt_int() {
  awk -v n="${1:-0}" 'BEGIN {
    n = int(n + 0.5); s = ""; if (n < 0) { neg = 1; n = -n }
    if (n == 0) s = "0"
    while (n > 0) { r = n % 1000; n = int(n / 1000);
      s = (n > 0) ? sprintf("%03d", r) (s == "" ? "" : "," s) : r (s == "" ? "" : "," s) }
    printf "%s%s", (neg ? "-" : ""), s
  }'
}

# aggregate_by_workflow <jsonl_dir>
# Emits a JSON array of {workflow,tier,model,calls,input,cache,output,et}, ET-desc.
aggregate_by_workflow() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  if [ ! -e "${files[0]}" ]; then
    echo "[]"
    return 0
  fi
  jq -s '
    map(select(type == "object"))
    | group_by((.workflow // "unknown") + "|" + (.tier // "-") + "|" + (.model // "-"))
    | map({
        workflow: (.[0].workflow // "unknown"),
        tier:     (.[0].tier // "-"),
        model:    (.[0].model // "-"),
        calls:    length,
        input:    (map(.input_tokens // 0)      | add),
        cache:    (map(.cache_read_tokens // 0)  | add),
        output:   (map(.output_tokens // 0)      | add),
        et:       (map(.et // 0)                 | add)
      })
    | sort_by(.et) | reverse
  ' "${files[@]}" 2>/dev/null
}

# aggregate_by_repo <jsonl_dir>
# Emits a JSON array of {repo,calls,et}, ET-desc. Requires a .repo field per record.
aggregate_by_repo() {
  local dir="$1"
  local files=("$dir"/*.jsonl)
  if [ ! -e "${files[0]}" ]; then
    echo "[]"
    return 0
  fi
  jq -s '
    map(select(type == "object"))
    | group_by(.repo // "unknown")
    | map({
        repo:  (.[0].repo // "unknown"),
        calls: length,
        et:    (map(.et // 0) | add)
      })
    | sort_by(.et) | reverse
  ' "${files[@]}" 2>/dev/null
}

# render_token_report <jsonl_dir> <lookback_days> <repo_count> <artifact_count> [generated_at]
# Writes the full Markdown report to stdout. Pure: no network, only reads <jsonl_dir>.
render_token_report() {
  local dir="$1" lookback="$2" repo_count="$3" artifact_count="$4" generated_at="${5:-}"

  local by_wf by_repo total_et total_calls total_in total_out record_count
  by_wf="$(aggregate_by_workflow "$dir")"
  by_repo="$(aggregate_by_repo "$dir")"
  total_et="$(printf '%s' "$by_wf"   | jq '[.[].et]    | add // 0')"
  total_calls="$(printf '%s' "$by_wf" | jq '[.[].calls] | add // 0')"
  total_in="$(printf '%s' "$by_wf"   | jq '[.[].input]  | add // 0')"
  total_out="$(printf '%s' "$by_wf"  | jq '[.[].output] | add // 0')"
  record_count="$total_calls"

  printf '# 📊 Token Cost Observatory — %s-day Report\n\n' "$lookback"
  if [ -n "$generated_at" ]; then
    printf '_Generated %s · org `%s` · %s repos scanned · %s agent runs · %s LLM calls_\n\n' \
      "$generated_at" "$ORG" "$repo_count" "$artifact_count" "$(_fmt_int "$record_count")"
  else
    printf '_org `%s` · %s repos scanned · %s agent runs · %s LLM calls_\n\n' \
      "$ORG" "$repo_count" "$artifact_count" "$(_fmt_int "$record_count")"
  fi

  if [ "$(printf '%s' "$by_wf" | jq 'length')" -eq 0 ]; then
    printf 'No token-usage records found in the last %s days.\n' "$lookback"
    return 0
  fi

  printf 'Effective Tokens (ET) `= m × (1.0·input + 0.1·cache + 4.0·output)`, '
  printf 'where `m` is the model cost multiplier (haiku 1× · sonnet 3× · o4-mini/gemini-pro 2× · opus 15×). '
  printf 'Higher ET ≈ higher cost.\n\n'

  printf '## Totals\n\n'
  printf -- '- **Total ET:** %s\n' "$(_fmt_int "$total_et")"
  printf -- '- **LLM calls:** %s\n' "$(_fmt_int "$total_calls")"
  printf -- '- **Input tokens:** %s   ·   **Output tokens:** %s\n\n' \
    "$(_fmt_int "$total_in")" "$(_fmt_int "$total_out")"

  printf '## Top cost drivers (workflow / tier / model)\n\n'
  printf '| Workflow | Tier | Model | Calls | Input | Cache | Output | Total ET | %% of ET |\n'
  printf '|---|---|---|---:|---:|---:|---:|---:|---:|\n'
  printf '%s' "$by_wf" | jq -r --argjson tot "$total_et" '
    .[] | [
      .workflow, .tier, .model, (.calls|tostring),
      (.input|tostring), (.cache|tostring), (.output|tostring),
      (.et|floor|tostring),
      (if $tot > 0 then (.et / $tot * 100 | floor | tostring) + "%" else "—" end)
    ] | @tsv' \
  | while IFS=$'\t' read -r wf tier model calls input cache output et pct; do
      printf '| `%s` | %s | `%s` | %s | %s | %s | %s | %s | %s |\n' \
        "$wf" "$tier" "$model" "$(_fmt_int "$calls")" "$(_fmt_int "$input")" \
        "$(_fmt_int "$cache")" "$(_fmt_int "$output")" "$(_fmt_int "$et")" "$pct"
    done
  printf '\n'

  printf '## By repository\n\n'
  printf '| Repository | Calls | Total ET | %% of ET |\n'
  printf '|---|---:|---:|---:|\n'
  printf '%s' "$by_repo" | jq -r --argjson tot "$total_et" '
    .[] | [
      .repo, (.calls|tostring), (.et|floor|tostring),
      (if $tot > 0 then (.et / $tot * 100 | floor | tostring) + "%" else "—" end)
    ] | @tsv' \
  | while IFS=$'\t' read -r repo calls et pct; do
      printf '| `%s` | %s | %s | %s |\n' \
        "$repo" "$(_fmt_int "$calls")" "$(_fmt_int "$et")" "$pct"
    done
  printf '\n'
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

# _extract_zip <zip_file> <dest_dir>
# Extracts a zip using unzip when available, else a python3 fallback (CI runners
# have unzip; the fallback keeps the script runnable in minimal environments).
_extract_zip() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  else
    python3 - "$zip" "$dest" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  fi
}

# collect_org_jsonl <jsonl_dir>  (stdout: "<repo_count> <artifact_count>")
# Discovers non-archived repos, downloads each token-usage artifact inside the
# lookback window, extracts its JSONL, and tags every record with its source repo.
collect_org_jsonl() {
  local jsonl_dir="$1"
  mkdir -p "$jsonl_dir"

  local repos_raw
  repos_raw="$(gh api "orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived == false) | .full_name' 2>/dev/null || true)"
  [ -n "$repos_raw" ] || { echo "0 0"; return 0; }

  local cutoff repo_count=0 artifact_count=0
  cutoff="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"

  local workdir; workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN

  local repo
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    repo_count=$((repo_count + 1))

    local arts
    arts="$(gh api "repos/${repo}/actions/artifacts" --paginate 2>/dev/null \
      | jq -r --arg cutoff "$cutoff" \
      '.artifacts[] | select(.name | startswith("token-usage-")) | select(.expired == false) | select(.created_at >= $cutoff) | [.id, .created_at] | @tsv' \
      || true)"
    [ -n "$arts" ] || continue

    local id created_at
    while IFS=$'\t' read -r id created_at; do
      [ -n "$id" ] || continue

      local zip="$workdir/a-$id.zip" ex="$workdir/x-$id"
      mkdir -p "$ex"
      gh api "repos/${repo}/actions/artifacts/${id}/zip" > "$zip" 2>/dev/null || continue
      _extract_zip "$zip" "$ex" 2>/dev/null || continue

      local found=false f
      while IFS= read -r f; do
        # Tag each record with its source repo for the by-repo rollup.
        if jq -c --arg repo "$repo" 'select(type=="object") | . + {repo: $repo}' \
            "$f" > "$jsonl_dir/${id}-$(basename "$f")" 2>/dev/null; then
          found=true
        fi
      done < <(find "$ex" -type f -name '*.jsonl' -print)
      [ "$found" = true ] && artifact_count=$((artifact_count + 1))

      rm -rf "$zip" "$ex"
    done <<< "$arts"
  done <<< "$repos_raw"

  echo "${repo_count} ${artifact_count}"
}

main() {
  local jsonl_dir counts repo_count artifact_count generated_at report
  jsonl_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$jsonl_dir'" EXIT

  echo "Collecting token-usage artifacts across ${ORG} (last ${LOOKBACK_DAYS} days)..." >&2
  counts="$(collect_org_jsonl "$jsonl_dir")"
  repo_count="${counts%% *}"
  artifact_count="${counts##* }"
  generated_at="$(date -u +%Y-%m-%d 2>/dev/null || echo '')"

  report="$(render_token_report "$jsonl_dir" "$LOOKBACK_DAYS" \
            "$repo_count" "$artifact_count" "$generated_at")"

  printf '%s\n' "$report"
  if [ -n "${TOKEN_REPORT_OUT:-}" ]; then
    printf '%s\n' "$report" > "$TOKEN_REPORT_OUT"
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
