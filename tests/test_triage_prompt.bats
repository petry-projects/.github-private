#!/usr/bin/env bats
# Structural guard for the triage skill prompt (prompts/triage.md), #896.
#
# The held-out eval regressed to 2/5 because the model systematically under-rated
# `risk` by one band: prompts/triage.md defined WHEN to escalate (criteria 1-7)
# but the `risk` field appeared ONLY in the output schema with no rubric, so the
# model guessed — and guessed low. The fix adds one additive `## Risk rating`
# section anchored to the existing escalate criteria.
#
# These checks are deterministic and offline (the live 5/5 held-out confirmation
# needs the real Haiku-tier model). They guard against the rubric section being
# silently removed or hollowed out by a future edit/template sync — the same
# silent-revert regression class the repo defends against elsewhere (#655, #823).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROMPT="$ROOT/prompts/triage.md"
}

@test "triage prompt has a Risk rating section" {
  grep -Eq '^##[[:space:]]+Risk rating' "$PROMPT"
}

# Extract the body of the Risk rating section (from its heading up to the next
# `## ` heading) so band assertions cannot accidentally match text elsewhere in
# the prompt (e.g. the LOW|MEDIUM|HIGH token in the output schema).
_risk_section() {
  awk '
    /^##[[:space:]]+Risk rating/ { insec=1; next }
    insec && /^##[[:space:]]/    { insec=0 }
    insec                        { print }
  ' "$PROMPT"
}

@test "Risk rating section defines all three bands (HIGH, MEDIUM, LOW)" {
  section="$(_risk_section)"
  grep -q 'HIGH'   <<<"$section"
  grep -q 'MEDIUM' <<<"$section"
  grep -q 'LOW'    <<<"$section"
}

@test "HIGH band is anchored to criterion-1 high-risk areas or criterion-3 anti-patterns" {
  section="$(_risk_section)"
  # The defining property of HIGH per the case data: a high-risk area (criterion
  # 1) is touched OR a security anti-pattern (criterion 3) is present.
  grep -Eiq 'high-risk' <<<"$section"
  grep -Eiq 'anti-pattern' <<<"$section"
}

@test "MEDIUM band covers process-driven escalation AND clean non-trivial changes" {
  section="$(_risk_section)"
  # MEDIUM must capture BOTH the escalate:true-but-not-dangerous case
  # (unresolved-thread) and the escalate:false clean-logic-fix case — otherwise
  # the model collapses one of them to HIGH or LOW.
  grep -Eiq 'process|unresolved|advisory|incomplete context' <<<"$section"
  grep -Eiq 'clean|non-trivial|logic' <<<"$section"
}

@test "LOW band is restricted to trivial / docs / test-only changes" {
  section="$(_risk_section)"
  grep -Eiq 'trivial' <<<"$section"
  grep -Eiq 'docs|comment|formatting|test-only' <<<"$section"
}

@test "the escalate criteria (1-7) remain intact alongside the new section" {
  # The escalate behavior is already correct and must stay untouched — guard that
  # the Decision criteria section and its escalate switch still exist.
  grep -q '## Decision criteria' "$PROMPT"
  grep -q '"escalate": true' "$PROMPT"
}
