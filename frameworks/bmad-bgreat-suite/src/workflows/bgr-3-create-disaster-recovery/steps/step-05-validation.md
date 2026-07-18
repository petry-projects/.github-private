# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: Before finalizing with 'C', ensure this entire file is read and understood
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating DR plan completeness and generating implementation sequence
- ✅ VALIDATE all critical services have recovery procedures defined
- ⚠️ Do not estimate software delivery timelines or task durations — but do define DR operational timing (backup cadence, RTO/RPO targets, failover time targets, drill schedules) as these are core DR plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ✅ Run comprehensive validation checks on the complete DR plan
- ⚠️ Present C/R menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: complete` before finishing
- 🚫 FORBIDDEN to finalize until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the validation results and finalize the disaster recovery plan
- **R (Revise)**: Discuss changes, address gaps, then re-present the menu

## CONTEXT BOUNDARIES:

- Complete disaster recovery document with all sections is available
- Service classification, RTO/RPO targets, backup strategy, and failover procedures are defined
- Focus on validation, gap analysis, and generating implementation sequence
- This is the final step — ensure the plan is actionable

## YOUR TASK:

Validate the complete disaster recovery plan for coverage, coherence, and actionability. Generate a prioritized implementation sequence and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate systematically:

**Gate 1: Service Classification Completeness**
- [ ] All services from architecture are classified into criticality tiers
- [ ] Tier assignments are justified by business impact analysis
- [ ] No services are missing from the classification
- [ ] Classification aligns with SLO targets (if observability plan exists)

**Gate 2: RTO/RPO Target Validity**
- [ ] RTO/RPO targets defined for every criticality tier
- [ ] Targets are achievable with the planned infrastructure
- [ ] Targets align with business requirements and SLAs
- [ ] Cost implications of targets are understood and accepted
- [ ] Recovery sequencing accounts for dependency chains

**Gate 3: Backup & Restore Coverage**
- [ ] Every data store has a defined backup procedure
- [ ] Backup frequency meets RPO targets for each tier
- [ ] Geographic replication strategy supports RTO targets
- [ ] Restore testing cadence is defined with success criteria
- [ ] Data protection policies cover encryption, compliance, and immutability

**Gate 4: Failover Procedure Completeness**
- [ ] Failover strategy defined for each criticality tier
- [ ] DR activation criteria are clear and unambiguous
- [ ] DR team roles and responsibilities are assigned
- [ ] DR runbook standard structure is documented
- [ ] Initial DR runbooks are identified with owners

**Gate 5: Communication Readiness**
- [ ] Internal communication plan covers all DR levels
- [ ] External communication plan addresses customer notifications
- [ ] Communication templates are ready for all phases (declaration, update, resolution)
- [ ] Status page integration is planned
- [ ] Communication cadence is defined per DR level

**Gate 6: Failback & Recovery Completeness**
- [ ] Failback prerequisites are documented
- [ ] Failback sequence is defined with gradual traffic shift
- [ ] Data reconciliation procedures address merge conflicts
- [ ] Post-DR review process is established

### 2. Cross-Workflow Coherence Validation

Check alignment with other completed workflow plans:

**If Observability Plan exists:**
- Do SLO targets align with RTO/RPO definitions?
- Are DR metrics monitored (replication lag, backup age, failover readiness)?
- Can observability tools detect DR trigger conditions?

**If Incident Response Plan exists:**
- Is DR activation distinct from incident escalation?
- Do communication procedures align (no conflicting templates)?
- Is the handoff from incident response to DR clearly defined?
- Do severity levels map to DR levels appropriately?

**If Infrastructure Plan exists:**
- Does the DR topology match the infrastructure architecture?
- Are DR regions consistent with infrastructure plans?
- Does the IaC support DR environment provisioning?

**If Pipeline Plan exists:**
- Can the CI/CD pipeline deploy to DR regions?
- Are deployment procedures consistent with DR recovery steps?
- Is rollback aligned with failback procedures?

### 3. Gap Analysis

Identify any missing elements:

**Critical Gaps** (block DR readiness):
- Services without recovery procedures
- RTO/RPO targets that cannot be met with current infrastructure
- Missing DR runbooks for Tier 1 services
- No restore testing schedule

**Important Gaps** (should be addressed soon):
- DR runbooks identified but not yet written
- Restore testing not yet performed
- Communication templates that need customization
- DR team roles assigned to positions but not specific people

**Enhancement Opportunities** (improve over time):
- Chaos engineering for DR validation
- Automated DR testing pipeline
- Cost optimization of DR infrastructure
- Multi-region active-active upgrade path

### 4. Present Validation Summary

Report the validation results to the user:

"I've completed a comprehensive validation of your Disaster Recovery Plan.

**Quality Gate Results:**

| Gate | Status | Notes |
|------|--------|-------|
| Service Classification | {PASS/FAIL} | {details} |
| RTO/RPO Targets | {PASS/FAIL} | {details} |
| Backup & Restore | {PASS/FAIL} | {details} |
| Failover Procedures | {PASS/FAIL} | {details} |
| Communication Readiness | {PASS/FAIL} | {details} |
| Failback & Recovery | {PASS/FAIL} | {details} |

{if_any_failures}
**Issues to Address:**
{list of failed gates with specific gaps}

Would you like to address these before finalizing?
{/if_any_failures}

{if_all_pass}
All quality gates passed. The disaster recovery plan is comprehensive and ready for implementation.
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
- Configure backup procedures for all Tier 1 data stores
- Set up geographic replication for Tier 1 services
- Create DR runbooks for Tier 1 services
- Establish DR communication channels and templates
- Configure DNS failover for Tier 1 services

**Priority 2 — Automation (implement second):**
- Automate failover detection and triggers for Tier 1
- Set up automated backup verification (daily)
- Configure replication lag monitoring and alerting
- Implement DR health check dashboard
- Automate Tier 2 backup procedures

**Priority 3 — Validation (implement third):**
- Conduct first point-in-time restore test
- Run first full-service restore drill
- Validate communication procedures with tabletop exercise
- Test DNS failover procedures
- Document findings and update procedures

**Priority 4 — Maturity (implement ongoing):**
- Schedule annual full DR drill
- Establish DR plan review cadence (quarterly)
- Implement chaos engineering for DR validation
- Optimize DR infrastructure costs
- Expand coverage to Tier 3 and Tier 4 services

### 7. Generate Validation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

| Gate | Status | Notes |
|------|--------|-------|
{{quality_gate_results}}

### DR Plan Completeness Checklist

**✅ Service Classification**

- [x] All services classified into criticality tiers
- [x] Business impact analysis completed
- [x] Dependency chains mapped

**✅ Recovery Objectives**

- [x] RTO/RPO targets defined per tier
- [x] Targets validated against infrastructure capabilities
- [x] Cost-risk trade-offs documented

**✅ Backup & Restore**

- [x] Backup procedures defined for all data stores
- [x] Geographic replication strategy designed
- [x] Restore testing cadence established
- [x] Data protection policies documented

**✅ Failover Procedures**

- [x] Failover strategy defined per tier
- [x] DR activation criteria and team roles documented
- [x] DR runbook standard and initial inventory created
- [x] Communication procedures for all phases

**✅ Failback & Recovery**

- [x] Failback prerequisites and sequence defined
- [x] Data reconciliation procedures established
- [x] Post-DR review process documented

## 10. Implementation Roadmap

| Milestone | Description | Owner | Target Date |
|-----------|-------------|-------|-------------|
{{implementation_sequence_entries}}

### Priority 1: Foundation

{{foundation_tasks}}

### Priority 2: Automation

{{automation_tasks}}

### Priority 3: Validation

{{validation_tasks}}

### Priority 4: Maturity

{{maturity_tasks}}

## 11. DR Plan Maintenance

### Review Cadence

- **Quarterly**: Review RTO/RPO targets against evolving business needs
- **After every DR event**: Update runbooks and procedures based on lessons learned
- **After architecture changes**: Validate service classification and recovery procedures
- **Annually**: Full DR plan review and update

### DR Drill Schedule

| Drill Type | Frequency | Scope | Next Scheduled |
|-----------|-----------|-------|----------------|
| Tabletop exercise | Quarterly | DR team walks through scenarios | |
| Backup restore test | Monthly | Tier 1 & 2 point-in-time restore | |
| Service failover test | Quarterly | Single Tier 1 service failover | |
| Full DR drill | Annually | Complete DR region activation | |
```

