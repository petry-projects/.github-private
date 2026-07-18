# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- NEVER generate content without user input

- CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- CRITICAL: Before finalizing with 'C', ensure this entire file is read and understood
- ALWAYS treat this as collaborative discovery between infrastructure peers
- YOU ARE A FACILITATOR, not a content generator
- FOCUS on validating cost optimization plan completeness and generating implementation sequence
- VALIDATE all resource categories have optimization recommendations and governance controls
- Do not estimate software delivery timelines or task durations — but do define operational timing (budget review cadence, anomaly detection windows, reserved instance evaluation schedules) as these are core cost optimization plan outputs
- YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- Run comprehensive validation checks on the complete cost optimization plan
- Present C/R menu after generating validation results
- ONLY save when user chooses C (Continue)
- Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: complete` before finishing
- FORBIDDEN to finalize until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the validation results and finalize the cost optimization plan
- **R (Revise)**: Discuss changes, address gaps, then re-present the menu

## CONTEXT BOUNDARIES:

- Complete cost optimization plan document with all sections is available
- Cost baseline, optimization strategy, and governance framework are defined
- Focus on validation, gap analysis, and generating implementation sequence
- This is the final step — ensure the plan is actionable

## YOUR TASK:

Validate the complete cost optimization plan for coverage, coherence, and actionability. Generate a prioritized implementation sequence and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate systematically:

**Gate 1: Cost Baseline Completeness**
- [ ] Current spend baseline established with real data or informed estimates
- [ ] Resource inventory cataloged across all cloud services
- [ ] Cost distribution analyzed by environment, service, and category
- [ ] Resource utilization assessed with waste identified
- [ ] Waste quantified with estimated monthly savings

**Gate 2: Right-Sizing Coverage**
- [ ] Compute right-sizing recommendations with savings estimates
- [ ] Database right-sizing addressed with migration risk assessment
- [ ] Storage optimization with tier recommendations
- [ ] Network optimization opportunities identified
- [ ] Growth projections considered in right-sizing decisions

**Gate 3: Reserved & Spot Strategy**
- [ ] Reservation analysis with break-even calculations
- [ ] Reservation recommendations with commitment terms and coverage targets
- [ ] Spot/preemptible strategy for eligible workloads
- [ ] Savings plan coverage targets defined
- [ ] Commitment approval process documented

**Gate 4: Cost Governance**
- [ ] Tagging taxonomy defined with enforcement strategy
- [ ] Cost allocation rules for shared resources
- [ ] Budget definitions with alert thresholds and owners
- [ ] Anomaly detection rules with response procedures
- [ ] Tag compliance monitoring and reporting

**Gate 5: SLO-Cost Integration**
- [ ] SLO-cost analysis completed for key service level objectives
- [ ] Error budget spending policy considers cost impact
- [ ] Performance-cost trade-offs documented with owners
- [ ] Reliability vs cost decision framework established

**Gate 6: FinOps Maturity**
- [ ] Current maturity state assessed with evidence
- [ ] Crawl/walk/run progression plan defined
- [ ] Maturity milestones with validation criteria
- [ ] Organizational adoption plan included

### 2. Cross-Workflow Coherence Validation

Check alignment with other completed workflow plans:

**If Capacity Plan exists:**
- Do right-sizing recommendations align with growth projections?
- Are reserved instance commitments consistent with capacity reserved capacity?
- Do cost guardrails align with capacity cost-performance trade-offs?
- Is the cost optimization review cadence compatible with capacity review cadence?

**If Infrastructure Plan exists:**
- Do right-sizing recommendations align with the infrastructure architecture?
- Are tagging standards compatible with infrastructure naming conventions?
- Do budget scopes align with infrastructure environment topology?
- Is the cost allocation model consistent with infrastructure ownership?

**If Observability Plan exists:**
- Are cost anomaly alerts aligned with existing alerting strategy?
- Do cost-aware SLO trade-offs reference SLOs defined in the observability plan?
- Are cost dashboards consistent with existing dashboard strategy?
- Is anomaly detection integrated with observability monitoring?

**If Pipeline Plan exists:**
- Are CI/CD resource costs included in the cost baseline?
- Can pipeline environments leverage spot instances?
- Is cost reporting integrated into deployment workflows?

**If Incident Response Plan exists:**
- Do cost anomaly severity levels align with incident severity classification?
- Are cost anomaly response procedures aligned with incident response procedures?
- Is cost anomaly escalation integrated with incident escalation paths?

### 3. Gap Analysis

Identify any missing elements:

**Critical Gaps** (block cost optimization readiness):
- Resources without right-sizing assessment
- Missing budget definitions for key cost centers
- No anomaly detection rules configured
- Tagging standards not defined or not enforceable

**Important Gaps** (should be addressed soon):
- Reserved instance purchases pending financial approval
- Tag compliance below target with remediation in progress
- Cost dashboards not yet configured
- Chargeback model not yet implemented

**Enhancement Opportunities** (improve over time):
- ML-based anomaly detection for cost patterns
- Automated right-sizing based on continuous utilization analysis
- Real-time cost attribution in deployment pipelines
- Predictive cost modeling integrated with capacity forecasting

### 4. Present Validation Summary

Report the validation results to the user:

"I've completed a comprehensive validation of your Cost Optimization Plan.

**Quality Gate Results:**

| Gate | Status | Notes |
|------|--------|-------|
| Cost Baseline | {PASS/FAIL} | {details} |
| Right-Sizing | {PASS/FAIL} | {details} |
| Reserved & Spot | {PASS/FAIL} | {details} |
| Cost Governance | {PASS/FAIL} | {details} |
| SLO-Cost Integration | {PASS/FAIL} | {details} |
| FinOps Maturity | {PASS/FAIL} | {details} |

{if_any_failures}
**Issues to Address:**
{list of failed gates with specific gaps}

Would you like to address these before finalizing?
{/if_any_failures}

{if_all_pass}
All quality gates passed. The cost optimization plan is comprehensive and ready for implementation.
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
- Implement cost tagging standards and enforcement
- Set up budget alerts for all cost centers
- Configure basic anomaly detection rules
- Create cost visibility dashboards
- Execute quick-win right-sizing (low risk, immediate savings)

**Priority 2 — Optimization (implement second):**
- Purchase reserved instances / savings plans for baseline workloads
- Migrate eligible workloads to spot/preemptible instances
- Implement non-production environment scheduling (stop overnight/weekends)
- Execute medium-risk right-sizing recommendations
- Set up chargeback/showback reporting

**Priority 3 — Governance (implement third):**
- Implement tag compliance monitoring and remediation
- Establish monthly cost review process
- Integrate cost anomaly alerts with incident response
- Create cost-aware SLO dashboards
- Implement storage lifecycle policies

**Priority 4 — Maturity (implement ongoing):**
- Advance FinOps maturity from crawl to walk to run
- Implement automated right-sizing
- Integrate cost metrics into architecture decision records
- Establish quarterly reserved capacity re-evaluation
- Build predictive cost modeling capabilities

### 7. Generate Validation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

| Gate | Status | Notes |
|------|--------|-------|
{{quality_gate_results}}

### Cost Optimization Plan Completeness Checklist

**Cost Baseline**

- [x] Current spend baseline established
- [x] Resource inventory cataloged
- [x] Cost distribution analyzed
- [x] Waste identified and quantified

**Right-Sizing**

- [x] Compute right-sizing with savings estimates
- [x] Database right-sizing addressed
- [x] Storage optimization defined
- [x] Network optimization identified

**Reserved & Spot Strategy**

- [x] Reservation analysis with break-even
- [x] Spot/preemptible strategy defined
- [x] Savings plan coverage targets set

**Cost Governance**

- [x] Tagging taxonomy defined
- [x] Budget alerts configured
- [x] Anomaly detection rules set
- [x] Tag compliance monitoring established

**SLO-Cost Integration**

- [x] SLO-cost analysis completed
- [x] Error budget spending policy defined
- [x] Performance-cost trade-offs documented

**FinOps Maturity**

- [x] Current state assessed
- [x] Crawl/walk/run progression planned
- [x] Maturity milestones defined

## 9. Implementation Roadmap

| Milestone | Description | Owner | Dependencies |
|-----------|-------------|-------|-------------|
{{implementation_sequence_entries}}

### Priority 1: Foundation

{{foundation_tasks}}

### Priority 2: Optimization

{{optimization_tasks}}

### Priority 3: Governance

{{governance_tasks}}

### Priority 4: Maturity

{{maturity_tasks}}

## 10. Cost Optimization Maintenance

### Review Cadence

- **Weekly**: Review anomaly alerts and budget burn rate
- **Monthly**: Review cost trends, right-sizing opportunities, and tag compliance
- **Quarterly**: Update reserved instance strategy, review SLO-cost trade-offs, maturity progression
- **After architecture changes**: Re-assess cost optimization opportunities
- **Annually**: Full cost optimization plan review, reserved capacity re-evaluation, FinOps maturity assessment

### Cost Health Indicators

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| Budget adherence | Within 5% | 5-15% over | > 15% over |
| Tag compliance | > 95% | 80-95% | < 80% |
| Right-sizing coverage | > 90% reviewed | 70-90% reviewed | < 70% reviewed |
| Reserved coverage | > 70% baseline | 50-70% baseline | < 50% baseline |
| Waste ratio | < 5% | 5-15% | > 15% |
```

