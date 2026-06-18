#!/usr/bin/env bash
# Pure downstream-impact mapping helper for the PR-review cascade (issue #750,
# epic #748).
#
# Given a PR's changed-file list and the consumer manifest (Story 1,
# scripts/lib/consumer-manifest.json), this answers a single question with NO
# network / `gh` I/O: which shared surfaces did these files touch, and which
# org repos (consumers) pin those surfaces? Keeping it pure makes the impact
# computation deterministic and unit-testable in isolation (mirrors the
# jq-program style of scripts/lib/review-cycle.sh).
#
# Matching is single-hop and EXACT-path (issue #653) — no prefix/glob/transitive
# source-graph expansion. Two and only two match kinds:
#   (a) a changed reusable-workflow path that a consumer ref pins exactly
#       (after normalising the manifest's provider prefix) -> direct surface;
#   (b) a changed scripts/lib/*.sh or prompts/* path listed in a reusable's
#       surface_sources -> that reusable surface -> the reusable's consumers.
#
# A consumer ref is provider-prefixed (e.g. ".github-private/.github/workflows/
# pr-review.yml") while a surface is identified by its repo-relative path
# (".github/workflows/pr-review.yml", the surface_sources key form). Normalising
# strips the longest matching declared provider prefix so the helper is
# provider-agnostic — it never hardcodes which provider repo it runs in.
#
# Output (always a single well-formed JSON object on stdout):
#   {
#     "impacted_surfaces":  [ "<repo-relative reusable path>", ... ],   # sorted, unique
#     "impacted_consumers": [ { "repo": "...", "via": ["<surface>", ...] }, ... ],
#     "unmatched":          [ "<changed path with no shared surface>", ... ]
#   }
#
# Defensive degradation (same philosophy as compute_review_cycle returning 0 on
# bad input): a missing/unreadable/malformed manifest, an empty changed-file
# list, or any jq failure yields the empty-but-well-formed object below rather
# than a non-zero exit that would break the cascade.

# jq program shared by the one public function. Inputs:
#   $changed : JSON array of changed paths (de-duplicated, blanks removed)
#   $m       : slurpfile array; $m[0] is the manifest object
_DOWNSTREAM_IMPACT_JQ='
  ($m[0] // {}) as $man
  | ($man.providers // []) as $providers
  | ($man.consumers // []) as $consumers
  | ($man.surface_sources // {}) as $sources
  | ($changed // []) as $changed

  # Normalise a consumer ref to its repo-relative surface key by stripping the
  # longest matching declared provider prefix. Null if no provider matches.
  | def strip_provider($ref):
      ( [ $providers[] as $p | select($ref | startswith($p + "/")) | $p ]
        | sort_by(length) | reverse | .[0] ) as $p
      | if $p == null then null else ($ref | ltrimstr($p + "/")) end;

  # The full set of repo-relative surfaces any consumer pins.
  ( [ $consumers[].refs[]? | strip_provider(.) | select(. != null) ] | unique ) as $pinned_surfaces

  # (a) Direct: a changed workflow path that is itself a pinned surface.
  | ( [ $changed[] | select(. as $c | $pinned_surfaces | index($c)) ] ) as $direct_surfaces

  # (b) Indirect: surface_sources keys whose value list contains a changed path.
  | ( [ $sources | to_entries[]
        | select(.value as $v | any($changed[]; . as $c | $v | index($c)))
        | .key ] ) as $indirect_surfaces

  | (($direct_surfaces + $indirect_surfaces) | unique) as $impacted_surfaces

  # Changed paths that matched neither kind.
  | ( [ $changed[]
        | . as $c
        | select(($pinned_surfaces | index($c)) | not)
        | select(($sources | to_entries | any(.value as $v | $v | index($c))) | not) ]
      | unique ) as $unmatched

  # Consumers carrying at least one impacted surface, with the surfaces (via).
  | ( [ $consumers[]
        | .repo as $repo
        | ( [ .refs[]? | strip_provider(.) | select(. != null) ] ) as $repo_surfaces
        | ( [ $impacted_surfaces[] | select(. as $s | $repo_surfaces | index($s)) ] ) as $via
        | select($via | length > 0)
        | { repo: $repo, via: $via } ]
      | sort_by(.repo) ) as $impacted_consumers

  | { impacted_surfaces: $impacted_surfaces,
      impacted_consumers: $impacted_consumers,
      unmatched: $unmatched }
'

# compute_downstream_impact <changed_files> <manifest>
#   <changed_files> : newline-delimited list of changed repo-relative paths.
#   <manifest>      : path to the consumer manifest JSON.
#   Prints the impact object (see header) to stdout; always exits 0.
compute_downstream_impact() {
  local changed_raw="${1:-}"
  local manifest="${2:-}"
  local empty='{"impacted_surfaces":[],"impacted_consumers":[],"unmatched":[]}'

  # Manifest must exist and be valid JSON, else degrade.
  if [ -z "$manifest" ] || [ ! -f "$manifest" ] || ! jq empty "$manifest" 2>/dev/null; then
    printf '%s\n' "$empty"
    return 0
  fi

  # Build the changed-file JSON array: split on newlines, drop blank lines,
  # de-duplicate. printf '%s' (no trailing newline) avoids a spurious empty tail.
  local changed_json
  changed_json=$(printf '%s' "$changed_raw" \
    | jq -R -s 'split("\n") | map(select(length > 0)) | unique' 2>/dev/null) || changed_json='[]'
  [ -n "$changed_json" ] || changed_json='[]'

  local out
  out=$(jq -n \
    --argjson changed "$changed_json" \
    --slurpfile m "$manifest" \
    "$_DOWNSTREAM_IMPACT_JQ" 2>/dev/null) || out="$empty"
  [ -n "$out" ] || out="$empty"
  printf '%s\n' "$out"
}
