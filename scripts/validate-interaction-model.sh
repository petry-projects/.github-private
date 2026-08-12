#!/usr/bin/env bash
# validate-interaction-model.sh — mechanical enforcement of the agentic
# interaction model (Story 4 / #1406, epic #1402).
#
# docs/agentic-interaction-model.md is a NORMATIVE repo-local standard: it fixes
# the three trigger classes (§2/§3), the timer contract (§6), the GITHUB_TOKEN
# event-boundary rule + its sanctioned bridges (§5), and a machine-checkable §4
# classification table. Story 2 (#1404) turned each role's interaction pattern
# into a machine-readable contract (personas/<id>/interaction.yml and
# interaction-contracts/<name>.yml). This script makes the standard and the
# contracts CI-enforced (§10) rather than review-enforced, so drift and unsafe
# additions are caught at PR time instead of surfacing as runaways.
#
# It is PURE / HERMETIC (reads in-repo files only, no network, no gh, no schema
# fetch), mirroring scripts/validate-workflow-schedules.sh and
# scripts/caller_stub_freeze.sh, so it runs in CI without credentials. Every scan
# helper is sourceable and unit-testable; main is thin I/O.
#
# It reports EVERY violation it finds (it never short-circuits on the first) so a
# single workflow tripping several rules surfaces all of them.
#
# Violation classes (tagged in output for grep-ability):
#   FAIL[a]     — an in-scope workflow has no §4 classification row (or a duplicate
#                 row). Adding a new agentic role without declaring it fails here.
#   FAIL[b]     — a Class-2 (scheduled interaction-family) row carries no valid
#                 timer_role (empty, `driver`, or anything outside
#                 backstop|safety-net|self-heal).
#   FAIL[c]     — a role's interaction contract diverges from its workflow's real
#                 on: block (declared events/timers != actual events/schedules).
#   FAIL[d]     — an interaction contract lacks an idempotency_key or a
#                 concurrency_lane.
#   FAIL[e]     — an agent->agent chain crosses the GITHUB_TOKEN boundary via a
#                 suppressed event without a declared repository_dispatch bridge.
#   FAIL[class] — a §4 row's asserted Class contradicts the workflow's real on:
#                 block via the §3 discriminator (both misclassification
#                 directions).
#   FAIL[table] — a §4 row names a workflow that does not exist on disk.
#
# Usage: validate-interaction-model.sh
#   INTERACTION_MODEL_ROOT — repo root to scan (default: the repo containing this
#                            script). Overridden by tests to point at fixture trees.

set -euo pipefail

VALID_TIMER_ROLES=" backstop safety-net self-heal "

# ── §3 discriminator primitives ──────────────────────────────────────────────

# imv_norm_timer_role <value> — echo the normalized timer_role: empty for an
# absent role (`—`, en-dash, `-`, `N/A`, whitespace), the trimmed value otherwise.
imv_norm_timer_role() {
  local v
  v="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  case "$v" in
    ""|"—"|"–"|"-"|"N/A"|"n/a"|"NA"|"na") printf '' ;;
    *) printf '%s' "$v" ;;
  esac
}

