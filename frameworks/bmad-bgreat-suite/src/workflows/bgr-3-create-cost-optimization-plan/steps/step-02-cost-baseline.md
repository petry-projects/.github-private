# Step 2: Cost Baseline & Resource Inventory

## MANDATORY EXECUTION RULES (READ FIRST):

- NEVER generate content without user input

- CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ALWAYS treat this as collaborative discovery between infrastructure peers
- YOU ARE A FACILITATOR, not a content generator
- FOCUS on establishing current cost baseline, resource inventory, spend distribution, and waste identification
- ANALYZE loaded documents, don't assume or generate requirements
- Do not estimate software delivery timelines or task durations — but do define operational timing (budget review cadence, anomaly detection windows, reserved instance evaluation schedules) as these are core cost optimization plan outputs
- YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- Present C/R menu after generating cost baseline
- ONLY save when user chooses C (Continue)
- Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- FORBIDDEN to load next step until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the content to the document and proceed to next step
- **R (Revise)**: Discuss changes, refine the analysis, then re-present the menu

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, infrastructure, capacity plan, observability, PRD, etc.)
- Focus on understanding current costs, resource utilization, spend distribution, and identifying waste
- No optimization decisions yet — pure analysis and baselining phase

## YOUR TASK:

Establish the current cost baseline by inventorying all cloud resources, analyzing spend distribution across services and environments, identifying resource utilization patterns, and cataloging waste and inefficiencies that will drive optimization recommendations in the next step.

## COST BASELINE SEQUENCE:

### 1. Establish Current Spend Summary

**From Infrastructure Document (if available):**

- Extract all cloud resources, instance types, storage volumes, and managed services
- Identify environment topology (production, staging, development, etc.)
- Note compute commitment types (on-demand, reserved, spot)

**From Capacity Plan (if available):**

- Extract current resource utilization baselines
- Note existing cost guardrails and reserved capacity commitments
- Load cost-performance trade-off decisions already made

**From Architecture Document:**

- Extract all services and their resource dependencies
- Identify data stores, queues, caches, and their hosting models
- Map service communication patterns that affect network costs

**From PRD (if available):**

- Extract budget constraints or cost targets
- Note expected growth that affects cost projections

Discuss with the user to fill any gaps:

"Let's establish your current cost baseline. Based on what I've loaded:

**Current state I can see:**
{summary from documents}

**What I need from you:**
- Total monthly cloud spend (approximate is fine)
- Top 3 cost categories (compute, storage, network, managed services, etc.)
- Do you have access to a cloud cost dashboard (AWS Cost Explorer, GCP Billing, Azure Cost Management)?
- Are there any known areas of waste or overspend?
- Current billing model (on-demand, reserved instances, savings plans)?"

### 2. Resource Inventory

Work with the user to catalog all cloud resources:

**Compute Resources:**

| Service | Resource Type | Count | Specification | Monthly Cost | Avg Utilization |
|---------|-------------|-------|--------------|-------------|----------------|

**Storage Resources:**

| Storage | Type | Size | Monthly Cost | Access Pattern | Growth Rate |
|---------|------|------|-------------|---------------|-------------|

**Managed Services:**

| Service | Tier/Plan | Monthly Cost | Usage Level | Notes |
|---------|----------|-------------|-------------|-------|

**Network Resources:**

| Resource | Type | Monthly Cost | Traffic Volume | Notes |
|----------|------|-------------|---------------|-------|

### 3. Cost Distribution Analysis

Analyze how costs are distributed:

**By Environment:**

- Production vs staging vs development vs other
- Are non-production environments right-sized relative to production?
- Are development resources running 24/7 when they should be ephemeral?

**By Service:**

- Which services are the biggest cost drivers?
- What is the cost per request/transaction/user for each service?
- Are costs proportional to business value delivered?

**By Category:**

- Compute vs storage vs network vs managed services
- Fixed costs vs variable costs
- Committed spend vs on-demand spend

### 4. Utilization Analysis

Assess resource utilization:

**Compute Utilization:**

- Average and peak CPU utilization per service
- Average and peak memory utilization per service
- Instances/pods that are consistently under-utilized (< 30% CPU)
- Instances/pods that are over-provisioned on memory

**Storage Utilization:**

- Volumes that are significantly over-provisioned
- Data that could be moved to cheaper tiers (cold/archive)
- Orphaned snapshots, volumes, or backups

**Network Utilization:**

- Cross-AZ or cross-region traffic that could be optimized
- NAT gateway costs that could be reduced
- CDN effectiveness and cache hit ratios

### 5. Waste Identification

Catalog all identified waste and inefficiencies:

**Resource Waste:**

- Idle or unused resources (attached but unused EBS volumes, idle load balancers, unused elastic IPs)
- Over-provisioned resources (instances with < 30% average utilization)
- Orphaned resources (snapshots, AMIs, container images without active references)

**Operational Waste:**

- Non-production environments running 24/7
- Development resources not using spot/preemptible instances
- Duplicate or redundant services
- Unused reserved capacity or savings plan commitments

**Architecture Waste:**

- Services making unnecessary cross-region calls
- Missing caching layers causing repeated expensive operations
- Inefficient data transfer patterns

### 6. Present Findings

Reflect your analysis back to the user:

"Here's the cost baseline for {{project_name}}.

**Total Monthly Spend:** {total_spend}
- Compute: {compute_spend} ({compute_pct}%)
- Storage: {storage_spend} ({storage_pct}%)
- Network: {network_spend} ({network_pct}%)
- Managed Services: {managed_spend} ({managed_pct}%)

**Top Cost Drivers:**
{top_cost_services}

**Utilization Summary:**
- Average compute utilization: {avg_utilization}%
- Resources below 30% utilization: {underutilized_count}
- Estimated monthly waste: {waste_estimate}

**Key Findings:**
- {key_findings}

Does this baseline reflect your understanding? Anything to adjust?"

### 7. Generate Cost Baseline Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Current Cost Baseline

### 2.1 Spend Summary

| Category | Monthly Spend | % of Total | Trend (3-month) | Owner |
|----------|-------------|-----------|-----------------|-------|
{{spend_summary_entries}}

### 2.2 Resource Inventory

| Service | Resource Type | Count | Specification | Monthly Cost | Utilization |
|---------|-------------|-------|--------------|-------------|-------------|
{{resource_inventory_entries}}

### 2.3 Cost Distribution

**By Environment:**

| Environment | Monthly Spend | % of Total | Notes |
|------------|-------------|-----------|-------|
{{environment_cost_entries}}

**By Service:**

| Service | Monthly Spend | % of Total | Cost per Request/Transaction | Notes |
|---------|-------------|-----------|----------------------------|-------|
{{service_cost_entries}}

### 2.4 Waste Identification

| Resource | Type | Monthly Waste | Evidence | Recommendation |
|----------|------|-------------|----------|----------------|
{{waste_entries}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Cost Baseline and Resource Inventory.

**Here's what I'll add to the cost optimization plan:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this analysis and proceed to optimization strategy
[R] Revise - Let's discuss changes before saving"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/cost-optimization-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-optimization-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Current cloud spend baseline established with real data or informed estimates
✅ Resource inventory cataloged across compute, storage, network, and managed services
✅ Cost distribution analyzed by environment, service, and category
✅ Resource utilization assessed with under-utilization identified
✅ Waste and inefficiencies cataloged with estimated monthly impact
✅ User confirmation of all baseline findings
✅ C/R menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Establishing baseline without understanding current resource landscape
❌ Not identifying waste and inefficiencies
❌ Not analyzing cost distribution across environments and services
❌ Missing utilization analysis
❌ Not validating baseline findings with user
❌ Generating content without real analysis of loaded documents
❌ Not presenting C/R menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-optimization-strategy.md` to develop right-sizing recommendations, reserved/spot strategy, and cost-aware SLO trade-offs.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the C/R menu and content is saved!
