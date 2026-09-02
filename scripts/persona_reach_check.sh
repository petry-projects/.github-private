#!/usr/bin/env bash
set -euo pipefail
# persona_reach_check.sh — consumer-reached / no-new-trigger-surface verification
# for a mention-routed persona (#1631, epic #1627).
#
# Usage:
#   persona_reach_check.sh <role> [--registry FILE] [--personas-dir DIR] [--router FILE]
#
# Why this exists
# ---------------
# A ring label moving is NOT evidence that a promotion reached a consumer
# (Discussion #1360 learning 12; the #1592 propagation hazard). solution-architect
# carries no dedicated reusable blob — its advisory logic is a prompt file served by
# the SHARED persona-mention router (.github/workflows/persona-mention.yml), whose
# channel the router already owns and cuts. Autocut only cuts a new channel version
# when a REUSABLE's blob changes, so a status/ring move on a prompt-only persona can
# advance the scoreboard yet propagate to nobody. Promotion therefore has to be
# verified two ways this guard encodes, hermetically and re-runnably:
#
#   1. NO NEW TRIGGER SURFACE (AC #5). The persona's DEPLOYED interaction events must
#      stay a subset of the shared mention router's events — promotion must not add a
#      pull_request:synchronize, a cron, or any fan-out that would turn an advisor
#      into a queue (§7 of the story body, learning 11).
#   2. ROUTES-TO != PROMOTED (AC #4). The verdict separates "a mention would route to
#      this persona" (wiring) from "this persona is actually promoted" (status past
#      draft AND registered once in the cross-repo canary-rings.json). The dangerous
#      state — status past draft with NO registration — is the #1052 hollow-green
#      skew, and is the ONLY state this guard fails on.
#
# The truly-live confirmation (dispatch a real @petry-projects/solution-architect
# mention and confirm the resulting persona-runner run resolves to this persona,
# mirroring qa-lead's #1300 mention smoke test) is an operational step run against a
# real consumer; this guard is the hermetic, offline core that gates the wiring and
# catches the skew at PR time.
#
# Following ADR-0004 (pure-logic + bats), the predicates below are pure and
# unit-tested BEFORE the guard is relied on (tests/persona_reach_check.bats); main()
# confines all I/O (reading manifests, the router, an optional registry, printing).
#
# Exit codes:
#   0  safe state — either an honest still-draft persona, or a promoted-and-registered
#      persona whose surface stayed mention-only.
#   2  SKEW / new surface — status advanced past draft with no cross-repo registration,
#      or promotion added a trigger surface beyond the shared mention router.
#   3  hard error — bad usage / missing inputs.

# The shared persona-mention router's DEPLOYED trigger events (persona-standards §4.1;
# .github/workflows/persona-mention.yml `on:` block). Anything a persona subscribes
# beyond this set is a NEW trigger surface introduced during promotion.
PRC_ROUTER_EVENTS="issue_comment pull_request_review_comment discussion_comment"

PRC_RING_ORDER="draft canary next ring0 ring1 stable retired"

# ── Pure logic (unit-tested in tests/persona_reach_check.bats) ─────────────────

# prc_surface_is_mention_only <events_csv>
# Return 0 iff <events_csv> is a NON-EMPTY comma-separated list every member of which
# is one of the shared mention router's events. An empty surface (nothing routes) or
# any event outside the router's set (a new trigger surface) returns non-zero and
# names the offending event on stdout. Surrounding whitespace is ignored.
prc_surface_is_mention_only() {
  local csv="${1:-}" ev seen=0
  local -a events
  IFS=',' read -r -a events <<< "$csv"
  for ev in "${events[@]}"; do
    ev="${ev#"${ev%%[![:space:]]*}"}"   # ltrim
    ev="${ev%"${ev##*[![:space:]]}"}"   # rtrim
    [ -n "$ev" ] || continue
    seen=1
    case " $PRC_ROUTER_EVENTS " in
      *" $ev "*) : ;;
      *) echo "new trigger surface not served by the shared mention router: $ev"; return 1 ;;
    esac
  done
  [ "$seen" -eq 1 ] || { echo "empty trigger surface: nothing routes to this persona"; return 1; }
  return 0
}

# prc_is_past_draft <status>
# Return 0 iff <status> is a ring strictly after 'draft' (the ring label has moved).
prc_is_past_draft() {
  # 'retired' is after draft too; a retired persona is intentionally treated as
  # "past draft" — it must have been registered to have ever shipped.
  local status="${1:-}" r i=0 draft_i=-1 status_i=-1
  for r in $PRC_RING_ORDER; do
    [ "$r" = "draft" ] && draft_i=$i
    [ "$r" = "$status" ] && status_i=$i
    i=$((i + 1))
  done
  [ "$status_i" -ge 0 ] || return 1
  if [ "$status_i" -gt "$draft_i" ]; then
    return 0
  fi
  return 1
}

# prc_promotion_verdict <status> <registered>
# The routes-to != promoted predicate (learning 12). Prints one of:
#   draft     — status is draft: not promoted regardless of routing wiring (safe, 0)
#   promoted  — status past draft AND registered "true" (safe, 0)
#   skew      — status past draft but NOT registered: the #1052 hollow-green hazard (2)
prc_promotion_verdict() {
  local status="${1:-}" registered="${2:-false}"
  if ! prc_is_past_draft "$status"; then
    echo "draft"
    return 0
  fi
  if [ "$registered" = "true" ]; then
    echo "promoted"
    return 0
  fi
  echo "skew"
  return 2
}

# ── I/O orchestration ─────────────────────────────────────────────────────────

