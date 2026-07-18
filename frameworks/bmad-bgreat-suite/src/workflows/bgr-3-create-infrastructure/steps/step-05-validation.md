# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating completeness, coherence, and implementation readiness
- ✅ VALIDATE all infrastructure decisions are coherent and complete
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ✅ Run comprehensive validation checks on the complete infrastructure plan
- ⚠️ Present [C]ontinue / [R]evise menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and `status: approved` before completing
- 🚫 FORBIDDEN to complete workflow until C is selected

## CONTEXT BOUNDARIES:

- Complete infrastructure document with all sections is available
- All infrastructure decisions from steps 2-4 are defined
- Focus on validation, gap analysis, and coherence checking
- Prepare for handoff to pipeline planning phase

## YOUR TASK:

Validate the complete infrastructure plan for coherence, completeness, and readiness to guide implementation.

## VALIDATION SEQUENCE:

### 1. Quality Gate Checks

Run through each quality gate and report pass/fail:

**IaC Strategy Gates:**

- [ ] IaC tool selected with clear rationale
- [ ] State management strategy defined (backend, locking, per-environment)
- [ ] Module/component strategy documented (granularity, versioning, registry)
- [ ] Policy-as-code approach defined (tools, categories, enforcement levels)
- [ ] Drift detection and remediation strategy documented

**Environment Strategy Gates:**

- [ ] Environment topology documented with purpose for each environment
- [ ] Environment isolation enforced — separate cloud accounts/subscriptions per environment
- [ ] Network isolation confirmed — no cross-environment VPC peering or transit routes
- [ ] Secrets isolation confirmed — separate secrets stores per environment, no shared credentials
- [ ] IAM isolation confirmed — no cross-environment role assumptions (except audited break-glass)
- [ ] State isolation confirmed — separate IaC state backends per environment
- [ ] Environment parity rules defined (identical vs different)
- [ ] Configuration management strategy documented
- [ ] Secrets management strategy defined (backend, rotation, injection) per environment
- [ ] Promotion gates defined at every environment boundary
- [ ] Production signoff requirements documented (reviewer who did not author the change)
- [ ] Hotfix pipeline path defined with minimum gates
- [ ] Cost management approach documented (non-prod controls, prod optimization)

**Change Control Gates:**

- [ ] All infrastructure changes flow through pipelines — no manual provisioning paths
- [ ] No-bypass enforcement documented — pipeline prevents skipping gates even for admins
- [ ] Direct production access disabled or restricted to read-only with audit logging
- [ ] Rollback procedures are pipeline-driven, not manual
- [ ] Drift detection configured with alerting for unauthorized changes

**Network Architecture Gates:**

- [ ] VPC/VNet design documented
- [ ] Subnet strategy defined
- [ ] DNS and load balancing approach documented
- [ ] Network security strategy defined

**Container Strategy Gates:**

- [ ] Container strategy defined (or explicitly deferred with rationale)
- [ ] If containers: cluster architecture, image strategy, and security documented
- [ ] If containers: service mesh evaluated with complexity-vs-value assessment

### Maturity-Level Gate Calibration

Read `{bgr_maturity}` from config. When evaluating the quality gates above, apply the following maturity-based expectations:

| Gate Group / Gate | greenfield | growing | established | advanced |
|-------------------|-----------|---------|-------------|----------|
| IaC Strategy: IaC tool selected with rationale | PASS | PASS | PASS | PASS |
| IaC Strategy: State management strategy defined | PASS | PASS | PASS | PASS |
| Environment Strategy: At least one environment defined with purpose | PASS | PASS | PASS | PASS |
| Environment Strategy: Secrets management strategy defined | PASS | PASS | PASS | PASS |
| Environment Strategy: Configuration management strategy | PASS | PASS | PASS | PASS |
| IaC Strategy: State management per-environment separation | DEFERRED | PASS | PASS | PASS |
| Environment Strategy: Environment parity rules defined | DEFERRED | PASS | PASS | PASS |
| IaC Strategy: Policy-as-code approach defined | DEFERRED | PASS | PASS | PASS |
| IaC Strategy: Drift detection and remediation strategy | DEFERRED | PASS | PASS | PASS |
| Environment Strategy: Separate cloud accounts per environment | DEFERRED | DEFERRED | PASS | PASS |
| Network Architecture: Network isolation and security strategy | DEFERRED | DEFERRED | PASS | PASS |
| Environment Strategy: Full secrets rotation | DEFERRED | DEFERRED | PASS | PASS |
| Environment Strategy: Promotion gates with signoff at every boundary | DEFERRED | DEFERRED | PASS | PASS |
| Network Architecture: Zero-trust IAM with break-glass procedures | DEFERRED | DEFERRED | DEFERRED | PASS |
| IaC Strategy: Automated compliance scanning (full change control) | DEFERRED | DEFERRED | DEFERRED | PASS |
| Container Strategy: Anti-pattern scans and security hardening | DEFERRED | DEFERRED | DEFERRED | PASS |

