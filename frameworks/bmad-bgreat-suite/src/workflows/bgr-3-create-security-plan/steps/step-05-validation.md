# Step 5: Validation & Finalization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between security peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on validating completeness and coherence of the security plan
- ✅ VALIDATE all critical areas are covered before finalizing
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ✅ Run comprehensive validation checks on the complete plan
- ⚠️ Present [C]ontinue / [R]evise menu after generating validation results
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4, 5]` and set `status: complete` before finalizing
- 🚫 FORBIDDEN to finalize until C is selected

## CONTEXT BOUNDARIES:

- Complete security plan with all sections is available
- All threat modeling, security controls, and compliance mapping are defined
- Focus on validation, gap analysis, and completeness checking
- Prepare for handoff to implementation

## YOUR TASK:

Validate the complete security plan for coherence, completeness, and implementation readiness. Present a summary and finalize the document.

## VALIDATION SEQUENCE:

### 1. Quality Gates Checklist

Run through each quality gate and assess pass/fail:

**Threat Modeling:**
- [ ] System assets identified and data classified
- [ ] Trust boundaries mapped with data flows
- [ ] STRIDE analysis applied to major components
- [ ] Threat matrix includes likelihood, impact, and risk level
- [ ] Existing controls documented alongside gaps

**Authentication & Authorization:**
- [ ] User authentication strategy defined (provider, MFA, session management)
- [ ] Service-to-service authentication defined
- [ ] Authorization model selected with enforcement points
- [ ] Least privilege principle applied across all access

**Data Protection:**
- [ ] Encryption at rest defined for all data classifications
- [ ] Encryption in transit defined (TLS version, mTLS for internal)
- [ ] PII/PHI handling procedures specified
- [ ] Data retention and disposal policies defined
- [ ] Backup security addressed

**Network Security:**
- [ ] Perimeter security controls defined (WAF, DDoS, rate limiting)
- [ ] Internal segmentation and micro-segmentation planned
- [ ] Zero-trust principles applied where appropriate
- [ ] Private endpoints for managed services specified

**Secret Management:**
- [ ] Centralized secret store selected
- [ ] Rotation policies defined for each secret type
- [ ] CI/CD secret strategy defined (OIDC federation preferred)
- [ ] Break-glass procedures documented

**Supply Chain Security:**
- [ ] Dependency scanning integrated into CI
- [ ] SBOM generation planned
- [ ] Container security controls defined
- [ ] Artifact signing strategy defined

**Security Testing:**
- [ ] SAST, SCA, and container scanning in CI pipeline
- [ ] DAST for pre-production environments
- [ ] Security review gates defined for high-risk changes
- [ ] Penetration testing schedule defined

**Compliance:**
- [ ] Applicable frameworks identified with rationale
- [ ] Controls mapped to framework requirements
- [ ] Gaps identified with risk levels
- [ ] Remediation roadmap prioritized

### 2. Coherence Validation

Check that all sections work together:

- Do security controls address every critical/high threat from the threat matrix?
- Does the auth strategy align with data classification requirements?
- Do network controls match the architecture's trust boundaries?
- Is the compliance mapping consistent with the controls actually defined?
- Does the security testing strategy cover the highest-risk areas?
- Are secret management practices consistent across development and production?

### 3. Gap Analysis

Identify any missing elements:

**Critical Gaps** (block production readiness):
- Unaddressed critical threats from the threat matrix
- Missing authentication for trust boundary crossings
- Sensitive data without encryption controls
- Compliance requirements without mapped controls

**Important Gaps** (should be addressed soon):
- Security testing not yet integrated into CI
- Manual secret management processes
- Incomplete compliance mapping for applicable frameworks

**Enhancement Opportunities** (improve over time):
- Advanced threat detection and anomaly monitoring
- Security chaos engineering
- Automated compliance evidence collection
- Red team exercises

### 4. Implementation Sequence

Define the recommended order of security implementation:

**Phase 1 — Foundation (before production):**
- Authentication and authorization implementation
- Data encryption (at rest and in transit)
- Secret management setup
- Basic network segmentation
- SAST and SCA in CI pipeline

**Phase 2 — Hardening (first quarter):**
- Complete network micro-segmentation
- DAST integration
- Container security hardening
- Dependency update automation
- Security review gates for high-risk changes

**Phase 3 — Maturity (ongoing):**
- Zero-trust architecture rollout
- SBOM and supply chain verification
- Compliance evidence automation
- Penetration testing program
- Security metrics and reporting

### 5. Present Validation Summary

Present the complete validation to user:

"I've completed a comprehensive validation of your Security Plan.

**Quality Gates:**

{{checklist_results_with_pass_fail_status}}

**Coherence Check:**
- {{assessment_of_how_all_sections_work_together}}

**Gap Analysis:**

**Critical:** {{critical_gaps_or_none_found}}
**Important:** {{important_gaps}}
**Enhancements:** {{enhancement_opportunities}}

### 6. Generate Validation & Implementation Content

Prepare the final content to append to the document:

#### Content Structure:

```markdown
## 13. Implementation Sequence

### 13.1 Phase 1 — Foundation (Before Production)

{{phase_1_security_controls_and_dependencies}}

### 13.2 Phase 2 — Hardening

