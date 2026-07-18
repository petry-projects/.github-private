# shellcheck shell=bash
# scripts/lib/persona-runner.sh — Persona runtime core (dispatch side)
#
# The other half of the mention framework. The router
# (petry-projects/.github scripts/lib/persona-mention.sh) resolves an
# `@petry-projects/<role>` mention and fires a `persona-mention`
# repository_dispatch at this repo; this library backs the workflow that
# receives it and runs the addressed persona's advisory prompt.
#
# ONE runner serves EVERY persona — it is manifest/convention driven, not one
# workflow per persona (§4.1: per-agent workflows are the drift the framework
# exists to prevent). It resolves the persona's advisory prompt by convention
# (prompts/<id>/advisory.md) exactly as the router resolves the manifest by
# convention (personas/<id>/persona.yml).
#
# ----------------------------------------------------------------------------
# Caller contract
# ----------------------------------------------------------------------------
# `set -euo pipefail`-safe, sourced by a parent (# shellcheck
# source=scripts/lib/persona-runner.sh). Does NOT call `set` itself and runs
# nothing at source time.
#
# ----------------------------------------------------------------------------
# The recursion marker is shared with the router, on purpose
# ----------------------------------------------------------------------------
# Every comment a persona posts MUST begin with '<!-- persona:<id> -->'. The
# router's pm_is_agent_comment skips any comment carrying '<!-- persona:', so a
# persona's own advisory cannot re-summon it (or any persona named in the
# thread). This is axis 2 of the router's guard, closed from the writing side.
# .github-private#860 burned 1,481 acks in 4.5h without it.
PR_MARKER_PREFIX='<!-- persona:'

# pr_agent_marker <persona-id> — the exact first line every advisory must carry.
pr_agent_marker() {
  printf '%s%s -->' "$PR_MARKER_PREFIX" "$1"
}

# pr_valid_persona_id <id> — 0 if id is a well-formed persona slug (kebab-case).
# The dispatch payload is attacker-influenced only through the mention body,
# which the router already constrained to this shape — but this runner is a
# separate trust boundary (a repository_dispatch can be sent by anything with a
# token), so it re-validates rather than trusting the payload. A bad id must
# never reach a path interpolation.
pr_valid_persona_id() {
  case "$1" in
    "" ) return 1 ;;
    *[!a-z0-9-]* ) return 1 ;;   # only lower kebab
    -* | *- ) return 1 ;;        # no leading/trailing hyphen
    *--* ) return 1 ;;           # no doubled hyphen
    * ) return 0 ;;
  esac
}

# pr_advisory_prompt_path <persona-id> — repo-relative path to the persona's
# advisory prompt. Convention, mirroring the router's manifest-by-convention.
pr_advisory_prompt_path() {
  printf 'prompts/%s/advisory.md' "$1"
}

# pr_require_advisory <persona-id> <repo-root> — echo the prompt path if it
# exists, else fail with a diagnostic. A missing prompt is a real answer
# ("this persona has no runtime wired yet"), not a crash: a persona can enable
# the mention surface and declare an address before its advisory prompt exists,
# and the runner must say so rather than invoke an empty prompt.
pr_require_advisory() {
  local id="$1" root="${2:-.}" path
  if ! pr_valid_persona_id "$id"; then
    echo "persona-runner: refusing malformed persona id '$id'" >&2
    return 2
  fi
  path="$(pr_advisory_prompt_path "$id")"
  if [ ! -f "$root/$path" ]; then
    echo "persona-runner: no advisory prompt at $path — persona '$id' has no runtime wired yet" >&2
    return 3
  fi
  printf '%s\n' "$path"
}

# pr_comment_has_marker <persona-id> <body> — 0 if the body's FIRST line is the
# persona's marker. The workflow asserts this on the agent's output before
# posting: a comment without the marker would self-summon, so an unmarked
# advisory is dropped rather than posted. Belt to the prompt's suspenders.
pr_comment_has_marker() {
  local id="$1" body="$2" first marker
  marker="$(pr_agent_marker "$id")"
  IFS= read -r first <<<"$body"
  [ "$first" = "$marker" ]
}