**How to interpret:**
- **PASS** — Gate must pass. Flag failures as blocking.
- **DEFERRED** — Gate is aspirational at this maturity level. Note it as a future improvement area but do not block. If the team has partially addressed it, acknowledge the progress.

When presenting validation results, report each gate's status as PASS, FAIL, or DEFERRED based on the team's maturity level.

### 2. Internal Coherence Validation

Check that all infrastructure decisions work together:

**Decision Compatibility:**

- Do IaC tool choices align with the container platform?
- Does state management strategy support the environment topology?
- Are policy-as-code tools compatible with the chosen IaC framework?
- Does the secrets management approach integrate with the container platform?

**Cross-Section Consistency:**

- Does the network architecture support the environment topology?
- Are cost controls consistent across IaC and environment sections?
- Does drift detection cover both IaC resources and container configuration?
- Are security decisions consistent across network, container, and secrets sections?

**DevOps Anti-Pattern Scan:**

- Are there any snowflake environments (manually built or diverged from IaC)?
- Is any infrastructure shared across SDLC environment boundaries?
- Are there any manual change paths (console, SSH, direct API) that bypass pipelines?
- Are any secrets hardcoded in code, config, or pipeline definitions?
- Can code reach production without passing through all environments and quality gates?
- Are there inconsistencies between staging and production topology?
- Are rollback procedures manual rather than pipeline-driven?
- Is there unaudited production access?

### 2b. Cross-Workflow Coherence Validation

Check alignment with other finalized workflow plans. For each plan, verify its `status` field before validating. If status is `draft`, note validation is deferred pending finalization.

**If Security Plan exists and status is `complete`:**
- Does the network architecture enforce the security plan's segmentation requirements?
- Are encryption mandates (at rest, in transit) reflected in infrastructure provisioning?
- Do IAM and access controls align with the security plan's trust boundaries?
- Is secrets management consistent with the security plan's secret rotation and storage requirements?

**If Disaster Recovery Plan exists and status is `complete`:**
- Does the infrastructure topology support DR failover targets (multi-region, multi-AZ)?
- Is backup storage provisioned according to DR plan's RPO requirements?
- Are DR environments consistent with primary environment architecture?
- Does IaC support rapid DR environment provisioning and teardown?

**If Capacity Plan exists and status is `complete`:**
- Does infrastructure sizing account for the capacity plan's growth projections?
- Is auto-scaling provisioned for services identified in the capacity plan?
- Are reserved capacity commitments aligned with infrastructure cost plans?
- Does the environment topology support the capacity plan's load testing requirements?

**If Observability Plan exists and status is `complete`:**
- Are resources provisioned for monitoring agents, collectors, and telemetry data egress?
- Does the network architecture allow observability tool traffic (metrics, logs, traces)?
- Are storage and compute resources allocated for observability backends?

**If Pipeline Plan exists and status is `complete`:**
- Does the environment topology match pipeline deployment targets?
- Is runner/agent infrastructure provisioned for CI/CD workloads?
- Are promotion gates between environments consistent with pipeline stage definitions?

**If Incident Response Plan exists and status is `complete`:**
- Do environment access controls support on-call responder access procedures?
- Are break-glass access paths documented and audited per incident response requirements?
- Does the infrastructure support war room tooling and communication channels?

### 3. Architecture Alignment

Verify infrastructure decisions support the source architecture document:

- Do compute decisions match the architecture's scale requirements?
- Does the network design support the architecture's communication patterns?
- Are security requirements from the architecture fully addressed?
- Does the environment strategy support the deployment model from the architecture?

### 4. Gap Analysis

Identify any remaining gaps:

**Critical Gaps** — Missing decisions that block implementation:
{{critical_gaps_or_none_found}}

**Important Gaps** — Areas needing more detail:
{{important_gaps_or_none_found}}

**Nice-to-Have Gaps** — Optional improvements:
{{nice_to_have_gaps_or_none_found}}

### 5. Generate Implementation Sequence

Prepare a recommended implementation order:

```markdown
## 6. Implementation Sequence

| Phase | Description | Dependencies | Owner |
|-------|-------------|-------------|-------|
| 1 | Bootstrap IaC backend and state management | None | {{owner}} |
| 2 | Provision network foundation (VPC, subnets, DNS) | Phase 1 | {{owner}} |
| 3 | Deploy secrets management infrastructure | Phase 2 | {{owner}} |
| 4 | Provision compute platform (K8s clusters / serverless) | Phase 2, 3 | {{owner}} |
| 5 | Configure policy-as-code and drift detection | Phase 1 | {{owner}} |
| 6 | Set up non-production environments | Phase 2, 3, 4 | {{owner}} |
| 7 | Set up production environment | Phase 6 validated | {{owner}} |
```

