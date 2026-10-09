#!/usr/bin/env bash
# dispatch-channel-gate.sh — skip a dispatch target whose dev-lead channel pin is
# older than the sweep's (#2086).
#
# WHY THIS EXISTS
#   dev-lead-retry.yml runs scripts/ at ONE release: the channel this repo's
#   dev-lead.yml pins via `agent_ref` (#2050). The sweep then sends
#   repository_dispatch to every repo in the org, and each target runs its
#   harness at ITS OWN dev-lead.yml pin (the stub contract allows a per-repo
#   ring/channel pin). A target pinned to an older channel than the sweep can be
#   sent a client_payload field its harness cannot read yet — the #2017 / #2050
#   skew again, across repos instead of across time.
#
# WHAT THIS LIBRARY DECIDES
#   For each target repo, read its dev-lead.yml `agent_ref` and compare it with
#   the sweep's channel by git ancestry (the compare API on the dev-lead host
#   repo), not by tag name — rings of one major sit on different commits, and a
#   rollback can move a channel backwards:
#     identical | behind     the target has every commit the sweep has → scan
#     ahead | diverged       the sweep has commits the target lacks → SKIP, warn
#     no dev-lead.yml        nothing in that repo receives a dispatch → skip
#     unreadable / unknown   cannot prove compatibility → SKIP, warn (fail closed)
#   A skipped repo keeps its markers; its retries resume once it is repinned to
#   the sweep's channel or newer (or the sweep's channel moves back to it).
#
# Env:
#   DCG_HOST_REPO    repo that hosts the dev-lead reusable, its channel tags and
#                    the sweep's own dev-lead.yml (default: $GITHUB_REPOSITORY,
#                    else petry-projects/.github-private)
#   SWEEP_AGENT_REF  override the sweep's channel (default: DCG_HOST_REPO's pin —
#                    the same ref dev-lead-retry.yml checks scripts/ out at)

DCG_HOST_REPO="${DCG_HOST_REPO:-${GITHUB_REPOSITORY:-petry-projects/.github-private}}"
# Same channel-tag shape dev-lead-retry.yml accepts for the sweep's own pin.
DCG_CHANNEL_RE='^dev-lead/v[0-9]+-(next|ring0|ring1|stable)$'
# target agent_ref -> 0 (compatible) | 1 (older) | 2 (unknown), per sweep run.
declare -gA _DCG_COMPAT_CACHE=()

# dcg_parse_agent_ref: stdin = dev-lead.yml text; prints its `agent_ref` channel
# tag. Returns 1 (prints nothing) when it is missing or not a channel tag.
dcg_parse_agent_ref() {
  local ref
  ref="$(sed -nE "s/^[[:space:]]*agent_ref:[[:space:]]*[\"']?([^\"'[:space:]#]*).*/\1/p" | head -n 1)"
  [[ "$ref" =~ $DCG_CHANNEL_RE ]] || return 1
  printf '%s\n' "$ref"
}

# dcg_read_repo_pin <repo>: prints the repo's dev-lead.yml agent_ref (default
# branch). Returns 2 when the repo has no dev-lead.yml, 1 on any other read
# failure or a malformed pin.
dcg_read_repo_pin() {
  local repo="$1" out
  if ! out="$(gh api "repos/${repo}/contents/.github/workflows/dev-lead.yml" \
      -H "Accept: application/vnd.github.raw" 2>&1)"; then
    if [[ "$out" == *"HTTP 404"* ]]; then
      return 2
    fi
    return 1
  fi
  dcg_parse_agent_ref <<<"$out"
}

# dcg_resolve_sweep_ref: prints the channel the sweep's scripts/ run at.
dcg_resolve_sweep_ref() {
  if [ -n "${SWEEP_AGENT_REF:-}" ]; then
    [[ "$SWEEP_AGENT_REF" =~ $DCG_CHANNEL_RE ]] || return 1
    printf '%s\n' "$SWEEP_AGENT_REF"
    return 0
  fi
  dcg_read_repo_pin "$DCG_HOST_REPO"
}

# dcg_pin_compat <target_ref> <sweep_ref>: 0 = the target's channel has every
# commit the sweep's has; 1 = it is older (or diverged); 2 = unknown. Cached.
dcg_pin_compat() {
  local target="$1" sweep="$2" status rc
  [ "$target" = "$sweep" ] && return 0
  if [ -n "${_DCG_COMPAT_CACHE[$target]+set}" ]; then
    return "${_DCG_COMPAT_CACHE[$target]}"
  fi
  if ! status="$(gh api "repos/${DCG_HOST_REPO}/compare/${target}...${sweep}" --jq '.status' 2>/dev/null)"; then
    status=""
  fi
  case "$status" in
    identical|behind) rc=0 ;;
    ahead|diverged)   rc=1 ;;
    *)                rc=2 ;;
  esac
  _DCG_COMPAT_CACHE[$target]="$rc"
  return "$rc"
}

# dcg_repo_dispatch_allowed <repo> <sweep_ref>: 0 = scan and dispatch to the
# repo; 1 = skip it. Logs the reason to stderr.
dcg_repo_dispatch_allowed() {
  local repo="$1" sweep="$2" target rc=0
  target="$(dcg_read_repo_pin "$repo")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      echo "[retry] skipping ${repo}: no dev-lead.yml, so nothing receives a dispatch" >&2
      return 1 ;;
    *)
      echo "::warning::[retry] skipping ${repo}: cannot read a dev-lead channel from its dev-lead.yml agent_ref, so payload compatibility with the sweep's ${sweep} is unproven (#2086)" >&2
      return 1 ;;
  esac

  rc=0
  dcg_pin_compat "$target" "$sweep" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      echo "::warning::[retry] skipping ${repo}: its dev-lead.yml pins ${target}, older than the sweep's ${sweep}; its harness may not read the sweep's dispatch payloads (#2086). Repin it to ${sweep} or newer." >&2
      return 1 ;;
    *)
      echo "::warning::[retry] skipping ${repo}: could not compare its pin ${target} with the sweep's ${sweep} (#2086)" >&2
      return 1 ;;
  esac
}
