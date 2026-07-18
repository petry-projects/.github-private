# Step 2: RTO/RPO Analysis & Service Criticality Classification

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on defining recovery targets and classifying service criticality
- 🎯 ANALYZE loaded documents, don't assume or generate requirements
- ⚠️ Do not estimate software delivery timelines or task durations — but do define DR operational timing (backup cadence, RTO/RPO targets, failover time targets, drill schedules) as these are core DR plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating RTO/RPO analysis
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the analysis, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, infrastructure, observability, incident response, etc.)
- Focus on defining recovery objectives and classifying services by criticality
- No implementation decisions yet - pure analysis and target-setting phase

## YOUR TASK:

Define Recovery Time Objectives (RTO) and Recovery Point Objectives (RPO) per service tier, classify services by business criticality, and map dependencies that affect recovery sequencing.

## RTO/RPO ANALYSIS SEQUENCE:

### 1. Identify All Services and Components

**From Architecture Document:**

- Extract all services, databases, message queues, and external dependencies
- Identify data stores and their types (relational, document, cache, object storage)
- Map service-to-service dependencies and communication patterns
- Note stateful vs stateless components

**From Infrastructure Document (if available):**

- Identify deployment regions and availability zones
- Note existing redundancy (multi-AZ, multi-region)
- Extract storage backends and replication configurations
- Identify network topology and cross-region connectivity

**From Observability Plan (if available):**

- Extract SLO targets — these inform acceptable recovery times
- Note SLI definitions that can validate recovery success
- Identify critical user journeys that must recover first

**From Incident Response Plan (if available):**

- Extract severity classification — align DR tiers with incident severity levels
- Note communication procedures that apply during DR events
- Identify escalation paths that activate during DR scenarios

### 2. Define Service Criticality Tiers

Work with the user to classify every service into tiers:

**Tier 1 — Mission Critical:**
- Direct revenue impact if unavailable
- Customer-facing with no acceptable downtime
- Data loss would cause regulatory or legal consequences
- Examples: Payment processing, authentication, core API

**Tier 2 — Business Critical:**
- Significant business impact if unavailable for extended periods
- Customer-visible degradation but not complete outage
- Data loss would require significant manual recovery effort
- Examples: Order management, notification service, search

**Tier 3 — Business Important:**
- Operational impact but business can function without temporarily
- Internal-facing or asynchronous workloads
- Data can be reconstructed from other sources if needed
- Examples: Analytics pipeline, reporting, admin tools

**Tier 4 — Non-Critical:**
- Minimal business impact if unavailable
- Can tolerate extended outages without customer impact
- Examples: Development tools, internal dashboards, batch jobs

Present the classification for user review and adjustment.

### 3. Define RTO/RPO Targets per Tier

For each tier, collaboratively define:

**Recovery Time Objective (RTO):**
- Maximum acceptable time from disaster declaration to service restoration
- Consider: automated failover time, manual intervention time, validation time
- Align with SLO error budgets where available

**Recovery Point Objective (RPO):**
- Maximum acceptable data loss measured in time
- Consider: replication lag, backup frequency, transaction volume
- Align with data criticality and compliance requirements

**Suggested Starting Points (discuss with user):**

| Tier | RTO | RPO | Rationale |
|------|-----|-----|-----------|
| Tier 1 — Mission Critical | < 15 minutes | < 1 minute | Automated failover, synchronous replication |
| Tier 2 — Business Critical | < 1 hour | < 15 minutes | Automated failover with manual validation |
| Tier 3 — Business Important | < 4 hours | < 1 hour | Manual recovery from recent backups |
| Tier 4 — Non-Critical | < 24 hours | < 24 hours | Restore from daily backups |

These are starting points for discussion — adjust based on business context, technical constraints, and cost trade-offs.

### 4. Map Dependency Chains for Recovery Sequencing

For each Tier 1 and Tier 2 service, map:

- **Upstream dependencies**: What must be running before this service can start?
- **Downstream dependents**: What breaks if this service is down?
- **Data dependencies**: What data stores must be recovered first?
- **External dependencies**: Third-party services that affect recovery
- **Recovery sequence**: Ordered list of services to bring up

Create a dependency graph showing recovery order:
- Level 0: Infrastructure (DNS, load balancers, networking)
- Level 1: Data stores (databases, caches, queues)
- Level 2: Core services (authentication, core API)
- Level 3: Dependent services (business logic services)
- Level 4: Edge services (frontend, CDN, monitoring)

### 5. Assess Cost-Risk Trade-offs

For each tier, discuss the cost implications:

- **Tier 1 targets** require: Multi-region active-active or active-passive, synchronous replication, automated failover — highest cost
- **Tier 2 targets** require: Multi-AZ with cross-region standby, asynchronous replication, semi-automated failover — moderate cost
- **Tier 3 targets** require: Regular backups with tested restore procedures — lower cost
- **Tier 4 targets** require: Daily backups with standard restore — minimal cost

Help the user understand the cost curve: each additional nine of availability roughly doubles cost.

### 6. Present Findings

Reflect your analysis back to the user:

"Here's the RTO/RPO analysis for {{project_name}}.

**Service Classification:**
- Tier 1 (Mission Critical): {count} services
- Tier 2 (Business Critical): {count} services
- Tier 3 (Business Important): {count} services
- Tier 4 (Non-Critical): {count} services

**Recovery Targets:**
{RTO/RPO table from step 2}

**Dependency Analysis:**
- {count} dependency chains mapped
- Critical path: {longest recovery chain}
- Key bottlenecks: {services that block the most dependents}

**Cost Implications:**
{summary of cost-risk trade-offs per tier}

Does this classification and these targets match your business priorities? Anything to adjust?"

### 7. Generate RTO/RPO Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Service Criticality Classification

### Criticality Tiers

| Service | Tier | Business Impact | Data Sensitivity | Dependencies |
|---------|------|-----------------|------------------|--------------|
{{service_classification_entries}}

### Tier Definitions

**Tier 1 — Mission Critical**
{{tier_1_criteria_and_services}}

**Tier 2 — Business Critical**
{{tier_2_criteria_and_services}}

**Tier 3 — Business Important**
{{tier_3_criteria_and_services}}

**Tier 4 — Non-Critical**
{{tier_4_criteria_and_services}}

## 3. Recovery Objectives

### RTO/RPO Targets

| Tier | RTO | RPO | Recovery Method | Validation Criteria |
|------|-----|-----|-----------------|---------------------|
{{rto_rpo_targets_per_tier}}

### Recovery Sequencing

{{dependency_chain_analysis}}

#### Recovery Order

| Level | Components | Dependencies | Estimated Recovery Time |
|-------|-----------|-------------|------------------------|
{{recovery_sequence_entries}}

### Cost-Risk Assessment

| Tier | DR Strategy | Infrastructure Required | Relative Cost |
|------|-------------|----------------------|---------------|
{{cost_risk_assessment_entries}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the RTO/RPO Analysis and Service Criticality Classification.

**Here's what I'll add to the disaster recovery plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this analysis and proceed to backup and restore strategy
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/disaster-recovery-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-backup-restore-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All services and components identified from loaded documents
✅ Services classified into criticality tiers with clear criteria
✅ RTO/RPO targets defined per tier with measurable objectives
✅ Dependency chains mapped for recovery sequencing
✅ Cost-risk trade-offs discussed and documented
✅ Recovery order established based on dependencies
✅ User confirmation of classification and targets
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Classifying services without understanding business impact
❌ Setting RTO/RPO targets without considering technical constraints
❌ Not mapping dependency chains for recovery sequencing
❌ Not discussing cost implications of recovery targets
❌ Not validating classification with user
❌ Generating content without real analysis of loaded documents
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-backup-restore-strategy.md` to define backup procedures, restore testing, and data protection policies.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the C/R menu and content is saved!