### 8. Save Final Document

- Append the validation and implementation content to `{bgr_artifacts}/cost-optimization-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4, 5]`
  - `status: complete`
  - `lastUpdated: {{current_date}}`

### 9. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation and generated the implementation roadmap.

**Here's what I'll add to finalize the cost optimization plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save and finalize the cost optimization plan
[R] Revise - Let's address issues before finalizing"

### 10. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-run relevant quality gates
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Save the final content to `{bgr_artifacts}/cost-optimization-plan.md`
- Update frontmatter to mark workflow as complete
- Present completion summary and next steps

### 11. Update Production Readiness Checklist

After saving the cost optimization plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it in place with the minimum required structure for this workflow:
     - Frontmatter including:
       - `lastUpdated: {{current_date}}`
       - `completedWorkflows: []`
     - An `## Overview` section that includes the checklist `lastUpdated`
     - A `## Workflow Completion Status` table with columns `| Workflow | Status | Completion Date | Output Document |` and a row for **Cost Optimization**
     - A cost optimization detail section with fields for **Status**, **Completion Date**, and **Output Document**
     - A `### Consistency Issues` section for cross-plan dependency findings
   - If it does exist, DO NOT rewrite the file into a different schema just to match the structure above
   - Treat the Step-01-generated checklist format and the canonical checklist format as equally valid
   - Preserve the existing organization, headings, frontmatter, and tables wherever possible; only add the minimum missing fields/sections needed to record cost-optimization completion
