# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: Before finalizing with 'C', ensure this entire file is read and understood
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating capacity plan completeness and generating implementation sequence
- ✅ VALIDATE all services have scaling strategies and capacity projections
- ⚠️ Do not estimate software delivery timelines or task durations — but do define operational timing (scaling response times, load test cadence, review schedules) as these are core capacity plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ✅ Run comprehensive validation checks on the complete capacity plan
- ⚠️ Present C/R menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: complete` before finishing
- 🚫 FORBIDDEN to finalize until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the validation results and finalize the capacity plan
- **R (Revise)**: Discuss changes, address gaps, then re-present the menu

## CONTEXT BOUNDARIES:

- Complete capacity plan document with all sections is available
- Growth model, scaling strategy, and load testing plan are defined
- Focus on validation, gap analysis, and generating implementation sequence
- This is the final step — ensure the plan is actionable

## YOUR TASK:

Validate the complete capacity plan for coverage, coherence, and actionability. Generate a prioritized implementation sequence and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate systematically:

**Gate 1: Growth Model Completeness**
- [ ] Current traffic baseline established with real data or informed estimates
- [ ] Growth scenarios defined (conservative, expected, aggressive)
- [ ] Growth drivers identified and quantified
- [ ] Seasonal and event-driven demand patterns documented
- [ ] Resource demand mapped per service

**Gate 2: Scaling Strategy Coverage**
- [ ] Every service has a defined scaling approach (horizontal, vertical, or hybrid)
- [ ] Auto-scaling policies defined with thresholds, cooldowns, and min/max
- [ ] Reactive, predictive, and scheduled triggers documented
- [ ] Database and data store scaling addressed separately
- [ ] Emergency scaling triggers defined with owner accountability

**Gate 3: Cost-Performance Analysis**
- [ ] Cost model covers baseline, peak, and scaling premium
- [ ] Reserved capacity strategy defined with commitment terms
- [ ] Cost guardrails established with thresholds and actions
- [ ] Trade-off decisions documented with rationale and owner
- [ ] Cost optimization strategies identified

**Gate 4: Load Testing Readiness**
- [ ] Load testing tools selected with rationale
- [ ] Test scenarios cover all growth projections and scaling triggers
- [ ] Testing environment strategy documented
- [ ] Testing cadence established (recurring and trigger-based)
- [ ] Success criteria tied to SLOs for each test scenario

**Gate 5: Capacity Validation Process**
- [ ] Capacity validation checklist covers all critical dimensions
- [ ] Capacity alerts defined with thresholds and owners
- [ ] Review process established with cadence and participants
- [ ] Reporting requirements documented

### Maturity-Level Gate Calibration

Read `{bgr_maturity}` from config. When evaluating the quality gates above, apply the following maturity-based expectations:

| Gate | greenfield | growing | established | advanced |
|------|-----------|---------|-------------|----------|
| Gate 1: Growth Model (current traffic baseline, resource demand mapped) | PASS | PASS | PASS | PASS |
| Gate 2: Scaling Strategy (basic auto-scaling for key services) | PASS | PASS | PASS | PASS |
| Gate 3: Cost-Performance (cost awareness, baseline cost model) | PASS | PASS | PASS | PASS |
| Gate 1: Growth scenarios (conservative, expected, aggressive) | DEFERRED | PASS | PASS | PASS |
| Gate 2: Scaling policies with thresholds, cooldowns, min/max | DEFERRED | PASS | PASS | PASS |
| Gate 4: Load Testing (tools selected, test scenarios planned) | DEFERRED | PASS | PASS | PASS |
| Gate 2: Predictive and scheduled scaling triggers | DEFERRED | DEFERRED | PASS | PASS |
| Gate 4: Comprehensive load testing suite tied to SLOs | DEFERRED | DEFERRED | PASS | PASS |
| Gate 3: Cost guardrails with thresholds and actions | DEFERRED | DEFERRED | PASS | PASS |
| Gate 5: Capacity alerts with thresholds and owners | DEFERRED | DEFERRED | PASS | PASS |
| Gate 2: ML-driven predictive auto-scaling | DEFERRED | DEFERRED | DEFERRED | PASS |
| Gate 1: Cross-region capacity planning | DEFERRED | DEFERRED | DEFERRED | PASS |
| Gate 5: Automated capacity validation | DEFERRED | DEFERRED | DEFERRED | PASS |
| Gate 5: Quarterly capacity reviews established | DEFERRED | DEFERRED | DEFERRED | PASS |

**How to interpret:**
- **PASS** — Gate must pass. Flag failures as blocking.
- **DEFERRED** — Gate is aspirational at this maturity level. Note it as a future improvement area but do not block. If the team has partially addressed it, acknowledge the progress.

When presenting validation results, report each gate's status as PASS, FAIL, or DEFERRED based on the team's maturity level.

### 2. Cross-Workflow Coherence Validation

Check alignment with other completed workflow plans:

**If Infrastructure Plan exists:**
- Do scaling approaches align with the infrastructure architecture?
- Are auto-scaling policies compatible with the container orchestration platform?
- Do reserved capacity commitments align with infrastructure cost plans?
- Is the scaling strategy consistent with environment topology?

**If Observability Plan exists:**
- Are capacity alerts aligned with existing alerting strategy?
- Do scaling triggers reference metrics defined in the observability plan?
- Are SLO targets used as success criteria in load tests?
- Are capacity dashboards consistent with existing dashboard strategy?

**If Pipeline Plan exists:**
- Can the CI/CD pipeline handle deployment during scaling events?
- Are load testing stages integrated into the pipeline?
- Is rollback aligned with scale-down procedures?

**If Incident Response Plan exists:**
- Do capacity alerts integrate with incident severity levels?
- Are emergency scaling triggers aligned with incident response procedures?
- Is capacity exhaustion covered in incident escalation paths?

**If Disaster Recovery Plan exists:**
- Does reserved capacity account for DR failover requirements?
- Are scaling strategies consistent across primary and DR regions?
- Do capacity projections include DR scenarios?

### 3. Gap Analysis

Identify any missing elements:

**Critical Gaps** (block capacity readiness):
- Services without defined scaling approach
- Missing auto-scaling policies for key services
- No load testing plan or tools selected
- Growth model based on no data or pure assumptions

**Important Gaps** (should be addressed soon):
- Load testing environment not yet provisioned
- Reserved capacity decisions pending financial approval
- Capacity alerts not yet integrated with alerting platform
- Testing cadence defined but first tests not yet scheduled

**Enhancement Opportunities** (improve over time):
- Predictive auto-scaling using ML-based forecasting
- Chaos engineering for capacity failure scenarios
- Automated capacity reporting and trending
- Cross-region capacity balancing optimization

### 4. Present Validation Summary

Report the validation results to the user:

"I've completed a comprehensive validation of your Capacity Plan.

**Quality Gate Results:**

| Gate | Status | Notes |
|------|--------|-------|
| Growth Model | {PASS/FAIL} | {details} |
| Scaling Strategy | {PASS/FAIL} | {details} |
| Cost-Performance | {PASS/FAIL} | {details} |
| Load Testing | {PASS/FAIL} | {details} |
| Capacity Validation | {PASS/FAIL} | {details} |

{if_any_failures}
**Issues to Address:**
{list of failed gates with specific gaps}

Would you like to address these before finalizing?
{/if_any_failures}

{if_all_pass}
All quality gates passed. The capacity plan is comprehensive and ready for implementation.
{/if_all_pass}"

### 5. Address Validation Issues

If any quality gates failed:

- Present the specific gaps clearly
- Collaborate with the user to resolve each gap
- Update the relevant document sections
- Re-run the failed quality gates to confirm resolution

### 6. Generate Implementation Sequence

Create a prioritized list of implementation tasks:

**Priority 1 — Foundation (implement first):**
- Configure auto-scaling policies for Tier 1 services
- Set up capacity monitoring dashboards and alerts
- Provision load testing environment
- Execute first baseline load test
- Configure cost guardrails and budget alerts

**Priority 2 — Validation (implement second):**
- Run capacity tests against 6-month growth projections
- Validate auto-scaling trigger response times
- Execute stress tests to identify breaking points
- Validate database scaling under projected load
- Review and adjust auto-scaling thresholds based on test results

**Priority 3 — Optimization (implement third):**
- Purchase reserved capacity commitments based on validated baseline
- Implement predictive scaling for known traffic patterns
- Set up automated capacity reporting
- Integrate load testing into CI/CD pipeline
- Establish capacity review cadence

**Priority 4 — Maturity (implement ongoing):**
- Implement ML-based predictive auto-scaling
- Establish capacity chaos engineering practice
- Optimize cross-region capacity distribution
- Quarterly growth model review and adjustment
- Annual reserved capacity re-evaluation

### 7. Generate Validation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

| Gate | Status | Notes |
|------|--------|-------|
{{quality_gate_results}}

### Capacity Plan Completeness Checklist

**✅ Growth Model**

- [x] Current traffic baseline established
- [x] Growth scenarios defined with projections
- [x] Seasonal and event patterns documented
- [x] Resource demand mapped per service

**✅ Scaling Strategy**

- [x] Scaling approach defined per service
- [x] Auto-scaling policies configured
- [x] Reactive, predictive, and scheduled triggers documented
- [x] Database scaling addressed
- [x] Emergency triggers with owner accountability

**✅ Cost-Performance**

- [x] Cost model with baseline, peak, and scaling premium
- [x] Reserved capacity strategy documented
- [x] Cost guardrails established
- [x] Trade-off decisions documented with owners

**✅ Load Testing**

- [x] Testing tools selected
- [x] Test scenarios cover all growth projections
- [x] Testing environment and cadence defined

**✅ Capacity Validation**

- [x] Validation checklist covers all dimensions
- [x] Capacity alerts with owners
- [x] Review process established

## 8. Implementation Roadmap

| Milestone | Description | Owner | Target Date |
|-----------|-------------|-------|-------------|
{{implementation_sequence_entries}}

### Priority 1: Foundation

{{foundation_tasks}}

### Priority 2: Validation

{{validation_tasks}}

### Priority 3: Optimization

{{optimization_tasks}}

### Priority 4: Maturity

{{maturity_tasks}}

## 9. Capacity Plan Maintenance

### Review Cadence

- **Monthly**: Review utilization metrics and scaling effectiveness
- **Quarterly**: Update growth model with actual traffic data, validate projections
- **After architecture changes**: Re-assess scaling strategies and capacity projections
- **Annually**: Full capacity plan review, reserved capacity re-evaluation, budget planning

### Capacity Health Indicators

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| Peak utilization | < 60% | 60-80% | > 80% |
| Auto-scaling response | < target | Within 2x target | > 2x target |
| Cost vs forecast | Within 10% | 10-20% over | > 20% over |
| Growth vs model | Within expected | Between expected and aggressive | Exceeds aggressive |
```