### 8. Save Final Document

- Append the validation and implementation content to `{bgr_artifacts}/disaster-recovery-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4, 5]`
  - `status: complete`
  - `lastUpdated: {{current_date}}`

### 9. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation and generated the implementation roadmap.

**Here's what I'll add to finalize the disaster recovery plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save and finalize the disaster recovery plan
[R] Revise - Let's address issues before finalizing"

### 10. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-run relevant quality gates
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Save the final content to `{bgr_artifacts}/disaster-recovery-plan.md`
- Update frontmatter to mark workflow as complete
- Present completion summary and next steps

### 11. Update Production Readiness Checklist

After saving the disaster recovery plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it in place with the minimum required structure for this workflow:
     - Frontmatter including:
       - `lastUpdated: {{current_date}}`
       - `completedWorkflows: []`
     - An `# Overview` section that includes the checklist `lastUpdated`
     - A `## Workflow Completion Status` table with a row for **Disaster Recovery Plan**
     - A disaster recovery plan detail section with fields for **Status**, **Completion Date**, and **Output Document**
     - A `### 4.3 Consistency Issues` section for cross-plan dependency findings
2. Update the **Disaster Recovery Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/disaster-recovery-plan.md`
3. Update the disaster recovery plan detail section with key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/disaster-recovery-plan.md`
   - DR topology chosen (active-active, active-passive, pilot light)
   - Number of criticality tiers and services per tier
   - RTO/RPO targets summary
   - Geographic replication approach
   - DR testing cadence
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps:
   - If Observability Plan exists: Verify DR monitoring metrics are defined, SLO targets align with RTO/RPO
   - If Incident Response Plan exists: Verify DR activation is distinct from incident escalation, communication procedures are consistent
   - If Infrastructure Plan exists: Verify DR topology matches infrastructure architecture, DR regions are consistent
   - If Pipeline Plan exists: Verify CI/CD can deploy to DR regions, rollback aligns with failback
   - Record any inconsistencies in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `disaster-recovery`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched environment topologies, missing rollback alignment, or undefined alerting-to-severity mappings).
