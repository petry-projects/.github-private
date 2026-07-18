# Step 4: SLO & Alerting Framework

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on defining reliability targets and alerting strategy
- 🎯 BUILD on the instrumentation design from step 3
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating SLO and alerting framework
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the framework, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with Current State Assessment and Instrumentation Strategy is available
- Metrics taxonomy and logging/tracing standards are defined
- Focus on turning instrumentation into actionable reliability targets and alerts
- This is where observability becomes operational

## YOUR TASK:

Define SLOs with error budgets, design multi-window multi-burn-rate alerting tied to SLOs, establish alert routing and escalation, and specify dashboard requirements for all audiences.

## SLO & ALERTING FRAMEWORK SEQUENCE:

### 1. Identify Critical User Journeys

Work with the user to map the most important paths through the system:

- What are the top 3-5 user journeys that define system health?
- Which journeys directly impact revenue or core business value?
- Which journeys have the strictest performance expectations?
- Are there internal journeys (batch jobs, data pipelines) that are critical?

For each journey, document:
- Journey name and description
- Services involved in the journey
- Expected traffic patterns (steady, bursty, time-of-day)
- Business impact if degraded or unavailable

### 2. Define SLIs per Journey

For each critical user journey, map Service Level Indicators:

**Availability SLI:**
- Measurement: Ratio of successful requests to total requests
- Exclusions: Planned maintenance windows, client errors (4xx)
- Collection point: Load balancer, API gateway, or application metrics

**Latency SLI:**
- Measurement: Response time at p50, p95, p99 percentiles
- Meaningful thresholds per journey (e.g., checkout < 2s at p95)
- Collection point: Client-side, server-side, or both

**Error Rate SLI:**
- Measurement: Ratio of error responses to total responses
- Error classification: Server errors only, or include specific client errors
- Exclude known non-errors (e.g., 404 on search)

**Throughput SLI:**
- Measurement: Requests per second, transactions per minute
- Baseline and expected growth
- Peak vs steady-state thresholds

### 3. Set SLO Targets

For each SLI, establish targets collaboratively:

**Target Setting Guidelines:**
- Start with what users actually experience today (baseline)
- Set targets slightly above current performance (aspirational but achievable)
- Consider business context: 99.9% vs 99.99% — what does the extra nine cost?
- Align with any existing SLA commitments (SLO should be stricter than SLA)

**Error Budget Calculation:**
- Window: 30-day rolling
- Budget = 1 - SLO target (e.g., 99.9% SLO = 0.1% error budget = ~43 minutes/month)
- Budget consumption tracking: real-time dashboard
- Budget exhaustion policy: What happens when budget is spent?

**Error Budget Policy:**
Discuss and define with the user:
- **Budget healthy (>50% remaining)**: Normal feature velocity
- **Budget warning (25-50% remaining)**: Increased review rigor, prioritize reliability fixes
- **Budget critical (<25% remaining)**: Freeze non-critical changes, focus on reliability
- **Budget exhausted (0%)**: Feature freeze until reliability improves

### 4. Design Alerting Strategy

Build alerts tied to SLO burn rates, not raw thresholds:

**Multi-Window Multi-Burn-Rate Alerts:**

For each SLO, define burn rate alerts:

| Alert | Burn Rate | Short Window | Long Window | Severity | Action |
|-------|-----------|-------------|-------------|----------|--------|
| Page | 14.4x | 1h | 5m | Critical | Wake on-call |
| Page | 6x | 6h | 30m | High | Interrupt on-call |
| Ticket | 3x | 1d | 2h | Medium | Create ticket |
| Ticket | 1x | 3d | 6h | Low | Review next business day |

**Alert Content Requirements:**
Every alert must include:
- **Summary**: One-line description of what is happening
- **Impact**: Who is affected and how
- **Hypothesis**: Most likely cause based on context
- **Runbook link**: Direct link to the response procedure
- **Dashboard link**: Direct link to the relevant triage dashboard
- **SLO context**: Current error budget consumption percentage

### 5. Define Alert Routing

Map alerts to the right people at the right time:

**Severity Definitions:**

| Severity | Definition | Response Time | Channel | Escalation |
|----------|------------|---------------|---------|------------|
| Critical (P1) | Customer-impacting outage | Immediate (<5 min) | PagerDuty/phone | Auto-escalate after 15 min |
| High (P2) | Degraded experience, partial outage | <15 min | PagerDuty/Slack | Auto-escalate after 30 min |
| Medium (P3) | Non-critical degradation | <1 hour | Slack channel | Review in standup |
| Low (P4) | Informational, minor issue | Next business day | Ticket/email | No escalation |

**Escalation Paths:**
- Primary on-call -> Secondary on-call -> Engineering manager -> VP Engineering
- Define maximum time at each escalation level
- Include executive notification criteria (P1 lasting >30 min)

**Runbook Requirements:**
Each alert must have a linked runbook containing:
- Summary: What this alert means, impact, detection method, owner
- Immediate actions: First 5 minutes
- Diagnostics: What to check and where
- Mitigations: How to stop the bleeding
- Verification: How to confirm the issue is resolved
- Postmortem trigger: When to initiate a postmortem

