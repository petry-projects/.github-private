# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating resilience testing plan completeness and generating implementation sequence
- ✅ VALIDATE all critical services have steady-state hypotheses and experiments
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ✅ Run comprehensive validation checks on the complete resilience testing plan
- ⚠️ Present C/R menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: complete` before finishing
- 🚫 FORBIDDEN to finalize until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the validation results and finalize the resilience testing plan
- **R (Revise)**: Discuss changes, address gaps, then re-present the menu

## CONTEXT BOUNDARIES:

- Complete resilience testing plan document with all sections is available
- All steady-state hypotheses, failure scenarios, and game day plans are defined
- Focus on validation, gap analysis, and generating implementation sequence
- This is the final step — ensure the plan is actionable

## YOUR TASK:

Validate the complete resilience testing plan for coverage, coherence, and actionability. Generate a prioritized implementation sequence and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate systematically:

**Gate 1: Steady-State Coverage**
- [ ] Every critical service has measurable health indicators
- [ ] SLOs referenced where available from observability plan
- [ ] Monitoring queries defined for each steady-state indicator
- [ ] Acceptable variance ranges documented
- [ ] Critical user journeys mapped to baseline metrics

**Gate 2: Failure Scenario Completeness**
- [ ] All infrastructure layers covered (compute, network, storage, dependencies, cloud provider)
- [ ] Blast radius controls defined for every experiment
- [ ] Abort criteria documented for every experiment
- [ ] Each failure mode has expected impact on steady-state indicators
- [ ] Recovery mechanisms defined (auto-heal, manual, rollback)

**Gate 3: Experiment Design Quality**
- [ ] Each experiment has a clear hypothesis
- [ ] Each experiment has a defined injection method
- [ ] Each experiment has an expected outcome
- [ ] Each experiment has verification criteria
- [ ] Experiments are prioritized by risk and learning value

**Gate 4: Game Day Readiness**
- [ ] Roles defined with responsibilities and required skills
- [ ] Communication plan documented for pre/during/post exercise
- [ ] Scheduling cadence established
- [ ] Progressive complexity planned (tabletop to production)
- [ ] Abort authority designated for every exercise type

**Gate 5: Cross-Workflow Alignment**
- [ ] If Observability Plan exists: steady-state indicators reference observability metrics
- [ ] If Incident Response Plan exists: failure scenarios reference severity levels and runbooks
- [ ] If Infrastructure Plan exists: failure modes cover all infrastructure layers in the plan
- [ ] If Pipeline Plan exists: deployment failures included as failure scenarios

### Maturity-Level Gate Calibration

Read `{bgr_maturity}` from config. Apply the following gate classification when evaluating quality gates:

**Required at ALL maturity levels (greenfield+):**
- Steady-state hypotheses for critical services
- Basic failure scenarios for compute and network
- Tabletop exercise plan
- Abort criteria for all experiments

**Required at growing+ maturity:**
- Full infrastructure layer coverage
- Live experiment designs with blast radius controls
- Game day roles and communication plan
- Progressive complexity path

**Required at established+ maturity:**
- Cross-workflow alignment with observability and incident response
- Production experiment readiness criteria
- Dependency failure chain mapping
- Scheduled game day cadence

**Required at advanced maturity:**
- Multi-region failure scenarios
- Automated chaos experiment execution
- Continuous resilience validation in CI/CD
- Cross-team game day coordination

**Guidance:**
- Gates below the team's maturity level are REQUIRED — flag failures as blocking
- Gates at the team's maturity level are RECOMMENDED — flag failures as warnings with improvement path
- Gates above the team's maturity level are INFORMATIONAL — mention as future growth areas but do not block

### 2. Cross-Workflow Coherence Checks

Run specific coherence checks against other workflow artifacts:

**If Observability Plan exists:**
- Do steady-state indicators reference the metrics defined in the observability plan?
- Are SLO targets used as thresholds for steady-state hypotheses?
- Do abort criteria reference alerting thresholds from the observability plan?

**If Incident Response Plan exists:**
- Do failure scenarios reference the severity classification system?
- Are game day exercises designed to test incident response runbooks?
- Does the communication plan align with incident communication procedures?

**If Infrastructure Plan exists:**
- Do failure modes cover all infrastructure layers described in the plan?
- Are environment-specific experiments designed for each environment tier?
- Do blast radius controls account for the infrastructure topology?

**If Pipeline Plan exists:**
- Are deployment failures included as failure scenarios?
- Do experiments test rollback mechanisms defined in the pipeline plan?
- Is canary analysis validation included in experiment designs?

### 3. Present Validation Summary

Report the validation results to the user:

"Here's the validation summary for the {{project_name}} Resilience Testing Plan.

**Quality Gate Results:**

| Gate | Status | Notes |
|------|--------|-------|
| Steady-State Coverage | {PASS/FAIL} | {details} |
| Failure Scenario Completeness | {PASS/FAIL} | {details} |
| Experiment Design Quality | {PASS/FAIL} | {details} |
| Game Day Readiness | {PASS/FAIL} | {details} |
| Cross-Workflow Alignment | {PASS/FAIL} | {details} |

{if_any_failures}
**Issues to Address:**
{list of failed gates with specific gaps}

Would you like to address these before finalizing?
{/if_any_failures}

{if_all_pass}
All quality gates passed. The resilience testing plan is comprehensive and ready for implementation.
{/if_all_pass}"

### 4. Address Validation Issues

If any quality gates failed:

- Present the specific gaps clearly
- Collaborate with the user to resolve each gap
- Update the relevant document sections
- Re-run the failed quality gates to confirm resolution

### 5. Generate Implementation Sequence

Create a prioritized implementation sequence:

**Phase 1 — Foundation (implement first):**
- Finalize steady-state monitoring queries and dashboards
- Set up chaos engineering tooling (e.g., Chaos Monkey, Litmus, Gremlin)
- Conduct initial tabletop exercises for all high-priority scenarios
- Establish game day roles and communication channels

**Phase 2 — Staging Experiments (implement second):**
- Execute single-service experiments in staging
- Validate abort criteria and runback procedures
- Refine steady-state hypotheses based on experiment results
- Train team on chaos engineering tools and procedures

**Phase 3 — Production Readiness (implement third):**
- Graduate validated experiments to production
- Conduct first production game day with full team
- Establish regular game day cadence
- Integrate experiment results into incident response improvements

**Phase 4 — Maturity (implement ongoing):**
- Automate recurring chaos experiments
- Integrate resilience validation into CI/CD pipeline
- Expand to multi-region and cross-team game days
- Establish quarterly resilience review cadence

### 6. Generate Validation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

| Gate | Status | Notes |
|------|--------|-------|
{{quality_gate_results}}

### Resilience Testing Completeness Checklist

**✅ Steady-State Hypotheses**

- [x] Health indicators defined for all critical services
- [x] Monitoring queries specified for each indicator
- [x] Acceptable variance ranges documented
- [x] Critical user journeys mapped to baselines

**✅ Failure Scenarios**

- [x] All infrastructure layers covered
- [x] Blast radius controls for every experiment
- [x] Abort criteria for every experiment
- [x] Dependency failure chains mapped

**✅ Experiment Designs**

- [x] Clear hypothesis for each experiment
- [x] Injection method and expected outcome defined
- [x] Prioritized by risk and learning value

**✅ Game Day Planning**

- [x] Exercise types defined with progressive complexity
- [x] Roles and responsibilities documented
- [x] Communication plan for all phases
- [x] Scheduling cadence established

**✅ Cross-Workflow Alignment**

- [x] Observability metrics referenced in steady-state definitions
- [x] Incident response procedures integrated into game days
- [x] Infrastructure topology reflected in failure modes

## 5. Experiment Results Log

| Date | Experiment ID | Outcome | Findings | Action Items |
|------|--------------|---------|----------|-------------|

## 6. Implementation Sequence

| Phase | Description | Dependencies | Owner |
|-------|-------------|-------------|-------|
{{implementation_sequence_entries}}

### Phase 1: Foundation

{{foundation_tasks}}

### Phase 2: Staging Experiments

{{staging_tasks}}

### Phase 3: Production Readiness

{{production_tasks}}

### Phase 4: Maturity

{{maturity_tasks}}
```