prc_die() { echo "::error::persona reach check: $1"; exit 3; }

# prc_manifest_status <persona.yml> — the manifest's top-level `status:` scalar.
prc_manifest_status() {
  local f="${1:-}"
  [ -f "$f" ] || prc_die "manifest not found: $f"
  awk -F: '/^status:[[:space:]]*/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$f"
}

# prc_deployed_events <interaction.yml> — the DEPLOYED interaction.triggers.events as
# a comma-separated list. Reads only the `events:` list items under `triggers:`,
# which the contract keeps in sync with the router's `on:` block.
prc_deployed_events() {
  local f="${1:-}"
  [ -f "$f" ] || prc_die "interaction contract not found: $f"
  awk '
    /^[[:space:]]*triggers:[[:space:]]*$/ {intrig=1; next}
    intrig && /^[[:space:]]*events:[[:space:]]*$/ {inev=1; next}
    inev {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*/) { line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); sub(/[[:space:]]*(#.*)?$/,"",line); print line; next }
      if ($0 ~ /[^[:space:]]/) { inev=0; intrig=0 }
    }
  ' "$f" | paste -sd, -
}

# prc_router_serves_events <router.yml> <events_csv> — return 0 iff every deployed
# event is present in the shared router workflow's `on:` block (the consumer path is
# actually wired, not just declared in the contract).
prc_router_serves_events() {
  local router="${1:-}" csv="${2:-}" ev
  [ -f "$router" ] || prc_die "router workflow not found: $router"
  local -a events
  IFS=',' read -r -a events <<< "$csv"
  for ev in "${events[@]}"; do
    ev="${ev#"${ev%%[![:space:]]*}"}"; ev="${ev%"${ev##*[![:space:]]}"}"
    [ -n "$ev" ] || continue
    grep -Eq "^[[:space:]]+${ev}:" "$router" || { echo "router does not subscribe event: $ev"; return 1; }
  done
  return 0
}

# prc_registry_has_agent <registry.json> <role> — return 0 iff the local registry
# file registers agents.<role>. Absent file / flag ⇒ non-zero (registration
# UNVERIFIED, hermetically treated as not-registered).
prc_registry_has_agent() {
  local reg="${1:-}" role="${2:-}"
  [ -n "$reg" ] && [ -f "$reg" ] || return 1
  command -v jq >/dev/null 2>&1 || prc_die "jq is required to read a registry"
  jq -e --arg a "$role" '.agents[$a] != null' "$reg" >/dev/null 2>&1
}

main() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "$script_dir/.." && pwd)"

  local role="" registry="" personas_dir="$repo_root/personas" router="$repo_root/.github/workflows/persona-mention.yml"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --registry)     [ "$#" -ge 2 ] || prc_die "--registry needs a file";      registry="$2"; shift 2 ;;
      --personas-dir) [ "$#" -ge 2 ] || prc_die "--personas-dir needs a dir";   personas_dir="$2"; shift 2 ;;
      --router)       [ "$#" -ge 2 ] || prc_die "--router needs a file";        router="$2"; shift 2 ;;
      -h|--help)      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) prc_die "unknown option: $1" ;;
      *)  if [ -z "$role" ]; then role="$1"; else prc_die "unexpected argument: $1"; fi; shift ;;
    esac
  done
  [ -n "$role" ] || prc_die "usage: persona_reach_check.sh <role> [--registry FILE]"
  command -v jq >/dev/null 2>&1 || prc_die "jq is required to run this check"

  local manifest="$personas_dir/$role/persona.yml"
  local contract="$personas_dir/$role/interaction.yml"

  local status events registered="false" routes_via_router="false" surface_ok="true" surface_msg=""
  status="$(prc_manifest_status "$manifest")"
  [ -n "$status" ] || prc_die "could not read status from $manifest"
  events="$(prc_deployed_events "$contract")"

  if surface_msg="$(prc_surface_is_mention_only "$events")"; then
    surface_ok="true"
  else
    surface_ok="false"
  fi

  if prc_router_serves_events "$router" "$events" >/dev/null; then
    routes_via_router="true"
  fi

  if prc_registry_has_agent "$registry" "$role"; then
    registered="true"
  fi

  local verdict prom_rc=0
  verdict="$(prc_promotion_verdict "$status" "$registered")" || prom_rc=$?

  jq -cn \
    --arg role "$role" \
    --arg status "$status" \
    --arg events "$events" \
    --argjson surface_mention_only "$surface_ok" \
    --argjson routes_via_router "$routes_via_router" \
    --argjson registered "$registered" \
    --arg verdict "$verdict" \
    '{role:$role, status:$status, events:$events, surface_mention_only:$surface_mention_only, routes_via_router:$routes_via_router, registered:$registered, verdict:$verdict}'

  if [ "$surface_ok" != "true" ]; then
    echo "::error::persona reach check: $role added a trigger surface beyond the shared mention router ($surface_msg)" >&2
    return 2
  fi
  if [ "$prom_rc" -ne 0 ]; then
    echo "::error::persona reach check: $role is past draft but has no agents.$role entry in canary-rings.json — a ring label moved without registration (the #1052 hollow-green skew)" >&2
    return 2
  fi
  if [ "$verdict" = "draft" ]; then
    echo "::notice::persona reach check: $role is still draft — routing wiring present ($routes_via_router), NOT promoted (routes-to != promoted; do not trust the ring label)" >&2
  else
    echo "::notice::persona reach check: $role is promoted and registered; surface stayed mention-only" >&2
  fi
  return 0
}

# Only run main when executed directly (not when sourced by tests).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
