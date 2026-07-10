#!/usr/bin/env bash
# Shared PR-context prefetch for the review cascade (epic #1101, Story 2 / #1103).
#
# Gather the FULL PR diff + a superset metadata JSON ONCE in review-one-pr.sh and
# persist them to files bound to PR_HEAD_SHA, exposed to the agentic tiers
# (deep / audit / single / rubber-duck) as PR_CONTEXT_DIFF_FILE and
# PR_CONTEXT_METADATA_FILE. This is a single authoritative pre-populated context
# the tiers can consume instead of each re-fetching the diff/metadata themselves.
#
# Gated DEFAULT-OFF behind PREFETCH_CONTEXT_ENABLED so the change is a safe no-op
# until explicitly enabled: when off, zero files are written and zero env vars are
# exported, keeping the tier prompts and their inputs byte-identical to
# pre-feature behavior (mirrors the DOWNSTREAM_IMPACT_ENABLED default-off idiom).
#
# This is PLUMBING ONLY (Story 2): it does not change any tier prompt. Consumers
# in Story 5 verify the persisted PR_HEAD_SHA stamp for freshness before use.

# Superset of every field the deep/audit/single prompts read
# (headRepository, headRepositoryOwner) and the rubber-duck prompt reads
# (repository) via `gh pr view`. Persisting the union — with the FULL, non-simplified
# `files` array — means no tier loses a field it uses today. This is intentionally
# richer than review-one-pr.sh's triage `_meta_fields`, which simplifies `files`
# and omits headRepository/repository/reviews/comments/commits, so the triage
# metadata copy is insufficient for the agentic tiers and one full fetch is done here.
PR_CONTEXT_METADATA_FIELDS="number,title,body,author,isDraft,baseRefName,headRefName,headRefOid,url,headRepository,headRepositoryOwner,repository,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviewRequests,reviews,comments,commits,closingIssuesReferences,additions,deletions,changedFiles,files"

# prefetch_pr_context <pr_url> <pr_head_sha> <full_diff_file> [out_dir]
#
#   Persists, under <out_dir> (default /tmp/cascade):
#     pr-context-diff.txt      — the FULL diff, header-stamped with PR_HEAD_SHA
#     pr-context-metadata.json — the superset metadata, stamped as .pr_head_sha
#   and exports their paths as PR_CONTEXT_DIFF_FILE / PR_CONTEXT_METADATA_FILE.
#
#   Fetch discipline (AC #4): the FULL diff is REUSED from <full_diff_file> — the
#   untruncated copy review-one-pr.sh already fetched during triage (either
#   `gh pr diff` or the per-file REST assembly on the >300-file 406 fallback) —
#   so no extra diff fetch happens here. Exactly ONE additional `gh pr view` is
#   performed for the superset metadata, because triage's metadata copy is
#   insufficient (simplified `files`, missing fields).
#
#   Gating (AC #1): a no-op returning 0 unless PREFETCH_CONTEXT_ENABLED=true.
#
#   Degradation (AC #5): a gh rate-limit on the metadata fetch returns the skip
#   sentinel 100 so the caller can take the existing skip path (exit 100) rather
#   than crashing; any other metadata-fetch failure degrades to a no-op (returns
#   0, no files, no exports) so the run continues on the tiers' own fetches. The
#   >300-file 406 case is already handled upstream (the reused diff is the REST
#   assembly), so it never reaches this helper.
prefetch_pr_context() {
  [ "${PREFETCH_CONTEXT_ENABLED:-false}" = "true" ] || return 0

  local pr_url="${1:?prefetch_pr_context: pr_url required}"
  local sha="${2:?prefetch_pr_context: pr_head_sha required}"
  local full_diff_file="${3:-}"
  local out_dir="${4:-/tmp/cascade}"

  mkdir -p "$out_dir" 2>/dev/null || true
  local diff_file="$out_dir/pr-context-diff.txt"
  local meta_file="$out_dir/pr-context-metadata.json"

  # --- Superset metadata: exactly one additional `gh pr view` ---
  local meta_err meta_json meta_stamped=false
  meta_err=$(mktemp "${TMPDIR:-/tmp}/pr-context-meta.XXXXXX") || { echo "Failed to create temp file" >&2; return 1; }
  if meta_json=$(gh pr view "$pr_url" --json "$PR_CONTEXT_METADATA_FIELDS" 2>"$meta_err"); then
    rm -f "$meta_err"
    # Stamp PR_HEAD_SHA as a top-level field so Story 5 consumers can verify
    # freshness. If jq is unavailable/errors skip the metadata file entirely so
    # the exported path always points to a properly stamped file.
    if printf '%s' "$meta_json" \
       | jq --arg sha "$sha" '. + {pr_head_sha: $sha}' > "$meta_file" 2>/dev/null; then
      meta_stamped=true
    else
      rm -f "$meta_file"
    fi
  else
    local err_content
    err_content=$(cat "$meta_err" 2>/dev/null || true)
    rm -f "$meta_err"
    if declare -F is_rate_limited >/dev/null 2>&1 && is_rate_limited "$err_content"; then
      # Graceful skip: let the caller degrade via the existing exit-100 path.
      return 100
    fi
    # Non-rate-limit failure: degrade to a no-op so the run continues.
    return 0
  fi

  # --- Full diff: reuse the already-fetched untruncated copy (no extra fetch) ---
  {
    printf '# PR_HEAD_SHA: %s\n' "$sha"
    if [ -n "$full_diff_file" ] && [ -f "$full_diff_file" ]; then
      cat "$full_diff_file"
    fi
  } > "$diff_file"

  export PR_CONTEXT_DIFF_FILE="$diff_file"
  [ "$meta_stamped" = true ] && export PR_CONTEXT_METADATA_FILE="$meta_file"
  return 0
}