### 8. Save Final Document

- Append the validation and implementation content to `{bgr_artifacts}/capacity-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4, 5]`
  - `status: complete`
  - `lastUpdated: {{current_date}}`

### 9. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation and generated the implementation roadmap.

**Here's what I'll add to finalize the capacity plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save and finalize the capacity plan
[R] Revise - Let's address issues before finalizing"

### 10. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-run relevant quality gates
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Save the final content to `{bgr_artifacts}/capacity-plan.md`
- Update frontmatter to mark workflow as complete
- Present completion summary and next steps

### 11. Update Production Readiness Checklist

After saving the capacity plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it in place with the minimum required structure for this workflow:
     - Frontmatter including:
       - `lastUpdated: {{current_date}}`
       - `completedWorkflows: []`
     - An `## Overview` section that includes the checklist `lastUpdated`
     - A `## Workflow Completion Status` table with columns `| Workflow | Status | Completion Date | Output Document |` and a row for **Capacity Planning**
     - A capacity plan detail section with fields for **Status**, **Completion Date**, and **Output Document**
     - A `### Consistency Issues` section for cross-plan dependency findings
   - If it does exist, DO NOT rewrite the file into a different schema just to match the structure above
   - Treat the Step-01-generated checklist format and the canonical checklist format as equally valid
   - Preserve the existing organization, headings, frontmatter, and tables wherever possible; only add the minimum missing fields/sections needed to record capacity-plan completion
