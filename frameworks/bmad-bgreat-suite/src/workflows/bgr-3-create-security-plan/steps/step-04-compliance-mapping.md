# Step 4: Compliance Mapping

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between security peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on mapping actual security controls to applicable regulatory frameworks
- 🎯 USE the security controls from step 3 and data classification from step 2 as input
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating compliance mapping
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Threat model, data classification, and security controls from steps 2-3 are in the document
- Input documents and system context are available from earlier steps
- Focus on applicable frameworks — not every framework applies to every system
- Provide practical mapping, not exhaustive compliance checklists

## YOUR TASK:

Collaboratively determine which compliance frameworks apply, map existing and planned security controls to framework requirements, identify compliance gaps, and define a remediation roadmap.

## COMPLIANCE MAPPING SEQUENCE:

### 1. Determine Applicable Frameworks

Discuss which frameworks apply based on the data classification and business context:

**Framework Applicability Assessment:**

| Framework | Applies When | Key Data Types |
|-----------|-------------|---------------|
| **SOC 2** | SaaS products, B2B services, cloud-hosted data processing | Any customer data |
| **HIPAA** | Healthcare data, health-related services | PHI (Protected Health Information) |
| **PCI-DSS** | Payment processing, storing card data | Cardholder data, PANs |
| **GDPR** | Processing EU resident data | Any personal data of EU residents |
| **CCPA/CPRA** | Processing California resident data | Personal information of CA residents |
| **SOX** | Publicly traded companies, financial reporting | Financial data and controls |
| **ISO 27001** | Organizations seeking formal ISMS certification | All information assets |
| **NIST CSF** | US government contractors, general best practice | Varies by contract |

Ask user:
"Based on your data classification, let's determine which compliance frameworks apply:

**Key questions:**
- What types of customers do you serve? (B2B SaaS, healthcare, financial, consumer)
- Do you process or store payment information?
- Do you handle health records or health-related data?
- Do you have users in the EU or California?
- Are there any contractual compliance requirements from your customers?
- Are you pursuing or maintaining any certifications? (SOC 2, ISO 27001)"

### 2. Map Controls to Framework Requirements

For each applicable framework, map the security controls defined in step 3:

**SOC 2 Mapping (if applicable):**

| Trust Service Criteria | Requirement | Your Control | Status |
|----------------------|-------------|-------------|--------|
| CC6.1 — Logical access | Restrict access to authorized users | {{auth_strategy}} | {{Implemented/Planned/Gap}} |
| CC6.2 — Authentication | Authenticate users before access | {{authn_controls}} | {{status}} |
| CC6.3 — Authorization | Enforce least privilege | {{authz_controls}} | {{status}} |
| CC6.6 — Boundary protection | Protect system boundaries | {{network_controls}} | {{status}} |
| CC6.7 — Data transmission | Protect data in transit | {{encryption_in_transit}} | {{status}} |
| CC6.8 — Data disposal | Secure data destruction | {{retention_controls}} | {{status}} |
| CC7.1 — Monitoring | Detect security events | {{monitoring_controls}} | {{status}} |
| CC7.2 — Anomaly detection | Identify anomalous activity | {{anomaly_detection}} | {{status}} |
| CC8.1 — Change management | Control system changes | {{change_management}} | {{status}} |

**HIPAA Mapping (if applicable):**

| HIPAA Rule | Requirement | Your Control | Status |
|-----------|-------------|-------------|--------|
| 164.312(a)(1) — Access control | Unique user identification, emergency access | {{access_controls}} | {{status}} |
| 164.312(a)(2)(iv) — Encryption | Encrypt ePHI | {{encryption_controls}} | {{status}} |
| 164.312(b) — Audit controls | Record access to ePHI | {{audit_logging}} | {{status}} |
| 164.312(c)(1) — Integrity | Protect ePHI from improper alteration | {{integrity_controls}} | {{status}} |
| 164.312(d) — Authentication | Verify identity of persons seeking ePHI | {{authn_controls}} | {{status}} |
| 164.312(e)(1) — Transmission security | Protect ePHI in transit | {{transit_encryption}} | {{status}} |
| 164.308(a)(1) — Risk analysis | Conduct accurate risk assessment | {{threat_model}} | {{status}} |
| 164.308(a)(5) — Security awareness | Train workforce on security | {{training_program}} | {{status}} |

**PCI-DSS Mapping (if applicable):**

| PCI-DSS Requirement | Requirement | Your Control | Status |
|-------------------|-------------|-------------|--------|
| Req 1 — Network segmentation | Install and maintain network controls | {{network_segmentation}} | {{status}} |
| Req 2 — Secure configuration | Apply secure configurations to all components | {{hardening_controls}} | {{status}} |
| Req 3 — Protect stored data | Protect stored account data | {{data_at_rest_encryption}} | {{status}} |
| Req 4 — Encrypt transmissions | Protect data with cryptography in transit | {{data_in_transit_encryption}} | {{status}} |
| Req 5 — Malware protection | Protect from malicious software | {{malware_protection}} | {{status}} |
| Req 6 — Secure development | Develop and maintain secure systems | {{sdlc_controls}} | {{status}} |
| Req 7 — Restrict access | Restrict access by business need | {{access_controls}} | {{status}} |
| Req 8 — Identify users | Identify users and authenticate access | {{identity_controls}} | {{status}} |
| Req 10 — Log and monitor | Log and monitor access to systems | {{logging_and_monitoring}} | {{status}} |
| Req 11 — Test security | Test security regularly | {{security_testing}} | {{status}} |
| Req 12 — Security policy | Support security with organizational policies | {{security_policies}} | {{status}} |

