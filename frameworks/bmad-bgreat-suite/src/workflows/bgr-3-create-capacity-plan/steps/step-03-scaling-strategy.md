# Step 3: Scaling Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on auto-scaling policies, resource scaling triggers, horizontal vs vertical scaling, and cost-performance trade-offs
- 🎯 ANALYZE growth model from step 2 to inform scaling decisions
- ⚠️ Do not estimate software delivery timelines or task durations — but do define operational timing (scaling response times, load test cadence, review schedules) as these are core capacity plan outputs
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- ⚠️ Present C/R menu after generating scaling strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the strategy, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with growth model from step 2 is available
- Input documents already loaded are in memory
- Focus on defining how to scale — policies, triggers, approaches, and cost trade-offs
- Build on the growth model and bottleneck analysis from step 2

## YOUR TASK:

Define auto-scaling policies, resource scaling triggers, horizontal vs vertical scaling decisions, cost-performance trade-offs, and reserved capacity planning through structured discussion with the user.

## SCALING STRATEGY SEQUENCE:

### 1. Scaling Approach per Service

For each service from the growth model, determine the scaling approach:

**Horizontal Scaling (scale-out):**
- Add more instances/pods to handle increased load
- Best for: stateless services, read-heavy workloads, request-driven services
- Considerations: session affinity, data partitioning, connection pooling

**Vertical Scaling (scale-up):**
- Increase resources (CPU, memory) on existing instances
- Best for: stateful services, memory-intensive workloads, database servers
- Considerations: downtime during resize, instance type limits, diminishing returns

**Hybrid Scaling:**
- Vertical first (faster, simpler), then horizontal when vertical limits are reached
- Best for: services transitioning from monolith to distributed architecture

Discuss with the user:

"Based on your growth model, here's my initial scaling assessment:

**Horizontal scaling candidates:**
{services that benefit from scale-out}

**Vertical scaling candidates:**
{services that need scale-up}

**Key considerations:**
- {stateful_services} need special handling for horizontal scaling
- {bottleneck_services} are likely to need scaling first

What's your team's experience with auto-scaling? Any constraints I should know about?"

### 2. Auto-Scaling Policies

Define auto-scaling configurations per service:

**Policy Components:**

| Service | Metric | Scale-Out Threshold | Scale-In Threshold | Cooldown | Min | Max |
|---------|--------|--------------------|--------------------|----------|-----|-----|

**Scaling Metrics to Consider:**

- **CPU utilization**: Standard but lagging indicator — scale-out at 60-70%, scale-in at 30-40%
- **Memory utilization**: Important for memory-bound services — scale-out at 70-80%
- **Request rate**: Leading indicator — scale based on requests/second per instance
- **Queue depth**: For async workers — scale based on messages pending
- **Custom metrics**: Business-specific (active sessions, concurrent connections, pipeline depth)
- **Predictive scaling**: Schedule-based scaling for known traffic patterns

**Multi-Metric Policies:**
- Consider combining metrics for more responsive scaling
- Example: Scale out when CPU > 70% OR request rate > threshold OR queue depth > threshold
- Avoid conflicting signals between metrics

### 3. Resource Scaling Triggers

Define the trigger framework:

**Reactive Triggers (respond to current demand):**

| Trigger | Metric | Threshold | Action | Response Time |
|---------|--------|-----------|--------|--------------|

**Predictive Triggers (anticipate demand):**

| Trigger | Signal | Lead Time | Action | Owner |
|---------|--------|-----------|--------|-------|

**Scheduled Triggers (known patterns):**

| Schedule | Services | Scale Action | Duration | Owner |
|----------|----------|-------------|----------|-------|

**Emergency Triggers:**

| Condition | Detection | Action | Approval Required | Owner |
|-----------|-----------|--------|-------------------|-------|

### 4. Cost-Performance Trade-offs

Analyze the cost implications of scaling decisions:

**Compute Cost Optimization:**

- **Reserved instances / savings plans**: For baseline capacity (always-on load)
- **On-demand instances**: For variable load above baseline
- **Spot / preemptible instances**: For fault-tolerant batch workloads and development
- **Right-sizing**: Match instance types to actual resource consumption patterns

**Cost Modeling:**

| Tier | Baseline Cost | Peak Cost | Scaling Cost Premium | Annual Estimate |
|------|-------------|----------|---------------------|----------------|

**Trade-off Analysis:**

| Decision | Performance Benefit | Cost Impact | Recommendation | Owner |
|----------|-------------------|------------|----------------|-------|

**Cost Guardrails:**

- Maximum monthly spend threshold per service / per environment
- Alert thresholds at 80% and 100% of budget
- Automatic scale-down when cost guardrails are breached (non-production only)
- Reserve capacity purchase approval process

### 5. Reserved Capacity Planning

