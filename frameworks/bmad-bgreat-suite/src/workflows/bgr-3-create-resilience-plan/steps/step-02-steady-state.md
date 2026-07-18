# Step 2: Steady-State Hypothesis Definition

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on defining what "healthy" looks like for each critical service
- ✅ USE SLOs from observability plan as baseline when available
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to save or proceed until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the steady-state hypotheses and move to failure scenario design
- **R (Revise)**: Discuss changes, refine hypotheses, then re-present the menu

## CONTEXT BOUNDARIES:

- Variables from workflow.md are available in memory
- Input documents from step-01 are loaded and available
- Architecture document provides service topology and critical paths
- Observability plan (if available) provides SLO targets and metrics
- Focus on defining measurable health indicators, not on failure scenarios yet

## YOUR TASK:

Guide the user through defining steady-state hypotheses — the measurable conditions that describe what "healthy" looks like for each critical service and user journey. These hypotheses become the foundation for all chaos experiments.

## DISCOVERY SEQUENCE:

### 1. Identify Critical Services

Using the architecture document and any available observability plan:

- List all services in the architecture
- Identify which are critical to core user journeys
- Map service dependencies to understand cascading failure potential
- Prioritize services by business impact

### 2. Define Steady-State Health Indicators

For each critical service, collaboratively define:

**Key Questions to Discuss:**
- "What metrics tell you the system is healthy right now?"
- "What SLO violations would indicate a problem worth investigating?"
- "What is the minimum set of checks that confirm the system is working?"
- "If you were paged at 3am, what dashboard would you check first?"
- "What does 'normal' look like for this service during peak hours vs. off-peak?"

**For each service, define:**
- Steady-state indicator (what to measure)
- Measurement method (how to collect the metric)
- Acceptable range (what values are "healthy")
- Monitoring query (the actual query to verify steady state)

### 3. Map Critical User Journey Baselines

For each critical user journey:

- Reference SLO targets from observability plan (if available)
- Define baseline metrics that represent normal operation
- Set variance thresholds — how much deviation before something is wrong
- Document the monitoring query or check that verifies the baseline

### 4. Define System-Wide Health Signals

Beyond individual services, define system-level health:

- Infrastructure health signals (cluster health, node availability)
- Cross-service communication health (inter-service latency, error rates)
- Data pipeline health (queue depth, processing lag)
- External dependency health (third-party API response times)

### 5. Generate Steady-State Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Steady-State Hypotheses

### 2.1 Critical Service Health Indicators

| Service | Steady-State Indicator | Measurement | Acceptable Range | Monitoring Query |
|---------|----------------------|-------------|-----------------|-----------------|

### 2.2 Critical User Journey Baselines

| Journey | SLO Reference | Baseline Metric | Variance Threshold |
|---------|--------------|----------------|-------------------|

### 2.3 System-Wide Health Signals

- **Infrastructure Health:**
- **Cross-Service Communication:**
- **Data Pipeline Health:**
- **External Dependencies:**
```

### 6. Present Content and Menu

Show the generated content and present choices:

"Here are the steady-state hypotheses I've drafted based on our discussion.

[Show the complete markdown content]

These hypotheses will form the foundation for every chaos experiment — each experiment will verify that injecting a failure does NOT violate these steady-state conditions (or if it does, we learn something valuable).

**What would you like to do?**
[C] Continue - Save and move to failure scenario design
[R] Revise - Let's refine the steady-state hypotheses"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the content to `{bgr_artifacts}/resilience-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2]`
  - `lastUpdated: {{current_date}}`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ All critical services identified with measurable health indicators
✅ SLOs from observability plan referenced where available
✅ Monitoring queries defined for each steady-state indicator
✅ Acceptable variance ranges documented for each indicator
✅ Critical user journeys mapped to baseline metrics
✅ System-wide health signals defined
✅ C/R menu presented and handled correctly

## FAILURE MODES:

❌ Defining vague or unmeasurable steady-state indicators
❌ Not referencing existing SLOs when observability plan is available
❌ Missing monitoring queries — every hypothesis needs a way to verify it
❌ Not considering system-wide signals beyond individual services
❌ Generating content without user collaboration and input
❌ Proceeding without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, load `./step-03-failure-scenarios.md` to begin designing failure scenarios and chaos experiments.

Remember: Do NOT proceed to step-03 until user explicitly selects [C] from the menu!
