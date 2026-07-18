# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating observability completeness and generating implementation backlog
- ✅ VALIDATE all critical journeys have full observability coverage
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ✅ Run comprehensive validation checks on the complete observability plan
- ⚠️ Present C/R menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: complete` before finishing
- 🚫 FORBIDDEN to finalize until C is selected

## COLLABORATION MENUS (C/R):

This step will generate content and present choices:

- **C (Continue)**: Save the validation results and finalize the observability plan
- **R (Revise)**: Discuss changes, address gaps, then re-present the menu

## CONTEXT BOUNDARIES:

- Complete observability document with all sections is available
- All instrumentation design, SLOs, alerting, and dashboards are defined
- Focus on validation, gap analysis, and generating implementation backlog
- This is the final step — ensure the plan is actionable

## YOUR TASK:

Validate the complete observability plan for coverage, coherence, and actionability. Generate a prioritized implementation backlog and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate systematically:

**Gate 1: Critical User Journey Coverage**
- [ ] Every critical user journey identified in step 4 has metrics defined
- [ ] Every critical user journey has at least one SLO with error budget
- [ ] Every critical user journey has burn-rate alerts configured
- [ ] Every critical user journey has a triage dashboard panel
- [ ] No journey is missing any of the four Golden Signals

**Gate 2: Logging Standards Completeness**
- [ ] Logging format is specified (JSON structured)
- [ ] Required fields are defined with consistent naming
- [ ] PII handling policy is documented with redaction approach
- [ ] Retention policy covers hot, warm, and cold storage
- [ ] Correlation IDs link logs to traces
- [ ] Log level guidelines are defined with usage examples

**Gate 3: Tracing Coverage**
- [ ] Distributed tracing covers all cross-service communication paths
- [ ] Span naming convention is documented and consistent
- [ ] Key attributes are defined for business and technical correlation
- [ ] Sampling strategy balances cost with observability needs
- [ ] Cardinality controls are specified to prevent storage explosion

**Gate 4: SLO & Error Budget Rigor**
- [ ] SLOs are defined with measurable SLIs (not aspirational statements)
- [ ] Error budgets have a 30-day rolling window
- [ ] Error budget policy defines actions at each consumption level
- [ ] SLO targets are based on current performance baselines
- [ ] SLOs are stricter than any external SLA commitments

**Gate 5: Alerting Operational Readiness**
- [ ] Alerts use multi-window multi-burn-rate approach (not raw thresholds)
- [ ] Every alert has a linked runbook (or runbook flagged for creation)
- [ ] Alert routing maps severity to channel and escalation path
- [ ] Noise reduction strategies are defined (grouping, suppression, dedup)
- [ ] Alert content includes summary, impact, hypothesis, and links

**Gate 6: Dashboard Alignment**
- [ ] Executive dashboard covers business KPIs and SLO status
- [ ] Engineering dashboard covers Golden Signals and deployments
- [ ] On-call dashboard covers active alerts and triage tools
- [ ] Each dashboard has a defined refresh rate and owner
- [ ] Dashboards answer "is the system healthy?" within seconds

### Maturity-Level Gate Calibration

Read `{bgr_maturity}` from config. When evaluating the quality gates above, apply the following maturity-based expectations:

| Gate | greenfield | growing | established | advanced |
|------|-----------|---------|-------------|----------|
| Gate 1: Critical User Journey Coverage (basic metrics, at least one SLO, basic burn-rate alerts) | PASS | PASS | PASS | PASS |
| Gate 2: Logging Standards (structured format, required fields, PII handling, retention, correlation IDs) | PASS | PASS | PASS | PASS |
| Gate 1+5: Golden Signals coverage, multi-burn-rate alerting, alert routing | DEFERRED | PASS | PASS | PASS |
| Gate 6: On-call triage dashboard | DEFERRED | PASS | PASS | PASS |
| Gate 3: Tracing Coverage (distributed tracing, span naming, sampling, cardinality) | DEFERRED | DEFERRED | PASS | PASS |
| Gate 4: SLO & Error Budget Rigor (error budget policies, baseline-driven targets) | DEFERRED | DEFERRED | PASS | PASS |
| Gate 6: Executive dashboards | DEFERRED | DEFERRED | PASS | PASS |
| Gate 5: Noise reduction strategies | DEFERRED | DEFERRED | PASS | PASS |
| Gate 3: Adaptive sampling | DEFERRED | DEFERRED | DEFERRED | PASS |
| Gate 6: Business KPI dashboards | DEFERRED | DEFERRED | DEFERRED | PASS |
| Gate 4: Quarterly SLO reviews | DEFERRED | DEFERRED | DEFERRED | PASS |

**How to interpret:**
- **PASS** — Gate must pass. Flag failures as blocking.
- **DEFERRED** — Gate is aspirational at this maturity level. Note it as a future improvement area but do not block. If the team has partially addressed it, acknowledge the progress.

When presenting validation results, report each gate's status as PASS, FAIL, or DEFERRED based on the team's maturity level.

### 2. Cross-Workflow Coherence Validation

Check alignment with other finalized workflow plans. For each plan, verify its `status` field before validating. If status is `draft`, note validation is deferred pending finalization.

**If Security Plan exists and status is `complete`:**
- Are security monitoring requirements (auth events, access logs, compliance audit trails) covered by the observability strategy?
- Do alerting rules cover security-critical events defined in the security plan's threat model?
- Is PII redaction in logging consistent with the security plan's data protection requirements?
- Are security scanning results and compliance status included in dashboards?

**If Disaster Recovery Plan exists and status is `complete`:**
- Do SLO definitions account for DR failover scenarios (degraded targets during failover)?
- Does monitoring cover failover health, replication lag, and backup integrity?
- Are DR-specific alerts defined for failover trigger conditions?
- Do dashboards include DR readiness indicators?

**If Capacity Plan exists and status is `complete`:**
- Do auto-scaling triggers reference metrics defined in the observability plan?
- Are capacity-related SLOs (latency under load, throughput) aligned with capacity plan targets?
- Are capacity dashboards consistent with the existing dashboard strategy?
- Do load testing success criteria reference observability-defined SLIs?

**If Infrastructure Plan exists and status is `complete` or `approved`:**
- Do monitoring targets match the environment topology (all environments covered)?
- Are observability agents and collectors provisioned in the infrastructure plan?
- Does the network architecture allow telemetry data egress?

**If Pipeline Plan exists and status is `complete`:**
- Do health check metrics align with post-deploy verification gates?
- Are deployment events tracked as observability signals (deploy markers, annotations)?
- Do pipeline failure alerts integrate with the alerting strategy?

**If Incident Response Plan exists and status is `complete`:**
- Do alerting thresholds and burn-rate windows align with incident severity classification?
- Are runbook links attached to all critical alerts?
- Does the on-call dashboard support incident triage workflows?
- Do SLO error budget exhaustion alerts map to incident escalation triggers?

### 3. Present Validation Summary

Report the validation results to the user:

"Here's the validation summary for the {{project_name}} Observability Plan.

**Quality Gate Results:**

| Gate | Status | Notes |
|------|--------|-------|
| Critical Journey Coverage | {PASS/FAIL} | {details} |
| Logging Standards | {PASS/FAIL} | {details} |
| Tracing Coverage | {PASS/FAIL} | {details} |
| SLO & Error Budgets | {PASS/FAIL} | {details} |
| Alerting Readiness | {PASS/FAIL} | {details} |
| Dashboard Alignment | {PASS/FAIL} | {details} |

{if_any_failures}
**Issues to Address:**
{list of failed gates with specific gaps}

Would you like to address these before finalizing?
{/if_any_failures}

{if_all_pass}
All quality gates passed. The observability plan is comprehensive and ready for implementation.
{/if_all_pass}"

### 4. Address Validation Issues

If any quality gates failed:

- Present the specific gaps clearly
- Collaborate with the user to resolve each gap
- Update the relevant document sections
- Re-run the failed quality gates to confirm resolution

### 5. Generate Implementation Backlog

Create a prioritized list of implementation tasks:

**Priority 1 — Foundation (implement first):**
- Set up log aggregation and structured logging across all services
- Deploy OpenTelemetry collectors and configure trace export
- Implement core Golden Signal metrics for critical services
- Create on-call triage dashboard

**Priority 2 — SLO Framework (implement second):**
- Define SLI measurement queries and error budget calculations
- Configure multi-window multi-burn-rate alerts
- Set up error budget tracking dashboard
- Create initial runbooks for all P1/P2 alerts

**Priority 3 — Full Coverage (implement third):**
- Extend metrics to all services (not just critical ones)
- Build executive and engineering dashboards
- Implement business KPI metrics collection
- Configure alert noise reduction rules

**Priority 4 — Maturity (implement ongoing):**
- Establish monthly alert quality reviews
- Implement adaptive sampling for tracing
- Add chaos engineering observability validation
- Create SLO review cadence (quarterly)

### 6. Generate Validation Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## Validation Results

### Quality Gates

| Gate | Status | Notes |
|------|--------|-------|
{{quality_gate_results}}

### Observability Completeness Checklist

**✅ Metrics & Instrumentation**

- [x] Golden Signals defined for all critical services
- [x] Metrics taxonomy covers reliability, business, and resource metrics
- [x] Collection methods and retention specified

**✅ Logging Standards**

- [x] JSON structured format with consistent fields
- [x] PII redaction policy documented
- [x] Retention policy aligned with compliance
- [x] Correlation IDs link logs to traces

**✅ Distributed Tracing**

- [x] OpenTelemetry instrumentation planned
- [x] Span naming and attributes standardized
- [x] Sampling strategy defined with cardinality controls

**✅ SLOs & Error Budgets**

- [x] SLIs mapped to critical user journeys
- [x] SLO targets set with 30-day rolling error budgets
- [x] Error budget policy defines escalating responses

**✅ Alerting & Response**

- [x] Multi-window multi-burn-rate alerts tied to SLOs
- [x] Alert routing with severity-based escalation
- [x] Runbook standards established
- [x] Noise reduction strategies defined

**✅ Dashboards**

- [x] Executive, engineering, and on-call dashboards specified
- [x] Each dashboard aligned with audience needs

## 9. Implementation Roadmap

| Milestone | Description | Owner | Target Date |
|-----------|-------------|-------|-------------|
{{implementation_backlog_entries}}

### Priority 1: Foundation

{{foundation_tasks}}

### Priority 2: SLO Framework

{{slo_framework_tasks}}

### Priority 3: Full Coverage

{{full_coverage_tasks}}

### Priority 4: Maturity

{{maturity_tasks}}
```

