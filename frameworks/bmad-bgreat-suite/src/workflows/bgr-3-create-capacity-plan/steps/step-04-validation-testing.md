# Step 4: Validation & Load Testing

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on load testing procedures, capacity validation, reserved capacity planning, and cost optimization
- 🎯 ANALYZE scaling strategy from step 3 to inform validation approach
- ⚠️ Do not estimate software delivery timelines or task durations — but do define operational timing (scaling response times, load test cadence, review schedules) as these are core capacity plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating validation and testing plan
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to final validation
- **R (Revise)**: Discuss changes, refine the testing plan, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with growth model (step 2) and scaling strategy (step 3) is available
- Input documents already loaded are in memory
- Focus on defining how to validate capacity assumptions through testing
- Build on the scaling policies and cost model from step 3

## YOUR TASK:

Define load testing procedures, capacity validation methodology, testing cadence, and ongoing capacity review processes that ensure the scaling strategy performs as designed.

## VALIDATION & TESTING SEQUENCE:

### 1. Load Testing Strategy

Determine the load testing approach:

**Test Types:**

- **Baseline test**: Validate current capacity under normal load
- **Stress test**: Find breaking points by increasing load beyond expected peaks
- **Spike test**: Simulate sudden traffic surges to validate auto-scaling response
- **Soak test**: Extended duration test to find memory leaks, connection exhaustion, and gradual degradation
- **Capacity test**: Validate specific capacity targets from the growth model (6-month and 12-month projections)

**Tool Selection:**

Discuss with the user:

"For load testing, let's pick the right tools. Common options:

| Tool | Strengths | Best For |
|------|----------|---------|
| k6 | Developer-friendly, JavaScript scripting, CI/CD integration | API load testing, developer-driven |
| Locust | Python-based, distributed, flexible | Complex user scenarios |
| Gatling | Scala/Java, detailed reports, CI integration | High-throughput API testing |
| JMeter | GUI + CLI, protocol variety, mature | Legacy systems, complex protocols |
| Artillery | YAML config, serverless-friendly, lightweight | Quick tests, serverless architectures |
| Cloud-native (AWS/GCP) | Managed, scalable, region-specific | Testing from specific geographies |

What does your team use today? Any preferences or constraints?"

### 2. Test Scenarios

Define specific test scenarios tied to the growth model:

**Scenario Design:**

| Scenario | Test Type | Target Load | Duration | Success Criteria | Priority |
|----------|----------|------------|----------|-----------------|----------|

**Key Scenarios to Cover:**

- Normal business day traffic pattern (baseline validation)
- Peak hour traffic at current capacity
- 6-month projected peak traffic
- 12-month projected peak traffic
- Seasonal event peak (maximum projected multiplier)
- Auto-scaling trigger validation (scale-out and scale-in)
- Database scaling limits (connection pool exhaustion, query latency degradation)
- Cascading failure resilience (single service overload impact on dependencies)

**For Each Scenario Define:**
- Traffic shape (ramp-up, steady, spike pattern)
- Expected resource consumption
- Auto-scaling behavior expected
- Pass/fail criteria tied to SLOs

### 3. Testing Environment

Define where and how to run load tests:

**Environment Strategy:**

- **Production-like environment**: Dedicated load test environment matching production topology (preferred for capacity validation)
- **Production with safeguards**: Canary-style load testing against production with kill switch
- **Scaled-down environment**: Cost-effective but requires extrapolation (risks inaccuracy)

**Data Requirements:**

- Test data generation strategy (synthetic vs anonymized production data)
- Data volume requirements to simulate realistic conditions
- Database seeding procedures

**Isolation Requirements:**

- Network isolation from production traffic
- Separate monitoring dashboards for test traffic
- Cost isolation (separate cloud accounts or cost tags)

### 4. Testing Cadence

Define the ongoing testing schedule:

**Recurring Tests:**

| Test | Frequency | Scope | Owner | Trigger |
|------|-----------|-------|-------|---------|
| Baseline validation | Monthly | Core services | | Scheduled |
| Capacity projection | Quarterly | All services | | Scheduled |
| Auto-scaling validation | Monthly | Auto-scaled services | | Scheduled |
| Stress test | Quarterly | Full system | | Scheduled |
| Pre-event capacity test | Event-driven | Event-impacted services | | Before planned events |

