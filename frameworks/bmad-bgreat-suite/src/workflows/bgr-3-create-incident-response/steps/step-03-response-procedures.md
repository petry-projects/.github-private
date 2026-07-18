# Step 3: Response Procedures & On-Call

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on practical response procedures that work for the user's team
- 🎯 BUILD on severity definitions from step 2 to create actionable procedures
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating response procedures
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Severity classification and escalation matrix from step 2 are in the document
- Input documents and organizational context are available from earlier steps
- Focus on operational procedures: who does what, when, and how
- Adapt to team size — solo developer procedures differ from enterprise

## YOUR TASK:

Collaboratively define incident commander role, on-call rotation, response workflow, communication templates, and war room procedures tailored to the user's team.

## RESPONSE PROCEDURES SEQUENCE:

### 1. Define Incident Commander Role

Discuss incident commander (IC) responsibilities with user:

**IC Responsibilities:**
- Owns the incident from declaration to resolution
- Coordinates response efforts across teams
- Makes decisions about mitigation strategies
- Ensures communication cadence is maintained
- Delegates tasks: communications lead, technical lead, scribe
- Determines when to escalate and when to de-escalate
- Triggers postmortem process after resolution

**IC Selection:**
- SEV1/SEV2: Most senior available engineer or designated IC on rotation
- SEV3: On-call engineer acts as IC
- SEV4: No IC needed — handled through normal workflow

Ask user:
"How should we handle the incident commander role for your team?
- Do you have enough people to separate IC from hands-on-keyboard responder?
- Should we define a rotating IC schedule or is it always the on-call?
- For a smaller team, one person often fills multiple roles — how does that work for you?"

### 2. Define On-Call Rotation

Discuss on-call structure with user:

**Rotation Schedule:**
- Rotation cadence: weekly, bi-weekly, or custom
- Handoff day and time (e.g., Monday 10:00 AM local time)
- Handoff protocol: outgoing engineer briefs incoming on active issues, pending alerts, and recent changes
- Primary and secondary on-call (if team size allows)

**Coverage Requirements:**
- Expected response time during business hours vs off-hours
- Laptop and connectivity requirements during on-call
- Maximum consecutive on-call shifts
- Holiday and vacation coverage planning

**Fatigue Management:**
- Maximum on-call hours before mandatory rest
- Follow-the-sun rotation if applicable (multiple time zones)
- Compensatory time off after SEV1/SEV2 incidents
- Alert noise budget — if on-call is paged too frequently, prioritize alert tuning

Ask user:
"Let's design an on-call rotation that works for your team:
- How many engineers can participate in the rotation?
- What time zone(s) does your team cover?
- Do you have existing on-call tooling (PagerDuty, OpsGenie, etc.)?
- How do you want to handle off-hours coverage?"

### 3. Define Response Workflow

Walk through the end-to-end response workflow:

**Detection → Triage → Communicate → Mitigate → Resolve → Postmortem**

**Detection:**
- Alert fires from monitoring/observability system
- Customer report via support channel
- Engineer discovers issue during routine work
- Automated health check failure

**Triage:**
- On-call acknowledges alert within response SLA
- Assess severity using classification from step 2
- Declare incident and open incident channel/ticket
- Page additional responders if needed

**Communicate:**
- Post initial status update (internal)
- Update status page if customer-visible (SEV1/SEV2)
- Notify stakeholders per escalation matrix
- Maintain update cadence per severity level

**Mitigate:**
- Follow applicable runbook if one exists
- Prioritize stabilization over root cause analysis
- Consider rollback, feature flag disable, traffic reroute
- Document actions taken in incident timeline

**Resolve:**
- Confirm service is restored to normal operation
- Verify with monitoring that metrics are healthy
- Update status page to resolved
- Send resolution notification to stakeholders

**Postmortem:**
- Schedule postmortem per trigger criteria (defined in step 4)
- Assign postmortem owner
- Collect timeline and artifacts

### 4. Define Communication Templates

Propose templates for each communication type:

**Internal Status Update:**
```
🔴 INCIDENT: [Title]
Severity: [SEV level]
Status: [Investigating / Identified / Monitoring / Resolved]
Impact: [What users are experiencing]
Current actions: [What we're doing]
Next update: [Time]
IC: [Name]
```

**Customer-Facing Status Page:**
```
[Service Name] — [Degraded Performance / Partial Outage / Major Outage]
We are aware of an issue affecting [description of impact].
Our team is actively investigating and working to resolve this.
We will provide updates as we have more information.
Last updated: [Time]
```

**Stakeholder Notification:**
```
Subject: [SEV level] Incident — [Brief title]

Summary: [1-2 sentence description of the incident and impact]
Start time: [When the incident began]
Current status: [What we know and what we're doing]
Customer impact: [Number of users affected, revenue impact if known]
Next update: [Expected time of next communication]
Incident lead: [Name and contact]
```

Discuss with user and adapt to their communication style and tools.

### 5. Define War Room Procedures

**War Room Activation:**
- SEV1: Immediately open war room (dedicated Slack channel or video call)
- SEV2: Open war room if not resolved within 30 minutes
- SEV3/SEV4: No war room needed

**War Room Roles:**
- Incident Commander: owns decisions and coordination
- Technical Lead: hands-on-keyboard debugging and mitigation
- Communications Lead: handles stakeholder updates and status page
- Scribe: documents timeline, decisions, and actions in real time

**War Room Rules:**
- Keep discussion focused on mitigation, not root cause
- IC makes final decisions when consensus isn't reached
- Status updates at regular intervals (per severity cadence)
- Non-essential discussion moves to a separate thread

Ask user:
"For war room procedures:
- What tool would you use for your war room? (Slack channel, Zoom, Google Meet)
- For smaller teams, do you want to simplify the roles?
- Are there any specific coordination needs for your team?"

### 6. Generate Response Procedures Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 4. On-Call Procedures

### 4.1 Rotation Schedule

{{rotation_cadence_schedule_and_participants}}

### 4.2 Handoff Protocol

{{handoff_day_time_and_briefing_process}}

### 4.3 Fatigue Management

{{max_hours_compensatory_time_and_noise_budget}}

## 5. Response Workflow

### 5.1 Detection & Triage

{{detection_sources_and_triage_process}}

### 5.2 Communication Templates

#### Internal Status Update
{{internal_template}}

#### Customer-Facing Status Page
{{customer_template}}

#### Stakeholder Notification
{{stakeholder_template}}

### 5.3 War Room Procedures

{{war_room_activation_criteria_roles_and_rules}}

### 5.4 Mitigation & Resolution

{{mitigation_priorities_resolution_verification_and_handoff_to_postmortem}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Response Procedures and On-Call section based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this and proceed to runbooks & postmortems
[R] Revise - Let's adjust the procedures, on-call setup, or templates"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/incident-response.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-runbooks-postmortems.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ Incident commander role defined and adapted to team size
✅ On-call rotation designed with realistic coverage
✅ End-to-end response workflow documented
✅ Communication templates ready for each audience
✅ War room procedures defined with activation criteria
✅ Fatigue management and on-call wellness addressed
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining procedures that don't match team size or structure
❌ Setting up on-call rotation without considering team capacity
❌ Missing communication templates for key audiences
❌ Not addressing war room procedures for critical incidents
❌ Ignoring on-call fatigue and wellness
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-runbooks-postmortems.md` to define runbook standards and postmortem process.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the menu and content is saved!
