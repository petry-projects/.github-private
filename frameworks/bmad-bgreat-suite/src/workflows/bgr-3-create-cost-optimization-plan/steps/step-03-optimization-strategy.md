# Step 3: Optimization Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- NEVER generate content without user input

- CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ALWAYS treat this as collaborative discovery between infrastructure peers
- YOU ARE A FACILITATOR, not a content generator
- FOCUS on right-sizing recommendations, reserved/spot instance strategy, cost-aware SLO trade-offs, and FinOps maturity progression
- ANALYZE cost baseline from step 2 to inform optimization decisions
- Do not estimate software delivery timelines or task durations — but do define operational timing (budget review cadence, reserved instance evaluation schedules, right-sizing review cycles) as these are core cost optimization plan outputs
- YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- Present C/R menu after generating optimization strategy
- ONLY save when user chooses C (Continue)
- Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the strategy, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document with cost baseline from step 2 is available
- Input documents already loaded are in memory
- Focus on defining how to optimize — right-sizing, reservations, spot usage, SLO trade-offs, and maturity progression
- Build on the cost baseline and waste identification from step 2

## YOUR TASK:

Develop resource right-sizing recommendations, reserved/spot instance strategy, cost-aware SLO trade-offs, and FinOps maturity progression plan through structured discussion with the user.

## OPTIMIZATION STRATEGY SEQUENCE:

### 1. Right-Sizing Recommendations

For each under-utilized resource from the cost baseline, determine the right-sizing approach:

**Compute Right-Sizing:**

- Analyze CPU and memory utilization data to recommend appropriate instance sizes
- Consider burst vs steady-state workloads (burstable vs fixed instance types)
- Factor in growth projections from the capacity plan if available
- Account for peak utilization headroom requirements

| Service | Current Spec | Recommended Spec | CPU Utilization | Memory Utilization | Monthly Savings | Risk |
|---------|-------------|-----------------|----------------|-------------------|----------------|------|

**Database Right-Sizing:**

- Analyze query patterns, connection counts, and IOPS requirements
- Consider read replica consolidation or expansion
- Evaluate managed vs self-managed cost trade-offs

| Database | Current Spec | Recommended Spec | Utilization | Monthly Savings | Migration Risk |
|----------|-------------|-----------------|-------------|----------------|----------------|

**Storage Optimization:**

- Identify data that can be moved to cheaper storage tiers
- Implement lifecycle policies for aging data
- Clean up orphaned snapshots and unused volumes

| Storage | Current Tier | Recommended Tier | Access Pattern | Monthly Savings | Migration Effort |
|---------|-------------|-----------------|---------------|----------------|-----------------|

**Network Optimization:**

- Reduce cross-AZ and cross-region data transfer
- Optimize NAT gateway usage
- Improve CDN cache hit ratios

Discuss with the user:

"Based on the cost baseline, here are my initial right-sizing observations:

**Quick wins (low risk, immediate savings):**
{low_risk_optimizations}

**Medium-term optimizations (moderate effort):**
{medium_term_optimizations}

**Longer-term architectural changes:**
{architectural_optimizations}

What's your team's comfort level with right-sizing? Any constraints around downtime windows or change management?"

### 2. Reserved & Spot Instance Strategy

Define the commitment and flexible compute strategy:

**Reservation Analysis:**

- Calculate break-even points for reserved instances vs on-demand
- Analyze historical usage patterns to determine commitment safety
- Factor in growth projections to avoid over-committing
- Compare savings plans vs reserved instances for the cloud provider

| Resource | On-Demand Cost | Reserved Cost | Commitment Term | Savings | Break-Even |
|----------|---------------|-------------|----------------|---------|-----------|

**Recommendation Framework:**

- **Baseline workloads (always running):** 1-year or 3-year commitments for maximum savings
- **Predictable growth:** Staged commitments aligned with capacity plan projections
- **Variable workloads:** On-demand or savings plans with flexible coverage
- **Fault-tolerant batch:** Spot/preemptible instances with fallback strategies

**Spot/Preemptible Strategy:**

- Identify workloads tolerant of interruption (batch processing, CI/CD, dev/test)
- Define fallback strategies for spot interruptions
- Set maximum spot price thresholds

| Workload | Current Type | Spot Eligible | Interruption Tolerance | Monthly Savings | Fallback Strategy |
|----------|-------------|-------------|----------------------|----------------|-------------------|

