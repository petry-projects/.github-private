#!/usr/bin/env bash
set -euo pipefail
# extract-fewshot.sh — build de-identified few-shot examples from this repo's
# merged-PR review->merge histories and store them in a proposer-visible dev
# split (issue #1093, epic #1088, Phase 2, Task 1).
#
# The deep-review tier reads these examples (via the $FEWSHOT_FILE optional-file
# contract assembled by scripts/lib/fewshot.sh) to calibrate to what this repo's
# maintainers actually accept and flag. Each example captures ONE past outcome:
# the PR's title/summary plus the review decision (approve|escalate) and risk.
#
# Held-out discipline (AC #2). The output MUST land under a proposer-visible dev
# split, NEVER under evals/**/holdout — the set the held-out gate later scores
# against. fewshot_source_is_holdout (the same guard the assembler enforces)
# hard-refuses a holdout output path here too, so a mis-pointed --out can never
# write into the held-out set.
#
# De-identification (evals/README.md decision A3). Every text field is scrubbed
# of secrets, tokens, internal hostnames, and PII via fewshot_scrub BEFORE it is
# committed — cases are redacted reconstructions, never raw captured content.
#
# Usage:
#   extract-fewshot.sh [--repo <owner/repo>] [--limit N] [--out <path>]
#
# Defaults: --repo $GITHUB_REPOSITORY, --limit 30,
#           --out evals/deep-review/dev/fewshot.jsonl
#
# Requires: gh (authenticated), jq. Exits non-zero on a holdout --out, missing
# tooling, or a failed fetch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/fewshot.sh
source "$REPO_ROOT/scripts/lib/fewshot.sh"

die() { echo "::error::extract-fewshot: $1" >&2; exit 1; }

REPO="${GITHUB_REPOSITORY:-}"
LIMIT=30
OUT="$REPO_ROOT/evals/deep-review/dev/fewshot.jsonl"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --limit) LIMIT="${2:-}"; shift 2 ;;
    --out)   OUT="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required but not installed"
command -v gh >/dev/null 2>&1 || die "gh is required but not installed"
[ -n "$REPO" ] || die "no repository: pass --repo <owner/repo> or set GITHUB_REPOSITORY"

# Hard holdout guard (AC #2): never write few-shot data into a held-out path.
if fewshot_source_is_holdout "$OUT"; then
  die "refusing to write few-shot data to held-out path '$OUT' — the dev split must be proposer-visible, never evals/**/holdout"
fi

echo "  [fewshot] extracting up to $LIMIT merged PRs from $REPO -> $OUT" >&2

raw="$(gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
  --json number,title,body,labels,reviews 2>/dev/null)" \
  || die "failed to list merged PRs for $REPO (auth/scope?)"

[ -n "$raw" ] || die "empty PR listing for $REPO"

# Derive one example per merged PR with a pure jq program:
#   decision: escalate if any review requested changes OR a HIGH-risk label is
#             present; else approve.
#   risk:     HIGH for security/auth/migration labels, LOW for docs/tests-only,
#             else MEDIUM.
# The title/summary are carried verbatim here and de-identified by fewshot_scrub
# below (jq cannot call the shell scrub, so scrubbing is a second pass).
examples="$(printf '%s' "$raw" | jq -c '
  def labelnames: [.labels[]?.name // empty | ascii_downcase];
  .[]
  | . as $pr
  | (labelnames) as $labels
  | (any($pr.reviews[]?; .state == "CHANGES_REQUESTED")) as $changes
  | (any($labels[]; test("security|auth|secret|migration|crypto"))) as $high
  | (any($labels[]; test("docs|documentation|test|chore|typo"))) as $low
  | {
      id: ("fs-pr-\($pr.number)"),
      title: ($pr.title // ""),
      summary: (($pr.body // "") | split("\n")[0] | .[0:200]),
      decision: (if ($changes or $high) then "escalate" else "approve" end),
      risk: (if $high then "HIGH" elif $low then "LOW" else "MEDIUM" end),
      rationale: (if $changes then "maintainer requested changes before merge"
                  elif $high then "touches a security/auth/migration surface"
                  elif $low then "low-risk docs/tests/chore change"
                  else "non-trivial logic change, merged after review" end)
    }
' 2>/dev/null)" || die "failed to derive examples from PR listing"

[ -n "$examples" ] || die "no examples derived from $REPO (no merged PRs?)"

# Second pass: de-identify every string field (A3). Scrub per-field so structure
# is preserved, then re-emit a compact JSONL line.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
count=0
while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  id="$(printf '%s' "$line"     | jq -r '.id')"
  title="$(fewshot_scrub "$(printf '%s' "$line" | jq -r '.title')")"
  summary="$(fewshot_scrub "$(printf '%s' "$line" | jq -r '.summary')")"
  decision="$(printf '%s' "$line" | jq -r '.decision')"
  risk="$(printf '%s' "$line"   | jq -r '.risk')"
  rationale="$(fewshot_scrub "$(printf '%s' "$line" | jq -r '.rationale')")"
  jq -cn \
    --arg id "$id" --arg title "$title" --arg summary "$summary" \
    --arg decision "$decision" --arg risk "$risk" --arg rationale "$rationale" \
    '{id:$id, title:$title, summary:$summary, decision:$decision, risk:$risk, rationale:$rationale}' \
    >> "$tmp"
  count=$((count + 1))
done <<< "$examples"

mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
trap - EXIT
echo "  [fewshot] wrote $count de-identified example(s) to $OUT" >&2
