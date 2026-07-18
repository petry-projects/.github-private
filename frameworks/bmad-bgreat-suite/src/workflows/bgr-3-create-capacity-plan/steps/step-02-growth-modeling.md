# Step 2: Growth Modeling & Traffic Forecasting

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on traffic forecasting, growth modeling, usage patterns, and seasonal analysis
- 🎯 ANALYZE loaded documents, don't assume or generate requirements
- ⚠️ Do not estimate software delivery timelines or task durations — but do define operational timing (scaling response times, load test cadence, review schedules) as these are core capacity plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating growth model
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the analysis, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, infrastructure, observability, PRD, etc.)
- Focus on understanding current traffic, modeling future growth, and identifying demand patterns
- No scaling decisions yet — pure analysis and forecasting phase

## YOUR TASK:

Model current and projected traffic patterns, forecast growth trajectories, analyze usage patterns and seasonal variations, and establish the demand baseline that will drive scaling decisions in the next step.

## GROWTH MODELING SEQUENCE:

### 1. Establish Current Baseline

**From Architecture Document:**

- Extract all services, their types (API, worker, streaming, batch), and communication patterns
- Identify stateful vs stateless components and their resource profiles
- Note current deployment topology (regions, AZs, replicas)

**From Infrastructure Document (if available):**

- Extract current compute resources (instance types, node counts, resource allocations)
- Identify current resource utilization patterns
- Note existing auto-scaling configurations
- Extract storage volumes and growth rates

**From Observability Plan (if available):**

- Extract current traffic metrics (requests per second, concurrent users, throughput)
- Note SLO targets that constrain scaling decisions (latency percentiles, error rates)
- Identify golden signal baselines per service

**From PRD (if available):**

- Extract expected user growth projections
- Note planned feature launches that may change traffic patterns
- Identify target markets or regions that affect geographic distribution

Discuss with the user to fill any gaps:

"Let's establish your current traffic baseline. Based on what I've loaded:

**Current state I can see:**
{summary from documents}

**What I need from you:**
- Current peak traffic (requests/sec, concurrent users, or transactions/hour)
- Current resource utilization at peak (CPU, memory, network)
- How old is this data? Is it representative of typical load?
- Any recent traffic anomalies we should exclude from the baseline?"

### 2. Traffic Forecasting

Work with the user to model future traffic:

**Growth Scenarios:**

| Scenario | Growth Rate | Time Horizon | Projected Peak | Confidence |
|----------|------------|-------------|---------------|------------|
| Conservative | | 6 months / 12 months | | |
| Expected | | 6 months / 12 months | | |
| Aggressive | | 6 months / 12 months | | |

**Growth Drivers to Discuss:**

- Organic user growth (historical trend extrapolation)
- Planned marketing campaigns or launches
- New feature releases that change traffic patterns
- Geographic expansion (new regions, new markets)
- B2B customer onboarding (step-function growth)
- API partner integrations (third-party traffic)
- Seasonal business cycles

Help the user quantify each driver:

"For each growth driver, let's estimate the traffic impact:
- What percentage increase in traffic would a {driver} bring?
- Over what time period would this ramp up?
- Is this additive or does it change the traffic shape?"

### 3. Usage Pattern Analysis

Characterize traffic patterns:

**Temporal Patterns:**

- **Daily patterns**: Peak hours, off-peak hours, daily traffic shape
- **Weekly patterns**: Weekday vs weekend, business hours vs evenings
- **Monthly patterns**: End-of-month spikes, billing cycles, reporting periods
- **Annual patterns**: Holiday seasons, fiscal year events, industry cycles

**Traffic Composition:**

- Read-heavy vs write-heavy ratios per service
- Synchronous vs asynchronous workload distribution
- Background job scheduling and resource contention
- Data pipeline batch windows and resource requirements

**Geographic Distribution:**

- Traffic by region and timezone
- Follow-the-sun patterns
- Latency-sensitive operations by geography

### 4. Seasonal & Event Analysis

Identify predictable demand spikes:

**Seasonal Events:**

| Event | Period | Traffic Multiplier | Duration | Predictability |
|-------|--------|-------------------|----------|---------------|
| | | | | |

**Planned Events:**

