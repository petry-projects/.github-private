#!/usr/bin/env bash
# auto_rebase_health.sh — Auto-rebase instrumentation report (#737, epic #736).
#
# Measures two things the maintainer needs to make the Merge Queue vs. auto-rebase
# decision with concrete numbers instead of estimates:
#
#   1. Agentic-conflict-resolution rate — how often the auto-rebase conflict
#      sentinel (`<!-- auto-rebase-conflict:`) fires and how often dev-lead emits
#      a `rebase` intent in response. Both are HTML-comment markers that GitHub
#      search cannot index reliably (discussion #735), so we scan the repo's
#      issue comments directly:
#        * sentinels  — comments containing `<!-- auto-rebase-conflict:`
#                       (the marker scripts/dev-lead-intent.sh keys on)
#        * responses  — dev-lead terminal markers `... intent=rebase status=... -->`
#                       posted by scripts/dev-lead-fix-reviews.sh (any status)
#        * applied    — the `status=applied` subset (resolved & force-pushed)
#
#   2. Fan-out CI-run volume — the `Auto-rebase non-Dependabot PRs` workflow
#      (.github/workflows/auto-rebase.yml) runs per push to main and fans
#      branch-update CI re-runs onto behind PRs. Per-run behind-PR counts are not
#      logged in this repo (the update-branch calls live in the central reusable),
#      so the re-run volume is an ESTIMATE: runs × current open non-Dependabot PRs.
#
#   3. Post-restriction fan-out — since petry-projects/.github#468 (issue #465) the
#      reusable only update-branches *review-ready* PRs (non-draft AND (current
#      APPROVED review OR the `auto-rebase:ready` label)). To show the reduction the
#      report mirrors the same predicate against the current open PRs and reports the
#      eligible-PR multiplier, the restricted re-run estimate, and the reduction vs.
#      the unrestricted (all-behind-PRs) multiplier. This is the cleaner before/after
#      signal feeding the Merge Queue go/no-go record (#739). Like (2) it is a
#      snapshot ESTIMATE — eligibility is read now, not per historical run.
#
# Layout (mirrors scripts/token_report.sh):
#   * The count_*/summarize_*/fmt_*/render_report functions are PURE — they take
#     JSON / scalars and write to stdout. Unit-tested in tests/auto_rebase_health.bats.
#   * main() does the network I/O: token selection, comment + run telemetry pulls.
#
# Env vars consumed:
#   GH_TOKEN        — primary token (needs actions:read + repo read on this repo)
#   GH_PAT_FALLBACK — optional fallback PAT if GH_TOKEN lacks run-telemetry access
#   AGENT_REPO      — repo to scan (default: petry-projects/.github-private)
#   LOOKBACK_DAYS   — days of history to consider (default: 7)
#   READY_LABEL     — label that opts a non-draft PR into auto-rebase without an
#                     approval; must match the reusable's `ready_label` input
#                     (default: auto-rebase:ready)
#   AUTO_REBASE_HEALTH_OUT — optional path; report is written there in addition to stdout
#   GITHUB_STEP_SUMMARY — written by the Actions runner when present

set -euo pipefail

WORKFLOW_REPO="${AGENT_REPO:-petry-projects/.github-private}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
READY_LABEL="${READY_LABEL:-auto-rebase:ready}"
AUTO_REBASE_WORKFLOW="auto-rebase.yml"

# Markers (kept in one place so a rename in the dev-lead scripts is a one-line fix).
SENTINEL_MARKER='<!-- auto-rebase-conflict:'
REBASE_RESPONSE_MARKER='intent=rebase status='
REBASE_APPLIED_MARKER='intent=rebase status=applied'

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; no network)
# ---------------------------------------------------------------------------

# count_marker <comments_json> <substring>
# Counts comment objects whose `.body` contains <substring>. Absent/empty JSON → 0.
count_marker() {
  local json="${1:-}" needle="${2:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq --arg n "$needle" \
    '[.[] | select((.body // "") | contains($n))] | length'
}

# summarize_sentinels <comments_json>
# Emits TSV: sentinels<TAB>responses<TAB>applied
#   sentinels — conflict sentinels fired
#   responses — dev-lead rebase intents that ran to a terminal/posted state
#   applied   — the resolved-and-pushed subset of responses
summarize_sentinels() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r \
    --arg sent "$SENTINEL_MARKER" \
    --arg resp "$REBASE_RESPONSE_MARKER" \
    --arg appl "$REBASE_APPLIED_MARKER" '
      [.[] | .body // ""] as $b |
      [
        ([$b[] | select(contains($sent))] | length),
        ([$b[] | select(contains($resp))] | length),
        ([$b[] | select(contains($appl))] | length)
      ] | @tsv'
}