**Savings Plan Coverage:**

- Target coverage percentage for committed spend
- Balance between flexibility and savings depth
- Review and adjustment cadence

### 3. Cost-Aware SLO Trade-offs

Collaborate with SRE perspectives to balance cost with reliability:

**SLO-Cost Analysis:**

For each SLO target, analyze the cost to maintain it:

| SLO | Current Target | Cost to Maintain | Relaxed Target | Cost Savings | Reliability Impact |
|-----|---------------|-----------------|---------------|-------------|-------------------|

**Error Budget Spending Policy:**

Define how error budget consumption interacts with cost decisions:

- When error budget is healthy: Allow cost optimization experiments (right-sizing, spot migration)
- When error budget is low: Prioritize reliability over cost savings
- When cost exceeds thresholds: Review SLO targets for potential relaxation

| SLO | Error Budget | Cost Threshold | Action When Budget Low | Action When Cost High |
|-----|-------------|---------------|----------------------|---------------------|

**Performance-Cost Trade-offs:**

| Decision | Performance Impact | Cost Impact | SLO Compliance | Recommendation | Owner |
|----------|-------------------|------------|---------------|----------------|-------|

**Reliability vs Cost Decision Framework:**

Define the decision criteria for common scenarios:

| Scenario | Reliability Priority | Cost Priority | Balanced Approach | Decision Criteria |
|----------|---------------------|-------------|------------------|------------------|

Discuss with the user:

"Let's talk about the relationship between your SLO targets and costs. Key questions:

- Are any SLOs over-provisioned relative to business requirements?
- Would relaxing any SLO target (e.g., from 99.99% to 99.9%) yield meaningful savings?
- How does your team handle the tension between cost reduction and reliability?
- Are there error budget policies that consider cost impact?"

### 4. FinOps Maturity Progression

Define the maturity journey from crawl to run:

**Current State Assessment:**

| Dimension | Current Level | Evidence | Gap |
|-----------|-------------|---------|-----|
| Cost visibility | | | |
| Cost allocation | | | |
| Optimization practices | | | |
| Forecasting accuracy | | | |
| Organizational adoption | | | |
| Tooling & automation | | | |

**Crawl Phase (Foundation):**

Focus on visibility and basic hygiene:
- Implement cost tagging and allocation
- Set up basic budget alerts
- Establish monthly cost review cadence
- Assign cost ownership to teams
- Create cost dashboards

**Walk Phase (Optimization):**

Focus on active optimization:
- Implement right-sizing automation
- Purchase reserved instances / savings plans
- Automate non-production environment scheduling
- Implement chargeback/showback model
- Integrate cost metrics into engineering decisions

**Run Phase (Operations):**

Focus on continuous optimization and culture:
- Real-time cost anomaly detection and response
- Automated right-sizing and scaling based on cost-efficiency
- Cost-aware architecture decisions embedded in design reviews
- FinOps practices integrated into sprint planning
- Predictive cost modeling for capacity planning

Discuss with the user:

"Based on your current practices, I'd assess your FinOps maturity as {assessed_level}. Here's why:

**Evidence:**
{maturity_evidence}

**Recommended progression:**
{progression_plan}

Does this assessment match your perception? What FinOps initiatives are already underway?"

### 5. Generate Optimization Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 3. Right-Sizing Recommendations

### 3.1 Compute Right-Sizing

| Service | Current Spec | Recommended Spec | CPU Utilization | Memory Utilization | Monthly Savings | Risk |
|---------|-------------|-----------------|----------------|-------------------|----------------|------|
{{compute_rightsizing_entries}}

### 3.2 Database Right-Sizing

| Database | Current Spec | Recommended Spec | Utilization | Monthly Savings | Migration Risk |
|----------|-------------|-----------------|-------------|----------------|----------------|
{{database_rightsizing_entries}}

### 3.3 Storage Optimization

| Storage | Current Tier | Recommended Tier | Access Pattern | Monthly Savings | Migration Effort |
|---------|-------------|-----------------|---------------|----------------|-----------------|
{{storage_optimization_entries}}

### 3.4 Network Optimization

| Traffic Path | Current Cost | Optimization | Monthly Savings | Implementation |
|-------------|-------------|-------------|----------------|----------------|
{{network_optimization_entries}}