| Event | Expected Date | Traffic Impact | Lead Time for Scaling | Owner |
|-------|--------------|---------------|----------------------|-------|

**Black Swan Scenarios:**

- Viral content / unexpected media coverage
- DDoS or abusive traffic patterns
- Cascading failures from upstream dependencies
- Sudden loss of a region or availability zone

### 5. Resource Demand Mapping

Map traffic forecasts to resource requirements:

**Per-Service Resource Profile:**

| Service | Type | CPU/Request | Memory/Request | Storage Growth | Network I/O |
|---------|------|------------|---------------|---------------|-------------|

**Bottleneck Identification:**

- Which services hit resource limits first under growth?
- Which data stores will outgrow their current allocation first?
- What are the hard limits (database connections, API rate limits, network bandwidth)?
- Where are the scaling cliffs (points where incremental scaling stops working)?

### 6. Present Findings

Reflect your analysis back to the user:

"Here's the growth model for {{project_name}}.

**Current Baseline:**
- Peak traffic: {peak_traffic}
- Resource utilization at peak: {utilization_summary}
- Number of services profiled: {count}

**Growth Forecast (12-month expected):**
- Projected peak: {projected_peak}
- Key growth drivers: {top_drivers}
- Confidence level: {confidence}

**Traffic Patterns:**
- Peak hours: {peak_hours}
- Seasonal multiplier: {max_seasonal_multiplier}x
- {count} planned events identified

**Key Bottlenecks:**
- {top_bottlenecks}

Does this model reflect your understanding? Anything to adjust?"

### 7. Generate Growth Model Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Current Baseline

### 2.1 Traffic Baseline

| Metric | Current Average | Current Peak | Measurement Period |
|--------|----------------|-------------|-------------------|
{{traffic_baseline_entries}}

### 2.2 Resource Baseline

| Service | Type | CPU (avg/peak) | Memory (avg/peak) | Storage | Replicas |
|---------|------|---------------|-------------------|---------|----------|
{{resource_baseline_entries}}

### 2.3 Utilization Summary

| Resource | Current Utilization | Headroom | Time to Exhaustion |
|----------|-------------------|----------|-------------------|
{{utilization_entries}}

## 3. Growth Forecast

### 3.1 Growth Scenarios

| Scenario | Growth Rate | 6-Month Projection | 12-Month Projection | Confidence |
|----------|------------|-------------------|---------------------|------------|
{{growth_scenario_entries}}

### 3.2 Growth Drivers

| Driver | Traffic Impact | Timeline | Probability | Notes |
|--------|--------------|----------|-------------|-------|
{{growth_driver_entries}}

### 3.3 Traffic Patterns

**Daily Pattern:** {{daily_pattern_description}}

**Weekly Pattern:** {{weekly_pattern_description}}

**Seasonal Events:**

| Event | Period | Traffic Multiplier | Duration | Predictability |
|-------|--------|-------------------|----------|---------------|
{{seasonal_event_entries}}

### 3.4 Resource Demand Projection

| Service | Current Peak | 6-Month Peak | 12-Month Peak | Scaling Cliff | Notes |
|---------|-------------|-------------|--------------|--------------|-------|
{{resource_demand_entries}}

### 3.5 Bottleneck Analysis

| Bottleneck | Service | Current Limit | Projected Breach | Mitigation |
|-----------|---------|--------------|-----------------|------------|
{{bottleneck_entries}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Growth Model and Traffic Forecast.

**Here's what I'll add to the capacity plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this analysis and proceed to scaling strategy
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/capacity-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-scaling-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Current traffic baseline established with real data or informed estimates
✅ Growth scenarios defined with conservative, expected, and aggressive projections
✅ Usage patterns characterized (daily, weekly, seasonal)
✅ Resource demand mapped per service with scaling cliff identification
✅ Bottleneck analysis completed with projected breach timelines
✅ User confirmation of all growth assumptions
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Forecasting growth without understanding current baseline
❌ Not identifying seasonal or event-driven demand spikes
❌ Missing bottleneck analysis
❌ Not mapping traffic growth to resource requirements
❌ Not validating growth assumptions with user
❌ Generating content without real analysis of loaded documents
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-scaling-strategy.md` to define auto-scaling policies, resource scaling triggers, and cost-performance trade-offs.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the C/R menu and content is saved!