2. Detect the existing checklist structure and update equivalent sections in place:
   - If frontmatter exists, update `lastUpdated: {{current_date}}` and preserve all other keys
   - If a `Workflow Completion Status` table exists, update the **Capacity Planning** row there
   - If the checklist uses a different workflow-status section/table format from Step-01, update the equivalent capacity-plan entry in that format instead of converting the file
   - If no workflow-status section exists in any format, add the minimum missing status section with a **Capacity Planning** entry
3. Record capacity-plan completion details in the existing capacity-plan section, or create a minimal one only if none exists:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/capacity-plan.md`
   - Include key decisions:
     - Growth forecast summary (conservative/expected/aggressive projections)
     - Scaling approach (horizontal, vertical, hybrid per service tier)
     - Reserved capacity commitments
     - Load testing cadence and tools
     - Cost guardrail thresholds
   - If an Overview section contains a human-readable `lastUpdated`, update it; otherwise do not create or rename sections solely for that purpose
4. Check for cross-plan dependency gaps:
   - If Infrastructure Plan exists: Verify scaling strategies align with infrastructure architecture, reserved capacity aligns with infrastructure cost plans
   - If Observability Plan exists: Verify capacity alerts align with alerting strategy, scaling triggers reference defined metrics
   - If Pipeline Plan exists: Verify load testing integrates with CI/CD pipeline, scaling events are compatible with deployment strategy
   - If Incident Response Plan exists: Verify capacity alerts integrate with incident severity levels
   - If Disaster Recovery Plan exists: Verify capacity reserves account for DR failover, scaling strategies are consistent across regions
   - Record inconsistencies in `### Consistency Issues` when that section exists
   - If the checklist uses an equivalent consistency/dependencies/issues section from Step-01, record the findings there instead
   - Only create a new minimal consistency issues subsection if no equivalent location exists
