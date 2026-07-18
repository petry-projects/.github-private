# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES

📖 READ this entire file before taking any action.
🛑 FOLLOW the sequence below exactly — do not skip or reorder.
⏳ WAIT for user input when instructed before proceeding.

---

## 5.1 Quality Gate Checklist

Review the pipeline plan against these quality gates. Present each item with a pass/fail status:

| # | Quality Gate | Status |
|---|-------------|--------|
| 1 | CI/CD platform selected with pipeline-as-code approach | |
| 2 | Branching strategy defined with trigger mapping | |
| 3 | All pipeline stages documented with pass/fail criteria | |
| 4 | Security scanning integrated (SAST, dependencies, containers, secrets) — blocking, not advisory | |
| 5 | Deployment strategy defined per service type | |
| 6 | Rollback procedures documented and pipeline-driven (no manual rollback execution; manual approval may trigger an automated/pipeline rollback) | |
| 7 | Database migration strategy addressed | |
| 8 | Artifact management and retention defined | |
| 9 | Promotion gates defined at every environment boundary with automated quality checks | |
| 10 | Production signoff requirement — approval from reviewer who did not author the change | |
| 11 | No-bypass enforcement — pipeline prevents skipping gates even for admins | |
| 12 | No manual deployment paths — all changes flow exclusively through pipelines | |
| 13 | Hotfix pipeline path defined with minimum gates and post-deploy review requirement | |
| 14 | Audit trail — all promotions and approvals recorded with timestamp and approver | |

For any gate that fails, note what is missing and discuss with the user whether to address it now or defer.

### Maturity-Level Gate Calibration

Read `{bgr_maturity}` from config. When evaluating the quality gates above, apply the following maturity-based expectations:

| Gate # | Quality Gate | greenfield | growing | established | advanced |
|--------|-------------|-----------|---------|-------------|----------|
| 1 | CI/CD platform selected with pipeline-as-code approach | PASS | PASS | PASS | PASS |
| 3 | All pipeline stages documented with pass/fail criteria | PASS | PASS | PASS | PASS |
| 8 | Artifact management and retention defined | PASS | PASS | PASS | PASS |
| 4 | Security scanning integrated (SAST, dependencies, containers, secrets) | DEFERRED | PASS | PASS | PASS |
| 2 | Branching strategy defined with trigger mapping | DEFERRED | PASS | PASS | PASS |
| 6 | Rollback procedures documented | DEFERRED | PASS | PASS | PASS |
| 4 | All security scans set to blocking | DEFERRED | DEFERRED | PASS | PASS |
| 5 | Deployment strategy with promotion gates and signoff | DEFERRED | DEFERRED | PASS | PASS |
| 5 | No manual deployment paths to production | DEFERRED | DEFERRED | PASS | PASS |
| 7 | Database migration strategy addressed, hotfix pipeline defined | DEFERRED | DEFERRED | PASS | PASS |
| — | Full audit trail for all deployments | DEFERRED | DEFERRED | DEFERRED | PASS |
| — | Error-budget-gated promotion | DEFERRED | DEFERRED | DEFERRED | PASS |
| — | Pipeline performance optimization | DEFERRED | DEFERRED | DEFERRED | PASS |

**How to interpret:**
- **PASS** — Gate must pass. Flag failures as blocking.
- **DEFERRED** — Gate is aspirational at this maturity level. Note it as a future improvement area but do not block. If the team has partially addressed it, acknowledge the progress.

When presenting validation results, report each gate's status as PASS, FAIL, or DEFERRED based on the team's maturity level.

### 5.1b Cross-Workflow Coherence Validation

Check alignment with other finalized workflow plans. For each plan, verify its `status` field before validating. If status is `draft`, note validation is deferred pending finalization.

**If Security Plan exists and status is `complete`:**
- Do pipeline security scanning stages (SAST, SCA, DAST, container scanning) align with the security plan's testing strategy?
- Are compliance gates in the pipeline consistent with the security plan's compliance requirements?
- Does the pipeline enforce the security plan's secret management practices (no secrets in logs, env vars, or artifacts)?
- Are dependency scanning and SBOM generation aligned with the security plan's supply chain requirements?

**If Disaster Recovery Plan exists and status is `complete`:**
- Can the pipeline deploy to DR regions and failover environments?
- Are deployment procedures consistent with DR recovery steps?
- Does the rollback strategy align with DR failback procedures?
- Is the pipeline tested for DR scenario deployments?