### 6. Design Dashboard Requirements

Define dashboards for each audience:

**Executive Dashboard:**
- Business KPIs: Revenue metrics, conversion rates, active users
- SLO status: Green/yellow/red per critical journey
- Error budget consumption: Visual burn-down
- Incident summary: Active incidents, recent postmortems
- Refresh: Every 5 minutes

**Engineering Dashboard:**
- Golden Signals: Latency, traffic, errors, saturation per service
- Deployment markers: Correlate changes with metric shifts
- Dependency health: External service status
- Resource utilization: CPU, memory, disk, network trends
- Refresh: Every 1 minute

**On-Call Triage Dashboard:**
- Active alerts: Sorted by severity
- Error budget status: Real-time burn rate
- Recent changes: Deployments, config changes, scaling events
- Quick links: Runbooks, escalation contacts, incident channel
- Refresh: Every 30 seconds

### 7. Define Noise Reduction Strategy

Minimize alert fatigue:

- **Grouping**: Combine related alerts into a single notification (e.g., all pods in a service)
- **Suppression**: Suppress downstream alerts when upstream root cause is detected
- **Deduplication**: Prevent repeated notifications for the same ongoing issue
- **Maintenance windows**: Silence alerts during planned maintenance
- **Flap detection**: Suppress alerts that oscillate between firing and resolved
- **Alert review cadence**: Monthly review of alert quality (fire rate, action rate, noise rate)

### 8. Present Framework

Reflect the SLO and alerting framework back to the user:

"Here's the SLO & Alerting Framework I've drafted for {{project_name}}.

**SLOs Defined:**
- {N} critical user journeys identified
- SLIs: Availability, latency (p50/p95/p99), error rate, throughput
- Error budget window: 30-day rolling
- Error budget policy: Defined with escalating responses

**Alerting Strategy:**
- Multi-window multi-burn-rate alerts tied to SLOs
- {N} alert rules across 4 severity levels
- Every alert includes: summary, impact, hypothesis, runbook link

**Alert Routing:**
- Severity -> Channel -> Escalation path defined
- Runbook requirements standardized

**Dashboards:**
- Executive: Business KPIs + SLO status
- Engineering: Golden Signals + deployments
- On-Call: Active alerts + triage tools

**Noise Reduction:**
- Grouping, suppression, deduplication, maintenance windows

Does this framework cover your reliability needs? Anything to adjust?"

### 9. Generate SLO & Alerting Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 6. SLOs & Error Budgets

| User Journey | SLI | Target | Window | Alert Threshold | Notes |
|-------------|-----|--------|--------|-----------------|-------|
{{slo_table_entries}}

### Error Budget Policy

{{error_budget_policy_definitions}}

## 7. Alerting Strategy

| Alert Name | Trigger | Severity | Channel | Runbook | Notes |
|-----------|---------|----------|---------|---------|-------|
{{alert_table_entries}}

### 7.1 Alert Routing & Escalation

| Severity | Definition | Response Time | Channel | Escalation |
|----------|------------|---------------|---------|------------|
{{severity_routing_table}}

### Escalation Paths

{{escalation_chain_definitions}}

### Runbook Standards

{{runbook_content_requirements}}

### 7.2 Noise Reduction

{{noise_reduction_strategies}}

## 8. Dashboard Requirements

| Dashboard | Audience | Key Metrics | Refresh | Owner |
|-----------|----------|-------------|---------|-------|
{{dashboard_table_entries}}

### Executive Dashboard

{{executive_dashboard_details}}

### Engineering Dashboard

{{engineering_dashboard_details}}

### On-Call Triage Dashboard

{{oncall_dashboard_details}}
```

### 10. Present Content and Menu

Show the generated content and present choices:

"I've drafted the SLO & Alerting Framework covering reliability targets, burn-rate alerts, routing, and dashboards.

**Here's what I'll add to the observability plan:**

[Show the complete markdown content from step 9]

**What would you like to do?**
[C] Continue - Save this framework and proceed to validation
[R] Revise - Let's discuss changes before saving"

### 11. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/observability.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 9.

## SUCCESS METRICS:

✅ Critical user journeys identified and mapped to services
✅ SLIs defined per journey with clear measurement methods
✅ SLO targets set with error budget windows and policies
✅ Multi-window multi-burn-rate alerts designed for each SLO
✅ Alert routing and escalation paths fully defined
✅ Runbook standards established with required content
✅ Dashboard requirements specified for all three audiences
✅ Noise reduction strategy defined
✅ User confirmation of SLO and alerting framework
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Setting SLO targets without understanding current performance
❌ Using raw threshold alerts instead of burn-rate alerts
❌ Not defining error budget policy with escalating responses
❌ Missing runbook requirements for alerts
❌ Not addressing alert noise and fatigue
❌ Designing dashboards without considering audience needs
❌ Not validating framework with user

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate completeness and finalize the observability plan.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the C/R menu and content is saved!
