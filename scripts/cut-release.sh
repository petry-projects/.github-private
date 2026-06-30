#!/usr/bin/env bash
#
# cut-release.sh — cut an immutable agent release tag and (optionally) advance a
# channel tag to it. The GitHub-native primitive behind the Release Strategy
# initiative (epic #495): immutable `<agent>/vX.Y.Z` tags are audit/rollback
# targets; moving `<agent>/<channel>` tags are what callers pin to.
#
# Usage:
#   cut-release.sh <agent> <version> [--ref <ref>] [--channel <name>]
#                                    [--push] [--dry-run]
#
#   <agent>      this repo: pr-review | dev-lead
#                cross-repo (reusable in petry-projects/.github): feature-ideation |
#                  agent-shield | auto-rebase | dependency-audit |
#                  dependabot-automerge | dependabot-rebase | pr-review-mention
#   <version>    semantic version without the leading v, e.g. 1.2.0
#   --ref        commit/ref to tag (default: main). For this-repo agents it is
#                resolved against local git (e.g. origin/main); for cross-repo
#                agents it is resolved against petry-projects/.github via the API
#                (an `origin/` prefix is stripped — `origin/main` means its `main`).
#   --channel    also move <agent>/<name> (e.g. stable) to the new release
#   --promote    move <agent>/<channel> to the EXISTING <agent>/vX.Y.Z release
#                instead of cutting a new one (ring-to-ring promotion). Requires
#                --channel; errors if the release tag does not already exist;
#                --ref is ignored (the release's own commit is authoritative).
#   --push       publish the created/moved tags (default: print only). For
#                this-repo agents this pushes to origin; for cross-repo agents it
#                creates/moves the tags on petry-projects/.github via the API.
#   --dry-run    print what would happen; touch nothing
#
# Examples:
#   cut-release.sh pr-review 1.1.0 --push
#   cut-release.sh pr-review 1.1.0 --channel stable --push
#   cut-release.sh dev-lead  2.0.0 --channel stable --dry-run
#   cut-release.sh agent-shield 2.1.0 --channel next --push   # cross-repo → .github
#
# Cross-repo agents (#872): feature-ideation + the six #482 reusables are hosted in
# petry-projects/.github (this repo holds only the thin caller stubs), so their
# tags are cut against THAT repo. Resolution + publish go through `gh api`
# (requires GH_TOKEN with contents:write on petry-projects/.github). See
# docs/release/versioning.md "Cross-repo reusables".
#
# The pure helpers (valid_agent, cross_repo_agent, validate_version, release_ref,
# channel_ref, strip_origin) are defined at the top level so tests can `source`
# this file without executing it (see the source-guard at the bottom and
# tests/test_cut_release.bats).
#
set -euo pipefail

# The repo whose git refs hold cross-repo agents' release/channel tags.
CROSS_REPO_TARGET="petry-projects/.github"

# ── pure helpers (sourced by tests; no side effects) ─────────────────────────

# valid_agent <agent> — return 0 iff agent is a known agent name. Covers the two
# agents hosted in this repo (pr-review, dev-lead) plus the cross-repo reusables
# hosted in petry-projects/.github (feature-ideation and the six #482 reusables
# brought under the ring model in #870).
valid_agent() {
  case "$1" in
    pr-review | dev-lead) return 0 ;;
    *) cross_repo_agent "$1" ;;
  esac
}

# cross_repo_agent <agent> — return 0 iff the agent's reusable workflow lives in
# petry-projects/.github (this repo holds only the thin caller stub). For these,
# a "release" is a commit on that public repo, so its release/channel tags are
# resolved and cut against THAT repo (CROSS_REPO_TARGET) via `gh api`, not this
# repo's `origin` (#872, wired). See docs/release/versioning.md "Cross-repo reusables".
cross_repo_agent() {
  case "$1" in
    feature-ideation) return 0 ;;
    agent-shield | auto-rebase | dependency-audit) return 0 ;;
    dependabot-automerge | dependabot-rebase | pr-review-mention) return 0 ;;
    *) return 1 ;;
  esac
}

# validate_version <version> — return 0 iff strictly MAJOR.MINOR.PATCH numerics.
validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# release_ref <agent> <version> — echo the immutable release tag name.
release_ref() { printf '%s/v%s\n' "$1" "$2"; }

# channel_ref <agent> <channel> — echo the channel tag name.
channel_ref() { printf '%s/%s\n' "$1" "$2"; }

# strip_origin <ref> — normalize a local-style ref to a remote-repo ref name for
# the cross-repo API path: `origin/main` → `main`, a bare ref/SHA passes through.
# (`git rev-parse` understands `origin/main`; the GitHub API does not.)
strip_origin() { printf '%s\n' "${1#origin/}"; }