Plan for committed resource reservations:

**Reservation Strategy:**

- **Baseline reservation**: Cover the minimum always-on workload with 1-year or 3-year commitments
- **Growth buffer**: Reserve additional capacity for expected 6-month growth
- **Burst capacity**: Maintain on-demand/spot burst capability above reservations

**Reservation Decisions:**

| Resource | Current Baseline | Reserved Amount | Commitment Term | Savings vs On-Demand |
|----------|-----------------|----------------|----------------|---------------------|

**Storage Capacity:**

| Data Store | Current Size | Growth Rate | 12-Month Projection | Reserved | Tier |
|-----------|-------------|------------|---------------------|----------|------|

### 6. Database & Data Store Scaling

Address data-layer scaling specifically:

**Read Scaling:**
- Read replicas, caching layers, CDN for static assets
- Connection pooling and query optimization

**Write Scaling:**
- Sharding strategy, write-ahead log optimization
- Eventual consistency trade-offs for non-critical writes

**Storage Scaling:**
- Auto-expanding volumes, tiered storage (hot/warm/cold)
- Data lifecycle policies, archival and purge schedules

### 7. Generate Scaling Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 4. Scaling Strategy

### 4.1 Scaling Approach

| Service | Scaling Type | Rationale | Constraints |
|---------|-------------|-----------|-------------|
{{scaling_approach_entries}}

### 4.2 Auto-Scaling Policies

| Service | Metric | Scale-Out Threshold | Scale-In Threshold | Cooldown | Min | Max |
|---------|--------|--------------------|--------------------|----------|-----|-----|
{{auto_scaling_policy_entries}}

**Multi-Metric Policy Notes:**
{{multi_metric_notes}}

### 4.3 Scaling Triggers

**Reactive Triggers:**

| Trigger | Metric | Threshold | Action | Response Time |
|---------|--------|-----------|--------|--------------|
{{reactive_trigger_entries}}

**Predictive Triggers:**

| Trigger | Signal | Lead Time | Action | Owner |
|---------|--------|-----------|--------|-------|
{{predictive_trigger_entries}}

**Scheduled Triggers:**

| Schedule | Services | Scale Action | Duration | Owner |
|----------|----------|-------------|----------|-------|
{{scheduled_trigger_entries}}

**Emergency Triggers:**

| Condition | Detection | Action | Approval Required | Owner |
|-----------|-----------|--------|-------------------|-------|
{{emergency_trigger_entries}}

### 4.4 Database & Data Store Scaling

**Read Scaling:** {{read_scaling_strategy}}

**Write Scaling:** {{write_scaling_strategy}}

**Storage Scaling:** {{storage_scaling_strategy}}

## 5. Cost-Performance Analysis

### 5.1 Cost Model

| Tier | Baseline Cost | Peak Cost | Scaling Premium | Annual Estimate |
|------|-------------|----------|----------------|----------------|
{{cost_model_entries}}

### 5.2 Reserved Capacity

| Resource | Current Baseline | Reserved Amount | Commitment | Savings |
|----------|-----------------|----------------|-----------|---------|
{{reserved_capacity_entries}}

### 5.3 Cost Optimization Strategies

{{cost_optimization_strategies}}

### 5.4 Cost Guardrails

| Guardrail | Threshold | Action | Environment | Owner |
|-----------|-----------|--------|-------------|-------|
{{cost_guardrail_entries}}

### 5.5 Trade-off Decisions

| Decision | Performance Benefit | Cost Impact | Recommendation | Owner |
|----------|-------------------|------------|----------------|-------|
{{trade_off_entries}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Scaling Strategy and Cost-Performance Analysis.

**Here's what I'll add to the capacity plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to validation and load testing
[R] Revise - Let's adjust specific sections before continuing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Scaling Approach / Auto-Scaling Policies / Triggers / Database Scaling / Cost Model / Reserved Capacity / Cost Guardrails)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to C/R menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/capacity-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-validation-testing.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Scaling approach defined per service with clear rationale
✅ Auto-scaling policies configured with appropriate thresholds and cooldowns
✅ Reactive, predictive, scheduled, and emergency triggers defined
✅ Database and data store scaling strategies addressed
✅ Cost-performance trade-offs analyzed with reserved capacity planning
✅ Cost guardrails established with owner accountability
✅ User confirmed all scaling decisions through discussion
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining scaling policies without considering the growth model from step 2
❌ Not addressing database scaling separately from compute scaling
❌ Missing cost analysis or cost guardrails
❌ Not defining reserved capacity strategy
❌ Setting auto-scaling thresholds without discussing with user
❌ Not considering multi-metric policies for responsive scaling
❌ Generating content without real discussion with user
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-validation-testing.md` to define load testing procedures, capacity validation, and testing cadence.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the C/R menu and content is saved!
