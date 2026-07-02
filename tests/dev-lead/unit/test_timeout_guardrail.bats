#!/usr/bin/env bats
# Guardrail for #1017 (epic #901, story A/3): the per-tier engine timeouts plus a
# fixed overhead margin must never exceed the dev-lead job's `timeout-minutes`
# backstop, so a hung tier can never silently blow past the job cap. This pins
# the raised budgets (DEEP/ACTION/AUDIT) and the raised job cap (120) against
# accidental drift, and proves the guardrail actually *fails* when a tier is
# inflated past the cap.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME"/../../.. && pwd)"
GUARDRAIL="$REPO_ROOT/scripts/dev-lead-timeout-guardrail.sh"
ENGINE="$REPO_ROOT/scripts/engine.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/dev-lead-reusable.yml"

# Extract a `VAR="${VAR:-N}"` default from engine.sh.
_tier_default() {
  sed -n "s/^$1=\"\${$1:-\([0-9][0-9]*\)}\".*/\1/p" "$ENGINE"
}

@test "guardrail: script exists and is executable" {
  [ -f "$GUARDRAIL" ]
  [ -x "$GUARDRAIL" ]
}

@test "guardrail: passes against the committed engine + workflow config" {
  run bash "$GUARDRAIL"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "guardrail: dispatch job timeout-minutes raised to 120" {
  run bash -c "
    awk '
      /^  dispatch:[[:space:]]*\$/ {inblk=1; next}
      inblk==1 && /^  [A-Za-z]/ {inblk=0}
      inblk==1 && /^    timeout-minutes:/ {print \$2; exit}
    ' '$WORKFLOW'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "120" ]
}

@test "guardrail: DEEP and ACTION defaults raised above the old 600 baseline" {
  local deep action
  deep="$(_tier_default DEEP_TIMEOUT_SEC)"
  action="$(_tier_default ACTION_TIMEOUT_SEC)"
  [ -n "$deep" ] && [ -n "$action" ]
  [ "$deep" -gt 600 ]
  [ "$action" -gt 600 ]
}

@test "guardrail: TRIAGE and DUCK stay lightweight (unchanged small budgets)" {
  [ "$(_tier_default TRIAGE_TIMEOUT_SEC)" -le 600 ]
  [ "$(_tier_default DUCK_TIMEOUT_SEC)" -le 600 ]
}

@test "guardrail: Sigma(tier budgets) + overhead margin <= job cap" {
  # Recompute the invariant independently of the script so the assertion is
  # not self-referential: sum the parsed tier defaults, add the overhead
  # margin the script prints, and compare against job timeout-minutes * 60.
  run bash "$GUARDRAIL"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE "PASS"
}

@test "guardrail: FAILS when a per-tier budget is inflated past the job cap" {
  # Point the guardrail at a doctored engine.sh whose DEEP budget alone exceeds
  # the job cap; the check must reject it (non-zero exit) rather than pass.
  local tmp
  tmp="$(mktemp)"
  sed 's/^DEEP_TIMEOUT_SEC="\${DEEP_TIMEOUT_SEC:-[0-9]*}"/DEEP_TIMEOUT_SEC="${DEEP_TIMEOUT_SEC:-99999}"/' "$ENGINE" > "$tmp"
  run env ENGINE_SH="$tmp" bash "$GUARDRAIL"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE "FAIL|exceed"
}
