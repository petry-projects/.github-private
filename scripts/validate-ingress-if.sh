#!/usr/bin/env bash
# validate-ingress-if.sh — the if:-as-event-filter-only guard for ADR-0007
# agent-ingress jobs (issue #1725 AC #3, epic #1723).
#
# WHY THIS EXISTS
#   ADR-0007 collapses the per-role Class-1 caller stubs into ONE agent-ingress
#   workflow with one thin-caller job per role. The single place it loosens
#   ADR-0001 is a job's `if:`: because the ingress fans one shared `on:` union out
#   to the right role, each job's `if:` selects the events that role answers.
#   That loosening is deliberately narrow — an `if:` is evaluated by the Actions
#   service BEFORE a runner exists, so it can only legitimately read the DELIVERED
#   EVENT (github.event_name / github.event.action / plain payload predicates).
#   The moment an `if:` reaches for repo state — org/repo config vars or secrets,
#   another job's computed outputs, the repo tree (hashFiles), repo identity, the
#   payload's standing default_branch, or the standing labels array — it is
#   script-in-disguise logic that belongs in the reusable as a permissioned step,
#   not in the thin caller. This guard fails such an ingress before merge.
#
# WHAT IT DOES
#   For an agent-ingress workflow it asserts, per job, that
#     (1) the job is a thin caller (it has a reusable `uses:` pin), and
#     (2) the job's `if:` is a PURE event filter (no forbidden repo-state reach).
#   The ALLOW/FORBID rulings are the FROZEN, machine-readable table at
#   tests/fixtures/agent-ingress/if-filter-rulings.tsv. This guard consumes THOSE
#   ROWS DIRECTLY (not the ADR prose), so guard and test cannot drift (QA #8).
#
# USAGE
#   validate-ingress-if.sh
#       Scan VIIF_ROOT (default: the repo containing this script) for
#       .github/workflows/agent-ingress.yml and validate it. A tree with no such
#       file is a clean pass (the ingress is a docs reference until the collapse
#       story lands) — never a silent skip that hides an absent guard.
#
# ENV
#   VIIF_ROOT      Repo root to scan (default: the repo containing this script).
#   VIIF_RULINGS   Path to the frozen rulings TSV (default: the repo's fixture).

# NOTE: strict mode is enabled only in the execute-directly guard at the bottom,
# so sourcing this file (the bats tests do) does not leak `set -euo pipefail`.

viif_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

viif_rulings_path() {
  if [ -n "${VIIF_RULINGS:-}" ]; then
    printf '%s\n' "$VIIF_RULINGS"
  else
    printf '%s/tests/fixtures/agent-ingress/if-filter-rulings.tsv\n' "$(viif_repo_root)"
  fi
}

# ── pure event-filter boundary detector ──────────────────────────────────────

# viif_expr_matches_construct <expr> <construct-name> — return 0 if <expr>
# reaches for the FORBID construct <construct-name> (a rulings key). This is the
# ONLY place a construct name is mapped to its detection; the set of names comes
# from the frozen rulings table, so an unmapped new FORBID row is caught by the
# test (its expr would be wrongly permitted) rather than silently under-enforced.
viif_expr_matches_construct() {
  local expr="$1" name="$2" lc="${1,,}"
  case "$name" in
    vars)                  [[ "$expr" =~ (^|[^._[:alnum:]])vars\. ]] ;;
    secrets)               [[ "$expr" =~ (^|[^._[:alnum:]])secrets\. ]] ;;
    needs-outputs)         [[ "$expr" =~ (^|[^._[:alnum:]])needs\. ]] ;;
    hashfiles)             [[ "$lc" == *hashfiles* ]] ;;
    repo-identity)         [[ "$expr" == *"github.repository"* ]] || \
                           [[ "$expr" =~ github\.event\.repository\.(full_name|name|id|node_id|owner) ]] ;;
    default-branch)        [[ "$expr" == *default_branch* ]] ;;
    labels-array-contains) [[ "$expr" == *".labels"* ]] ;;
    *)                     return 1 ;;
  esac
}

