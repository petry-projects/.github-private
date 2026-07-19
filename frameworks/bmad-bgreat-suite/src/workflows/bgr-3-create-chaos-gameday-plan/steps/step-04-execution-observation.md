# Step 4: Execution Plan, Observation & Post-Game Analysis

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on the game day execution flow, what to watch during each experiment, and how to capture findings
- 🎯 TIE observation points to the SLOs and metrics defined in earlier steps
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating execution and observation content
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Experiments, hypotheses, blast radius controls, and safety gates from steps 2-3 are in the document
- Input documents (observability plan, infrastructure plan) are available for context
- Focus on the practical game day schedule, what to observe, and how to record findings
- The post-game analysis template should be ready to fill in immediately after the game day

## YOUR TASK:

Collaboratively define the game day execution schedule, observation points tied to steady-state metrics, real-time recording practices, and the post-game analysis template with findings-to-action tracking.

## EXECUTION AND OBSERVATION SEQUENCE:

### 1. Define the Game Day Execution Schedule

Build a structured agenda for the game day session:

**Game Day Structure:**

- **Pre-game window** (30-60 minutes): run pre-checks, confirm team readiness, brief on hypotheses and abort conditions
- **Experiment blocks**: each experiment gets a dedicated time block with buffer for observation
- **Between-experiment recovery windows**: allow time for steady-state metrics to normalize before starting the next experiment
- **Lunch/break** (if full-day): schedule a break that does not fall during an active experiment
- **Post-game retrospective**: structured debrief, findings capture, action item assignment

Ask: "How long is your planned game day window, and how many experiments are you targeting? Let's build an agenda that isn't rushed — experiments need breathing room between them."

**Experiment Block Structure:**
Each experiment block should follow this sequence:
1. **Pre-experiment checkpoint** (5 min): confirm all abort conditions are clear, verify steady-state metrics are nominal
2. **Fault injection start**: tool operator introduces the fault as planned
3. **Observation window**: team watches dashboards and records observations
4. **Fault removal**: tool operator removes the fault per procedure
5. **Recovery window**: team observes restoration of steady-state metrics
6. **Hypothesis verdict**: did the system behave as expected? (confirmed / refuted / inconclusive)
7. **Quick debrief** (5 min): capture key findings before moving to next experiment

### 2. Define Observation Points for Each Experiment

For each experiment, define the specific dashboards, metrics, and signals the team will monitor during the fault injection window.

**Observation Point Categories:**

- **Primary steady-state metrics**: the metrics from the hypothesis that determine pass/fail
- **Secondary health metrics**: adjacent signals that may reveal unexpected impact (e.g., database query time during a pod termination test)
- **Infrastructure metrics**: node CPU/memory, network I/O, pod counts (especially if infrastructure plan is loaded)
- **User-facing signals**: error rates, latency distributions, session counts
- **System event log**: Kubernetes events, deployment logs, auto-scaling activity

If an observability plan was loaded, reference specific dashboards or alert names from it:
"Your observability plan includes a checkout service dashboard — let's add that as the primary observation point for the checkout-related experiments."

Ask: "For each experiment, who is watching what? Let's assign specific people to specific dashboards so nothing is missed."

**Recording During Experiments:**
Define what the Scribe captures in real time:
- Fault injection start time (timestamp)
- Initial system response observed
- Any unexpected behaviors noted
- Abort conditions checked at each interval
- Fault removal time (timestamp)
- Recovery start observed
- Steady-state restored timestamp
- Hypothesis verdict with supporting evidence

### 3. Define Findings Classification

After each experiment, classify findings by type and severity:

**Finding Types:**
- **Hypothesis confirmed**: system behaved exactly as expected — evidence of resilience
- **Hypothesis refuted**: system did NOT behave as expected — finding requires action
- **Unexpected behavior**: something happened outside the hypothesis scope — may be a hidden failure mode
- **Near miss**: system recovered but only barely, or via a path that was not intended

**Finding Severity Classification:**

| Severity | Criteria | Action Required |
|----------|----------|----------------|
| Critical | Service was unavailable, data was lost or corrupted, or blast radius exceeded scope | Immediate — fix before next game day; do not run further experiments in this area |
| High | Hypothesis refuted; system degraded but recovered; blast radius larger than expected | Address within next sprint; document in incident response plan |
| Medium | Unexpected behavior observed; system recovered normally; no user impact | Investigate and document; add to backlog |
| Low | Hypothesis confirmed; minor observations noted | Document as positive signal; consider future hardening |

Ask: "How does your team classify and track engineering findings? Let's align this severity scale with your existing issue tracking practice."

### 4. Post-Game Analysis Template

Define a structured post-game analysis to complete within 24-48 hours of the game day:

**Post-Game Analysis Sections:**
1. **Executive Summary**: one-paragraph narrative of what was tested and key outcomes
2. **Experiment Results Table**: for each experiment — hypothesis, actual behavior, verdict, severity
3. **Key Findings**: top 3-5 findings with evidence and recommended actions
4. **Findings-to-Action Tracker**: each finding assigned an owner, severity, and target resolution date
5. **What Worked Well**: positive observations about the game day process itself
6. **Process Improvements**: how to run the next game day better
7. **Recommended Next Game Day**: proposed experiment candidates based on new failure modes discovered