{{phase_2_controls_and_improvements}}

### 13.3 Phase 3 — Maturity

{{phase_3_advanced_security_practices}}

## Validation Results

### Quality Gates

{{quality_gates_checklist_with_status}}

### Plan Completeness

**Overall Status:** {{READY_FOR_USE / NEEDS_ATTENTION}}

**Strengths:**
{{list_of_plan_strengths}}

**Areas for Improvement:**
{{areas_that_should_be_addressed}}

### Recommended Next Steps

{{prioritized_list_of_next_actions}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've completed the validation. Here's the final section to add:

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save and finalize the security plan
[R] Revise - Let's address gaps or adjust any section of the plan"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Navigate back to relevant sections if needed
- Collaborate on revisions
- Re-run validation if significant changes made
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/security-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4, 5]`
- Update frontmatter: `status: complete`
- Update frontmatter: `lastUpdated` to current date
- Save the final document

### 9. Finalization Report

After saving, present the completion summary:

"Your Security Plan is complete and saved to `{bgr_artifacts}/security-plan.md`.

**What you have:**
- Asset inventory and data classification
- Trust boundary mapping and attack surface analysis
- STRIDE threat model with prioritized threat matrix
- Authentication and authorization strategy
- Data protection controls aligned with classification
- Network security posture with zero-trust principles
- Secret management strategy with lifecycle policies
- Supply chain security controls
- Security testing strategy integrated into CI/CD
- Compliance mapping to applicable regulatory frameworks
- Gap analysis with prioritized remediation roadmap
- Phased implementation sequence

**Recommended next steps:**
1. Implement Phase 1 security controls before production launch
2. Set up security scanning in your CI/CD pipeline (use Riley's `bgr-3-create-pipeline` workflow)
3. Configure security-relevant observability (use Morgan's `bgr-3-create-observability` workflow)
4. Create incident response procedures for security events (use Morgan's `bgr-3-create-incident-response` workflow)
5. Schedule your first penetration test
6. Share this plan with the team and get feedback

**Integration with other agents:**
- **Morgan (SRE)**: Security observability, security incident response procedures, post-incident security review
- **Riley (DevOps)**: Pipeline security scanning, infrastructure hardening, container security

Thank you for building this plan together, {{user_name}}! A security plan is only as good as its implementation — the phased approach ensures you build on a solid foundation without trying to boil the ocean."

### 10. Update Production Readiness Checklist

After saving the security plan, update the cross-workflow production readiness checklist:

1. Load `{bgr_artifacts}/production-readiness-checklist.md`
   - If it does not exist, create it from `../../../templates/bgr-production-readiness-checklist-template.md`
2. Update the **Security Plan** row in the Workflow Completion Status table:
   - Status: `Complete`
   - Completion Date: `{{current_date}}`
   - Output Document: `{bgr_artifacts}/security-plan.md`
3. Update section **2.5 Security Plan** detail fields and key decisions:
   - Set **Status** to `Complete`
   - Set **Completion Date** to `{{current_date}}`
   - Set **Output Document** to `{bgr_artifacts}/security-plan.md`
   - Auth strategy chosen
   - Data protection approach
   - Compliance frameworks identified
   - Threat model completed
   - Update checklist `lastUpdated` in both frontmatter and the Overview section
4. Check for cross-plan dependency gaps (verify each plan's `status` field before validating):
   - **Observability Plan** — if `Complete`: verify security monitoring requirements (auth events, compliance logs) are covered. If `Draft`: validation deferred.
   - **Incident Response Plan** — if `Complete`: verify security incident classification aligns with severity framework. If `Draft`: validation deferred.
   - **Infrastructure Plan** — if `Complete` or `Approved`: verify network segmentation and encryption mandates are enforced. If `Draft`: validation deferred.
   - **Pipeline Plan** — if `Complete`: verify security scanning stages align with testing strategy. If `Draft`: validation deferred.
   - **Disaster Recovery Plan** — if `Complete`: verify DR procedures account for security failover requirements. If `Draft`: validation deferred.
   - **Capacity Planning** — if `Complete`: verify capacity planning accounts for security infrastructure overhead. If `Draft`: validation deferred.
   - Record any inconsistencies or deferred validations in section **4.3 Consistency Issues**
5. Update the `completedWorkflows` array in checklist frontmatter to include `security-plan`. Add this workflow only if it is not already present.
6. If all 7 workflows are now complete, update **Overall Status** to `READY` (if no critical gaps remain).
7. Save the updated checklist

## SUCCESS METRICS:

✅ All quality gates evaluated with clear pass/fail
✅ Coherence between all sections validated
✅ Gaps identified and communicated with priority levels
✅ Implementation sequence defined in practical phases
✅ Final document saved with complete frontmatter
✅ Actionable next steps provided with cross-agent integration points
✅ Production readiness checklist updated with security plan completion
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Rubber-stamping validation without thorough checks
❌ Missing critical gaps that would leave the system vulnerable
❌ Not checking coherence between threat model and controls
❌ Finalizing without user confirmation
❌ Not providing actionable implementation sequence
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## WORKFLOW COMPLETE:

This is the final step. After finalization, the security plan workflow is complete. The user can invoke additional workflows or return to the agent menu.