## 4. Reserved & Spot Instance Strategy

### 4.1 Reservation Analysis

| Resource | On-Demand Cost | Reserved Cost | Commitment Term | Savings | Break-Even |
|----------|---------------|-------------|----------------|---------|-----------|
{{reservation_analysis_entries}}

### 4.2 Reservation Recommendations

| Resource | Plan Type | Commitment | Coverage Target | Annual Savings | Approval Required |
|----------|----------|-----------|----------------|---------------|-------------------|
{{reservation_recommendation_entries}}

### 4.3 Spot/Preemptible Strategy

| Workload | Current Type | Spot Eligible | Interruption Tolerance | Monthly Savings | Fallback Strategy |
|----------|-------------|-------------|----------------------|----------------|-------------------|
{{spot_strategy_entries}}

### 4.4 Savings Plan Coverage

| Category | Current Coverage | Target Coverage | Gap | Action |
|----------|-----------------|----------------|-----|--------|
{{savings_plan_entries}}

## 7. Cost-Aware SLO Trade-offs

### 7.1 SLO-Cost Analysis

| SLO | Current Target | Cost to Maintain | Relaxed Target | Cost Savings | Reliability Impact |
|-----|---------------|-----------------|---------------|-------------|-------------------|
{{slo_cost_entries}}

### 7.2 Error Budget Spending Policy

**Cost-Aware Error Budget Rules:**

| SLO | Error Budget | Cost Threshold | Action When Budget Low | Action When Cost High |
|-----|-------------|---------------|----------------------|---------------------|
{{error_budget_entries}}

### 7.3 Performance-Cost Trade-offs

| Decision | Performance Impact | Cost Impact | SLO Compliance | Recommendation | Owner |
|----------|-------------------|------------|---------------|----------------|-------|
{{performance_cost_entries}}

### 7.4 Reliability vs Cost Decision Framework

| Scenario | Reliability Priority | Cost Priority | Balanced Approach | Decision Criteria |
|----------|---------------------|-------------|------------------|------------------|
{{decision_framework_entries}}

## 8. FinOps Maturity Progression

### 8.1 Current State Assessment

| Dimension | Current Level | Evidence | Gap |
|-----------|-------------|---------|-----|
{{maturity_assessment_entries}}

### 8.2 Crawl Phase (Foundation)

| Initiative | Description | Owner | Target Date | Status |
|-----------|-------------|-------|-------------|--------|
{{crawl_phase_entries}}

### 8.3 Walk Phase (Optimization)

| Initiative | Description | Owner | Target Date | Depends On |
|-----------|-------------|-------|-------------|-----------|
{{walk_phase_entries}}

### 8.4 Run Phase (Operations)

| Initiative | Description | Owner | Target Date | Depends On |
|-----------|-------------|-------|-------------|-----------|
{{run_phase_entries}}

### 8.5 Maturity Milestones

| Milestone | Criteria | Target Date | Validation |
|-----------|---------|-------------|-----------|
{{maturity_milestone_entries}}
```

### 6. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Optimization Strategy, SLO Trade-offs, and FinOps Maturity Plan.

**Here's what I'll add to the cost optimization plan:**

[Show the complete markdown content from step 5]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to cost governance
[R] Revise - Let's adjust specific sections before continuing"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Right-Sizing / Reserved & Spot Strategy / SLO Trade-offs / FinOps Maturity)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to C/R menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/cost-optimization-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-governance.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ Right-sizing recommendations defined per resource with savings estimates
✅ Reserved/spot instance strategy defined with break-even analysis
✅ Cost-aware SLO trade-offs analyzed with error budget spending policy
✅ FinOps maturity assessed with crawl/walk/run progression plan
✅ Performance-cost trade-off decisions documented with owners
✅ User confirmed all optimization decisions through discussion
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Recommending right-sizing without considering the cost baseline from step 2
❌ Not addressing reserved instance strategy separately from spot strategy
❌ Missing SLO-cost trade-off analysis
❌ Not defining FinOps maturity progression
❌ Setting optimization targets without discussing with user
❌ Not considering growth projections when recommending commitments
❌ Generating content without real discussion with user
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-governance.md` to define cost governance rules, tagging standards, anomaly detection, and budget alerts.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the C/R menu and content is saved!
