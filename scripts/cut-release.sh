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
#   --ref        commit/ref to tag (default: origin/main)
#   --channel    also move <agent>/<name> (e.g. stable) to the new release
#   --push       push the created/moved tags to origin (default: local only)
#   --dry-run    print what would happen; touch nothing
#
# Examples:
#   cut-release.sh pr-review 1.1.0 --push
#   cut-release.sh pr-review 1.1.0 --channel stable --push
#   cut-release.sh dev-lead  2.0.0 --channel stable --dry-run
#
# The pure helpers (valid_agent, cross_repo_agent, validate_version, release_ref,
# channel_ref) are defined at the top level so tests can `source` this file without
# executing it (see the source-guard at the bottom and tests/test_cut_release.bats).
#
set -euo pipefail

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
# a "release" is a commit on that public repo, so its release/channel tags must be
# cut against THAT repo — not this repo's `origin`. The cross-repo push target is
# an open question (TODO #872), so live cuts are refused and only --dry-run is
# supported. See docs/release/versioning.md "Cross-repo reusables".
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

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  local agent="" version="" ref="origin/main" channel="" do_push=false dry=false

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

  local rel chan sha
  rel="$(release_ref "$agent" "$version")"
  if ! sha="$(git rev-parse --verify "$ref^{commit}")"; then
    echo "::error::ref '$ref' could not be resolved — verify the ref exists and the remote has been fetched" >&2
    return 1
  fi

  echo "agent=$agent version=$version ref=$ref ($sha)"
  echo "release tag: $rel"
  [ -n "$channel" ] && { chan="$(channel_ref "$agent" "$channel")"; echo "channel tag: $chan -> $rel"; }

  if [ "$dry" = true ]; then
    if cross_repo_agent "$agent"; then
      echo "::warning::cross-repo placeholder: the SHA above ($sha) was resolved from petry-projects/.github-private. ${agent}'s canonical commits and tags live in petry-projects/.github — this SHA is a local placeholder only."
    fi
    echo "(dry-run) no tags created or pushed."
    return 0
  fi

  # TODO(#872): the cross-repo agents' reusables live in petry-projects/.github, so
  # their release/channel tags must be cut against THAT repo — but main() pushes to
  # this repo's `origin`. The cross-repo push target (a --repo/remote arg vs.
  # dispatching against the public repo) is an open question reserved for a human
  # decision. Until it is wired, only --dry-run is supported for these agents; refuse
  # live cuts so tags are never written to the wrong remote.
  if cross_repo_agent "$agent"; then
    echo "::error::live cut/push for '$agent' is not wired yet — its tags belong on petry-projects/.github (cross-repo target is an open question; see TODO). Use --dry-run for now." >&2
    return 1
  fi

  if git rev-parse -q --verify "refs/tags/$rel" >/dev/null; then
    echo "::error::release tag '$rel' already exists — immutable tags are never overwritten." >&2
    return 1
  fi
  git tag -a "$rel" "$sha" -m "$agent release v$version"
  echo "created $rel"

  local pushrefs=("$rel")
  if [ -n "$channel" ]; then
    git tag -f "$chan" "$sha"
    echo "moved $chan -> $sha"
    pushrefs+=("$chan")
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