# viif_forbidden <if-expr> — print the FORBID construct name(s) <if-expr> reaches
# for (space-separated) and return 1; print nothing and return 0 if it is a pure
# event filter. Enumerates the FORBID rows straight from the frozen rulings table.
viif_forbidden() {
  local expr="$1" rulings hits="" name verdict row_expr row_rationale
  rulings="$(viif_rulings_path)"
  [ -f "$rulings" ] || { echo "::error::rulings table not found: $rulings" >&2; return 2; }

  # shellcheck disable=SC2034  # row_expr/row_rationale columns are consumed by the test, not here
  while IFS=$'\t' read -r name verdict row_expr row_rationale; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "FORBID" ] || continue
    if viif_expr_matches_construct "$expr" "$name"; then
      hits+="${hits:+ }$name"
    fi
  done < "$rulings"

  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# ── file-level validation ─────────────────────────────────────────────────────

# viif_validate_ingress <file> — validate one agent-ingress workflow file. Each
# job must be a thin caller (reusable `uses:` pin) whose `if:` is a pure event
# filter. Emits ::error:: naming the offending job (and, for an if: violation,
# the forbidden construct); returns 1 on any failure, 0 if clean.
viif_validate_ingress() {
  local file="$1" rc=0 job uses ifexpr bad
  local -a jobs

  mapfile -t jobs < <(yq '.jobs | keys | .[]' "$file" 2>/dev/null)
  if [ "${#jobs[@]}" -eq 0 ]; then
    echo "::error::agent-ingress $(basename "$file") declares no jobs"
    return 1
  fi

  for job in "${jobs[@]}"; do
    [ -n "$job" ] || continue

    # (1) thin-caller structural check: the job MUST pin a reusable via uses:.
    uses="$(yq ".jobs[\"$job\"].uses // \"\"" "$file" 2>/dev/null)"
    if [ -z "$uses" ] || [ "$uses" = "null" ]; then
      echo "::error::agent-ingress job '$job' is not a thin caller — it has no reusable 'uses:' pin (an ingress job must be a thin caller)"
      rc=1
      continue
    fi

    # (2) if:-as-event-filter check.
    ifexpr="$(yq ".jobs[\"$job\"].if // \"\"" "$file" 2>/dev/null)"
    [ "$ifexpr" = "null" ] && ifexpr=""
    if [ -n "$ifexpr" ]; then
      if bad="$(viif_forbidden "$ifexpr")"; then
        : # pure event filter
      else
        echo "::error::agent-ingress job '$job' if: reaches for repo state, not the event — forbidden construct(s): ${bad} (an ingress if: may reference only the delivered event; move repo-state logic into the reusable)"
        rc=1
      fi
    fi
  done

  return "$rc"
}

# ── repo scan ────────────────────────────────────────────────────────────────

viif_scan() {
  local root="$1" ingress="$1/.github/workflows/agent-ingress.yml"
  if [ ! -f "$ingress" ]; then
    echo "ingress-if: no agent-ingress.yml under ${root}/.github/workflows — nothing to check (clean pass)."
    return 0
  fi
  if viif_validate_ingress "$ingress"; then
    echo "ingress-if: OK — every agent-ingress job is a thin caller with a pure event-filter if:."
    return 0
  fi
  echo "" >&2
  echo "ingress-if: FAIL — an agent-ingress job is not a thin caller or its if: reaches for repo state." >&2
  echo "An ingress if: may reference ONLY the delivered event. See tests/fixtures/agent-ingress/if-filter-rulings.tsv and ADR-0007." >&2
  return 1
}

main() {
  local root="${VIIF_ROOT:-}"
  [ -n "$root" ] || root="$(viif_repo_root)"
  viif_scan "$root"
}

# Run only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  main "$@"
fi
