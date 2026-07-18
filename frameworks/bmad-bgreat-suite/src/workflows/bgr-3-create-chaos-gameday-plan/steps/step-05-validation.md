# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: Before finalizing with 'C', ensure this entire file is read and understood
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating plan completeness and safety before the game day runs
- ✅ VALIDATE all experiments have complete controls before the plan is approved for execution
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ✅ Run comprehensive validation checks on the complete plan
- ⚠️ Present [C]ontinue / [R]evise menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and set `status: complete` before finalizing
- 🚫 FORBIDDEN to finalize until C is selected

## CONTEXT BOUNDARIES:

- Complete chaos game day plan with all sections is available
- All experiments, hypotheses, blast radius controls, safety gates, and execution schedule are defined
- Focus on validation, gap analysis, and readiness assessment
- Prepare the plan for handoff to the game day lead and participants

## YOUR TASK:

Validate the complete chaos engineering game day plan for safety, completeness, and operational readiness. Present a summary and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate and assess pass/fail:

**Hypothesis Quality:**
- [ ] Every experiment has a well-formed hypothesis (When/Expect/Because/Measured by structure)
- [ ] Every hypothesis references a specific, measurable steady-state metric and threshold
- [ ] Steady-state metrics are observable with the team's current tooling
- [ ] Experiment sequence prioritizes safer/lower-blast-radius experiments first

**Blast Radius Controls:**
- [ ] Blast radius quantified for every experiment (user scope, service scope, data risk)
- [ ] Containment strategy defined for every experiment
- [ ] Abort conditions are specific and unambiguous for every experiment
- [ ] Rollback procedure defined for every experiment with step-by-step instructions
- [ ] Rollback SLA defined (maximum time to restore service)

**Safety Gates:**
- [ ] Pre-game-day checklist covers system health and team readiness
- [ ] Between-experiment safety gate is defined
- [ ] Abort authority is clearly assigned (any participant recommended)
- [ ] Abort communication channel is named
- [ ] End-of-day gate ensures all rollbacks are confirmed before closing

**Execution Readiness:**
- [ ] Game day schedule includes recovery windows between experiments
- [ ] Roles assigned: Game Day Lead, Safety Officer, Tool Operator(s), Scribe
- [ ] Observation points named (specific dashboards or metrics) for each experiment
- [ ] Scribe recording protocol defined

**Post-Game Analysis:**
- [ ] Findings classification criteria are unambiguous
- [ ] Post-game analysis template is ready to fill in
- [ ] Findings-to-action tracker format defined with owner and target date fields
- [ ] Findings review cadence established

### 2. Cross-Workflow Coherence Validation

Check alignment with other completed workflow plans:

**If Observability Plan exists:**
- Are steady-state metrics aligned with defined SLOs and burn-rate windows?
- Do observation points reference existing dashboards and alert definitions?
- Could any experiment trigger existing alerts? (confirm this is expected or mitigated)

**If Incident Response Plan exists:**
- Do abort conditions and escalation thresholds align with severity classification?
- Is there a clear distinction between "chaos experiment abort" and "real incident escalation"?
- Should the on-call team be notified when game day starts?

**If Infrastructure Plan exists:**
- Do experiments target services and infrastructure components that exist in the plan?
- Do rollback procedures align with the IaC and deployment strategy?

**If Disaster Recovery Plan exists:**
- Are any experiments designed to validate DR procedures (e.g., failover, backup restore)?
- Do RTO/RPO targets align with experiment recovery expectations?

### 3. Gap Analysis

Identify any missing elements:

**Critical Gaps** (block game day execution):
- Experiments without rollback procedures
- Abort conditions that are vague or unmeasurable
- Observation points that cannot be accessed with current tooling
- No safety officer or tool operator assigned

**Important Gaps** (should be addressed before the game day):
- Rollback procedures not tested in non-production
- Observation points not verified to be functional
- Post-game analysis template not reviewed by participants
- Findings-to-action tracking system not set up

**Enhancement Opportunities** (improve over time):
- Automate fault injection with chaos engineering tooling (e.g., Chaos Monkey, LitmusChaos, AWS Fault Injection Simulator)
- Build a chaos experiment CI/CD pipeline for continuous resilience validation
- Expand scope to multi-region or cross-service experiments
- Run game days on a regular cadence (quarterly recommended)

### 4. Present Validation Summary

Present the complete validation to user:

"I've completed a comprehensive validation of your Chaos Engineering Game Day Plan.

**Quality Gates:**

{{checklist_results_with_pass_fail_status}}

**Coherence Check:**
- {{assessment_of_how_all_sections_work_together}}

**Gap Analysis:**

**Critical:** {{critical_gaps_or_none_found}}
**Important:** {{important_gaps}}
**Enhancements:** {{enhancement_opportunities}}

