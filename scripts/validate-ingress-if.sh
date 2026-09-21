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

# viif_normalize_expr <expr> — rewrite bracket/indexed context access to dot
# access so `x['y']` / `x["y"]` and `x.y` are ONE construct for matching. The
# detectors below (and the allowlist gate) match dot notation only; without this
# an indexed reach such as vars['DEV_LEAD_ENGINE'] or github['repository'] would
# slip past every dot-notation check (#1772). Applied globally so chained indices
# (needs['detect'].outputs['should_run']) collapse to a single dotted path.
viif_normalize_expr() {
  printf '%s' "$1" | sed -E "s/\[[[:space:]]*'([^']*)'[[:space:]]*\]/.\1/g; s/\[[[:space:]]*\"([^\"]*)\"[[:space:]]*\]/.\1/g"
}

# viif_expr_matches_construct <expr> <construct-name> — return 0 if <expr>
# reaches for the FORBID construct <construct-name> (a rulings key). This is the
# ONLY place a construct name is mapped to its detection; the set of names comes
# from the frozen rulings table, so an unmapped new FORBID row is caught by the
# test (its expr would be wrongly permitted) rather than silently under-enforced.
# Expects a NORMALIZED and LITERAL-STRIPPED expr (see viif_normalize_expr and the
# stripping in viif_forbidden) so indexed and dot forms are treated identically
# and a policed name inside a quoted literal is not mistaken for a reference.
viif_expr_matches_construct() {
  local expr="$1" name="$2" lc="${1,,}"
  case "$name" in
    # vars/secrets/needs are ALWAYS a repo-state reach, whether accessed with a
    # property (vars.X, normalized from vars['X']) or used BARE as a whole value
    # (toJSON(vars), or the root passed as any function argument). Match the root
    # as an identifier TOKEN — bounded left and right, not requiring a trailing
    # dot — so the bare form no longer slips past the dotted-only pattern (#1781).
    vars)                  [[ "$expr" =~ (^|[^._[:alnum:]-])vars([^_[:alnum:]-]|$) ]] ;;
    secrets)               [[ "$expr" =~ (^|[^._[:alnum:]-])secrets([^_[:alnum:]-]|$) ]] ;;
    needs-outputs)         [[ "$expr" =~ (^|[^._[:alnum:]-])needs([^_[:alnum:]-]|$) ]] ;;
    hashfiles)             [[ "$lc" == *hashfiles* ]] ;;
    repo-identity)         [[ "$expr" == *"github.repository"* ]] || \
                           [[ "$expr" =~ github\.event\.repository\.(full_name|name|id|node_id|owner) ]] ;;
    default-branch)        [[ "$expr" == *default_branch* ]] ;;
    labels-array-contains) [[ "$expr" == *".labels"* ]] ;;
    *)                     return 1 ;;
  esac
}

# viif_reaches_unlisted_context <expr> — the ALLOWLIST backstop. ADR-0007 permits
# an ingress if: to reference ONLY the delivered event: github.event_name,
# github.event.action, and github.event.<payload>. The named FORBID rows above
# are a DENYLIST of known repo-state reaches, which passes anything unlisted by
# default — env.*, inputs.*, steps.*, job.*, runner.*, matrix.*, strategy.*, and
# non-event github.* (github.actor/ref/sha/token/…) all validate today. This gate
# closes that default: it returns 0 (reaches unlisted context) for any context
# root outside the event-only allowlist, so an unenumerated reach cannot pass
# silently (#1772). Expects a NORMALIZED and LITERAL-STRIPPED expr (see
# viif_forbidden). vars/secrets/needs and bare github.repository are owned by the
# named rows above and excluded here to avoid double-reporting them.
viif_reaches_unlisted_context() {
  local stripped="$1" sub

  # (a) a github.<x> reference outside the event allowlist (event_name / event.*).
  #     bare github.repository is the repo-identity construct's own concern.
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      event_name|event|repository) continue ;;
      *) return 0 ;;
    esac
  done < <(printf '%s\n' "$stripped" | grep -oE '(^|[^._[:alnum:]])github\.[A-Za-z_][A-Za-z0-9_-]*' | sed -E 's/.*github\.//')

  # (a2) BARE github used as a whole value (toJSON(github)) — no property to walk,
  #      so part (a)'s dotted grep never sees it. Serializing the whole context is
  #      the most severe reach: it is repo identity/actor/ref/… , not the event.
  #      Match github as a token NOT followed by a dot (the dotted forms are (a)'s
  #      concern; event.* stays allowed there) (#1781).
  if [[ "$stripped" =~ (^|[^._[:alnum:]-])github([^._[:alnum:]-]|$) ]]; then
    return 0
  fi

  # (b) any other policed context root that is never the delivered event, whether
  #     accessed with a property (env.FOO) or used BARE as a whole value
  #     (toJSON(env)). Match the root as an identifier TOKEN, not requiring a
  #     trailing dot, so the bare form is caught too (#1781).
  if [[ "$stripped" =~ (^|[^._[:alnum:]-])(env|inputs|steps|job|jobs|runner|matrix|strategy)([^_[:alnum:]-]|$) ]]; then
    return 0
  fi
  return 1
}

# viif_forbidden <if-expr> — print the FORBID construct name(s) <if-expr> reaches
# for (space-separated) and return 1; print nothing and return 0 if it is a pure
# event filter. Enumerates the FORBID rows straight from the frozen rulings table,
# then applies the event-only allowlist backstop for any unlisted context root.
viif_forbidden() {
  local expr="$1" nexpr sexpr rulings hits="" name verdict row_expr row_rationale
  nexpr="$(viif_normalize_expr "$expr")"
  # Strip string literals AFTER normalizing (normalize rewrites x['y']→x.y using
  # the quotes, so stripping first would erase the index). Both the named FORBID
  # matching and the allowlist backstop then run on the literal-stripped expr, so
  # a policed name that appears only inside a quoted literal (e.g. an issue-comment
  # body 'set vars.X please') is not mistaken for a context reference (#1781 AC #2).
  sexpr="$(printf '%s' "$nexpr" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
  rulings="$(viif_rulings_path)"
  [ -f "$rulings" ] || { echo "::error::rulings table not found: $rulings" >&2; return 2; }

  # shellcheck disable=SC2034  # row_expr/row_rationale columns are consumed by the test, not here
  while IFS=$'\t' read -r name verdict row_expr row_rationale || [ -n "$name" ]; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$verdict" = "FORBID" ] || continue
    if viif_expr_matches_construct "$sexpr" "$name"; then
      case " $hits " in *" $name "*) : ;; *) hits+="${hits:+ }$name" ;; esac
    fi
  done < "$rulings"

  # Allowlist backstop: fail any context root the denylist above does not name.
  if viif_reaches_unlisted_context "$sexpr"; then
    case " $hits " in *" unlisted-context "*) : ;; *) hits+="${hits:+ }unlisted-context" ;; esac
  fi

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
  command -v yq >/dev/null 2>&1 || { echo "::error::yq is required but not installed." >&2; return 1; }
  local root="${VIIF_ROOT:-}"
  [ -n "$root" ] || root="$(viif_repo_root)"
  viif_scan "$root"
}

# Run only when executed directly, so tests can source the helpers.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  main "$@"
fi
