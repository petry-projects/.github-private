# Step 4: Runbooks & Postmortems

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on practical runbook standards and a postmortem process the team will actually follow
- 🎯 USE architecture docs to identify services that need runbooks
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating runbook and postmortem content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Severity classification and response procedures from steps 2-3 are in the document
- Architecture and observability documents (if loaded) inform runbook identification
- Focus on defining standards, not writing full runbooks (those come later)
- Postmortem process should tie back to severity triggers from step 2

## YOUR TASK:

Collaboratively define the runbook standard structure, identify initial runbooks needed, define the postmortem process with templates, and establish blameless culture principles.

## RUNBOOKS & POSTMORTEMS SEQUENCE:

### 1. Define Runbook Standard Structure

Present the runbook standard and discuss with user:

**Runbook Structure:**

Every runbook should follow a consistent format:

| Section | Purpose |
|---------|---------|
| **Summary** | Impact description, detection method, runbook owner |
| **Immediate Actions** | Numbered steps to stabilize the service — what to do in the first 5 minutes |
| **Diagnostics** | What to check and how — specific commands, dashboards, log queries |
| **Mitigations** | Specific fixes or workarounds to restore service |
| **Verification** | How to confirm the issue is actually resolved |
| **References** | Links to dashboards, log systems, relevant contacts, architecture docs |

Point the user to the runbook template: `The runbook template is available at ../templates/runbook-template.md for creating individual runbooks.`

Ask user:
"Does this runbook structure work for your team? Key questions:
- Do you want to add any additional sections (e.g., customer communication, known false positives)?
- Should runbooks include rollback procedures as a standard section?
- Where should runbooks be stored and how should they be kept up to date?"

### 2. Identify Initial Runbooks Needed

Based on architecture documents (if available) and discussion with user, identify the runbooks that should be created:

**Common runbook categories:**

- **Database**: Connection pool exhaustion, replication lag, disk space, backup failure, slow queries
- **API/Web**: High latency, elevated error rates, certificate expiration, rate limiting
- **Queue/Messaging**: Consumer lag, dead letter queue growth, message processing failures
- **Authentication**: Auth service degradation, token expiration issues, SSO failures
- **Infrastructure**: Node unhealthy, disk full, memory pressure, network partition
- **External Dependencies**: Third-party API degradation, CDN issues, DNS failures
- **Deployment**: Failed deployment rollback, canary failure, feature flag emergency disable

Ask user:
"Based on your architecture, here are the runbooks I'd recommend starting with:

[List runbooks based on discovered architecture components]

**Questions:**
- Which of these are highest priority for your team?
- Are there any failure modes specific to your system that I missed?
- Do you have any existing runbooks we should incorporate?"

### 3. Define Postmortem Process

**Trigger Criteria:**
- SEV1: Postmortem always required
- SEV2: Postmortem required if any of: customer impact > X users, duration > 1 hour, data integrity affected, or repeat incident
- SEV3/SEV4: Postmortem optional, at team discretion

**Timeline:**
- Postmortem document started within 24 hours of resolution
- Initial draft completed within 48 hours of resolution
- Team review scheduled within 5 business days
- Action items assigned with owners and deadlines during review
- Follow-up verification within 30 days

**Postmortem Template:**
Point user to: `The postmortem template is available at ../templates/postmortem-template.md`

Key sections in the template:
- **Incident Summary**: What happened in 2-3 sentences
- **Timeline**: Chronological events from detection to resolution
- **Impact**: Users affected, revenue impact, SLO budget consumed
- **Root Cause**: The underlying technical cause
- **Contributing Factors**: What made the incident possible or worse
- **What Went Well**: Effective responses and tooling that helped
- **What Could Be Improved**: Process or tooling gaps identified
- **Action Items**: Specific tasks with owner, priority, due date, and status

**Review Process:**
- Postmortem author presents to the team
- Focus on learning, not blame
- Action items must be specific, owned, and time-bound
- Track action items in issue tracker (not just the document)
- Follow-up review to verify action items are completed

### 4. Establish Blameless Culture Principles

Discuss blameless postmortem culture:

**Core Principles:**
- People did the best they could with the information they had at the time
- Focus on systems and processes, not individuals
- "How did our system allow this to happen?" not "Who caused this?"
- Punishing people for honest mistakes drives incidents underground
- The goal is to make the system more resilient, not to assign fault

**Practical Implementation:**
- Use "the system" or "the process" as subjects, not people's names when describing failures
- Frame findings as "Contributing factors" not "Mistakes"
- Celebrate transparency — acknowledging errors is valued
- Action items improve systems, not police behavior
- Leadership must visibly support blamelessness

Ask user:
"Blameless postmortems are fundamental to effective incident learning. How does this approach align with your team's culture?
- Is there existing organizational support for blamelessness?
- Are there any specific concerns about implementing this?
- Should we add any team-specific norms?"

### 5. Generate Runbooks & Postmortems Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 6. Runbook Standards

### 6.1 Runbook Template

{{runbook_structure_summary_with_reference_to_template}}

### 6.2 Required Runbooks

| Service | Failure Mode | Runbook | Owner | Last Tested |
|---------|-------------|---------|-------|-------------|
{{identified_runbooks_table}}

### 6.3 Runbook Maintenance

{{how_runbooks_are_kept_current_review_cadence_testing}}

## 7. Postmortem Process

### 7.1 Trigger Criteria

{{when_postmortems_are_required_vs_optional}}

### 7.2 Timeline & Ownership

{{postmortem_timeline_from_incident_to_action_item_completion}}

### 7.3 Postmortem Template

{{template_reference_and_key_sections_summary}}

### 7.4 Action Item Tracking

{{how_action_items_are_tracked_and_followed_up}}

### 7.5 Blameless Culture

{{blameless_principles_and_practical_implementation}}
```

### 6. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Runbook Standards and Postmortem Process based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 5]

**What would you like to do?**
[C] Continue - Save this and proceed to validation & finalization
[R] Revise - Let's adjust the runbook standards, postmortem process, or identified runbooks"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/incident-response.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ Runbook standard structure defined and agreed upon
✅ Initial runbooks identified based on architecture and team needs
✅ Postmortem trigger criteria tied to severity levels
✅ Postmortem timeline and ownership clearly defined
✅ Action item tracking process established
✅ Blameless culture principles documented
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining runbook standards without considering what the team will actually maintain
❌ Not using architecture docs to identify needed runbooks
❌ Postmortem process that's too heavyweight for the team to follow
❌ Missing blameless culture principles
❌ Not connecting postmortem triggers to severity classification
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate and finalize the incident response plan.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the menu and content is saved!
