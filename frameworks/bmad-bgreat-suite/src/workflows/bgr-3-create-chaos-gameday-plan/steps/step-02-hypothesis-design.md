# Step 2: Hypothesis Design & Experiment Selection

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on defining well-formed hypotheses and selecting experiments appropriate for the team's maturity
- 🎯 ANALYZE loaded documents for SLOs, service topology, and known failure modes
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating hypothesis and experiment content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (observability, infrastructure, architecture, etc.)
- Focus on hypothesis quality and experiment scope — blast radius controls are handled in step 3
- Adapt recommendations to the team's chaos engineering maturity

## YOUR TASK:

Collaboratively define the game day scope, write well-formed hypotheses using the chaos engineering hypothesis template, and select a prioritized set of experiments.

## HYPOTHESIS DESIGN SEQUENCE:

### 1. Understand Game Day Context

Before proposing experiments, discuss with the user:

- What is the goal of this game day? (build confidence, validate a new service, test a specific failure mode, fulfill compliance requirement)
- What is the team's experience with chaos engineering? (first game day, experienced team, running automated chaos)
- What environment will experiments run in? (production, staging, a dedicated chaos environment)
- Are there specific failure scenarios the team is worried about or has never tested?
- Are there upcoming high-traffic events or releases that motivate testing specific failure modes?
- What is the planned game day window? (full day, half day, 2-hour focused session)

### 2. Identify Steady-State Metrics

Steady-state metrics define "normal" — what you measure to determine if the system is behaving correctly.

If an observability plan was loaded, surface its SLOs as steady-state candidates:
- "Your observability plan defines a 99.9% availability SLO for the API gateway — this is an excellent steady-state metric."
- "The observability plan shows a p99 latency target of 500ms for checkout — we can use this as a steady-state threshold."

If no observability plan is available, help the user define metrics manually:
- Which metrics indicate healthy system behavior? (request success rate, latency percentiles, error rate, queue depth, etc.)
- What thresholds distinguish normal from degraded?
- Where are these metrics visible? (dashboards, runbooks, alerting tools)

Ask: "What signals tell you the system is working correctly right now? Let's use those as our steady-state baseline."

### 3. Propose Experiment Candidates

Based on the architecture and failure modes identified, propose a prioritized list of experiment candidates:

**Infrastructure-Level Experiments (Riley's domain — involve Riley if infrastructure IaC context is available):**
- Pod / instance termination (single and cascading)
- Node failure and auto-scaling validation
- Network partition between services
- Latency injection into service-to-service calls
- Resource exhaustion (CPU, memory, disk I/O)
- DNS failure and service discovery disruption

**Application-Level Experiments:**
- Dependency timeout and slow response injection
- Upstream service unavailability
- Database connection pool exhaustion
- Cache failure and fallback behavior
- Queue consumer lag or consumer failure
- Circuit breaker validation (trips and recovers correctly)

**Data-Level Experiments:**
- Read replica lag injection
- Storage unavailability for non-critical paths
- Schema migration rollback validation

**Security-Boundary Experiments (Sam's domain — surface for blast radius review in step 3):**
- Rate limiting under load
- Authentication service degradation
- Secrets rotation under traffic

Help the user select 3-5 experiments that are well-matched to the game day window and the team's experience level.

### 4. Write Hypothesis Statements

For each selected experiment, collaboratively write a well-formed hypothesis using the structure:

> **When** [fault condition is introduced],
> **We expect** [specific measurable behavior],
> **Because** [the system design rationale],
> **Measured by** [specific metric and threshold].

**Example — Pod Termination:**
> **When** a single API service pod is terminated,
> **We expect** the service to remain available with no user-visible errors,
> **Because** Kubernetes will reschedule the pod within 30 seconds and the load balancer will route traffic to healthy pods,
> **Measured by** HTTP success rate staying above 99.5% and p99 latency staying below 600ms throughout the experiment.

**Example — Dependency Timeout:**
> **When** the payment service introduces a 3-second artificial delay in responses to the checkout service,
> **We expect** the checkout service to return a degraded (but non-error) response to users within its timeout budget,
> **Because** the checkout service implements a circuit breaker with a 2-second timeout and a graceful fallback,
> **Measured by** checkout service error rate staying below 0.1% and circuit breaker opening within 5 seconds.

Work through each selected experiment with the user to ensure:
- The steady-state is defined with specific, measurable thresholds
- The "because" clause reflects the actual system design
- The metric is observable with available tooling

### 5. Define Experiment Scope and Sequence

For each experiment, define:
- **Target service(s)**: which services or infrastructure components are affected
- **Experiment duration**: how long the fault condition will be active
- **Blast radius scope**: estimated number of affected users or service instances (detailed controls in step 3)
- **Sequence order**: which experiments run first (safer, lower blast radius experiments first)

Recommend sequencing rules:
- Start with read-only or reversible experiments before destructive ones
- Start in lower environments or non-critical services before production
- Run experiments with known good recovery paths before untested ones
- Schedule high-risk experiments early in the day when the team is fresh

### 6. Generate Hypothesis and Experiment Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Game Day Scope and Goals

- **Goal**: {{game_day_goal}}
- **Environment**: {{target_environment}}
- **Session window**: {{planned_date_and_duration}}
- **Team experience level**: {{chaos_maturity}}

## 3. Steady-State Metrics

| Metric | Normal Range | Threshold | Source |
|--------|-------------|-----------|--------|
{{steady_state_metrics_rows}}

## 4. Experiments

{{for each experiment:}}
### Experiment {{N}}: {{experiment_name}}

**Hypothesis:**
> When {{fault_condition}},
> We expect {{measurable_outcome}},
> Because {{system_design_rationale}},
> Measured by {{metric_and_threshold}}.

**Experiment Details:**
- **Fault type**: {{fault_type}}
- **Target**: {{target_service_or_component}}
- **Duration**: {{fault_duration}}
- **Sequence position**: {{order_in_game_day}}

{{/for each experiment}}

## 5. Experiment Sequence

| Order | Experiment | Target | Risk Level | Rationale |
|-------|-----------|--------|-----------|-----------|
{{experiment_sequence_rows}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the game day scope, steady-state metrics, hypotheses, and experiment sequence based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this and proceed to blast radius controls and safety gates
[R] Revise - Let's adjust the hypotheses, experiment selection, or sequence"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/chaos-gameday-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-blast-radius-safety.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ Game day goal and context understood
✅ Steady-state metrics defined with specific, measurable thresholds
✅ Experiments selected appropriate to team maturity and game day window
✅ Each experiment has a well-formed hypothesis (When/Expect/Because/Measured by)
✅ Experiment sequence prioritizes safer experiments first
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Proposing experiments without understanding team's chaos maturity
❌ Writing vague hypotheses without measurable outcomes
❌ Selecting too many experiments for the available time window
❌ Not using SLOs from observability plan as steady-state baselines when available
❌ Sequencing high-risk experiments before safer validation ones
❌ Not discussing steady-state metrics before defining hypotheses

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-blast-radius-safety.md` to define blast radius controls, safety gates, and rollback procedures.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the menu and content is saved!