# ── cross-repo tag operations (gh api; require GH_TOKEN with contents:write) ───
# Thin wrappers kept separate from the pure helpers so the network surface is
# explicit. Each targets an arbitrary <repo> so tests can mock `gh`.

# gh_resolve_sha <repo> <ref> — echo the commit SHA <ref> resolves to on <repo>.
gh_resolve_sha() { gh api "repos/$1/commits/$2" --jq '.sha'; }

# gh_tag_exists <repo> <tag> — return 0 iff refs/tags/<tag> exists on <repo>.
gh_tag_exists() { gh api "repos/$1/git/ref/tags/$2" >/dev/null 2>&1; }

# gh_create_annotated_tag <repo> <tag> <sha> <message> — create an annotated tag
# object and the ref pointing at it (mirrors `git tag -a`). Fails if the ref
# exists (the API refuses to create a duplicate ref — immutability is enforced).
gh_create_annotated_tag() {
  local obj
  obj=$(gh api -X POST "repos/$1/git/tags" \
        -f "tag=$2" -f "message=$4" -f "object=$3" -f "type=commit" --jq '.sha')
  gh api -X POST "repos/$1/git/refs" -f "ref=refs/tags/$2" -f "sha=$obj" >/dev/null
}

# gh_release_commit <repo> <tag> — echo the COMMIT sha a release tag points to,
# dereferencing an annotated tag object. Empty + non-zero if the tag is absent.
gh_release_commit() {
  local obj type
  obj=$(gh api "repos/$1/git/ref/tags/$2" --jq '.object.sha' 2>/dev/null) || return 1
  [ -z "$obj" ] && return 1
  type=$(gh api "repos/$1/git/ref/tags/$2" --jq '.object.type' 2>/dev/null)
  if [ "$type" = "tag" ]; then
    gh api "repos/$1/git/tags/$obj" --jq '.object.sha' 2>/dev/null
  else
    printf '%s\n' "$obj"
  fi
}

