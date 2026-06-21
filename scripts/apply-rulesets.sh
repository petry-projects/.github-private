#!/usr/bin/env bash
set -euo pipefail
# apply-rulesets.sh — codified, idempotent application of repository rulesets from
# .github/rulesets/*.json (initiative #495, issue #868). Makes the previously
# live-only rulesets — notably `release-channel-tags`, which protects the moving
# channel tags `pr-review/**` + `dev-lead/**` (and therefore the ring channels
# next/ring0/ring1 via the `**` glob) — reproducible and version-controlled.
#
# For each ruleset JSON, this finds the existing ruleset by name on the target repo
# and PUTs an update, or POSTs a create if absent. Re-running is a no-op-shaped
# convergence to the file's desired state.
#
# Usage:
#   bash scripts/apply-rulesets.sh [--repo owner/repo] [--dry-run] [<name>...]
#   RULESETS_REPO=owner/repo bash scripts/apply-rulesets.sh
#
# Env:
#   RULESETS_REPO   target repo (default: petry-projects/.github-private — where the
#                   pr-review/dev-lead release tags live)
#   RULESETS_DIR    directory of ruleset JSONs (default: .github/rulesets)
#   GH_TOKEN        token with admin:org / repo admin to read+write rulesets
#   DRY_RUN         "true" → print intent, make no write calls
#
# Bypass model (release-channel-tags): OrganizationAdmin + the automation Integration
# app may move/delete channel tags; agents running as GITHUB_TOKEN cannot. The
# canary-rollout promotion workflow (#501) moves tags via GH_PAT_WORKFLOWS (owned by
# an org admin); the long-term hardening is a dedicated GitHub App whose id is added
# to bypass_actors here so the bypass scopes to the workflow identity.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RULESETS_REPO="${RULESETS_REPO:-petry-projects/.github-private}"
RULESETS_DIR="${RULESETS_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)/.github/rulesets}"
DRY_RUN="${DRY_RUN:-false}"

# ruleset_id_by_name <repo> <name> — echo the id of an existing ruleset, or empty.
ruleset_id_by_name() {
  local repo="$1" name="$2"
  gh api --paginate "repos/${repo}/rulesets" \
    | jq -r --arg n "$name" 'if type=="array" then .[] else . end | select(.name==$n) | .id'
}

# apply_one <repo> <json_file> — create or update the ruleset described by json_file.
apply_one() {
  local repo="$1" file="$2"
  local name id
  name="$(jq -r '.name' "$file")"
  [ -n "$name" ] && [ "$name" != "null" ] || { echo "::error::$file has no .name" >&2; return 1; }
  id="$(ruleset_id_by_name "$repo" "$name")"

  if [ -n "$id" ]; then
    echo "  update ruleset '${name}' (id ${id}) on ${repo}"
    if [ "$DRY_RUN" = "true" ]; then echo "    [dry-run] PUT repos/${repo}/rulesets/${id}"; return 0; fi
    gh api --method PUT "repos/${repo}/rulesets/${id}" --input "$file" >/dev/null
  else
    echo "  create ruleset '${name}' on ${repo}"
    if [ "$DRY_RUN" = "true" ]; then echo "    [dry-run] POST repos/${repo}/rulesets"; return 0; fi
    gh api --method POST "repos/${repo}/rulesets" --input "$file" >/dev/null
  fi
}

main() {
  local repo="$RULESETS_REPO"
  local names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        if [ "$#" -lt 2 ]; then
          echo "::error::--repo requires a value" >&2
          return 2
        fi
        repo="$2"
        shift 2
        ;;
      --dry-run) DRY_RUN=true; shift ;;
      --*) echo "::error::unknown flag: $1" >&2; return 2 ;;
      *) names+=("$1"); shift ;;
    esac
  done

  [ -d "$RULESETS_DIR" ] || { echo "::error::rulesets dir not found: $RULESETS_DIR" >&2; return 1; }
  echo "[apply-rulesets] repo=${repo} dir=${RULESETS_DIR} dry_run=${DRY_RUN}"

  local files=()
  if [ "${#names[@]}" -gt 0 ]; then
    local n
    for n in "${names[@]}"; do
      [ -f "${RULESETS_DIR}/${n}.json" ] && files+=("${RULESETS_DIR}/${n}.json") \
        || { echo "::error::no ruleset file ${n}.json" >&2; return 1; }
    done
  else
    local f
    for f in "${RULESETS_DIR}"/*.json; do [ -e "$f" ] && files+=("$f"); done
  fi
  [ "${#files[@]}" -gt 0 ] || { echo "  no ruleset files to apply"; return 0; }

  local file
  for file in "${files[@]}"; do apply_one "$repo" "$file"; done
  echo "[apply-rulesets] done (${#files[@]} ruleset(s))"
}

# Source-guard: tests source this to exercise ruleset_id_by_name / apply_one.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