### 5. Generate Validation Content

Prepare the final content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

{{quality_gates_checklist_with_status}}

### Plan Completeness

**Overall Status:** {{READY FOR EXECUTION / NEEDS ATTENTION}}

**Strengths:**
{{list_of_plan_strengths}}

**Areas to Address Before Game Day:**
{{areas_that_should_be_resolved_before_running}}

### Recommended Next Steps

{{prioritized_list_of_next_actions_before_game_day}}

## 13. Game Day Readiness Checklist (Final)

This checklist to be completed by the Game Day Lead 24 hours before execution:

- [ ] All participants confirmed and briefed on hypotheses and abort conditions
- [ ] All rollback procedures reviewed and tested (or acknowledged untested)
- [ ] Observation tools and dashboards verified functional
- [ ] Issue tracker ready for findings capture
- [ ] On-call team notified of scheduled game day window
- [ ] Game Day Lead has authority to cancel if pre-checks fail
```

### 6. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation. Here's the final section to add:

[Show the complete markdown content from step 5]

**What would you like to do?**
[C] Continue - Save and finalize the chaos game day plan
[R] Revise - Let's address gaps or adjust any section of the plan"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Navigate back to relevant sections if needed
- Collaborate on revisions
- Re-run validation if significant changes made
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/chaos-gameday-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4, 5]`
- Update frontmatter: `status: complete`
- Update frontmatter: `lastUpdated` to current date
- Save the final document

### 8. Update Production Readiness Checklist

After saving the chaos game day plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **Chaos Game Day Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/chaos-gameday-plan.md`
3. Update section **Chaos Game Day Plan** detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/chaos-gameday-plan.md`
   - Number of experiments defined
   - Environment targeted (production / staging / dedicated chaos env)
   - Steady-state metrics source (SLO-based or manually defined)
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - If Observability Plan exists and status is `complete`: Verify steady-state metrics align with SLOs and dashboards are referenced. If status is `draft`, note validation is deferred pending finalization.
   - If Incident Response Plan exists and status is `complete`: Verify abort conditions are distinct from incident escalation thresholds. If status is `draft`, note validation is deferred pending finalization.
   - If Infrastructure Plan exists and status is `complete`: Verify experiments target infrastructure components consistent with the plan. If status is `draft`, note validation is deferred pending finalization.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `chaos-gameday`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness.
7. Save the updated checklist

### 9. Finalization Report

After saving, present the completion summary:

"Your Chaos Engineering Game Day Plan is complete and saved to `{bgr_artifacts}/chaos-gameday-plan.md`.

**What you have:**
- {{N}} hypothesis-driven experiments with measurable steady-state criteria
- Blast radius controls and containment strategies for each experiment
- Explicit abort conditions and rollback procedures for each experiment
- Pre-game-day checklist covering system health and team readiness
- Safety gate layers from pre-game through end-of-day
- Game day execution schedule with observation points and recovery windows
- Findings classification framework with severity scale
- Post-game analysis template with findings-to-action tracker
- Final readiness checklist for 24-hour pre-game review

**Recommended next steps:**
1. Review the plan with all game day participants and confirm understanding of abort conditions
2. Test rollback procedures for high-blast-radius experiments in a non-production environment
3. Verify all observation dashboards are accessible and functional
4. Notify the on-call team of the scheduled game day window
5. Schedule a 30-minute pre-brief on the day of the game day
6. After the game day, complete the post-game analysis template within 24 hours

**Related Workflows:**
- `bgr-3-create-observability` — Align SLOs and dashboards with steady-state metrics
- `bgr-3-create-incident-response` — Ensure abort escalation aligns with incident severity
- `bgr-3-create-disaster-recovery` — Design experiments to validate DR procedures

Thank you for building this plan together, {{user_name}}! A well-prepared game day builds organizational confidence in system resilience — and reveals the failure modes you didn't know you had."

## SUCCESS METRICS:

✅ All quality gates evaluated with clear pass/fail
✅ Coherence between all sections validated
✅ Gaps identified and communicated with priority levels
✅ Final readiness checklist included for 24-hour pre-game review
✅ Final document saved with complete frontmatter
✅ Actionable next steps provided
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected
✅ Production readiness checklist updated with completion status and key decisions
✅ Cross-plan dependency gaps identified and recorded in checklist

## FAILURE MODES:

❌ Rubber-stamping validation without thorough checks
❌ Missing critical gaps that would cause safety issues during a real game day
❌ Not checking coherence between experiment hypotheses and available observation tooling
❌ Finalizing without user confirmation
❌ Not providing actionable next steps before game day execution
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding this finalization step
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## WORKFLOW COMPLETE:

This is the final step. After finalization, the chaos game day workflow is complete. The user can invoke additional workflows or return to the agent menu.
