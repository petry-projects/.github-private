# Step 3: Blast Radius Controls & Safety Gates

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on practical, enforceable controls — not theoretical risk assessments
- 🎯 BUILD on the experiments defined in step 2 to create specific controls for each
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating blast radius and safety content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Experiments and hypotheses from step 2 are in the document
- Input documents (infrastructure plan, incident response plan) are available for context
- Focus on controls that are enforceable during the game day — not wishful thinking
- Sam (Security Lead) should be consulted for experiments touching authentication, authorization, or secrets

## YOUR TASK:

Collaboratively define blast radius controls, abort conditions, pre-game-day checks, rollback procedures, and safety gates for each experiment. Ensure the game day can be stopped safely at any point.

## BLAST RADIUS AND SAFETY SEQUENCE:

### 1. Define Blast Radius for Each Experiment

For each experiment defined in step 2, work with the user to quantify and bound the blast radius:

**Blast Radius Dimensions:**
- **User impact scope**: How many users or sessions are potentially affected? (e.g., "10% of traffic", "all users of checkout service", "only internal admin users")
- **Service dependency scope**: Which downstream services could be affected beyond the primary target?
- **Data risk**: Could any experiment cause data loss, corruption, or inconsistency? (even temporarily)
- **Financial risk**: Could the experiment trigger cost spikes (e.g., auto-scaling, data transfer, retries)?
- **External dependencies**: Could the fault propagate to external partners, payment processors, or third-party services?

Ask: "For each experiment, let's identify who and what could be affected beyond the intended target — and how we can limit that impact."

**Blast Radius Containment Strategies:**
- Run in a non-production environment first
- Limit fault injection to a subset of pods/instances (e.g., 1 of 10 replicas)
- Use feature flags to restrict fault injection to internal test users
- Set a short experiment window (inject fault, observe, remove fault quickly)
- Use traffic mirroring rather than live traffic where possible

### 2. Define Abort Conditions (Stop Experiment Triggers)

For each experiment, define clear, unambiguous abort conditions — the signals that mean "stop immediately regardless of planned duration":

**Default Abort Triggers (apply to all experiments):**
- Steady-state metric breaches threshold for more than [N] consecutive minutes
- An on-call page fires during the experiment
- User-facing error rate exceeds [X]% for [N] seconds
- Any team member calls abort verbally ("I'm calling abort")
- The rollback procedure fails to restore service within [timeout]

**Experiment-Specific Abort Conditions:**
For each experiment, define additional abort triggers based on its specific fault type and target. For example:
- Pod termination: abort if more than [N] pods are in CrashLoopBackOff simultaneously
- Network partition: abort if database replication lag exceeds [threshold]
- CPU stress: abort if host CPU exceeds [X]% for more than [N] seconds

**Abort Decision Authority:**
- Who can call an abort? (any participant, only the game day lead, designated safety officer)
- How is abort communicated? (verbal call in game day channel, Slack command, dedicated abort button)
- Does an abort require consensus or is it a unilateral decision? (recommend: any participant can abort unilaterally)

### 3. Define Pre-Game-Day Checks

Pre-checks are gate conditions that must pass before the game day can begin. They confirm the system is in a known-good state before introducing faults.

**System Health Pre-checks:**
- All steady-state metrics are within normal range for the past [N] hours
- No active incidents or degraded services in target environment
- No recent deployments in the target environment in the past [N] hours (configurable per team)
- All observability dashboards and alerting are confirmed functional
- On-call rotation is staffed and aware of the game day
- Rollback tools and procedures have been reviewed by participants

**Environment Pre-checks (from infrastructure plan if available):**
- Infrastructure is at expected scale (no scaled-down resources that would make results unrepresentative)
- Load balancers and health checks are in normal configuration
- Backups are current and verified for any experiments touching data

**Team Readiness Pre-checks:**
- All experiment participants are present and confirmed in the game day channel
- Roles are assigned: Game Day Lead, Safety Officer, Scribe, Tool Operator(s)
- Rollback procedures have been rehearsed or at minimum reviewed
- Communication channel (Slack, video bridge) is open and working

Ask: "What pre-checks do you want to enforce before starting the game day? We should err on the side of caution here."

### 4. Define Rollback Procedures

For each experiment, define an explicit, tested rollback procedure:

**Rollback Principles:**
- Every experiment must have a rollback defined before it runs
- Rollback should be automated where possible (e.g., re-enabling a feature flag, restarting a service)
- Manual rollback steps must be documented and reviewed by the tool operator before the game day
- Rollback must be tested in a non-production environment first when feasible
- A rollback time SLA should be defined (e.g., "service must be restored within 5 minutes of abort")

**Rollback by Fault Type:**
- Pod termination: Kubernetes auto-healing (observe natural recovery; manual: scale up deployment)
- Network partition: Remove network policy or firewall rule; restore service mesh routing
- Latency injection: Remove latency rule from service mesh or load balancer; confirm metric recovery
- CPU/memory stress: Kill stress tool process; confirm resource metrics normalize
- Feature flag fault: Disable fault injection flag in feature flag system
- Instance termination: Auto-scaling group replacement (observe); manual: launch replacement instance

Work with the user to define rollback for each specific experiment planned.

