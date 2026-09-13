#!/usr/bin/env bats
# Unit + fixture tests for scripts/validate-interaction-model.sh (#1406, epic #1402).
#
# validate-interaction-model.sh is the mechanical enforcement (§10) of the
# agentic interaction model (docs/agentic-interaction-model.md): the three
# trigger classes (§2/§3), the timer contract (§6), the GITHUB_TOKEN
# event-boundary rule + its bridges (§5), and the §4 classification table. It
# also cross-checks the per-role interaction contracts (personas/<id>/
# interaction.yml, interaction-contracts/<name>.yml) against the real on: blocks.
#
# The fixture trees under tests/fixtures/interaction-model/ are minimal, isolated
# stand-ins: a canonical conforming tree (pass/) and one fault-seeded variant per
# violation class. Each fail tree trips exactly its own rule so a green live tree
# never masks a regression.
#
# Run with: bats tests/test_validate_interaction_model.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/validate-interaction-model.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures/interaction-model"
  # shellcheck source=/dev/null
  source "$SCRIPT"
}

# ---------------------------------------------------------------------------
# imv_norm_timer_role / imv_valid_timer_role — §6.1 timer_role normalization
# ---------------------------------------------------------------------------

@test "imv_norm_timer_role treats an em-dash placeholder as absent" {
  run imv_norm_timer_role "—"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "imv_norm_timer_role treats a bare hyphen and N/A as absent" {
  [ -z "$(imv_norm_timer_role '-')" ]
  [ -z "$(imv_norm_timer_role 'N/A')" ]
  [ -z "$(imv_norm_timer_role '   ')" ]
}

@test "imv_norm_timer_role passes through a real role, trimming space" {
  run imv_norm_timer_role "  backstop "
  [ "$status" -eq 0 ]
  [ "$output" = "backstop" ]
}

@test "imv_valid_timer_role accepts the three §6.1 roles" {
  run imv_valid_timer_role "backstop"; [ "$status" -eq 0 ]
  run imv_valid_timer_role "safety-net"; [ "$status" -eq 0 ]
  run imv_valid_timer_role "self-heal"; [ "$status" -eq 0 ]
}

@test "imv_valid_timer_role rejects a driver role and empties" {
  run imv_valid_timer_role "driver"; [ "$status" -ne 0 ]
  run imv_valid_timer_role ""; [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# imv_on_signals / imv_on_has_schedule / imv_on_event_set — §3 discriminator
# ---------------------------------------------------------------------------

@test "imv_on_has_schedule is true for a scheduled workflow" {
  run imv_on_has_schedule "$FIXTURES/pass/.github/workflows/beta.yml"
  [ "$status" -eq 0 ]
}

@test "imv_on_has_schedule is false for an event-only workflow" {
  run imv_on_has_schedule "$FIXTURES/pass/.github/workflows/alpha.yml"
  [ "$status" -eq 1 ]
}

@test "imv_on_event_set lists the webhook events, excluding dispatch/call" {
  run imv_on_event_set "$FIXTURES/pass/.github/workflows/alpha.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'issue_comment\npull_request')" ]
}

@test "imv_on_event_set is empty for a schedule + workflow_dispatch workflow" {
  run imv_on_event_set "$FIXTURES/pass/.github/workflows/beta.yml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "imv_on_crons reads the schedule.cron string" {
  run imv_on_crons "$FIXTURES/pass/.github/workflows/beta.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "17 */2 * * *" ]
}

@test "imv_on_signals emits typed events for block-form repository_dispatch types" {
  tmp="$(mktemp)"
  printf 'on:\n  repository_dispatch:\n    types:\n      - foo\n      - bar\njobs: {}\n' > "$tmp"
  run imv_on_signals "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EVENT repository_dispatch:foo"* ]]
  [[ "$output" == *"EVENT repository_dispatch:bar"* ]]
  [[ "$output" != *"EVENT repository_dispatch"$'\n'* ]]
}

@test "imv_on_signals emits bare EVENT repository_dispatch for an unfiltered trigger" {
  tmp="$(mktemp)"
  printf 'on:\n  repository_dispatch:\npermissions: {}\n' > "$tmp"
  run imv_on_signals "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "EVENT repository_dispatch" ]
}

# ---------------------------------------------------------------------------
# §4 classification-table parsing
# ---------------------------------------------------------------------------

@test "imv_table_rows extracts path/class/timer_role data rows only" {
  run imv_table_rows "$FIXTURES/pass/docs/agentic-interaction-model.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *".github/workflows/alpha.yml	1	—"* ]]
  [[ "$output" == *".github/workflows/beta.yml	2	backstop"* ]]
  # the excluded plumbing row lives in the blockquoted table and must not appear
  [[ "$output" != *"plumbing.yml"* ]]
}