### 7. Save Final Document

- Append the validation and implementation content to `{bgr_artifacts}/resilience-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4, 5]`
  - `status: complete`
  - `lastUpdated: {{current_date}}`

### 8. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation and generated the implementation sequence.

**Here's what I'll add to finalize the resilience testing plan:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save and finalize the resilience testing plan
[R] Revise - Let's address issues before finalizing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-run relevant quality gates
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Save the final content to `{bgr_artifacts}/resilience-plan.md`
- Update frontmatter to mark workflow as complete
- Present completion summary and next steps

### 10. Update Production Readiness Checklist

After saving the resilience testing plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **Resilience Testing Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/resilience-plan.md`
3. Update section detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/resilience-plan.md`
   - Number of steady-state hypotheses defined
   - Number of failure scenarios catalogued
   - Number of experiment designs created
   - Game day cadence established
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - If Observability Plan exists and status is `complete`: Verify steady-state indicators align with observability metrics. If status is `draft`, note validation is deferred pending finalization.
   - If Incident Response Plan exists and status is `complete`: Verify game day exercises test incident response procedures. If status is `draft`, note validation is deferred pending finalization.
   - If Infrastructure Plan exists and status is `complete` or `approved`: Verify failure modes match infrastructure topology. If status is `draft`, note validation is deferred pending finalization.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `resilience-testing`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched environment topologies, missing rollback alignment, or undefined alerting-to-severity mappings).
7. Save the updated checklist

### 11. Completion Summary

After saving, present the final summary:

"The Resilience Testing Plan for {{project_name}} is complete and saved to `{bgr_artifacts}/resilience-plan.md`.

**Summary:**
- {N} steady-state hypotheses defined with monitoring queries
- {N} failure scenarios catalogued across all infrastructure layers
- {N} experiment designs with blast radius controls and abort criteria
- Game day schedule established with progressive complexity
- Prioritized implementation sequence with {N} phases

**Recommended Next Steps:**
- **Create Disaster Recovery Plan (CD)** — Define RTO/RPO targets, backup and restore procedures, geographic failover, and DR runbooks
- **Return to agent menu** — Explore other capabilities

Thank you for collaborating on this, {{user_name}}. Your services will be battle-tested before they ever face a real incident."

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ All quality gates evaluated systematically
✅ Any failures identified and addressed with user
✅ Implementation sequence generated with clear phases
✅ Final document saved with complete frontmatter
✅ User presented with clear next steps
✅ C/R menu presented and handled correctly
✅ Workflow marked as complete
✅ Production readiness checklist updated with completion status and key decisions
✅ Cross-plan dependency gaps identified and recorded in checklist

## FAILURE MODES:

❌ Rubber-stamping quality gates without thorough checking
❌ Not addressing failed quality gates before finalizing
❌ Generating a sequence without prioritization
❌ Not saving the final document with updated frontmatter
❌ Not presenting recommended next steps
❌ Finalizing without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols
