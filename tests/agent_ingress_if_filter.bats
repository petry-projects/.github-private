#!/usr/bin/env bats
# Tests for the frozen if:-as-event-filter boundary rulings (issue #1724 AC #2, #6;
# ADR-0007). The ambiguous if: cases are DECIDED here — as named, machine-readable
# fixtures Story #1725's two guards consume DIRECTLY (not as prose) — so the two
# guards cannot disagree. Each row rules one construct ALLOW (a pure event
# predicate) or FORBID (a reach for repo state).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RULINGS="$SCRIPT_DIR/tests/fixtures/agent-ingress/if-filter-rulings.tsv"

# _field <name> <col> — echo column <col> (name|verdict|expression|rationale) of
# the data row whose name is <name>, ignoring comment/blank lines.
_field() {
  awk -F'\t' -v n="$1" -v cname="$2" '
    BEGIN { split("name verdict expression rationale", names, " ")
            for (i in names) col[names[i]] = i }
    /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
    $1 == n { print $(col[cname]); found=1; exit }
    END { if (!found) exit 3 }' "$RULINGS"
}

@test "rulings: the named-fixture manifest exists" {
  [ -f "$RULINGS" ]
}

@test "rulings: every data row is 4 tab-separated fields with a valid verdict" {
  run awk -F'\t' '
    /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
    { if (NF != 4) { print "bad-arity:" $0; bad=1 }
      if ($2 != "ALLOW" && $2 != "FORBID") { print "bad-verdict:" $0; bad=1 } }
    END { exit bad }' "$RULINGS"
  [ "$status" -eq 0 ]
}

# ── AC #6: the enumerated FORBIDDEN cases are each present and ruled FORBID ─────
@test "rulings: vars.* is FORBIDDEN (org/repo configuration state)" {
  [ "$(_field vars verdict)" = "FORBID" ]
  [[ "$(_field vars expression)" == *"vars."* ]]
}

@test "rulings: secrets.* is FORBIDDEN (not event data)" {
  [ "$(_field secrets verdict)" = "FORBID" ]
  [[ "$(_field secrets expression)" == *"secrets."* ]]
}

@test "rulings: needs.*.outputs.* is FORBIDDEN (another job's computed state)" {
  [ "$(_field needs-outputs verdict)" = "FORBID" ]
  [[ "$(_field needs-outputs expression)" == *".outputs."* ]]
}

@test "rulings: hashFiles(...) is FORBIDDEN (reads the repo tree)" {
  [ "$(_field hashfiles verdict)" = "FORBID" ]
  [[ "$(_field hashfiles expression)" == *"hashFiles("* ]]
}

@test "rulings: github.repository == ... is FORBIDDEN (repo identity, not event predicate)" {
  [ "$(_field repo-identity verdict)" = "FORBID" ]
  [[ "$(_field repo-identity expression)" == *"github.repository"* ]]
}

@test "rulings: github.event.repository.default_branch is FORBIDDEN (repo config in payload)" {
  [ "$(_field default-branch verdict)" = "FORBID" ]
  [[ "$(_field default-branch expression)" == *"default_branch"* ]]
}

# ── AC #6: the genuinely contested case is DECIDED here, ruled FORBID ───────────
@test "rulings: contains(github.event.pull_request.labels.*.name, ...) is FORBIDDEN (human-mutated repo-state snapshot in payload)" {
  [ "$(_field labels-array-contains verdict)" = "FORBID" ]
  [[ "$(_field labels-array-contains expression)" == *"github.event.pull_request.labels"* ]]
}

# ── The allowed pure-event predicates (including the contrasting alternatives) ──
@test "rulings: github.event_name is ALLOWED" {
  [ "$(_field event-name verdict)" = "ALLOW" ]
  [[ "$(_field event-name expression)" == *"github.event_name"* ]]
}

@test "rulings: github.event.action is ALLOWED" {
  [ "$(_field event-action verdict)" = "ALLOW" ]
  [[ "$(_field event-action expression)" == *"github.event.action"* ]]
}

@test "rulings: github.event.label.name is ALLOWED (the triggering delta, contrast to the labels array)" {
  [ "$(_field label-name verdict)" = "ALLOW" ]
  [[ "$(_field label-name expression)" == *"github.event.label.name"* ]]
}

@test "rulings: github.event.pull_request.base.ref is ALLOWED (payload predicate, contrast to default_branch)" {
  [ "$(_field base-ref verdict)" = "ALLOW" ]
  [[ "$(_field base-ref expression)" == *"base.ref"* ]]
}

@test "rulings: no FORBID row's construct leaks into any ALLOW expression" {
  # A cross-check that the allow-list stays clean: no allowed expression may
  # reference a forbidden construct token.
  run awk -F'\t' '
    /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
    $2 == "ALLOW" {
      if ($3 ~ /vars\.|secrets\.|\.outputs\.|hashFiles\(|github\.repository|default_branch|labels\.\*\.name/) {
        print "leaked:" $0; bad=1 }
    }
    END { exit bad }' "$RULINGS"
  [ "$status" -eq 0 ]
}