### 7. Save Final Document

- Append the validation and implementation content to `{bgr_artifacts}/observability.md`
- Update frontmatter:
  - `stepsCompleted: [1, 2, 3, 4, 5]`
  - `status: complete`
  - `lastUpdated: {{current_date}}`

### 8. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation and generated the implementation roadmap.

**Here's what I'll add to finalize the observability plan:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save and finalize the observability plan
[R] Revise - Let's address issues before finalizing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Discuss the user's concerns or corrections
- Update the content based on feedback
- Re-run relevant quality gates
- Re-present the C/R menu with updated content

#### If 'C' (Continue):

- Save the final content to `{bgr_artifacts}/observability.md`
- Update frontmatter to mark workflow as complete
- Present completion summary and next steps

### 10. Update Production Readiness Checklist

After saving the observability plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **Observability Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/observability.md`
3. Update section **2.1 Observability Plan** detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/observability.md`
   - Metrics backend chosen
   - Logging backend chosen
   - Tracing approach
   - SLO targets defined (count and summary)
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - If Incident Response Plan exists and status is `complete`: Verify alerting thresholds align with severity classification. If status is `draft`, note validation is deferred pending finalization.
   - If Infrastructure Plan exists and status is `complete` or `approved`: Verify monitoring targets match environment topology. If status is `draft`, note validation is deferred pending finalization.
   - If Pipeline Plan exists and status is `complete`: Verify health check metrics align with post-deploy verification. If status is `draft`, note validation is deferred pending finalization.
   - **Security Plan** — if `Complete`: verify security monitoring requirements (auth events, compliance audit logs) are covered by the observability strategy. If `Draft`: validation deferred.
   - **Disaster Recovery Plan** — if `Complete`: verify SLO definitions account for DR failover scenarios and monitoring covers failover health. If `Draft`: validation deferred.
   - **Capacity Planning** — if `Complete`: verify scaling triggers reference metrics defined in the observability plan. If `Draft`: validation deferred.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `observability`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all 7 workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched environment topologies, missing rollback alignment, or undefined alerting-to-severity mappings).