**GDPR Mapping (if applicable):**

| GDPR Article | Requirement | Your Control | Status |
|-------------|-------------|-------------|--------|
| Art. 5 — Data principles | Lawful, fair, transparent processing | {{data_handling_policies}} | {{status}} |
| Art. 6 — Lawful basis | Establish lawful basis for processing | {{consent_management}} | {{status}} |
| Art. 15-20 — Data subject rights | Right to access, rectify, erase, port | {{data_subject_rights}} | {{status}} |
| Art. 25 — Data protection by design | Build privacy into design | {{privacy_by_design}} | {{status}} |
| Art. 30 — Records of processing | Maintain processing activity records | {{processing_records}} | {{status}} |
| Art. 32 — Security of processing | Implement appropriate security measures | {{security_controls}} | {{status}} |
| Art. 33 — Breach notification | Notify authority within 72 hours | {{breach_notification}} | {{status}} |
| Art. 35 — Impact assessment | DPIA for high-risk processing | {{dpia_process}} | {{status}} |
| Art. 44-49 — International transfers | Protect cross-border data transfers | {{transfer_mechanisms}} | {{status}} |

Present applicable mappings to user and discuss:
"Here's how your security controls map to the applicable frameworks. Let's review together:

**Well-covered areas:**
[List areas with Implemented status]

**Planned controls:**
[List areas with Planned status]

**Gaps requiring attention:**
[List areas with Gap status]

**Questions:**
- Are there any controls I've mapped incorrectly?
- Do you have additional controls in place that I haven't captured?
- For the gaps, are there business constraints we should account for in remediation?"

### 3. Gap Analysis and Remediation Roadmap

For each identified gap, define remediation:

| Gap | Framework | Risk Level | Remediation Action | Effort | Priority |
|-----|-----------|-----------|-------------------|--------|----------|
| {{gap_description}} | {{framework}} | {{Critical/High/Medium/Low}} | {{specific_remediation}} | {{S/M/L}} | {{P1/P2/P3}} |

**Remediation Prioritization:**
- **P1 — Immediate**: Gaps that expose the system to regulatory action or high-severity threats. Address before production launch.
- **P2 — Near-term**: Gaps that represent meaningful risk but have partial mitigations. Address within first quarter.
- **P3 — Planned**: Gaps that are low-risk or have acceptable workarounds. Schedule for planned improvement.

Ask user:
"Here's the gap analysis and recommended remediation roadmap:

[Present gap table]

**Questions:**
- Are the priorities aligned with your business timeline?
- Are there any gaps you'd like to reprioritize?
- Do you have capacity constraints that affect the remediation sequence?"

### 4. Generate Compliance Mapping Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 11. Compliance Framework Mapping

### 11.1 Applicable Frameworks

{{list_of_applicable_frameworks_with_rationale}}

### 11.2 Control Mapping

{{framework_specific_mapping_tables_for_each_applicable_framework}}

### 11.3 Compliance Posture Summary

| Framework | Total Requirements | Implemented | Planned | Gaps |
|-----------|-------------------|-------------|---------|------|
{{summary_per_framework}}

## 12. Gap Analysis & Remediation

### 12.1 Identified Gaps

{{gap_table_with_framework_risk_and_remediation}}

### 12.2 Remediation Roadmap

{{prioritized_remediation_plan_with_phases}}

### 12.3 Ongoing Compliance Activities

{{regular_activities_audits_reviews_and_evidence_collection}}
```

### 5. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Compliance Mapping and Gap Analysis based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 4]

**What would you like to do?**
[C] Continue - Save this and proceed to validation & finalization
[R] Revise - Let's adjust the compliance mapping, gap analysis, or remediation priorities"

### 6. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/security-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 4.

## SUCCESS METRICS:

✅ Applicable compliance frameworks identified based on data types and business context
✅ Security controls mapped to specific framework requirements
✅ Control status (Implemented/Planned/Gap) accurately assessed
✅ Gap analysis completed with risk levels
✅ Remediation roadmap prioritized by risk and business timeline
✅ Ongoing compliance activities defined
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Mapping frameworks that don't apply to the user's system
❌ Generic compliance checklists without mapping to actual controls
❌ Not connecting compliance requirements to controls defined in step 3
❌ Remediation roadmap without practical prioritization
❌ Missing gap analysis for applicable frameworks
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-05-validation.md` to validate and finalize the security plan.

Remember: Do NOT proceed to step-05 until user explicitly selects 'C' from the menu and content is saved!
