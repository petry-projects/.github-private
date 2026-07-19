# Step 4: Cost Governance

## MANDATORY EXECUTION RULES (READ FIRST):

- NEVER generate content without user input

- CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ALWAYS treat this as collaborative discovery between infrastructure peers
- YOU ARE A FACILITATOR, not a content generator
- FOCUS on cost allocation tagging standards, anomaly detection rules, budget alert configuration, and cost governance procedures
- ANALYZE optimization strategy from step 3 to inform governance decisions
- Do not estimate software delivery timelines or task durations — but do define operational timing (budget review cadence, anomaly detection windows, tag compliance audit frequency) as these are core cost optimization plan outputs
- YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- Present C/R menu after generating governance framework
- ONLY save when user chooses C (Continue)
- Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the governance framework, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with cost baseline and optimization strategy is available
- Input documents already loaded are in memory
- Focus on defining governance — tagging, budgets, anomaly detection, and operational procedures
- Build on the optimization decisions from step 3

## YOUR TASK:

Define cost allocation tagging standards, anomaly detection rules, budget alert configuration, chargeback/showback model, and cost governance procedures through structured discussion with the user.

## GOVERNANCE SEQUENCE:

### 1. Cost Allocation Tagging Standards

Define the tagging taxonomy for cost attribution:

**Required Tags:**

| Tag Key | Required | Values/Pattern | Purpose | Enforcement |
|---------|---------|---------------|---------|-------------|

**Standard tag categories to discuss:**

- **Environment**: production, staging, development, sandbox
- **Service/Application**: service name or identifier
- **Team/Owner**: responsible team or individual
- **Cost Center**: business unit or budget code
- **Project**: project identifier for project-based allocation
- **Lifecycle**: permanent, temporary, ephemeral (with expiry date)

**Tag Enforcement Strategy:**

- How to handle untagged resources (alert, auto-tag, prevent creation)
- Tag validation rules (naming conventions, allowed values)
- Compliance scanning cadence and reporting
- Exception process for resources that can't be tagged

Discuss with the user:

"Let's define your cost allocation tagging strategy. Key questions:

- What organizational dimensions matter for cost allocation? (team, project, cost center, etc.)
- Do you have existing tagging standards we should align with?
- How strict should enforcement be? (advisory, preventive, or remediation)
- Who is responsible for tag compliance?"

### 2. Cost Allocation Rules

Define how shared costs are allocated:

**Shared Resource Allocation:**

| Shared Resource | Allocation Method | Split Basis | Owner | Review Cadence |
|----------------|------------------|-----------|-------|---------------|

**Allocation Methods:**

- **Proportional**: Split based on usage metrics (requests, compute hours, storage)
- **Equal split**: Divide equally among consuming teams
- **Fixed allocation**: Pre-defined percentages based on agreements
- **Direct attribution**: Assign 100% to the primary consumer

**Chargeback/Showback Model:**

- **Showback**: Visibility into costs without billing (recommended for crawl phase)
- **Chargeback**: Actual cost allocation to team budgets (walk/run phase)

| Team/Service | Allocated Cost | Basis | Billing Cadence | Dashboard |
|-------------|---------------|-------|----------------|-----------|

### 3. Budget Definitions

Set up budget controls:

**Budget Structure:**

| Budget | Scope | Monthly Amount | Alert at 50% | Alert at 80% | Alert at 100% | Owner |
|--------|-------|--------------|-------------|-------------|--------------|-------|

**Budget Types to Consider:**

- **Account-level budget**: Overall cloud spend cap
- **Service-level budget**: Per-service or per-application budgets
- **Team-level budget**: Budget ownership by team
- **Environment-level budget**: Separate budgets for production vs non-production
- **Project-level budget**: Time-bound budgets for specific initiatives

**Budget Review Process:**

- Monthly budget review meetings with stakeholders
- Budget variance analysis and trend reporting
- Budget adjustment process for planned growth
- Emergency budget increase approval workflow

### 4. Anomaly Detection Rules

Define cost anomaly detection:

**Detection Rules:**

| Rule | Metric | Baseline | Threshold | Detection Window | Action | Owner |
|------|--------|---------|-----------|-----------------|--------|-------|

**Anomaly Types to Detect:**

- **Sudden spike**: Cost increase > X% within Y hours
- **Gradual drift**: Cost trending > X% above baseline over Z days
- **New resource**: Unexpected resource creation in monitored accounts
- **Unusual patterns**: Weekend/off-hours spending for business-hours workloads

**Alert Routing:**