7. Save the updated checklist

### 11. Completion Summary

After saving, present the final summary:

"The Observability Plan for {{project_name}} is complete and saved to `{bgr_artifacts}/observability.md`.

**Summary:**
- {N} critical user journeys with full observability coverage
- {N} SLOs with error budgets and burn-rate alerts
- Structured logging, distributed tracing, and dashboards defined
- Prioritized implementation roadmap with {N} milestones

**Recommended Next Steps:**
- **Create Incident Response Plan (CR)** — Define severity classification, runbooks, on-call procedures, and postmortem processes
- **Return to agent menu** — Explore other capabilities

Thank you for collaborating on this, {{user_name}}. Your services will be well-observed."

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ All quality gates evaluated systematically
✅ Any failures identified and addressed with user
✅ Implementation backlog generated with clear priorities
✅ Final document saved with complete frontmatter
✅ User presented with clear next steps
✅ C/R menu presented and handled correctly
✅ Workflow marked as complete
✅ Production readiness checklist updated with completion status and key decisions
✅ Cross-plan dependency gaps identified and recorded in checklist

## FAILURE MODES:

❌ Rubber-stamping quality gates without thorough checking
❌ Not addressing failed quality gates before finalizing
❌ Generating a backlog without prioritization
❌ Not saving the final document with updated frontmatter
❌ Not presenting recommended next steps
❌ Finalizing without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols
