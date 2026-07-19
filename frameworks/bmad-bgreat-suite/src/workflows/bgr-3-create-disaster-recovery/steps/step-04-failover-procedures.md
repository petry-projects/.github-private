# Step 4: Failover Procedures & DR Runbooks

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on designing failover strategies, DR runbooks, and communication procedures
- 🎯 BUILD on the RTO/RPO targets and backup strategy from steps 2-3
- ⚠️ Do not estimate software delivery timelines or task durations — but do define DR operational timing (backup cadence, RTO/RPO targets, failover time targets, drill schedules) as these are core DR plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating failover procedures
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the procedures, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with service classification, RTO/RPO targets, and backup strategy is available
- Infrastructure topology and cloud provider details are loaded
- Incident response procedures (if available) inform communication during DR events
- Focus on operational procedures: how to execute failover and how to communicate during DR events

## YOUR TASK:

Design geographic failover strategies, create DR runbook templates, define communication procedures during DR events, and establish failback procedures for returning to normal operations.

## FAILOVER PROCEDURES SEQUENCE:

### 1. Define Failover Strategies per Tier

Based on RTO targets and infrastructure topology:

**Tier 1 — Automated Hot Failover:**
- Active-active or active-passive with automated detection
- Failover trigger: Health check failures across multiple monitors
- DNS failover with low TTL (30-60 seconds)
- Connection draining and session handling
- Data consistency validation during failover
- Estimated failover time: < 5 minutes (automated)

**Tier 2 — Semi-Automated Warm Failover:**
- Standby environment with recent data replication
- Failover trigger: Manual declaration after automated detection
- DNS update with pre-configured failover records
- Application startup and health verification
- Data reconciliation for replication lag
- Estimated failover time: 15-60 minutes

**Tier 3 — Manual Cold Recovery:**
- Restore from backups to standby infrastructure
- Failover trigger: Manual decision after impact assessment
- Infrastructure provisioning (from IaC templates)
- Data restore from most recent backup
- Application deployment and configuration
- Estimated recovery time: 2-4 hours

**Tier 4 — Restore from Backup:**
- Restore from daily backups when convenient
- No standby infrastructure maintained
- Provision on-demand infrastructure
- Restore data and redeploy applications
- Estimated recovery time: 8-24 hours

### 2. Create DR Declaration and Activation Procedures

**DR Event Classification:**

| DR Level | Criteria | Activation Authority | Response |
|----------|----------|---------------------|----------|
| DR-1 (Full) | Complete region failure, data center loss | VP Engineering / CTO | Full regional failover |
| DR-2 (Partial) | Multiple service failures, AZ loss | Engineering Manager | Partial failover, service-level recovery |
| DR-3 (Service) | Single critical service failure beyond incident response | On-call Lead | Service-specific DR procedures |

**DR Declaration Checklist:**
1. Confirm the failure is beyond normal incident response capability
2. Assess scope: Which services and tiers are affected?
3. Notify DR coordinator and assemble DR team
4. Declare DR level based on classification criteria
5. Activate appropriate failover procedures
6. Begin communication protocol

**DR Team Roles:**

| Role | Responsibility | Activation |
|------|---------------|------------|
| DR Coordinator | Overall DR execution, decision authority | All DR levels |
| Infrastructure Lead | Failover execution, DNS, networking | DR-1, DR-2 |
| Data Recovery Lead | Backup restore, data validation, consistency | All DR levels |
| Application Lead | Service deployment, health verification | All DR levels |
| Communications Lead | Internal/external status updates | DR-1, DR-2 |
| Security Lead | Access control, audit logging during DR | DR-1 |

### 3. Design DR Runbook Templates

Create standardized DR runbook structure:

**DR Runbook Standard Structure:**

```text
# DR Runbook: {Service/Scenario Name}

## Summary
- **DR Level**: DR-1 / DR-2 / DR-3
- **Affected Services**: {list}
- **RTO Target**: {from step 2}
- **RPO Target**: {from step 2}
- **Last Tested**: {date}
- **Owner**: {team/person}

## Pre-Conditions
- {what must be true before executing this runbook}
- {required access, tools, credentials}

## Failover Procedure
1. {step-by-step failover instructions}
2. {include exact commands where possible}
3. {decision points clearly marked}

## Validation Checks
- [ ] {check 1: e.g., DNS resolves to DR region}
- [ ] {check 2: e.g., Database replication caught up}
- [ ] {check 3: e.g., Health endpoints returning 200}
- [ ] {check 4: e.g., Sample transactions succeeding}

## Rollback / Failback
- {how to revert if failover fails}
- {how to return to primary when ready}

## Communication Triggers
- {when to send which notification}
- {status page update instructions}

## Post-DR Actions
- [ ] Document timeline and decisions
- [ ] Verify data consistency
- [ ] Update DR test results
- [ ] Schedule postmortem
```

**Initial DR Runbooks to Create:**

Based on the architecture and service classification, identify the minimum set of DR runbooks needed:

- Regional failover runbook (DR-1)
- Database failover runbook (per Tier 1 database)
- Application failover runbook (per Tier 1 service)
- DNS failover runbook
- Data reconciliation runbook

### 4. Define Communication Procedures During DR Events

**Internal Communication:**

| Phase | Audience | Channel | Frequency | Template |
|-------|----------|---------|-----------|----------|
| Declaration | Engineering + Leadership | Slack #dr-events + PagerDuty | Immediate | DR Declaration |
| In-Progress | Engineering | Slack #dr-events | Every 15 min | DR Status Update |
| Resolution | All Staff | Email + Slack | Once | DR Resolution |

**External Communication:**

| Phase | Audience | Channel | Frequency | Template |
|-------|----------|---------|-----------|----------|
| Awareness | Customers | Status Page | Within 10 min of declaration | Customer Impact Notice |
| Updates | Customers | Status Page + Email | Every 30 min | Customer Status Update |
| Resolution | Customers | Status Page + Email + Blog | Once | Customer Resolution |

**Communication Templates:**

**DR Declaration Template:**
> **[DR-{level}] Disaster Recovery Activated — {brief description}**
>
> **Time**: {timestamp}
> **Impact**: {affected services and customer impact}
> **DR Coordinator**: {name}
> **Status**: Failover in progress
> **Next update**: {time}

**DR Status Update Template:**
> **[UPDATE {N}] [DR-{level}] {brief description}**
>
> **Status**: {current phase}
> **Progress**: {what has been completed}
> **Remaining**: {what is still in progress}
> **Data Status**: {replication/restore status}
> **Next update**: {time}

**DR Resolution Template:**
> **[RESOLVED] [DR-{level}] {brief description}**
>
> **Duration**: {start} to {end} ({total})
> **Impact**: {summary of customer impact}
> **Data Loss**: {actual data loss vs RPO target}
> **Recovery Time**: {actual recovery time vs RTO target}
> **Postmortem**: Scheduled for {date}

### 5. Design Failback Procedures

Define how to return to normal operations after DR:

**Failback Prerequisites:**
- Root cause of original failure identified and resolved
- Primary region infrastructure verified healthy
- Data consistency between DR and primary validated
- Failback window approved by leadership
- Communication plan for failback prepared

**Failback Sequence:**
1. Verify primary region health (infrastructure, networking, DNS)
2. Sync data from DR region back to primary (resolve conflicts)
3. Validate data integrity in primary (checksums, application validation)
4. Shift traffic gradually (canary: 5% -> 25% -> 50% -> 100%)
5. Monitor for issues at each traffic percentage
6. Confirm full failback and deactivate DR mode
7. Update status page and notify stakeholders
8. Document failback timeline and any issues

**Data Reconciliation:**
- Identify writes that occurred only in DR region during failover
- Merge strategy: Last-writer-wins, application-level merge, manual review
- Conflict resolution procedures for critical data
- Verification queries to confirm data completeness

### 6. Present Procedures

Reflect the failover procedures back to the user:

"Here's the Failover & DR Runbook framework for {{project_name}}.

**Failover Strategies:**
- Tier 1: Automated hot failover (< 5 min)
- Tier 2: Semi-automated warm failover (15-60 min)
- Tier 3: Manual cold recovery (2-4 hours)
- Tier 4: Restore from backup (8-24 hours)

**DR Activation:**
- 3 DR levels defined with clear criteria
- DR team roles and responsibilities documented
- Declaration checklist ready

**DR Runbooks:**
- Standard runbook template created
- {count} initial runbooks identified
- Runbook maintenance process defined

**Communication:**
- Internal and external communication plans
- Templates for declaration, updates, and resolution
- Status page integration defined

**Failback:**
- Prerequisites, sequence, and data reconciliation defined
- Gradual traffic shift approach

Does this framework cover your DR operational needs? Anything to adjust?"

### 7. Generate Failover Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 5. Failover Strategies

### Failover Approach by Tier

| Tier | Strategy | Trigger | Automation Level | Target Time |
|------|----------|---------|-----------------|-------------|
{{failover_strategy_per_tier}}

### Detailed Failover Procedures

#### Tier 1 — Automated Hot Failover
{{tier_1_failover_details}}

#### Tier 2 — Semi-Automated Warm Failover
{{tier_2_failover_details}}

#### Tier 3 — Manual Cold Recovery
{{tier_3_failover_details}}

#### Tier 4 — Restore from Backup
{{tier_4_failover_details}}

## 6. DR Activation Procedures

### DR Event Classification

| DR Level | Criteria | Activation Authority | Response |
|----------|----------|---------------------|----------|
{{dr_level_classification}}

### DR Declaration Checklist

{{dr_declaration_checklist}}

### DR Team Roles

| Role | Responsibility | Activation |
|------|---------------|------------|
{{dr_team_roles}}

## 7. DR Runbooks

### Runbook Standard Structure

{{runbook_template_structure}}

### Required DR Runbooks

| Runbook | Scope | DR Level | Owner | Last Tested |
|---------|-------|----------|-------|-------------|
{{required_runbooks_inventory}}

## 8. Communication During DR Events

### Internal Communication Plan

{{internal_communication_plan}}

### External Communication Plan

{{external_communication_plan}}

### Communication Templates

{{dr_communication_templates}}

## 9. Failback Procedures

### Failback Prerequisites

{{failback_prerequisites}}

### Failback Sequence

{{failback_step_by_step}}

### Data Reconciliation

{{data_reconciliation_procedures}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Failover Procedures covering DR activation, runbooks, communication, and failback.

**Here's what I'll add to the disaster recovery plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save these procedures and proceed to validation
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/disaster-recovery-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Failover strategies defined per tier aligned with RTO targets
✅ DR activation criteria and team roles documented
✅ DR runbook standard structure established
✅ Initial DR runbooks identified with owners
✅ Communication procedures defined for internal and external audiences
✅ Communication templates ready for DR events
✅ Failback procedures defined with data reconciliation
✅ User confirmation of procedures
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Designing failover without aligning to RTO targets from step 2
❌ Not defining DR activation criteria and authority levels
❌ Missing communication procedures for DR events
❌ Not planning for failback and data reconciliation
❌ Creating runbooks without standard structure
❌ Not validating procedures with user
❌ Generating content without building on steps 2-3

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate completeness and finalize the disaster recovery plan.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the C/R menu and content is saved!