# summarize_runs <runs_json>
# Emits TSV: total<TAB>success<TAB>failed over the auto-rebase run telemetry.
summarize_runs() {
  local json="${1:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq -r '
    [
      length,
      ([.[] | select(.conclusion == "success")] | length),
      ([.[] | select(.conclusion == "failure")] | length)
    ] | @tsv'
}

# estimate_fanout <run_count> <behind_prs>
# Estimated branch-update CI re-runs = runs × current open non-Dependabot PRs.
estimate_fanout() {
  local runs="${1:-0}" behind="${2:-0}"
  echo $(( runs * behind ))
}

# fmt_rate <num> <denom>
# Integer percentage with a zero-denominator guard ("n/a"), so a window with no
# sentinels never divides by zero.
fmt_rate() {
  local num="${1:-0}" denom="${2:-0}"
  if [ "$denom" -le 0 ]; then
    echo "n/a"
    return 0
  fi
  echo "$(( num * 100 / denom ))%"
}

# fmt_reduction <from> <to>
# Integer percentage DECREASE going from <from> to <to> (e.g. 7→3 = "57%").
# Zero/negative <from> guard renders "n/a" (no PRs to reduce). Mirrors the
# behind→eligible multiplier reduction that the eligibility gate buys.
fmt_reduction() {
  local from="${1:-0}" to="${2:-0}"
  if [ "$from" -le 0 ]; then
    echo "n/a"
    return 0
  fi
  echo "$(( (from - to) * 100 / from ))%"
}

