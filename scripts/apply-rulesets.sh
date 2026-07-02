#!/usr/bin/env bash
set -euo pipefail
# apply-rulesets.sh — codified, idempotent application of repository rulesets
# (initiative #495, issue #868).
#
# The org-wide compliance rulesets — `code-quality` and `pr-quality` — are OWNED by
# petry-projects/.github and sourced from its standards/rulesets/*.json (relocated
# there under petry-projects/.github#575; the repo boundary is codified in #576).
# The one ruleset that stays LOCAL to this repo is `release-channel-tags`, which
# protects .github-private's own moving channel tags `pr-review/**` + `dev-lead/**`
# (and therefore the ring channels next/ring0/ring1 via the `**` glob).
#
# By default this materializes the fleet rulesets (code-quality, pr-quality) from
# petry-projects/.github and applies them to the target repo. To apply the
# repo-local `release-channel-tags`, point RULESETS_DIR at this repo's own dir:
#   RULESETS_DIR=.github/rulesets RULESETS_REPO=petry-projects/.github-private \
#     bash scripts/apply-rulesets.sh release-channel-tags
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
#   RULESETS_REPO       target repo to apply rulesets TO (default: petry-projects/.github-private)
#   RULESETS_DIR        explicit directory of ruleset JSONs. When set, it is used
#                       as-is — this is how the repo-local `release-channel-tags` is
#                       applied from this repo's own .github/rulesets. When UNSET,
#                       the fleet rulesets are materialized from STANDARDS_REPO.
#   FLEET_RULESETS_DIR  local checkout of .github/standards/rulesets to source the
#                       fleet rulesets from, skipping the network fetch (offline/CI/pin).
#   STANDARDS_REPO      repo owning the fleet rulesets (default: petry-projects/.github).
#   GH_TOKEN            token with admin:org / repo admin to read+write rulesets
#   DRY_RUN             "true" → print intent, make no write calls
#
# Bypass model (release-channel-tags): OrganizationAdmin + the automation Integration
# app may move/delete channel tags; agents running as GITHUB_TOKEN cannot. The
# canary-rollout promotion workflow (#501) moves tags via GH_PAT_WORKFLOWS (owned by
# an org admin); the long-term hardening is a dedicated GitHub App whose id is added
# to bypass_actors here so the bypass scopes to the workflow identity.

RULESETS_REPO="${RULESETS_REPO:-petry-projects/.github-private}"
RULESETS_DIR="${RULESETS_DIR:-}"
FLEET_RULESETS_DIR="${FLEET_RULESETS_DIR:-}"
STANDARDS_REPO="${STANDARDS_REPO:-petry-projects/.github}"
DRY_RUN="${DRY_RUN:-false}"

# The org-wide fleet rulesets, owned by petry-projects/.github (standards/rulesets/).
FLEET_RULESETS=(code-quality pr-quality)

# _cleanup_fleet_tmpdir / _materialize_fleet_dir — when RULESETS_DIR is unset, place
# the fleet ruleset JSONs into a directory and assign it to the global RULESETS_DIR.
# Uses FLEET_RULESETS_DIR verbatim when provided (offline/CI/local checkout), else
# fetches each fleet ruleset from ${STANDARDS_REPO} via the contents API into a temp
# dir (registered for cleanup on exit). Mirrors seed-repo-template.sh's fetch model.
_FLEET_TMPDIR=""
_cleanup_fleet_tmpdir() { [ -n "$_FLEET_TMPDIR" ] && rm -rf "$_FLEET_TMPDIR"; return 0; }

_materialize_fleet_dir() {
  if [ -n "$FLEET_RULESETS_DIR" ]; then
    [ -d "$FLEET_RULESETS_DIR" ] \
      || { echo "::error::FLEET_RULESETS_DIR not found: $FLEET_RULESETS_DIR" >&2; return 1; }
    RULESETS_DIR="$FLEET_RULESETS_DIR"
    return 0
  fi
  _FLEET_TMPDIR="$(mktemp -d)"
  trap _cleanup_fleet_tmpdir EXIT
  local name
  for name in "${FLEET_RULESETS[@]}"; do
    gh api "repos/${STANDARDS_REPO}/contents/standards/rulesets/${name}.json" --jq '.content' 2>/dev/null \
      | base64 -d 2>/dev/null > "${_FLEET_TMPDIR}/${name}.json" || true
    [ -s "${_FLEET_TMPDIR}/${name}.json" ] \
      || { echo "::error::could not fetch standards/rulesets/${name}.json from ${STANDARDS_REPO}" >&2; return 1; }
  done
  RULESETS_DIR="$_FLEET_TMPDIR"
}

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

  # Resolve the source directory: an explicit RULESETS_DIR (e.g. this repo's own
  # .github/rulesets for release-channel-tags) wins; otherwise materialize the fleet
  # rulesets owned by petry-projects/.github.
  if [ -z "$RULESETS_DIR" ]; then
    _materialize_fleet_dir || return 1
  fi

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