7. Save the updated checklist

### 12. Completion Summary

After saving, present the final summary:

"The Disaster Recovery Plan for {{project_name}} is complete and saved to `{bgr_artifacts}/disaster-recovery-plan.md`.

**Summary:**
- {N} services classified across {N} criticality tiers
- RTO/RPO targets defined for every tier
- Backup and restore strategy with geographic replication
- Failover procedures with {N} DR runbooks identified
- Communication templates for all DR phases
- Failback procedures with data reconciliation
- Prioritized implementation roadmap with {N} milestones

**Recommended Next Steps:**
1. Implement Priority 1 foundation tasks (backup configuration, replication setup)
2. Write the initial DR runbooks identified in the plan
3. Schedule your first DR tabletop exercise
4. Configure DR monitoring metrics in your observability stack
5. Share this plan with the DR team and get feedback

**Related Workflows:**
- **Create Observability Plan (CO)** — Add DR-specific monitoring and alerting
- **Create Incident Response Plan (CR)** — Align incident escalation with DR activation
- **Return to agent menu** — Explore other capabilities

Thank you for building this plan together, {{user_name}}! A practiced disaster recovery plan is the difference between a business disruption and a business-ending event."

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All quality gates evaluated systematically
✅ Any failures identified and addressed with user
✅ Cross-workflow coherence validated
✅ Implementation sequence generated with clear priorities
✅ DR plan maintenance cadence established
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

This is the final step. After finalization, the disaster recovery workflow is complete. The user can invoke additional workflows or return to the agent menu.