**If Capacity Plan exists and status is `complete`:**
- Are load testing stages from the capacity plan integrated into the pipeline?
- Can the pipeline handle deployments during auto-scaling events?
- Are CI/CD resource costs accounted for in the capacity plan's cost model?
- Does the pipeline support canary or blue-green deployments for capacity validation?

**If Infrastructure Plan exists and status is `complete` or `approved`:**
- Do pipeline deployment targets match the defined environment topology?
- Is runner/agent infrastructure provisioned and consistent with pipeline requirements?
- Are promotion gates aligned with environment boundary definitions?

**If Observability Plan exists and status is `complete`:**
- Do post-deploy verification gates reference the correct health check metrics and SLO thresholds?
- Are deployment events instrumented for observability (deploy markers, annotations)?
- Does the pipeline validate that observability agents are healthy after deployment?

**If Incident Response Plan exists and status is `complete`:**
- Does rollback automation integrate with incident severity classification?
- Are deployment failure escalation paths aligned with incident response procedures?
- Does the pipeline emit alerts that map to the incident response severity framework?

## 5.2 Present Validation Summary

Present a concise summary of the complete pipeline plan:

- 🏗️ **Platform & Architecture** — CI/CD platform, branching strategy, runner strategy
- 🔄 **Pipeline Stages** — Number of stages, key stage gates, estimated pipeline duration
- 🔒 **Security** — Scanning tools integrated, blocking vs advisory findings
- 🚀 **Deployment** — Strategy per service, rollback approach, zero-downtime requirements
- 📦 **Release** — Versioning scheme, changelog automation, approval process

## 5.3 Address Gaps

If any quality gates failed:

- Discuss with the user whether to fill gaps now or document them as follow-up items
- For deferred items, add them to section 6 (Implementation Sequence) as future phases

## 5.4 Finalize Document

- Update `status` in frontmatter from `draft` to `complete`
- Update `lastUpdated` to today's date
- Save the final document to `{bgr_artifacts}/pipeline.md`

## 5.5 Update Production Readiness Checklist

After saving the pipeline plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **CI/CD Pipeline Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: today's date
   - Output Document: `{bgr_artifacts}/pipeline.md`
3. Update section **2.4 CI/CD Pipeline Plan** detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to today's date
   - Set **Output Document** to `{bgr_artifacts}/pipeline.md`
   - CI/CD platform selected
   - Branching strategy chosen
   - Deployment strategy per service type
   - Security scanning approach
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - If Observability Plan exists and status is `complete`: Verify post-deploy verification gates reference the correct health check metrics and SLO thresholds. If status is `draft`, defer validation until plan is finalized.
   - If Incident Response Plan exists and status is `complete`: Verify rollback automation triggers align with incident severity classification and escalation procedures. If status is `draft`, defer validation until plan is finalized.
   - If Infrastructure Plan exists and status is `complete` or `approved`: Verify pipeline deployment targets match the defined environment topology, and runner infrastructure is provisioned. If status is `draft`, defer validation until plan is finalized.
   - If Security Plan exists and status is `complete`: Verify pipeline security scanning stages align with the security plan's testing strategy and compliance gates. If status is `draft`, defer validation.
   - If Disaster Recovery Plan exists and status is `complete`: Verify pipeline supports DR deployment procedures and failover testing. If status is `draft`, defer validation.
   - If Capacity Plan exists and status is `complete`: Verify pipeline integrates load testing stages defined in the capacity plan. If status is `draft`, defer validation.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `pipeline`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all 7 workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched environment topologies, missing rollback alignment, or undefined alerting-to-severity mappings).
7. Save the updated checklist

## 5.6 Recommend Next Steps

Suggest logical follow-up actions:

- 📋 Create infrastructure plan (if not yet done) to support the pipeline architecture
- 📋 Create observability plan to monitor pipeline and deployment health
- 📋 Create incident response plan for deployment failures
- 🔧 Implement pipeline configuration files based on this plan
- 🔧 Set up pipeline secrets and credential management
- 🔧 Configure notification integrations (Slack, PagerDuty, email)

---

**Menu:**

- **[C]omplete** — Finalize and save the pipeline plan
- **[R]evise** — Return to a specific step to make changes

🔄 **Before completing:** Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]`.

🔄 **Before completing:** Update the production readiness checklist per step 5.5.

✅ **Workflow complete.** The pipeline plan has been saved to `{bgr_artifacts}/pipeline.md`. The production readiness checklist has been updated with completion status and cross-plan dependency analysis.