### 6. Present Validation Summary

Present the complete validation to the user:

"I've completed validation of your Infrastructure Plan.

**Quality Gate Results:**

- IaC Strategy: {{pass_count}}/{{total_count}} gates passed
- Environment Strategy: {{pass_count}}/{{total_count}} gates passed
- Network Architecture: {{pass_count}}/{{total_count}} gates passed
- Container Strategy: {{pass_count}}/{{total_count}} gates passed

**Coherence Check:** {{coherent_or_issues_found}}

**Architecture Alignment:** {{aligned_or_gaps_found}}

{if_gaps_found}
**Gaps Found:**
{{gap_summary}}
{/if_gaps_found}

**Implementation Sequence:**
[Show the implementation sequence table]

**What would you like to do?**
[C] Continue - Finalize the infrastructure plan
[R] Revise - Address gaps or adjust decisions before finalizing"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which area would you like to address? (Quality gates / Coherence issues / Gaps / Implementation sequence)"
- Navigate back to the appropriate step or discuss inline
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append validation results and implementation sequence to `{bgr_artifacts}/infrastructure.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4, 5]`, `status: approved`
- Update the Overview section (section 1) with project details gathered during the workflow
- Save the final document

### 8. Update Production Readiness Checklist

After saving the infrastructure plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **Infrastructure Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/infrastructure.md`
3. Update section **2.3 Infrastructure Plan** detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/infrastructure.md`
   - IaC tool selected
   - Cloud provider
   - Container orchestration platform
   - Environment topology summary
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - If Observability Plan exists and status is `complete`: Verify infrastructure provisions resources for monitoring agents, collectors, and telemetry data egress. If status is `draft`, note validation is deferred pending finalization.
   - If Incident Response Plan exists and status is `complete`: Verify environment access controls support on-call responder access and war room procedures. If status is `draft`, note validation is deferred pending finalization.
   - If Pipeline Plan exists and status is `complete`: Verify environment topology matches pipeline deployment targets and runner infrastructure needs. If status is `draft`, note validation is deferred pending finalization.
   - **Security Plan** — if `Complete`: verify network architecture enforces security plan's segmentation requirements and encryption mandates. If `Draft`: validation deferred.
   - **Disaster Recovery Plan** — if `Complete`: verify infrastructure topology supports DR failover targets (multi-region, backup storage). If `Draft`: validation deferred.
   - **Capacity Planning** — if `Complete`: verify infrastructure sizing accounts for growth projections and auto-scaling is provisioned. If `Draft`: validation deferred.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `infrastructure`. Add this workflow only if it is not already present (use set-style uniqueness to prevent duplicate entries on re-run).
6. If all 7 workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain). A **critical gap** is a missing workflow artifact, an unresolved cross-plan dependency, or a key decision conflict between plans that would block production readiness (e.g., mismatched environment topologies, missing rollback alignment, or undefined alerting-to-severity mappings).
7. Save the updated checklist

### 9. Completion Message

After saving:

"Your Infrastructure Plan has been finalized and saved to `{bgr_artifacts}/infrastructure.md`.

**Summary of Decisions:**

- **IaC Tool:** {{selected_tool}}
- **Environments:** {{environment_list}}
- **Container Platform:** {{container_platform_or_deferred}}
- **Secrets Backend:** {{secrets_backend}}
- **Key Policies:** {{policy_summary}}

**Recommended Next Step:**
Create Pipeline Plan (CP) — Define CI/CD pipelines that deploy to the infrastructure you've just planned.

Thank you for the collaboration, {{user_name}}!"

## APPEND TO DOCUMENT:

When user selects 'C', append the validation results and implementation sequence to the document, and update the Overview section with gathered project details.

## SUCCESS METRICS:

✅ All quality gates evaluated and reported
✅ Coherence validated across all infrastructure sections
✅ Architecture alignment verified
✅ Gap analysis completed with prioritized findings
✅ Implementation sequence defined
✅ Final document saved with approved status
✅ Next workflow recommended to user
✅ Production readiness checklist updated with completion status and key decisions
✅ Cross-plan dependency gaps identified and recorded in checklist

## FAILURE MODES:

❌ Skipping quality gate checks
❌ Not validating coherence across sections
❌ Missing gap analysis
❌ Not providing implementation sequence
❌ Not updating frontmatter status to approved
❌ Not recommending next workflow step

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## WORKFLOW COMPLETE:

After the completion message is delivered, this workflow is finished. The infrastructure plan is saved and ready to inform the Pipeline workflow.