| Alert Type | Channel | Escalation | Response SLA | Owner |
|-----------|---------|-----------|-------------|-------|

**Anomaly Response Procedures:**

| Severity | Criteria | Response Time | Investigation Steps | Escalation |
|----------|---------|--------------|-------------------|-----------|

**Integration with Incident Response:**

- If an Incident Response Plan exists, align cost anomaly severity with incident severity levels
- Define when a cost anomaly triggers an incident (e.g., suspected breach, runaway scaling)
- Establish runbook references for cost anomaly investigation

Discuss with the user:

"Let's set up your cost governance framework. Key questions:

- What budget granularity do you need? (account, service, team, project)
- Who should receive budget alerts and anomaly notifications?
- How quickly should cost anomalies be investigated? (minutes, hours, days)
- Do you want automated actions (e.g., auto-terminate untagged resources after X days)?
- Should cost anomalies trigger incidents in your incident response process?"

### 5. Tag Compliance Monitoring

Define ongoing tag compliance:

**Compliance Metrics:**

| Enforcement Level | Action | Timeline | Exception Process |
|------------------|--------|----------|-------------------|

**Compliance Targets:**

- Tag compliance rate target (e.g., > 95% of resources tagged)
- New resource tagging requirement (tag at creation or within X hours)
- Remediation timeline for untagged resources
- Escalation path for chronic non-compliance

**Compliance Reporting:**

- Dashboard showing tag compliance by team/service
- Weekly compliance report to team leads
- Monthly compliance trend to engineering leadership
- Quarterly compliance audit with remediation tracking

### 6. Generate Governance Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 5. Cost Allocation & Tagging Standards

### 5.1 Tagging Taxonomy

| Tag Key | Required | Values/Pattern | Purpose | Enforcement |
|---------|---------|---------------|---------|-------------|
{{tagging_taxonomy_entries}}

### 5.2 Cost Allocation Rules

| Shared Resource | Allocation Method | Split Basis | Owner | Review Cadence |
|----------------|------------------|-----------|-------|---------------|
{{allocation_rule_entries}}

### 5.3 Chargeback/Showback Model

**Model Type:** {{model_type}}

**Allocation Units:** {{allocation_units}}

| Team/Service | Allocated Cost | Basis | Billing Cadence | Dashboard |
|-------------|---------------|-------|----------------|-----------|
{{chargeback_entries}}

### 5.4 Tag Compliance

| Enforcement Level | Action | Timeline | Exception Process |
|------------------|--------|----------|-------------------|
{{tag_compliance_entries}}

## 6. Anomaly Detection & Budget Alerts

### 6.1 Budget Definitions

| Budget | Scope | Monthly Amount | Alert at 50% | Alert at 80% | Alert at 100% | Owner |
|--------|-------|--------------|-------------|-------------|--------------|-------|
{{budget_entries}}

### 6.2 Anomaly Detection Rules

| Rule | Metric | Baseline | Threshold | Detection Window | Action | Owner |
|------|--------|---------|-----------|-----------------|--------|-------|
{{anomaly_rule_entries}}

### 6.3 Alert Routing

| Alert Type | Channel | Escalation | Response SLA | Owner |
|-----------|---------|-----------|-------------|-------|
{{alert_routing_entries}}

### 6.4 Cost Anomaly Response Procedures

| Severity | Criteria | Response Time | Investigation Steps | Escalation |
|----------|---------|--------------|-------------------|-----------|
{{anomaly_response_entries}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Cost Governance framework including tagging standards, budget controls, and anomaly detection.

**Here's what I'll add to the cost optimization plan:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this governance framework and proceed to validation
[R] Revise - Let's adjust specific sections before continuing"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Tagging Standards / Cost Allocation / Budgets / Anomaly Detection / Alert Routing)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to C/R menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/cost-optimization-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ Tagging taxonomy defined with enforcement strategy
✅ Cost allocation rules defined for shared resources
✅ Chargeback/showback model selected and configured
✅ Budget definitions set with alert thresholds and owners
✅ Anomaly detection rules defined with response procedures
✅ Alert routing configured with escalation paths
✅ Tag compliance monitoring established
✅ User confirmed all governance decisions through discussion
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining governance without considering the optimization strategy from step 3
❌ Not establishing tagging standards or enforcement mechanisms
❌ Missing budget definitions or alert thresholds
❌ Not defining anomaly detection rules or response procedures
❌ Setting governance policies without discussing with user
❌ Not integrating with existing incident response procedures
❌ Generating content without real discussion with user
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate the plan, generate implementation roadmap, and update the production readiness checklist.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the C/R menu and content is saved!