# gh_move_tag <repo> <tag> <sha> — point refs/tags/<tag> at <sha> (force-move if
# it exists, create if not). Lightweight ref, matching `git tag -f` for channels.
gh_move_tag() {
  if gh_tag_exists "$1" "$2"; then
    gh api -X PATCH "repos/$1/git/refs/tags/$2" -f "sha=$3" -F "force=true" >/dev/null
  else
    gh api -X POST "repos/$1/git/refs" -f "ref=refs/tags/$2" -f "sha=$3" >/dev/null
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  local agent="" version="" ref="origin/main" channel="" do_push=false dry=false promote=false

  if [ "$#" -lt 2 ]; then
    echo "::error::usage: cut-release.sh <agent> <version> [--ref <ref>] [--channel <name>] [--push] [--dry-run]" >&2
    return 2
  fi
  agent="$1"
  version="$2"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -lt 2 ] && { echo "::error::--ref requires an argument" >&2; return 2; }
        ref="$2"; shift 2 ;;
      --channel)
        [ "$#" -lt 2 ] && { echo "::error::--channel requires an argument" >&2; return 2; }
        channel="$2"; shift 2 ;;
      --push) do_push=true; shift ;;
      --promote) promote=true; shift ;;
      --dry-run) dry=true; shift ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
  done

  if ! valid_agent "$agent"; then
    echo "::error::unknown agent '$agent' (expected: pr-review | dev-lead | feature-ideation | agent-shield | auto-rebase | dependency-audit | dependabot-automerge | dependabot-rebase | pr-review-mention)" >&2
    return 2
  fi
  if ! validate_version "$version"; then
    echo "::error::invalid version '$version' (expected MAJOR.MINOR.PATCH, e.g. 1.2.0)" >&2
    return 2
  fi

  local rel chan sha pushrefs
  rel="$(release_ref "$agent" "$version")"
  pushrefs=("$rel")
  if [ -n "$channel" ]; then chan="$(channel_ref "$agent" "$channel")"; pushrefs+=("$chan"); fi

  # ── --promote: move an existing release's channel; never cut a new tag ──
  # A ring-to-ring promotion (e.g. ring0 → ring1 of an already-cut vX.Y.Z). The
  # release commit is read from the existing tag, so --ref is irrelevant and the
  # immutable release tag is left untouched (and MUST exist).
  if [ "$promote" = true ]; then
    [ -z "$channel" ] && { echo "::error::--promote requires --channel <name> (the ring to advance to the existing release)" >&2; return 2; }
    local pcommit
    if cross_repo_agent "$agent"; then
      command -v gh >/dev/null 2>&1 || { echo "::error::'gh' CLI is required for cross-repo agents but was not found in PATH" >&2; return 1; }
      gh_tag_exists "$CROSS_REPO_TARGET" "$rel" || { echo "::error::cannot promote: release tag '$rel' does not exist on $CROSS_REPO_TARGET — cut it first." >&2; return 1; }
      pcommit="$(gh_release_commit "$CROSS_REPO_TARGET" "$rel")"
      echo "promote $chan -> $rel ($pcommit) on $CROSS_REPO_TARGET"
      [ "$dry" = true ] && { echo "(dry-run) channel not moved."; return 0; }
      [ "$do_push" != true ] && { echo "print only — re-run with --push to move $chan on $CROSS_REPO_TARGET"; return 0; }
      gh_move_tag "$CROSS_REPO_TARGET" "$chan" "$pcommit"
      echo "moved $chan -> $pcommit on $CROSS_REPO_TARGET"
      return 0
    fi
    git rev-parse -q --verify "refs/tags/$rel" >/dev/null || { echo "::error::cannot promote: release tag '$rel' does not exist — cut it first." >&2; return 1; }
    pcommit="$(git rev-parse --verify "$rel^{commit}")"
    echo "promote $chan -> $rel ($pcommit)"
    [ "$dry" = true ] && { echo "(dry-run) channel not moved."; return 0; }
    git tag -f "$chan" "$pcommit"; echo "moved $chan -> $pcommit"
    if [ "$do_push" = true ]; then git push --force origin "$chan"; echo "pushed $chan"; else echo "local only — re-run with --push to publish $chan"; fi
    return 0
  fi

  # Resolve the target SHA. This-repo agents resolve against local git; cross-repo
  # agents (#872) resolve against petry-projects/.github via the API.
  if cross_repo_agent "$agent"; then
    if ! command -v gh >/dev/null 2>&1; then
      echo "::error::'gh' CLI is required for cross-repo agents but was not found in PATH" >&2
      return 1
    fi
    local rref; rref="$(strip_origin "$ref")"
    if ! sha="$(gh_resolve_sha "$CROSS_REPO_TARGET" "$rref")" || [ -z "$sha" ]; then
      echo "::error::ref '$rref' could not be resolved on $CROSS_REPO_TARGET (check the ref exists and GH_TOKEN has access)" >&2
      return 1
    fi
  else
    if ! sha="$(git rev-parse --verify "$ref^{commit}")"; then
      echo "::error::ref '$ref' could not be resolved — verify the ref exists and the remote has been fetched" >&2
      return 1
    fi
  fi

  local target="origin (this repo)"
  cross_repo_agent "$agent" && target="$CROSS_REPO_TARGET (cross-repo)"
  echo "agent=$agent version=$version ref=$ref ($sha) target=$target"
  echo "release tag: $rel"
  [ -n "$channel" ] && echo "channel tag: $chan -> $rel"

  if [ "$dry" = true ]; then
    echo "(dry-run) no tags created or pushed."
    return 0
  fi

  # ── cross-repo agents: create/move tags on petry-projects/.github via the API ──
  if cross_repo_agent "$agent"; then
    if gh_tag_exists "$CROSS_REPO_TARGET" "$rel"; then
      echo "::error::release tag '$rel' already exists on $CROSS_REPO_TARGET — immutable tags are never overwritten." >&2
      return 1
    fi
    if [ "$do_push" != true ]; then
      echo "print only — re-run with --push to publish to $CROSS_REPO_TARGET: ${pushrefs[*]}"
      return 0
    fi
    gh_create_annotated_tag "$CROSS_REPO_TARGET" "$rel" "$sha" "$agent release v$version"
    echo "created $rel on $CROSS_REPO_TARGET"
    if [ -n "$channel" ]; then
      gh_move_tag "$CROSS_REPO_TARGET" "$chan" "$sha"
      echo "moved $chan -> $sha on $CROSS_REPO_TARGET"
    fi
    echo "published to $CROSS_REPO_TARGET: ${pushrefs[*]}"
    return 0
  fi

  # ── this-repo agents: local annotated tag + force-moved channel, pushed to origin ──
  if git rev-parse -q --verify "refs/tags/$rel" >/dev/null; then
    echo "::error::release tag '$rel' already exists — immutable tags are never overwritten." >&2
    return 1
  fi
  git tag -a "$rel" "$sha" -m "$agent release v$version"
  echo "created $rel"
  if [ -n "$channel" ]; then
    git tag -f "$chan" "$sha"
    echo "moved $chan -> $sha"
  fi

  if [ "$do_push" = true ]; then
    # Push the immutable release tag without --force to prevent accidental remote overwrites
    git push origin "$rel"
    if [ -n "$channel" ]; then
      # --force is required to move the mutable channel tag
      git push --force origin "$chan"
    fi
    echo "pushed: ${pushrefs[*]}"
  else
    echo "local only — re-run with --push to publish: ${pushrefs[*]}"
  fi
}

# Run main only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