@test "imv_table_exclusions extracts the blockquoted exclusion paths" {
  run imv_table_exclusions "$FIXTURES/pass/docs/agentic-interaction-model.md"
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/plumbing.yml" ]
}

# ---------------------------------------------------------------------------
# ADR-0007 multi-role ingress — the §4 shape now carries one row per role-job
# ---------------------------------------------------------------------------

@test "imv_table_rows parses the ingress role qualifier into a 4th field" {
  run imv_table_rows "$FIXTURES/ingress-pass/docs/agentic-interaction-model.md"
  [ "$status" -eq 0 ]
  # the two ingress rows share the path but carry distinct role qualifiers
  [[ "$output" == *".github/workflows/agent-ingress.yml	1	—	dev-lead"* ]]
  [[ "$output" == *".github/workflows/agent-ingress.yml	1	—	pr-review-mention"* ]]
  # a legacy single-role stub row has an empty (trailing) role field
  [[ "$output" == *".github/workflows/legacy-stub.yml	1	—	"* ]]
}

@test "imv_wf_jobs lists the top-level job names of a workflow" {
  run imv_wf_jobs "$FIXTURES/ingress-pass/.github/workflows/agent-ingress.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'dev-lead\npr-review-mention')" ]
}

# ---------------------------------------------------------------------------
# interaction-contract parsing
# ---------------------------------------------------------------------------

@test "imv_c_events reads the declared triggers.events" {
  run imv_c_events "$FIXTURES/pass/personas/alpha/interaction.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'issue_comment\npull_request')" ]
}

@test "imv_c_field reads a 2-space interaction scalar" {
  run imv_c_field "$FIXTURES/pass/personas/alpha/interaction.yml" concurrency_lane
  [ "$status" -eq 0 ]
  [ "$output" = "alpha-pr-<pr>" ]
}

@test "imv_c_timer_crons reads the declared timer cron" {
  run imv_c_timer_crons "$FIXTURES/pass/interaction-contracts/beta.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "17 */2 * * *" ]
}

# ---------------------------------------------------------------------------
# End-to-end scans over fixture trees — one fault-seeded tree per class (AC 2)
# ---------------------------------------------------------------------------

@test "the conforming fixture tree passes" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/pass" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "AC1a: an in-scope workflow with no §4 row is flagged (FAIL[a])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/fail-a" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[a]"* ]]
  [[ "$output" == *"gamma.yml"* ]]
}

@test "AC1b: a Class-2 row with an invalid timer_role is flagged (FAIL[b])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/fail-b" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[b]"* ]]
  [[ "$output" == *"beta.yml"* ]]
}

@test "AC1c: a contract diverging from its on: block is flagged (FAIL[c])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/fail-c" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[c]"* ]]
}

@test "AC1d: a contract missing an idempotency_key is flagged (FAIL[d])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/fail-d" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[d]"* ]]
  [[ "$output" == *"idempotency_key"* ]]
}

@test "AC1e: an agent→agent bare-event chain crossing the token boundary is flagged (FAIL[e])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/fail-e" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[e]"* ]]
  [[ "$output" == *"boundary"* || "$output" == *"never triggers"* ]]
}

# ---------------------------------------------------------------------------
# AC6: a combined-violation tree reports ALL violations, not just the first
# ---------------------------------------------------------------------------

@test "AC6: a tree with two faults reports both FAIL[b] and FAIL[c]" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/combined" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[b]"* ]]
  [[ "$output" == *"FAIL[c]"* ]]
}

# ---------------------------------------------------------------------------
# AC7: misclassification fixtures in BOTH directions (§3 discriminator vs §4)
# ---------------------------------------------------------------------------

@test "AC7: an event workflow asserted Class 3 is flagged (FAIL[class])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/misclass-1as3" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[class]"* ]]
  [[ "$output" == *"Class 3"* ]]
}

@test "AC7: a schedule-only workflow asserted Class 1 is flagged (FAIL[class])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/misclass-3as1" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[class]"* ]]
  [[ "$output" == *"report.yml"* ]]
}

# ---------------------------------------------------------------------------
# AC8: the §4 table is cross-checked against real on: blocks — a row naming a
# non-existent workflow is a dangling entry
# ---------------------------------------------------------------------------

@test "AC8: a §4 row naming a non-existent workflow is flagged (FAIL[table])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/table-dangling" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[table]"* ]]
  [[ "$output" == *"ghost.yml"* ]]
}

# ---------------------------------------------------------------------------
# stop_marker enforcement (#1745, AC #4/#5) — a declared human-brake must be
# honoured by a serving surface, and every persona must declare the canonical
# needs-human-review brake so a human hold stops the mention surface too.
# ---------------------------------------------------------------------------

