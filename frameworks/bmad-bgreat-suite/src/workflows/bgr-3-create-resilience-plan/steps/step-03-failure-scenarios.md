# Step 3: Failure Scenario Design

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on identifying failure modes and designing experiments with controls
- ✅ PRIORITIZE by risk (likelihood x impact) and learning value
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to save or proceed until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the failure scenarios and move to game day planning
- **R (Revise)**: Discuss changes, refine scenarios, then re-present the menu

## CONTEXT BOUNDARIES:

- Variables from workflow.md are available in memory
- Steady-state hypotheses from step-02 are in the document
- Architecture document provides infrastructure layers and dependencies
- Infrastructure plan (if available) provides environment topology
- Focus on failure scenario design, not on game day logistics yet

## YOUR TASK:

Guide the user through identifying failure modes across all infrastructure layers, designing chaos experiments with blast radius controls, and prioritizing scenarios by risk and learning value.

## DISCOVERY SEQUENCE:

### 1. Identify Failure Modes by Infrastructure Layer

Walk through each layer systematically with the user:

**Compute:**
- Pod/instance crashes and restarts
- OOM (out of memory) kills
- CPU exhaustion and throttling
- Process hangs and zombie processes

**Network:**
- Latency injection between services
- Packet loss on critical paths
- DNS resolution failure
- Network partition between availability zones
- Load balancer health check manipulation

**Storage:**
- Disk full scenarios
- I/O latency injection
- Data corruption simulation
- Storage service unavailability

**Dependencies:**
- Upstream service timeout
- Downstream service unavailability
- Message queue backup and consumer lag
- Cache eviction and cold cache scenarios
- Database connection pool exhaustion

**Cloud Provider:**
- Availability zone failure
- Regional degradation
- Managed service outage (e.g., managed database, object storage)
- API rate limiting from cloud provider

### 2. Define Experiment Details for Each Failure Mode

For each identified failure mode, collaboratively define:

- **Expected impact on steady-state indicators** — Which hypotheses from step 2 will be tested?
- **Blast radius** — What else is affected? Can we contain it?
- **Detection time** — How quickly should alerts fire?
- **Recovery mechanism** — Auto-heal, manual intervention, or rollback?
- **Injection method** — What tool or technique introduces the failure?
- **Abort criteria** — When do we stop the experiment immediately?

### 3. Prioritize Scenarios

Help the user prioritize using two dimensions:

- **Risk score** = Likelihood x Impact (1-5 scale each)
- **Learning value** = How much will we learn from this experiment? (High/Medium/Low)

High-priority experiments are those with high risk score OR high learning value.

### 4. Map Dependency Failure Chains

Create a visual or tabular mapping of:

- Which services depend on which
- What happens when each dependency fails
- Where cascading failures could occur
- Which circuit breakers or bulkheads exist (or are missing)

### 5. Generate Failure Scenario Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 3. Failure Scenario Catalog

### 3.1 Failure Modes by Layer

| Layer | Failure Mode | Likelihood | Impact | Detection | Recovery | Priority |
|-------|-------------|-----------|--------|-----------|----------|----------|

### 3.2 Experiment Designs

| ID | Failure Scenario | Steady-State Hypothesis | Injection Method | Blast Radius Controls | Abort Criteria | Expected Outcome |
|----|-----------------|------------------------|-----------------|---------------------|----------------|-----------------|

### 3.3 Dependency Failure Map

- **Service A:**
  - Depends on: {list}
  - If unavailable, impacts: {list}
  - Circuit breaker: {yes/no — details}
  - Fallback behavior: {graceful degradation / hard failure}
```

### 6. Present Content and Menu

Show the generated content and present choices:

"Here are the failure scenarios and experiment designs I've drafted based on our discussion.

[Show the complete markdown content]

Each experiment is designed to test one or more steady-state hypotheses while maintaining strict blast radius controls and clear abort criteria.

**What would you like to do?**
[C] Continue - Save and move to game day planning
[R] Revise - Let's refine the failure scenarios"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the content to `{bgr_artifacts}/resilience-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3]`
  - `lastUpdated: {{current_date}}`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ All infrastructure layers covered with failure modes
✅ Every experiment has a clear hypothesis, injection method, and expected outcome
✅ Blast radius controls defined for every experiment
✅ Abort criteria documented for every experiment
✅ Scenarios prioritized by risk and learning value
✅ Dependency failure chains mapped
✅ C/R menu presented and handled correctly

## FAILURE MODES:

❌ Missing entire infrastructure layers in failure mode analysis
❌ Designing experiments without blast radius controls
❌ Not defining abort criteria — every experiment needs a kill switch
❌ Not connecting experiments back to steady-state hypotheses
❌ Ignoring dependency failures and cascading failure potential
❌ Generating content without user collaboration and input
❌ Proceeding without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, load `./step-04-game-day-planning.md` to begin planning game day exercises.

Remember: Do NOT proceed to step-04 until user explicitly selects [C] from the menu!