# imv_valid_timer_role <value> — return 0 iff <value> is one of the §6.1 roles.
imv_valid_timer_role() {
  case "$VALID_TIMER_ROLES" in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

# ── on: block parsing (S / E signals) ────────────────────────────────────────

# imv_on_signals <file> — emit one line per top-level on: trigger:
#   SCHEDULE                              (a schedule.cron trigger is present)
#   EVENT <name>                          (a webhook event that represents work;
#                                          repository_dispatch is expanded to
#                                          EVENT repository_dispatch:<type>)
# workflow_dispatch and workflow_call are neither S nor E (a manual escape hatch
# and a reusable entrypoint — §3). Pure: reads the file, writes stdout.
imv_on_signals() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    BEGIN { inon=0; topkey="" }
    # inline array form: on: [push, pull_request]
    /^on:[[:space:]]*\[/ {
      s=$0; sub(/^on:[[:space:]]*\[/,"",s); sub(/\].*/,"",s);
      n=split(s,a,",");
      for (i=1;i<=n;i++) { gsub(/[[:space:]"\\047]/,"",a[i]);
        if (a[i]=="schedule") print "SCHEDULE";
        else if (a[i]!="" && a[i]!="workflow_dispatch" && a[i]!="workflow_call") print "EVENT " a[i] }
      next
    }
    # inline scalar form: on: push
    /^on:[[:space:]]*[A-Za-z_]/ {
      s=$0; sub(/^on:[[:space:]]*/,"",s); sub(/[[:space:]#].*/,"",s);
      if (s=="schedule") print "SCHEDULE";
      else if (s!="" && s!="workflow_dispatch" && s!="workflow_call") print "EVENT " s;
      next
    }
    # block form
    /^on:/ { inon=1; next }
    inon && /^[A-Za-z_]/ { inon=0 }
    inon {
      if ($0 ~ /^  [A-Za-z_]+:/) {
        key=$0; sub(/^  /,"",key); sub(/:.*/,"",key);
        topkey=key;
        if (key=="schedule") print "SCHEDULE";
        else if (key=="workflow_dispatch" || key=="workflow_call" || key=="repository_dispatch") { }
        else print "EVENT " key;
        next
      }
      if (topkey=="repository_dispatch" && $0 ~ /types:[[:space:]]*\[/) {
        s=$0; sub(/.*\[/,"",s); sub(/\].*/,"",s);
        n=split(s,a,",");
        for (i=1;i<=n;i++) { gsub(/[[:space:]"\\047]/,"",a[i]); if (a[i]!="") print "EVENT repository_dispatch:" a[i] }
        next
      }
    }
  ' "$file"
}

# imv_on_has_schedule <file> — return 0 iff the on: block declares a schedule.
imv_on_has_schedule() {
  imv_on_signals "$1" | grep -q '^SCHEDULE$'
}

# imv_on_event_set <file> — print the sorted, unique set of webhook event tokens.
imv_on_event_set() {
  imv_on_signals "$1" | sed -n 's/^EVENT //p' | sort -u
}

# imv_on_crons <file> — print each schedule.cron string in the on: block (quotes
# and trailing comments stripped). Pure.
imv_on_crons() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  awk '
    /^on:/ { inon=1 }
    inon && /^[A-Za-z_]/ && !/^on:/ { inon=0 }
    inon && /^  schedule:/ { insch=1; next }
    insch && /^  [A-Za-z_]/ { insch=0 }
    insch && /cron:/ {
      s=$0; sub(/.*cron:[[:space:]]*/,"",s);
      sub(/#.*/,"",s); gsub(/[\047"]/,"",s);
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",s);
      if (s!="") print s
    }
  ' "$file"
}

# ── §4 classification table parsing ──────────────────────────────────────────

# imv_table_rows <md> — print `path<TAB>class<TAB>timer_role` for each §4 data row
# (a table row whose first cell is a `.github/workflows/...` path). The header,
# separator, and the blockquoted exclusion table are ignored. Pure.
imv_table_rows() {
  local md="${1:-}"
  [ -n "$md" ] && [ -f "$md" ] || return 0
  awk -F'|' '
    $0 ~ "^\\|[[:space:]]*`\\.github/workflows/" {
      path=$2; gsub(/[[:space:]`]/,"",path);
      cls=$3;  gsub(/[[:space:]]/,"",cls);
      tr=$4;   gsub(/^[[:space:]]+|[[:space:]]+$/,"",tr);
      print path "\t" cls "\t" tr
    }
  ' "$md"
}

# imv_table_exclusions <md> — print each `.github/workflows/...` path listed in
# the §4 blockquoted exclusion table. Pure.
imv_table_exclusions() {
  local md="${1:-}"
  [ -n "$md" ] && [ -f "$md" ] || return 0
  awk '
    $0 ~ "^>[[:space:]]*\\|[[:space:]]*`\\.github/workflows/" {
      s=$0; sub(/^[^`]*`/,"",s); sub(/`.*/,"",s); print s
    }
  ' "$md"
}

# ── interaction-contract parsing ─────────────────────────────────────────────

# imv_contract_files <root> — print every interaction contract path under <root>.
imv_contract_files() {
  local root="${1:-}"
  { find "$root/personas" -maxdepth 2 -type f -name 'interaction.yml' 2>/dev/null
    find "$root/interaction-contracts" -maxdepth 1 -type f -name '*.yml' 2>/dev/null
  } | sort
}

# imv_c_role <file> — the contract's top-level role value.
imv_c_role() {
  awk '/^role:/ { sub(/^role:[[:space:]]*/,""); gsub(/[\047"]/,""); print; exit }' "$1"
}

# imv_c_workflows <file> — the contract's declared workflow paths, one per line.
imv_c_workflows() {
  awk '
    /^workflows:/ { f=1; next }
    f && /^  - / { v=$0; sub(/^  - /,"",v); gsub(/[\047"]/,"",v); gsub(/[[:space:]]+$/,"",v); print v; next }
    f && /^[A-Za-z_]/ { f=0 }
  ' "$1"
}

# imv_c_events <file> — the contract's declared triggers.events, one per line.
imv_c_events() {
  awk '
    /^    events:/ { f=1; next }
    f && /^      - / { v=$0; sub(/^      - /,"",v); gsub(/[\047"]/,"",v); gsub(/[[:space:]]+$/,"",v); print v; next }
    f && /^    [A-Za-z]/ { f=0 }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_timer_crons <file> — the cron string of each declared timer.
imv_c_timer_crons() {
  awk '
    /^    timers:/ { f=1; next }
    f && /cron:/ { v=$0; sub(/.*cron:[[:space:]]*/,"",v); sub(/#.*/,"",v); gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); if (v!="") print v }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_emits <file> — the contract's declared emits, one per line.
imv_c_emits() {
  awk '
    /^  emits:/ { f=1; next }
    f && /^    - / { v=$0; sub(/^    - /,"",v); gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; next }
    f && /^  [A-Za-z]/ { f=0 }
    f && /^[A-Za-z]/ { f=0 }
  ' "$1"
}

# imv_c_field <file> <key> — the trimmed (quote-stripped) value of a 2-space
# indented interaction.<key> scalar (e.g. idempotency_key, concurrency_lane).
imv_c_field() {
  awk -v k="$2" '
    $0 ~ "^  " k ":" {
      v=$0; sub("^  " k ":[[:space:]]*","",v);
      gsub(/[\047"]/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);
      print v; exit
    }
  ' "$1"
}

# ── detectors (each prints tagged FAIL lines; none aborts on first finding) ───

# imv_v_completeness <root> <md> — FAIL[a] for every in-scope workflow that has no
# §4 row (bidirectional completeness, §10). An in-scope workflow is a
# .github/workflows/*.yml not on the §4 exclusion list.
imv_v_completeness() {
  local root="$1" md="$2" f rel
  local rows exclusions
  rows="$(imv_table_rows "$md" | cut -f1)"
  exclusions="$(imv_table_exclusions "$md")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root/"}"
    if printf '%s\n' "$exclusions" | grep -qxF "$rel"; then continue; fi
    if ! printf '%s\n' "$rows" | grep -qxF "$rel"; then
      printf 'FAIL[a]: %s is an in-scope workflow with no §4 classification row (declare it in docs/agentic-interaction-model.md §4, or add it to the exclusion list).\n' "$rel"
    fi
  done < <(find "$root/.github/workflows" -maxdepth 1 -type f -name '*.yml' 2>/dev/null | sort)
}

# imv_v_timer_roles <md> — FAIL[b] for every Class-2 row lacking a valid timer_role.
imv_v_timer_roles() {
  local md="$1" path cls tr trn
  while IFS=$'\t' read -r path cls tr; do
    [ -n "$path" ] || continue
    [ "$cls" = "2" ] || continue
    trn="$(imv_norm_timer_role "$tr")"
    if [ -z "$trn" ] || ! imv_valid_timer_role "$trn"; then
      printf 'FAIL[b]: %s is Class 2 (a scheduled interaction-family timer) but its timer_role is %s — a Class-2 backstop must declare one of backstop|safety-net|self-heal (§6.1).\n' \
        "$path" "${trn:-<none>}"
    fi
  done < <(imv_table_rows "$md")
}

# imv_v_class <root> <md> — FAIL[table] for a row naming a missing workflow, and
# FAIL[class] when a row's asserted Class contradicts the workflow's real on:
# block via the §3 discriminator.
imv_v_class() {
  local root="$1" md="$2" path cls tr trn wf S
  while IFS=$'\t' read -r path cls tr; do
    [ -n "$path" ] || continue
    wf="$root/$path"
    if [ ! -f "$wf" ]; then
      printf 'FAIL[table]: §4 row names %s, which does not exist on disk — remove the stale row (§10).\n' "$path"
      continue
    fi
    trn="$(imv_norm_timer_role "$tr")"
    if imv_on_has_schedule "$wf"; then S=1; else S=0; fi
    case "$cls" in
      1)
        if [ "$S" = "1" ]; then
          printf 'FAIL[class]: %s is asserted Class 1 but its on: block has a schedule — a Class-1 event reaction must not carry a cron (§2/§3).\n' "$path"
        fi
        if [ -n "$trn" ]; then
          printf 'FAIL[class]: %s is asserted Class 1 but declares timer_role %s — Class 1 carries no timer_role (§3).\n' "$path" "$trn"
        fi
        ;;
      2)
        if [ "$S" = "0" ]; then
          printf 'FAIL[class]: %s is asserted Class 2 but its on: block has no schedule — a Class-2 backstop is defined by its reconciliation timer (§2/§3).\n' "$path"
        fi
        ;;
      3)
        if [ "$S" = "0" ]; then
          printf 'FAIL[class]: %s is asserted Class 3 but its on: block has no schedule — a Class-3 origin is the cadence (§2/§3).\n' "$path"
        fi
        if [ -n "$trn" ]; then
          printf 'FAIL[class]: %s is asserted Class 3 but declares timer_role %s — a Class-3 report/canary carries no timer_role (§6.1).\n' "$path" "$trn"
        fi
        ;;
      *)
        printf 'FAIL[class]: %s has an unrecognized Class %s — must be 1, 2, or 3 (§2).\n' "$path" "${cls:-<none>}"
        ;;
    esac
  done < <(imv_table_rows "$md")
}

# imv_v_contracts <root> — FAIL[c] when a contract's declared triggers diverge
# from the union of its workflows' real on: blocks; FAIL[d] when a contract lacks
# an idempotency_key or a concurrency_lane.
imv_v_contracts() {
  local root="$1" c rel wf actual_events actual_crons decl_events decl_crons
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    rel="${c#"$root/"}"

    actual_events=""; actual_crons=""
    while IFS= read -r wf; do
      [ -n "$wf" ] || continue
      actual_events+="$(imv_on_event_set "$root/$wf")"$'\n'
      actual_crons+="$(imv_on_crons "$root/$wf")"$'\n'
    done < <(imv_c_workflows "$c")

    actual_events="$(printf '%s' "$actual_events" | grep -v '^$' | sort -u || true)"
    actual_crons="$(printf '%s' "$actual_crons" | grep -v '^$' | sort -u || true)"
    decl_events="$(imv_c_events "$c" | grep -v '^$' | sort -u || true)"
    decl_crons="$(imv_c_timer_crons "$c" | grep -v '^$' | sort -u || true)"

    if [ "$decl_events" != "$actual_events" ]; then
      printf 'FAIL[c]: %s declares triggers.events {%s} but its workflows subscribe to {%s} — the contract must mirror the real on: block (§8.1/§10).\n' \
        "$rel" "$(printf '%s' "$decl_events" | paste -sd, -)" "$(printf '%s' "$actual_events" | paste -sd, -)"
    fi
    if [ "$decl_crons" != "$actual_crons" ]; then
      printf 'FAIL[c]: %s declares timer crons {%s} but its workflows schedule {%s} — the contract must mirror the real on: block (§8.1/§10).\n' \
        "$rel" "$(printf '%s' "$decl_crons" | paste -sd, -)" "$(printf '%s' "$actual_crons" | paste -sd, -)"
    fi

    if [ -z "$(imv_c_field "$c" idempotency_key)" ]; then
      printf 'FAIL[d]: %s declares no idempotency_key — an interaction driver must state what makes a re-run a no-op (§8.1).\n' "$rel"
    fi
    if [ -z "$(imv_c_field "$c" concurrency_lane)" ]; then
      printf 'FAIL[d]: %s declares no concurrency_lane — an interaction driver must state its serialization lane (§8.1).\n' "$rel"
    fi
  done < <(imv_contract_files "$root")
}

# imv_v_boundary <root> — FAIL[e] when one role emits a bare (suppressed) webhook
# event that a DIFFERENT role subscribes to, with no repository_dispatch bridge.
# GITHUB_TOKEN-authored suppressed events (push, …) never trigger a downstream
# workflow (§5); such a chain must cross the boundary via a sanctioned bridge.
imv_v_boundary() {
  local root="$1" c role ev emit sub_role sub_ev subs=""
  # Collect `role<TAB>bare-event` subscription pairs across all contracts.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    role="$(imv_c_role "$c")"
    while IFS= read -r ev; do
      case "$ev" in ""|*:*) continue ;; esac   # skip empties and prefixed (bridge) events
      subs+="${role}"$'\t'"${ev}"$'\n'
    done < <(imv_c_events "$c")
  done < <(imv_contract_files "$root")

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    role="$(imv_c_role "$c")"
    while IFS= read -r emit; do
      case "$emit" in ""|*:*) continue ;; esac  # only bare emits (commit, push) can be a raw event
      while IFS=$'\t' read -r sub_role sub_ev; do
        [ -n "$sub_role" ] || continue
        [ -n "$sub_ev" ] || continue
        [ "$sub_ev" = "$emit" ] || continue
        [ "$sub_role" != "$role" ] || continue
        printf 'FAIL[e]: role %s emits the suppressed event %q that role %s subscribes to, with no repository_dispatch bridge — a GITHUB_TOKEN-authored %s never triggers a downstream workflow (§5).\n' \
          "$role" "$emit" "$sub_role" "$emit"
      done <<< "$subs"
    done < <(imv_c_emits "$c")
  done < <(imv_contract_files "$root")
}

# ── main ─────────────────────────────────────────────────────────────────────

imv_repo_root() {
  if [ -n "${INTERACTION_MODEL_ROOT:-}" ]; then
    printf '%s' "$INTERACTION_MODEL_ROOT"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

main() {
  local root md violations
  root="$(imv_repo_root)"
  md="$root/docs/agentic-interaction-model.md"

  if [ ! -f "$md" ]; then
    echo "::error::validate-interaction-model: standard not found at $md" >&2
    return 1
  fi

  violations="$(
    imv_v_completeness "$root" "$md"
    imv_v_timer_roles "$md"
    imv_v_class "$root" "$md"
    imv_v_contracts "$root"
    imv_v_boundary "$root"
  )"

  if [ -n "$violations" ]; then
    echo "" >&2
    echo "validate-interaction-model: FAIL — the agentic interaction model (docs/agentic-interaction-model.md) is violated:" >&2
    printf '%s\n' "$violations" >&2
    echo "" >&2
    echo "See docs/adding-an-agentic-role.md for the conforming shape." >&2
    return 1
  fi

  echo "validate-interaction-model: OK — §4 table, on: blocks, and interaction contracts all agree."
  return 0
}

# Only run main when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