2. Detect the existing checklist structure and update equivalent sections in place:
   - If frontmatter exists, update `lastUpdated: {{current_date}}` and preserve all other keys
   - If a `Workflow Completion Status` table exists, update the **Cost Optimization** row there
   - If the checklist uses a different workflow-status section/table format from Step-01, update the equivalent cost-optimization entry in that format instead of converting the file
   - If no workflow-status section exists in any format, add the minimum missing status section with a **Cost Optimization** entry
3. Record cost-optimization completion details in the existing cost-optimization section, or create a minimal one only if none exists:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/cost-optimization-plan.md`
   - Include key decisions:
     - Total identified savings (monthly estimate)
     - Right-sizing approach summary
     - Reserved/spot instance strategy summary
     - Tagging taxonomy and enforcement approach
     - Anomaly detection and budget alert strategy
     - FinOps maturity current state and target
   - If an Overview section contains a human-readable `lastUpdated`, update it; otherwise do not create or rename sections solely for that purpose
4. Check for cross-plan dependency gaps:
   - If Capacity Plan exists: Verify right-sizing aligns with growth projections, reserved commitments are consistent with capacity strategy
   - If Infrastructure Plan exists: Verify tagging standards align with infrastructure naming, budget scopes match environment topology
   - If Observability Plan exists: Verify cost anomaly alerts align with alerting strategy, SLO-cost trade-offs reference defined SLOs
   - If Pipeline Plan exists: Verify CI/CD costs are included in baseline, pipeline environments consider spot usage
   - If Incident Response Plan exists: Verify cost anomaly severity aligns with incident severity levels
   - Record inconsistencies in `### Consistency Issues` when that section exists
   - If the checklist uses an equivalent consistency/dependencies/issues section from Step-01, record the findings there instead
   - Only create a new minimal consistency issues subsection if no equivalent location exists
5. Record workflow completion without forcing a schema conversion:
   - If checklist frontmatter contains `completedWorkflows`, add `cost-optimization` only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run)
   - If the checklist uses a different Step-01 completion-tracking structure, update the equivalent completion marker there as well
6. If all workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). The Overall Status field lives in the `## Overview` section of the production readiness checklist (e.g., as a line `**Overall Status**: READY`); if the checklist uses frontmatter to track overall status, update it there instead. A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched scaling strategies, missing cost alerts, or undefined tagging standards).
7. Save the updated checklist, preserving the existing schema and content ordering as much as possible

### 12. Completion Summary

After saving, present the final summary:

"The Cost Optimization Plan for {{project_name}} is complete and saved to `{bgr_artifacts}/cost-optimization-plan.md`.

**Summary:**
- Total monthly spend baselined: {total_spend}
- Identified savings opportunities: {total_savings}/month ({savings_pct}% of spend)
- {N} resources right-sized with savings estimates
- Reserved/spot strategy covering {coverage_pct}% of baseline workloads
- {N} budget alerts configured with anomaly detection
- Tagging taxonomy with {N} required tags and {enforcement_level} enforcement
- FinOps maturity: {current_level} with progression to {target_level}
- Prioritized implementation roadmap with {N} milestones

**Recommended Next Steps:**
1. Implement Priority 1 foundation tasks (tagging, budget alerts, quick-win right-sizing)
2. Purchase reserved instances/savings plans based on validated baseline
3. Schedule first monthly cost review meeting
4. Set up cost visibility dashboards for all stakeholders
5. Begin tag compliance monitoring and remediation

**Related Workflows:**
- **Create Capacity Plan (CC)** — Align scaling strategy with cost optimization
- **Create Infrastructure Plan (CI)** — Align infrastructure architecture with cost targets
- **Create Observability Plan (CO)** — Integrate cost metrics into observability dashboards
- **Return to agent menu** — Explore other capabilities

Thank you for building this plan together, {{user_name}}! FinOps is a journey — every dollar optimized is a dollar that can be reinvested in building better products."

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All quality gates evaluated systematically
✅ Any failures identified and addressed with user
✅ Cross-workflow coherence validated
✅ Implementation sequence generated with clear priorities
✅ Cost optimization maintenance cadence established
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

This is the final step. After finalization, the cost optimization planning workflow is complete. The user can invoke additional workflows or return to the agent menu.
