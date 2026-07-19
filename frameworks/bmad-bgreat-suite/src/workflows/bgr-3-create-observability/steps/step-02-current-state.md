# Step 2: Current State Assessment

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on auditing existing telemetry and identifying gaps
- 🎯 ANALYZE loaded documents, don't assume or generate requirements
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating current state assessment
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the assessment, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, infrastructure, PRD, etc.)
- Focus on what exists today and what gaps need to be addressed
- No design decisions yet - pure assessment phase

## YOUR TASK:

Audit the existing observability landscape by analyzing loaded project documents to understand what telemetry exists, what signals are available, and where the blind spots are.

## CURRENT STATE ASSESSMENT SEQUENCE:

### 1. Scan for Existing Observability Signals

**From Architecture Document:**

- Identify services, components, and integration points
- Note any monitoring or observability requirements mentioned
- Extract technology stack decisions that affect instrumentation options
- Identify data flows that need tracing

**From Infrastructure Document (if available):**

- Identify cloud provider monitoring capabilities (CloudWatch, Stackdriver, Azure Monitor)
- Note any existing monitoring tools or platforms mentioned
- Extract networking and load balancer health check configurations
- Identify container orchestration observability features (K8s metrics, pod health)

**From PRD (if available):**

- Extract performance requirements and SLA commitments
- Identify business-critical user journeys that need monitoring
- Note compliance or audit logging requirements
- Identify availability expectations

**From Project Source (if accessible):**

- Scan for existing logging configuration (log levels, frameworks)
- Check for existing metrics collection (Prometheus, StatsD, custom)
- Look for tracing instrumentation (OpenTelemetry, Jaeger, Zipkin)
- Identify existing health check endpoints

### 2. Map Available Signals to Golden Signals

For each identified service or component, assess coverage:

| Service | Latency | Traffic | Errors | Saturation | Notes |
|---------|---------|---------|--------|------------|-------|

- **Latency**: Are response times measured? At what percentiles?
- **Traffic**: Is request volume tracked? By endpoint, by user segment?
- **Errors**: Are error rates captured? Categorized by type?
- **Saturation**: Are resource limits monitored? Queue depths? Connection pools?

### 3. Assess Logging Landscape

Evaluate current logging practices:

- **Logging framework**: What libraries or tools are in use?
- **Log format**: Structured (JSON) or unstructured (plaintext)?
- **Log levels**: Are they consistently applied across services?
- **Retention**: How long are logs kept? Where are they stored?
- **Correlation**: Can logs be correlated across services? (request IDs, trace IDs)
- **PII handling**: Is sensitive data redacted or masked in logs?
- **Centralization**: Are logs aggregated to a central platform?

### 4. Evaluate Existing Dashboards and Alerts

- **Dashboards**: What dashboards exist? Who uses them? What do they show?
- **Alerts**: What alerts are configured? What thresholds trigger them?
- **On-call**: Is there an on-call rotation? What does the escalation path look like?
- **Runbooks**: Do alert-linked runbooks exist?
- **Noise level**: Are there noisy or ignored alerts?

### 5. Document Gaps and Blind Spots

Categorize findings into:

**Critical Gaps** (blind spots that could hide production issues):
- Services without any monitoring
- Missing error tracking for critical paths
- No alerting on customer-impacting failures
- Absent distributed tracing for cross-service flows

**Important Gaps** (incomplete coverage that limits troubleshooting):
- Inconsistent logging formats across services
- Missing business KPI metrics
- No SLO/error budget tracking
- Incomplete dashboard coverage

**Improvement Opportunities** (enhancements to existing observability):
- Better sampling strategies
- Richer span attributes for tracing
- More granular metrics cardinality
- Dashboard consolidation

### 6. Present Findings

Reflect your analysis back to the user:

"Here's my assessment of the current observability landscape for {{project_name}}.

**Signal Coverage Summary:**
{golden signals coverage table from step 2}

**Logging Assessment:**
- Format: {structured/unstructured/mixed}
- Correlation: {available/partial/missing}
- PII handling: {compliant/needs work/not addressed}

**Dashboard & Alert Status:**
- Dashboards: {count and coverage summary}
- Active alerts: {count and quality summary}
- Runbooks: {coverage summary}

**Key Gaps Identified:**
{prioritized list of gaps from step 5}

This assessment will guide our instrumentation design in the next step.

Does this match your understanding of the current state? Anything I missed or got wrong?"

### 7. Generate Current State Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Current State Summary

### Existing Observability Signals

{{analysis_of_existing_monitoring_and_telemetry}}

### Golden Signals Coverage

| Service | Latency | Traffic | Errors | Saturation | Notes |
|---------|---------|---------|--------|------------|-------|
{{golden_signals_coverage_per_service}}

### Logging Assessment

- **Format**: {{structured_or_unstructured}}
- **Correlation**: {{correlation_id_availability}}
- **PII Handling**: {{pii_status}}
- **Centralization**: {{log_aggregation_status}}
- **Retention**: {{current_retention_policy}}

### Dashboard & Alerting Status

{{current_dashboard_and_alert_inventory}}

### Gaps & Blind Spots

**Critical Gaps:**
{{critical_gaps_list}}

**Important Gaps:**
{{important_gaps_list}}

**Improvement Opportunities:**
{{improvement_opportunities_list}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Current State Assessment based on your project documents.

**Here's what I'll add to the observability plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this assessment and proceed to instrumentation design
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/observability.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-design-instrumentation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ All loaded documents thoroughly analyzed for existing observability signals
✅ Golden Signals coverage mapped per service
✅ Logging practices assessed with clear findings
✅ Dashboard and alerting inventory documented
✅ Gaps and blind spots categorized by priority
✅ User confirmation of current state understanding
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Skimming documents without thorough observability analysis
❌ Missing existing monitoring that's already configured
❌ Not mapping signals to the four Golden Signals
❌ Not validating current state understanding with user
❌ Generating content without real analysis of loaded documents
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-design-instrumentation.md` to design the future-state instrumentation strategy.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the C/R menu and content is saved!