@test "imv_c_kind reads the contract kind" {
  run imv_c_kind "$FIXTURES/stop-pass/personas/alpha/interaction.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "persona" ]
}

@test "imv_c_stop_markers reads the declared stop_markers" {
  run imv_c_stop_markers "$FIXTURES/stop-pass/personas/alpha/interaction.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha:hands-off\nneeds-human-review\ndev-lead:needs-human')" ]
}

@test "imv_c_stop_markers yields nothing for an inline empty list" {
  tmp="$(mktemp)"
  printf 'interaction:\n  stop_markers: []\n  budget: none\n' > "$tmp"
  run imv_c_stop_markers "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "imv_c_stop_markers reads a non-empty inline list" {
  tmp="$(mktemp)"
  printf 'interaction:\n  stop_markers: [needs-human-review, "dev-lead:needs-human"]\n  budget: none\n' > "$tmp"
  run imv_c_stop_markers "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'needs-human-review\ndev-lead:needs-human')" ]
}

@test "imv_persona_opt_out reads opt_out_label from persona.yml" {
  run imv_persona_opt_out "$FIXTURES/stop-pass" alpha
  [ "$status" -eq 0 ]
  [ "$output" = "alpha:hands-off" ]
}

@test "imv_escalation_label_from parses a := default assignment" {
  tmp="$(mktemp)"
  printf ': "${NEEDS_HUMAN_REVIEW_LABEL:=needs-human-review}"\n' > "$tmp"
  run imv_escalation_label_from "$tmp" NEEDS_HUMAN_REVIEW_LABEL
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
}

@test "imv_needs_human_review_label derives the brake from pr-automation-budget.sh" {
  run imv_needs_human_review_label
  [ "$status" -eq 0 ]
  [ "$output" = "needs-human-review" ]
}

@test "imv_canonical_escalation_markers derives both markers from the serving scripts" {
  run imv_canonical_escalation_markers
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-human-review"* ]]
  [[ "$output" == *"dev-lead:needs-human"* ]]
}

@test "a persona declaring the brake + honoured markers passes (stop-pass)" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/stop-pass" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# AC5: a multi-role ingress classifies each role-job against the shared on:
# block; completeness passes with N rows (one per role-job) alongside a legacy
# single-role stub (backward-compat).
# ---------------------------------------------------------------------------

@test "AC5: a multi-role ingress tree passes (N rows for N role-jobs + a legacy single-role stub)" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/ingress-pass" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "AC5: a persona omitting needs-human-review is flagged (FAIL[stop])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/stop-missing" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL[stop]"* ]]
  [[ "$output" == *"needs-human-review"* ]]
}

@test "AC5: a persona declaring a marker no serving workflow honours is flagged (FAIL[stop])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/stop-overclaim" bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL[stop]"* ]]
  [[ "$output" == *"bogus:not-a-brake"* ]]
}

@test "AC5: an invalid INTERACTION_MODEL_SCRIPTS_DIR fails closed (FAIL[stop])" {
  # A serving-script dir that cannot yield the canonical markers must not
  # silently disable the required human-brake check — even for a tree that
  # otherwise passes (stop-pass).
  run env INTERACTION_MODEL_ROOT="$FIXTURES/stop-pass" \
    INTERACTION_MODEL_SCRIPTS_DIR="$BATS_TEST_TMPDIR/no-such-scripts-dir" \
    bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL[stop]"* ]]
  [[ "$output" == *"could not derive the canonical escalation markers"* ]]
}

# QA AC #6: backward-compat proven by FAILURE — an ingress with N role-jobs but
# only N-1 rows must FAIL completeness (a completeness rule that cannot fail on
# an under-documented ingress is not a completeness rule).
@test "AC6: an ingress with N role-jobs but N-1 rows fails completeness (FAIL[a])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/ingress-underdoc" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[a]"* ]]
  [[ "$output" == *"pr-review-mention"* ]]
}

# QA AC #6: an ingress row whose asserted Class contradicts the shared on: block
# must FAIL the §3 discriminator check.
@test "AC6: an ingress row whose Class contradicts the shared on: block fails (FAIL[class])" {
  run env INTERACTION_MODEL_ROOT="$FIXTURES/ingress-misclass" bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL[class]"* ]]
  [[ "$output" == *"Class 3"* ]]
}

# ---------------------------------------------------------------------------
# The live repo tree must pass — Stories 1–3 already brought it into conformance
# ---------------------------------------------------------------------------

@test "the current repository tree passes validate-interaction-model" {
  run env INTERACTION_MODEL_ROOT="$REPO_ROOT" bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
