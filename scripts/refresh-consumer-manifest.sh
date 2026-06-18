#!/usr/bin/env bash
set -euo pipefail
# refresh-consumer-manifest.sh — empirically repopulate the consumer manifest's
# `consumers` map (issue #749, epic #748).
#
# Consumers are NOT hand-curated: this script enumerates every repo in the org
# and detects which provider reusable workflows each one pins via `uses:`. The
# `providers` list and the hand-maintained `surface_sources` map are preserved
# from the existing manifest verbatim — this script only refreshes `consumers`.
#
# Output is written deterministically (sorted object keys, consumers sorted by
# repo, refs sorted + de-duplicated) so re-runs produce a clean, reviewable diff.
#
# Auth: uses GH_TOKEN exactly as .github/workflows/pr-review.yml does — pass the
# bot PAT (DON_PETRY_BOT_GH_PAT_CLASSIC || DON_PETRY_BOT_GH_PAT, surfaced as
# GH_PAT in that workflow). The org enumeration needs read access across the
# consumer repos, which that token already has.
#
# Usage:
#   refresh-consumer-manifest.sh [--manifest PATH] [--org ORG] [--dry-run]
# Env overrides (lower precedence than flags):
#   CONSUMER_MANIFEST   path to the manifest JSON (default: scripts/lib/consumer-manifest.json)
#   TARGET_ORG          org to enumerate (default: petry-projects)
# --dry-run prints the regenerated manifest to stdout instead of writing it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFEST="${CONSUMER_MANIFEST:-$SCRIPT_DIR/lib/consumer-manifest.json}"
ORG="${TARGET_ORG:-petry-projects}"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
    --org)      ORG="${2:?--org needs a value}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "refresh-consumer-manifest: unknown argument '$1'" >&2
      exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "refresh-consumer-manifest: gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "refresh-consumer-manifest: jq not found" >&2; exit 1; }

# Preserve providers + surface_sources from the existing manifest; default to the
# fixed provider list (#653) when no manifest exists yet.
if [ -f "$MANIFEST" ] && jq empty "$MANIFEST" 2>/dev/null; then
  providers_json=$(jq -c '.providers // [".github", ".github-private"]' "$MANIFEST")
  surface_json=$(jq -c '.surface_sources // {}' "$MANIFEST")
else
  providers_json='[".github", ".github-private"]'
  surface_json='{}'
fi

# Build a regex of provider repos to match in `uses:` refs, derived from the
# preserved providers list so the two stay in sync.
providers_alt=$(printf '%s' "$providers_json" \
  | jq -r '.[]' \
  | sed 's/[.]/\\./g' \
  | paste -sd'|' -)

pairs_file="$(mktemp)"
trap 'rm -f "$pairs_file"' EXIT

# Enumerate every repo in the org and scan its workflow files for `uses:`
# references to a provider reusable workflow. Each detection is recorded as a
# "<repo>\t<provider>/.github/workflows/<name>.yml" line.
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  while IFS= read -r wf_path; do
    [ -n "$wf_path" ] || continue
    case "$wf_path" in *.yml|*.yaml) : ;; *) continue ;; esac
    content=$(gh api "repos/$repo/contents/$wf_path" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null || true)
    [ -n "$content" ] || continue
    matches=$(printf '%s\n' "$content" \
      | grep -oE "petry-projects/(${providers_alt})/\.github/workflows/[A-Za-z0-9_.-]+\.yml" \
      | sed 's#^petry-projects/##' || true)
    [ -n "$matches" ] || continue
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      printf '%s\t%s\n' "$repo" "$ref" >> "$pairs_file"
    done <<< "$matches"
  done < <(gh api "repos/$repo/contents/.github/workflows" --jq '.[].path' 2>/dev/null || true)
done < <(gh repo list "$ORG" --limit 500 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

# Group detections into the consumers array: one entry per repo with sorted,
# de-duplicated refs. group_by sorts by repo, giving a stable order.
consumers_json=$(sort -u "$pairs_file" | jq -R -s '
  split("\n")
  | map(select(length > 0) | split("\t"))
  | group_by(.[0])
  | map({ repo: .[0][0], refs: (map(.[1]) | unique) })
')

manifest_json=$(jq -n --sort-keys \
  --argjson providers "$providers_json" \
  --argjson consumers "$consumers_json" \
  --argjson surface_sources "$surface_json" \
  '{ providers: $providers, consumers: $consumers, surface_sources: $surface_sources }')

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$manifest_json"
else
  printf '%s\n' "$manifest_json" > "$MANIFEST"
  echo "refresh-consumer-manifest: wrote $(jq '.consumers | length' "$MANIFEST") consumer(s) to $MANIFEST" >&2
fi