5. Record workflow completion without forcing a schema conversion:
   - If checklist frontmatter contains `completedWorkflows`, add `capacity-planning` only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run)
   - If the checklist uses a different Step-01 completion-tracking structure, update the equivalent completion marker there as well
6. If all workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). The Overall Status field lives in the `## Overview` section of the production readiness checklist (e.g., as a line `**Overall Status**: READY`); if the checklist uses frontmatter to track overall status, update it there instead. A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched scaling strategies, missing capacity alerts, or undefined cost guardrails).
7. Save the updated checklist, preserving the existing schema and content ordering as much as possible

### 12. Completion Summary

After saving, present the final summary:

"The Capacity Plan for {{project_name}} is complete and saved to `{bgr_artifacts}/capacity-plan.md`.

**Summary:**
- {N} services profiled with growth projections
- Growth forecast: {conservative}% to {aggressive}% over 12 months
- {N} auto-scaling policies defined with triggers
- Reserved capacity strategy covering {percentage}% of baseline
- Load testing cadence: {summary}
- Cost guardrails: {guardrail_summary}
- Prioritized implementation roadmap with {N} milestones

**Recommended Next Steps:**
1. Implement Priority 1 foundation tasks (auto-scaling policies, monitoring, load test environment)
2. Execute first baseline load test to validate current capacity
3. Schedule first capacity review meeting
4. Procure reserved capacity based on validated baseline
5. Integrate capacity metrics into existing observability dashboards

**Related Workflows:**
- **Create Observability Plan (CO)** — Add capacity-specific metrics and alerting
- **Create Infrastructure Plan (CI)** — Align infrastructure with scaling requirements
- **Return to agent menu** — Explore other capabilities

Thank you for building this plan together, {{user_name}}! Capacity planning is the difference between scaling gracefully and scrambling at 3am."

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All quality gates evaluated systematically
✅ Any failures identified and addressed with user
✅ Cross-workflow coherence validated
✅ Implementation sequence generated with clear priorities
✅ Capacity plan maintenance cadence established
✅ Final document saved with complete frontmatter
✅ User presented with clear next steps
✅ C/R menu presented and handled correctly
✅ Workflow marked as complete
✅ Production readiness checklist updated with completion status and key decisions
✅ Cross-plan dependency gaps identified and recorded in checklist

## FAILURE MODES:

❌ Rubber-stamping quality gates without thorough checking
❌ Not addressing failed quality gates before finalizing
❌ Generating implementation sequence without prioritization
❌ Not saving the final document with updated frontmatter
❌ Not presenting recommended next steps
❌ Finalizing without user confirmation
❌ Not updating production readiness checklist

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding this finalization step
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## WORKFLOW COMPLETE:

This is the final step. After finalization, the capacity planning workflow is complete. The user can invoke additional workflows or return to the agent menu.