# pr_has_current_approval <reviews_json>
# Returns 0 if a PR currently has at least one APPROVED review, else 1. Mirrors
# petry-projects/.github .github/scripts/auto-rebase/lib/eligibility.sh exactly:
# the reviewer's most recent decision review wins (a later CHANGES_REQUESTED or
# DISMISSED cancels an earlier APPROVED; COMMENTED/PENDING do not change a stance).
# We read real review states rather than reviewDecision, which is null on repos
# without required reviews (issue #465 implementer note).
pr_has_current_approval() {
  local json="${1:-}" result
  [ -n "$json" ] || json='[]'
  result=$(printf '%s' "$json" | jq -r '
    reduce (.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")) as $r ({}; .[$r.user.login] = $r.state)
    | any(. == "APPROVED")')
  [ "$result" = "true" ]
}

# count_eligible <prs_meta_json> <ready_label>
# Counts review-ready PRs in a metadata array. Each element is
# {"draft":bool,"approved":bool,"labels":[{"name":...}]}; a PR is eligible when it
# is non-draft AND (approved OR carries <ready_label>). Same predicate as the
# reusable's `review-ready` mode. Absent/empty JSON → 0.
count_eligible() {
  local json="${1:-}" label="${2:-}"
  [ -n "$json" ] || json='[]'
  printf '%s' "$json" | jq --arg L "$label" '
    [ .[]
      | select(((.draft // false) | not)
        and ((.approved // false) or ([.labels[]?.name] | any(. == $L)))) ]
    | length'
}

# render_report <comments_json> <runs_json> <lookback_days> <behind_prs> [today] [eligible_prs] [ready_label]
# Writes the full Markdown report to stdout. Pure: no network.
# When <eligible_prs> is supplied (non-empty), the post-restriction section is
# rendered; omit it to render the legacy two-section report.
render_report() {
  local comments_json="${1:-[]}" runs_json="${2:-[]}"
  local lookback="${3:-7}" behind="${4:-0}" today="${5:-}"
  local eligible="${6:-}" ready_label="${7:-auto-rebase:ready}"
  [ -n "$today" ] || today="$(date -u +%Y-%m-%d)"

  local sentinels responses applied
  IFS=$'\t' read -r sentinels responses applied < <(summarize_sentinels "$comments_json")

  local total success failed
  IFS=$'\t' read -r total success failed < <(summarize_runs "$runs_json")

  local fanout
  fanout="$(estimate_fanout "$total" "$behind")"

  local runs_per_day rerun_per_day
  runs_per_day="$(awk -v t="$total" -v d="$lookback" 'BEGIN { printf "%.1f", (d > 0 ? t / d : 0) }')"
  rerun_per_day="$(awk -v t="$fanout" -v d="$lookback" 'BEGIN { printf "%.1f", (d > 0 ? t / d : 0) }')"

  printf '# 🔁 Auto-rebase Health — %s\n\n' "$today"
  printf '_Repo `%s` · lookback %s day(s)_\n\n' "$WORKFLOW_REPO" "$lookback"

  printf '## Agentic conflict-resolution rate\n\n'
  printf -- '- **Sentinels fired** (`%s`): %s\n' "$SENTINEL_MARKER" "$sentinels"
  printf -- '- **Dev-lead rebase responses** (`intent=rebase`): %s\n' "$responses"
  printf -- '- **Resolved & pushed** (`status=applied`): %s\n' "$applied"
  printf -- '- **Resolution rate** (responses ÷ sentinels): %s\n' "$(fmt_rate "$responses" "$sentinels")"
  printf -- '- **Applied rate** (applied ÷ sentinels): %s\n\n' "$(fmt_rate "$applied" "$sentinels")"

  printf '## Auto-rebase fan-out volume (estimate)\n\n'
  printf -- '- **Workflow runs** (`%s`): %s total · %s success · %s failed\n' \
    "$AUTO_REBASE_WORKFLOW" "$total" "$success" "$failed"
  printf -- '- **Behind-PR multiplier** (open non-Dependabot PRs): %s\n' "$behind"
  printf -- '- **Estimated branch-update CI re-runs**: ~%s\n' "$fanout"
  printf -- '- **Per-day baseline**: %s auto-rebase run(s)/day · ~%s CI re-run(s)/day\n\n' \
    "$runs_per_day" "$rerun_per_day"
  printf '> Fan-out is an **estimate** — per-run behind-PR counts are not logged in this repo, '
  printf 'so re-runs = runs × current open non-Dependabot PR count.\n'

  # Post-restriction section — only when an eligible-PR count is supplied.
  [ -n "$eligible" ] || return 0

  local restricted reduction restricted_per_day verdict
  restricted="$(estimate_fanout "$total" "$eligible")"
  reduction="$(fmt_reduction "$behind" "$eligible")"
  restricted_per_day="$(awk -v t="$restricted" -v d="$lookback" 'BEGIN { printf "%.1f", (d > 0 ? t / d : 0) }')"
  # ≥50% multiplier reduction is the epic #736 success metric.
  if [ "$behind" -gt 0 ] && [ "$(( (behind - eligible) * 100 / behind ))" -ge 50 ]; then
    verdict="✅ met"
  else
    verdict="❌ not met"
  fi

  printf '\n## Post-restriction fan-out (review-ready eligibility)\n\n'
  printf -- '- **Eligible PRs** (non-draft AND (current `APPROVED` review OR `%s` label)): %s of %s open non-Dependabot PRs\n' \
    "$ready_label" "$eligible" "$behind"
  printf -- '- **Estimated branch-update CI re-runs (restricted)**: ~%s (~%s/day)\n' \
    "$restricted" "$restricted_per_day"
  printf -- '- **Fan-out reduction** (behind→eligible multiplier): %s\n' "$reduction"
  printf -- '- **≥50%% reduction success metric** (epic #736): %s\n\n' "$verdict"
  printf '> Reduction is a point-in-time snapshot: eligibility is read now, not per '
  printf 'historical run, so the multiplier (not the absolute run count) is the like-for-like signal.\n'
}

# ---------------------------------------------------------------------------
# Network I/O (main)
# ---------------------------------------------------------------------------

main() {
  local today cutoff
  today="$(date -u +%Y-%m-%d)"
  # GNU date: -d "N days ago"; BSD/macOS: -v-Nd
  cutoff="$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${LOOKBACK_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"

  echo "=== Auto-rebase Health Report ===" >&2
  echo "  Repo:     $WORKFLOW_REPO" >&2
  echo "  Lookback: ${LOOKBACK_DAYS} day(s) (since ${cutoff})" >&2
  echo "  Date:     $today" >&2

  # Token selection — verify run-telemetry access; fall back to a PAT if needed.
  if ! gh api "repos/${WORKFLOW_REPO}/actions/workflows/${AUTO_REBASE_WORKFLOW}/runs?per_page=1" \
       >/dev/null 2>&1; then
    if [ -n "${GH_PAT_FALLBACK:-}" ]; then
      echo "::warning::GH_TOKEN cannot read ${AUTO_REBASE_WORKFLOW} runs — using GH_PAT_FALLBACK" >&2
      export GH_TOKEN="$GH_PAT_FALLBACK"
    else
      echo "::error::GH_TOKEN cannot read ${AUTO_REBASE_WORKFLOW} run telemetry and GH_PAT_FALLBACK is unset." >&2
      echo "::error::Grant actions:read on ${WORKFLOW_REPO} or set the fallback PAT secret." >&2
      exit 1
    fi
  fi

  # 1. Comments — the issues/comments endpoint covers PR comments too (PRs are
  #    issues), and `since` filters server-side so we only pull the window.
  local comments_json
  comments_json="$(gh api \
    "repos/${WORKFLOW_REPO}/issues/comments?since=${cutoff}&per_page=100" --paginate \
    --jq '.[] | {body, created_at, html_url}' 2>/dev/null \
    | jq -s '.' 2>/dev/null || echo '[]')"

  # 2. Auto-rebase run telemetry. --paginate so long manual-dispatch windows are
  #    not silently truncated at 100 runs (GitHub still caps created>= at 1,000).
  local runs_json
  runs_json="$(gh api \
    "repos/${WORKFLOW_REPO}/actions/workflows/${AUTO_REBASE_WORKFLOW}/runs?per_page=100&created=>=${cutoff}" \
    --paginate --jq '.workflow_runs | map({conclusion, created_at})' 2>/dev/null \
    | jq -s 'add // []' 2>/dev/null || echo '[]')"

  # 3. Behind-PR multiplier — open non-Dependabot PR numbers (proxy for branches
  #    the fan-out updates). Best-effort; empty list → behind=0 so it still renders.
  local pr_numbers behind
  pr_numbers="$(gh pr list --repo "$WORKFLOW_REPO" --state open --limit 200 --json number,author \
    --jq '.[] | select((.author?.login // "") | test("dependabot"; "i") | not) | .number' \
    2>/dev/null || true)"
  if [ -n "$pr_numbers" ]; then
    behind="$(printf '%s\n' "$pr_numbers" | grep -c .)"
  else
    behind=0
  fi

  # 4. Eligible-PR multiplier — the review-ready subset the gate now updates. For
  #    each open non-Dependabot PR, read draft/labels (one pulls call) and the
  #    current approval state (reviews call), then apply the same predicate as the
  #    reusable. No CI re-runs and no LLM cost — a handful of read calls per daily
  #    run. Best-effort: any failure leaves eligible empty so the post-restriction
  #    section is simply omitted rather than reported wrongly.
  local eligible="" prs_meta
  if [ -n "$pr_numbers" ]; then
    local recs="[]" n pr_json draft labels reviews_json approved rec
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      pr_json="$(gh api "repos/${WORKFLOW_REPO}/pulls/${n}" 2>/dev/null || echo '{}')"
      draft="$(printf '%s' "$pr_json" | jq -r 'if .draft == true then "true" else "false" end')"
      labels="$(printf '%s' "$pr_json" | jq -c '.labels // []')"
      reviews_json="$(gh api --paginate "repos/${WORKFLOW_REPO}/pulls/${n}/reviews" 2>/dev/null \
        | jq -s 'add // []' 2>/dev/null || echo '[]')"
      if pr_has_current_approval "$reviews_json"; then approved=true; else approved=false; fi
      rec="$(jq -nc --argjson d "$draft" --argjson a "$approved" --argjson l "$labels" \
        '{draft:$d, approved:$a, labels:$l}')"
      recs="$(printf '%s' "$recs" | jq -c --argjson r "$rec" '. + [$r]')"
    done <<< "$pr_numbers"
    prs_meta="$recs"
    eligible="$(count_eligible "$prs_meta" "$READY_LABEL" 2>/dev/null || echo "")"
  fi

  local report
  report="$(render_report "$comments_json" "$runs_json" "$LOOKBACK_DAYS" "$behind" "$today" \
    "$eligible" "$READY_LABEL")"

  printf '%s\n' "$report"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$report" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ -n "${AUTO_REBASE_HEALTH_OUT:-}" ]; then
    printf '%s\n' "$report" > "$AUTO_REBASE_HEALTH_OUT"
  fi
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
