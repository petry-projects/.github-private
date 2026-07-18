# Step 4: Game Day Planning

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on planning structured game day exercises and roles
- ✅ DESIGN progressive complexity — start simple, increase scope over time
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present C/R menu after generating content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to save or proceed until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the game day plan and move to validation
- **R (Revise)**: Discuss changes, refine the plan, then re-present the menu

## CONTEXT BOUNDARIES:

- Variables from workflow.md are available in memory
- Steady-state hypotheses from step-02 are in the document
- Failure scenarios from step-03 are in the document
- Incident response plan (if available) provides roles and procedures
- Focus on game day logistics and procedures, not on defining new failure scenarios

## YOUR TASK:

Guide the user through planning game day exercises — from tabletop walkthroughs to live failure injection — including roles, communication plans, abort procedures, scheduling cadence, and progressive complexity.

## DISCOVERY SEQUENCE:

### 1. Define Game Day Types

Collaboratively define the types of exercises the team will conduct:

**Tabletop Exercises:**
- Scenario walkthrough without live injection
- Team discusses "what would we do if X happened?"
- Low risk, high learning value for new teams
- Good for validating runbooks and communication procedures

**Live Experiments:**
- Actual failure injection with controls in place
- Uses the experiment designs from step 3
- Requires abort authority and monitoring
- Progressive: start in staging, graduate to production

**Full Game Days:**
- Multi-hour coordinated exercise
- Multiple failure scenarios in sequence
- Tests cross-team coordination and communication
- Scheduled in advance with full team participation

### 2. Define Game Day Roles

For each type of exercise, define who participates and what they do:

**Key Questions to Discuss:**
- "Who has authority to abort an experiment immediately?"
- "Who observes and takes notes vs. who actively responds?"
- "How do we ensure the game day doesn't impact real customers?"
- "Who is responsible for communicating status to stakeholders?"

**Standard Roles:**
- **Facilitator** — Runs the exercise, injects failures, controls pacing
- **Observer** — Documents what happens, tracks timeline, notes surprises
- **Responders** — The team being tested, responding as they would in a real incident
- **Abort Authority** — Single person with power to stop the experiment immediately
- **Communications Lead** — Handles any external communication if needed

### 3. Design Communication Plan

Define how experiments are announced and coordinated:

- Pre-experiment notification (who, when, how)
- During-experiment status updates
- Post-experiment debrief scheduling
- Stakeholder communication (if production experiments)
- Incident channel usage during game days

### 4. Define Abort Criteria and Runback Procedures

For every game day type:

- **Abort triggers** — Conditions that immediately stop the experiment
  - Real incident detected during exercise
  - Blast radius exceeds defined boundaries
  - Customer impact detected beyond acceptable threshold
  - Experiment cannot be reversed within defined timeframe
- **Runback procedures** — How to undo experiment effects
  - Automated rollback mechanisms
  - Manual intervention steps
  - Verification that steady state is restored
  - Post-abort incident review process

### 5. Plan Scheduling Cadence

Collaboratively define:

- How often each type of exercise runs
- Progressive complexity over time
- How to balance game days with feature development
- Criteria for graduating from staging to production experiments

### 6. Design Progressive Complexity Path

Start simple and increase scope over time:

- **Phase 1**: Tabletop exercises for all scenarios
- **Phase 2**: Single-service experiments in staging
- **Phase 3**: Multi-service experiments in staging
- **Phase 4**: Single-service experiments in production (during low-traffic)
- **Phase 5**: Multi-service production game days

### 7. Generate Game Day Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 4. Game Day Planning

### 4.1 Game Day Types

| Type | Description | Frequency | Participants | Prerequisites |
|------|-------------|-----------|-------------|---------------|

### 4.2 Game Day Roles

| Role | Responsibilities | Required Skills |
|------|-----------------|----------------|

### 4.3 Game Day Schedule

| Quarter | Exercise Type | Target System | Scenario | Complexity |
|---------|-------------|--------------|----------|-----------|

### 4.4 Abort Criteria & Runback Procedures

**Abort Triggers:**
- {list of conditions that immediately stop any experiment}

**Runback Procedures:**
- {step-by-step procedures to undo experiment effects}

**Communication Plan:**
- Pre-experiment: {notification procedure}
- During experiment: {status update procedure}
- Post-experiment: {debrief procedure}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"Here's the game day planning framework I've drafted based on our discussion.

[Show the complete markdown content]

This gives your team a structured path from tabletop walkthroughs to full production game days, with clear roles, abort criteria, and progressive complexity.

**What would you like to do?**
[C] Continue - Save and move to validation
[R] Revise - Let's refine the game day plan"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Append the content to `{bgr_artifacts}/resilience-plan.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4]`
  - `lastUpdated: {{current_date}}`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Game day types defined with clear descriptions and prerequisites
✅ Roles defined with responsibilities and required skills
✅ Communication plan documented for all phases of an exercise
✅ Abort criteria defined with clear triggers and runback procedures
✅ Scheduling cadence established with progressive complexity
✅ Progressive complexity path designed from tabletop to production
✅ C/R menu presented and handled correctly

## FAILURE MODES:

❌ Planning live experiments without abort criteria
❌ Not defining roles — especially abort authority
❌ Missing communication plan for stakeholders
❌ Not designing progressive complexity — jumping to production too fast
❌ Not defining runback procedures for every experiment type
❌ Generating content without user collaboration and input
❌ Proceeding without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, load `./step-05-validation.md` to validate the complete resilience testing plan.

Remember: Do NOT proceed to step-05 until user explicitly selects [C] from the menu!
