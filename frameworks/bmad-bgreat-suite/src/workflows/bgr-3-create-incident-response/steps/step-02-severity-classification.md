# Step 2: Severity Classification & Escalation

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on severity definitions and escalation paths that fit the user's organization
- 🎯 ANALYZE loaded documents for clues about service criticality and team structure
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating severity classification
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, observability, PRD, etc.)
- Focus on severity definitions and escalation that match the user's team and services
- Adapt recommendations to team size and organizational structure

## YOUR TASK:

Collaboratively define severity levels (SEV1-SEV4) with clear criteria, response SLAs, communication requirements, and escalation paths tailored to the user's organization.

## SEVERITY CLASSIFICATION SEQUENCE:

### 1. Understand Organizational Context

Before proposing severity levels, discuss with the user:

- What is the team size and structure? (solo developer, small team, multiple teams, enterprise)
- Are there existing severity definitions or incident processes in place?
- What services or user journeys are most critical to the business?
- Is there an existing on-call rotation or is this being built from scratch?
- What communication tools are available? (PagerDuty, OpsGenie, Slack, email, status page)

### 2. Propose Severity Levels

Based on user context, propose severity definitions:

**SEV1 — Critical / Complete Outage:**
- Complete service outage or data loss affecting all users
- Security breach with active data exposure
- All hands on deck — incident commander activated immediately
- Response time SLA: acknowledge within 15 minutes
- Communication cadence: updates every 30 minutes to stakeholders
- Escalation: immediate page to on-call, team lead, engineering manager
- Status page: public incident posted immediately

**SEV2 — Major / Significant Degradation:**
- Major feature degraded with significant user impact
- Performance severely degraded (e.g., 10x latency increase)
- Data integrity issue affecting subset of users
- Response time SLA: acknowledge within 30 minutes
- Communication cadence: updates every 1 hour to stakeholders
- Escalation: page on-call engineer, notify team lead
- Status page: public incident posted within 30 minutes

**SEV3 — Minor / Limited Impact:**
- Minor feature impact with workaround available
- Non-critical service degradation
- Elevated error rates not yet impacting core user journeys
- Response time SLA: acknowledge within 2 hours
- Communication cadence: updates in engineering channel
- Escalation: notify on-call engineer via Slack/chat
- Status page: not required unless customer-visible

**SEV4 — Low / Cosmetic:**
- Cosmetic or low-impact issue
- Non-user-facing service degradation
- Technical debt causing minor operational friction
- Response time SLA: next business day
- Communication cadence: tracked in issue tracker
- Escalation: assigned to relevant team in normal workflow
- Status page: not required

Present these to the user and ask:
"Here's a proposed severity classification based on industry best practices. Let's adapt this to your specific needs.

**Key questions:**
- Do these severity levels match how your team thinks about incidents?
- Are the response time SLAs realistic for your team size?
- What communication tools should we map to each level?
- Should we adjust the escalation paths for your org structure?"

### 3. Define Escalation Matrix

Propose an escalation matrix and discuss with user:

| Time Elapsed | SEV1 | SEV2 | SEV3 | SEV4 |
|-------------|------|------|------|------|
| 0 min | On-call engineer paged | On-call engineer paged | On-call notified via chat | Ticket created |
| 15 min | Team lead notified | — | — | — |
| 30 min | Engineering manager notified | Team lead notified | — | — |
| 1 hour | VP/Director engaged | Engineering manager notified | On-call follows up | — |
| 4 hours | Executive briefing | VP/Director notified | Team lead review | — |

"Let's adapt this escalation matrix to your organization:
- Who are the escalation contacts at each level?
- Do you have different escalation paths for different services?
- Are there external stakeholders (customers, partners) who need specific notification?"

### 4. Define Communication Channels

Map communication channels per severity:

| Severity | Primary Alert | Team Communication | Stakeholder Updates | Public Status |
|----------|--------------|-------------------|--------------------|--------------|
| SEV1 | PagerDuty/phone | War room channel | Email + Slack exec channel | Status page |
| SEV2 | PagerDuty/push | Incident channel | Email summary | Status page (if visible) |
| SEV3 | Slack/chat | Team channel | Not required | Not required |
| SEV4 | Issue tracker | Team standup | Not required | Not required |

Discuss with user and adapt to their tooling.

### 5. Generate Severity Classification Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Severity Classification

| Level | Criteria | Response Time | Communication | Escalation |
|-------|----------|---------------|---------------|------------|
| SEV1 | {{sev1_criteria}} | {{sev1_response_time}} | {{sev1_communication}} | {{sev1_escalation}} |
| SEV2 | {{sev2_criteria}} | {{sev2_response_time}} | {{sev2_communication}} | {{sev2_escalation}} |
| SEV3 | {{sev3_criteria}} | {{sev3_response_time}} | {{sev3_communication}} | {{sev3_escalation}} |
| SEV4 | {{sev4_criteria}} | {{sev4_response_time}} | {{sev4_communication}} | {{sev4_escalation}} |

### Severity Decision Guide

{{decision_tree_or_guidelines_for_classifying_incidents}}

## 3. Escalation Matrix

{{escalation_matrix_table_with_time_based_escalation}}

### Escalation Contacts

{{named_roles_or_teams_at_each_escalation_level}}

### Communication Channels

{{channel_mapping_per_severity}}
```

### 6. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Severity Classification and Escalation Matrix based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 5]

**What would you like to do?**
[C] Continue - Save this and proceed to response procedures & on-call
[R] Revise - Let's adjust the severity levels, SLAs, or escalation paths"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/incident-response.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-response-procedures.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ Severity levels defined with clear, unambiguous criteria
✅ Response time SLAs realistic for user's team size
✅ Escalation matrix defined with time-based triggers
✅ Communication channels mapped per severity level
✅ Adapted to user's organizational structure and tooling
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Proposing severity levels without understanding team context
❌ Setting unrealistic response SLAs for the team size
❌ Generic escalation matrix not adapted to the organization
❌ Missing communication channel mapping
❌ Not discussing severity decision criteria with user
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-response-procedures.md` to define response procedures and on-call rotation.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the menu and content is saved!