### 5. Define Safety Gates

Safety gates are automated or manual checks that pause or stop the game day if conditions are unsafe:

**Game Day Safety Gate Layers:**

| Gate Layer | Trigger | Action |
|-----------|---------|--------|
| Pre-game gate | Any pre-check fails | Do not start game day; reschedule |
| Between-experiment gate | Steady state not restored after previous experiment | Hold; do not start next experiment until restored |
| Mid-experiment gate | Abort condition triggered | Immediately execute rollback; pause game day |
| Post-experiment gate | Service not restored within rollback SLA | Escalate to on-call; cancel remaining experiments |
| End-of-day gate | Any open issues or incomplete rollbacks | Do not close game day; ensure all systems restored before team leaves |

**Monitoring During Experiments:**
- Who is watching the dashboards during each experiment?
- Is alerting in a suppressed state for expected metrics, or will it fire normally? (recommend: do NOT suppress alerts — if they fire, treat them seriously)
- What is the communication channel for calling abort?

### 6. Security Review for Relevant Experiments (Sam's Domain)

If any experiments touch authentication, authorization, rate limiting, secrets, or external-facing services:

Prompt: "Some of the experiments you've selected touch security-sensitive areas. Let's review the blast radius from a security perspective:
- Could this experiment expose internal endpoints or data to unintended parties?
- Could a cascading failure bypass rate limiting or authentication checks?
- Could secrets be inadvertently exposed during service restarts or crashes?
- Should Sam (Security Lead) be included in the pre-game review for these experiments?"

Note any security-relevant blast radius concerns in the plan.

### 7. Generate Blast Radius and Safety Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 6. Blast Radius Controls

{{for each experiment:}}
### {{Experiment N}} — {{experiment_name}}

**Blast Radius:**
- User impact: {{user_scope}}
- Service scope: {{downstream_services_affected}}
- Data risk: {{data_risk_assessment}}
- Financial risk: {{cost_risk_if_any}}
- Containment strategy: {{how_blast_radius_is_limited}}

**Abort Conditions:**
- {{abort_condition_1}}
- {{abort_condition_2}}
- {{experiment_specific_abort_conditions}}

**Rollback Procedure:**
1. {{rollback_step_1}}
2. {{rollback_step_2}}
3. {{verification_step — confirm steady-state metrics restored}}

**Rollback SLA:** Service restored within {{N}} minutes of abort

{{/for each experiment}}

## 7. Pre-Game-Day Checklist

### System Health
- [ ] {{pre_check_1}}
- [ ] {{pre_check_2}}
- [ ] All steady-state metrics within normal range for past {{N}} hours
- [ ] No active incidents in target environment
- [ ] No recent deployments in past {{N}} hours

### Team Readiness
- [ ] All participants confirmed in game day channel
- [ ] Roles assigned: Game Day Lead, Safety Officer, Scribe, Tool Operator(s)
- [ ] Rollback procedures reviewed by all tool operators
- [ ] Communication channel open and tested

## 8. Safety Gates

| Gate | Trigger | Action |
|------|---------|--------|
| Pre-game | Any pre-check fails | Reschedule game day |
| Between experiments | Steady state not restored | Hold until restored |
| Mid-experiment abort | Abort condition triggered | Execute rollback immediately |
| Post-experiment | Rollback SLA breached | Escalate to on-call; cancel remaining experiments |
| End of day | Any open issues | Do not close until all systems restored |

**Abort Authority:** {{who_can_call_abort — recommend: any participant}}
**Abort Channel:** {{communication_channel_for_calling_abort}}

## 9. Game Day Roles

| Role | Responsibility | Assigned To |
|------|---------------|-------------|
| Game Day Lead | Owns the game day agenda, pacing, and go/no-go decisions | |
| Safety Officer | Monitors steady-state metrics; calls abort if conditions met | |
| Tool Operator(s) | Executes fault injection and rollback commands | |
| Scribe | Records observations, timeline, and findings in real time | |
| Observer(s) | Watches service behavior and secondary metrics | |
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the blast radius controls, safety gates, pre-checks, rollback procedures, and game day roles based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this and proceed to execution plan and observation
[R] Revise - Let's adjust controls, abort conditions, rollback procedures, or roles"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/chaos-gameday-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-execution-observation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Blast radius quantified for each experiment across all four dimensions (users, services, data, cost)
✅ Containment strategies defined for each experiment
✅ Abort conditions are specific and unambiguous — no vague triggers
✅ Rollback procedures are step-by-step and reviewed
✅ Pre-game-day checklist is thorough and enforceable
✅ Safety gate layers cover pre-, during-, and post-experiment scenarios
✅ Abort authority and communication channel are defined
✅ Security-sensitive experiments flagged for Sam's review where applicable
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining blast radius without quantifying the user or service impact
❌ Vague abort conditions ("if things look bad") that can't be objectively applied
❌ Rollback procedures that haven't been tested or reviewed
❌ Missing pre-game-day checks that assume the system is in a known-good state
❌ Not defining abort authority — ambiguity leads to hesitation when it matters
❌ Not flagging security-sensitive experiments for Sam's review

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-execution-observation.md` to define the game day execution schedule, observation points, and post-game analysis template.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the menu and content is saved!