### 5. Define Findings-to-Action Tracking Process

Define how findings become work items:

- **Critical and High severity**: create issue in issue tracker immediately after the game day; assign owner; set target resolution date
- **Medium severity**: add to backlog with game day label/tag; review in next sprint planning
- **Low severity / confirmed hypotheses**: document in a "resilience evidence" section; use to inform future game day scope

Ask: "How do you currently track engineering action items? Let's align findings tracking with your existing process (Jira, Linear, GitHub Issues, etc.)."

**Findings Review Cadence:**
- Review open findings in weekly team standup until resolved
- Follow up on Critical/High findings at 1-week and 2-week marks
- Include findings summary in quarterly reliability review

### 6. Generate Execution and Observation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 10. Game Day Execution Schedule

### Pre-Game Window ({{start_time}} — {{end_time}})
- [ ] Run full pre-game-day checklist (Section 7)
- [ ] Confirm all participants are present
- [ ] Brief team on hypotheses, abort conditions, and roles
- [ ] Verify dashboards and observation tools are ready
- [ ] Game Day Lead gives go/no-go decision

{{for each experiment:}}
### {{Experiment N}} Block ({{estimated_start_time}})

| Phase | Activity | Owner | Duration |
|-------|----------|-------|----------|
| Pre-experiment checkpoint | Verify steady-state metrics nominal | Safety Officer | 5 min |
| Fault injection | {{specific_fault_command_or_tool}} | Tool Operator | — |
| Observation window | Watch dashboards per observation points | All | {{duration}} |
| Fault removal | {{specific_rollback_action}} | Tool Operator | — |
| Recovery window | Observe steady-state restoration | Safety Officer | {{buffer}} |
| Hypothesis verdict | Record pass/fail/inconclusive | Scribe | 5 min |
| Quick debrief | Capture findings before next experiment | Game Day Lead | 5 min |

**Observation Points:**
- Primary: {{primary_metric_and_dashboard}}
- Secondary: {{secondary_metrics}}
- Infrastructure: {{infra_metrics_if_relevant}}
{{/for each experiment}}

### Post-Game Retrospective ({{estimated_start_time}})
- Hypothesis verdicts reviewed for all experiments
- Key findings discussed and classified
- Action items assigned
- Process improvements noted
- Next game day candidates proposed

## 11. Findings Classification

| Finding Type | Definition | Action Required |
|-------------|------------|----------------|
| Hypothesis Confirmed | System behaved as expected | Document as resilience evidence |
| Hypothesis Refuted | System did not behave as expected | Classify severity; create action item |
| Unexpected Behavior | Out-of-scope behavior observed | Investigate; classify severity |
| Near Miss | System recovered via unintended path | Classify as High or Critical |

### Severity Scale

| Severity | Criteria | Response SLA |
|----------|----------|-------------|
| Critical | Availability loss, data risk, or blast radius exceeded | Fix before next game day |
| High | Hypothesis refuted; degradation observed | Address within next sprint |
| Medium | Unexpected behavior; no user impact | Add to backlog |
| Low | Hypothesis confirmed; positive signal | Document as evidence |

## 12. Post-Game Analysis Template

### Executive Summary

{{one_paragraph_narrative_of_game_day_outcomes}}

### Experiment Results

| Experiment | Hypothesis | Actual Behavior | Verdict | Severity |
|-----------|-----------|----------------|---------|----------|
{{experiment_results_rows}}

### Key Findings

{{numbered_list_of_top_findings_with_evidence}}

### Findings-to-Action Tracker

| Finding | Severity | Owner | Target Date | Status | Issue Link |
|---------|----------|-------|-------------|--------|-----------|
{{findings_tracker_rows}}

### What Worked Well

{{positive_observations_about_game_day_execution}}

### Process Improvements

{{how_to_run_the_next_game_day_better}}

### Recommended Next Game Day Candidates

{{experiment_candidates_surfaced_by_this_game_day}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the game day execution schedule, observation points, findings classification framework, and post-game analysis template based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this and proceed to validation and finalization
[R] Revise - Let's adjust the schedule, observation points, findings classification, or post-game template"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/chaos-gameday-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ Game day schedule is realistic with recovery windows between experiments
✅ Observation points are specific — named dashboards and metrics, not generic categories
✅ Observation points tied to SLOs/metrics from observability plan where available
✅ Scribe recording protocol is clearly defined
✅ Findings classification criteria are unambiguous
✅ Post-game analysis template is ready to fill in immediately after the game day
✅ Findings-to-action tracking aligns with team's existing issue tracking
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Scheduling experiments too tightly with no recovery buffer between them
❌ Vague observation points ("watch the system") rather than named metrics and dashboards
❌ Not assigning specific people to specific dashboards during experiments
❌ Post-game analysis template that is too complex to fill in under time pressure
❌ Not tying findings to specific action items with owners and dates
❌ Missing the real-time recording protocol for the Scribe role

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate the complete game day plan and finalize the document.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the menu and content is saved!