**Trigger-Based Tests:**

- After significant architecture changes
- Before planned marketing events or launches
- After auto-scaling policy changes
- When utilization exceeds 70% of capacity

### 5. Capacity Validation Procedures

Define how to validate that capacity meets requirements:

**Validation Checklist:**

- [ ] Each service handles projected 6-month peak within SLO targets
- [ ] Auto-scaling triggers fire within expected response time
- [ ] Scale-out achieves target capacity within defined timeframe
- [ ] Scale-in returns to baseline without oscillation
- [ ] Database handles projected query load without latency degradation
- [ ] Network bandwidth supports projected traffic without saturation
- [ ] Cost stays within guardrails during scaling events

**Reporting:**

- Load test results report template
- Capacity trend dashboard requirements
- Executive summary format for capacity reviews

### 6. Capacity Review Process

Define ongoing capacity management:

**Review Cadence:**

| Review | Frequency | Participants | Inputs | Outputs |
|--------|-----------|-------------|--------|---------|
| Capacity check | Monthly | DevOps team | Utilization metrics, cost data | Scaling adjustments |
| Growth review | Quarterly | DevOps + Product | Traffic trends, product roadmap | Updated growth model |
| Annual planning | Annually | Engineering leadership | Full capacity model, budget | Annual capacity budget |

**Capacity Alerts:**

| Alert | Threshold | Channel | Action | Owner |
|-------|-----------|---------|--------|-------|
| Utilization warning | 70% sustained | | Review scaling policies | |
| Utilization critical | 85% sustained | | Immediate scale action | |
| Cost anomaly | 20% above forecast | | Cost review | |
| Growth deviation | Actual > aggressive forecast | | Update growth model | |

### 7. Generate Validation & Testing Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 6. Load Testing Strategy

### 6.1 Tool Selection

| Tool | Purpose | Environment | Integration | Owner |
|------|---------|-------------|-------------|-------|
{{tool_selection_entries}}

**Selection Rationale:** {{tool_rationale}}

### 6.2 Test Scenarios

| Scenario | Test Type | Target Load | Duration | Success Criteria | Priority |
|----------|----------|------------|----------|-----------------|----------|
{{test_scenario_entries}}

### 6.3 Testing Environment

**Environment:** {{test_environment_approach}}

**Data Strategy:** {{test_data_strategy}}

**Isolation:** {{isolation_requirements}}

### 6.4 Testing Cadence

| Test | Frequency | Scope | Owner | Trigger |
|------|-----------|-------|-------|---------|
{{testing_cadence_entries}}

## 7. Capacity Validation

### 7.1 Validation Checklist

{{validation_checklist_items}}

### 7.2 Capacity Alerts

| Alert | Threshold | Channel | Action | Owner |
|-------|-----------|---------|--------|-------|
{{capacity_alert_entries}}

### 7.3 Review Process

| Review | Frequency | Participants | Inputs | Outputs |
|--------|-----------|-------------|--------|---------|
{{review_process_entries}}

### 7.4 Reporting

**Load Test Report Template:**
{{report_template_outline}}

**Capacity Dashboard Requirements:**
{{dashboard_requirements}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Load Testing Strategy and Capacity Validation procedures.

**Here's what I'll add to the capacity plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this plan and proceed to final validation
[R] Revise - Let's adjust specific sections before continuing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Tool Selection / Test Scenarios / Testing Environment / Testing Cadence / Validation Checklist / Capacity Alerts / Review Process)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to C/R menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/capacity-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Load testing tools selected with clear rationale
✅ Test scenarios defined for all growth projections and scaling triggers
✅ Testing environment strategy documented
✅ Testing cadence established with recurring and trigger-based schedules
✅ Capacity validation checklist covers all critical dimensions
✅ Capacity alerts defined with thresholds, actions, and owners
✅ Review process established with defined cadence and participants
✅ User confirmed all testing decisions through discussion
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining tests without tying them to the growth model projections
❌ Not addressing testing environment and data requirements
❌ Missing ongoing capacity review process
❌ Not defining capacity alerts with clear thresholds and owners
❌ Setting testing cadence without considering trigger-based tests
❌ Not validating auto-scaling behavior as a test scenario
❌ Generating content without real discussion with user
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate the complete capacity plan and generate the implementation roadmap.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the C/R menu and content is saved!
