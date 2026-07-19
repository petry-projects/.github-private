# Step 2: Threat Modeling

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between security peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on identifying real threats to the user's specific system, not generic checklists
- 🎯 ANALYZE loaded documents for components, data flows, and trust boundaries
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating threat model
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (architecture, PRD, infrastructure, etc.)
- Focus on identifying threats specific to the user's system architecture
- Use STRIDE as the primary framework, supplemented by PASTA risk analysis

## YOUR TASK:

Collaboratively identify system assets, map trust boundaries, apply STRIDE threat analysis, build a threat matrix with severity and likelihood, and identify existing controls and gaps.

## THREAT MODELING SEQUENCE:

### 1. Identify System Assets and Data Classification

Before modeling threats, establish what needs protecting:

**Asset Inventory:**
- What are the critical system components? (from architecture document)
- What data does the system store and process?
- What are the external integrations and third-party dependencies?
- What are the user-facing entry points?

**Data Classification:**
| Classification | Description | Examples |
|---------------|-------------|----------|
| Restricted | Highest sensitivity — breach causes severe harm | PII, PHI, payment data, credentials, encryption keys |
| Confidential | Business-sensitive — breach causes significant harm | Business logic, internal APIs, analytics data |
| Internal | For internal use — breach causes moderate harm | Configuration, internal docs, non-sensitive logs |
| Public | No sensitivity — freely available | Marketing content, public APIs, open-source code |

Ask user:
"Let's start by understanding what we're protecting. Based on your architecture:

**Key questions:**
- What types of sensitive data does your system handle? (PII, payment info, health records, credentials)
- What are the most business-critical services or flows?
- Are there external integrations that handle sensitive data?
- What compliance requirements apply to your data? (SOC2, HIPAA, PCI-DSS, GDPR)"

### 2. Map Trust Boundaries and Data Flows

Based on architecture and user input, identify trust boundaries:

**Trust Boundary Categories:**
- **External → Internal**: Internet-facing entry points (API gateway, web app, mobile backend)
- **Service → Service**: Inter-service communication within the system
- **Application → Data Store**: Access to databases, caches, object storage
- **Internal → Third-Party**: Outbound calls to external APIs, SaaS services
- **User → System**: Authentication and session boundaries
- **Environment → Environment**: Dev/staging/production boundaries

"Based on your architecture, here are the trust boundaries I've identified:

[List trust boundaries discovered from architecture docs]

**Questions:**
- Are there additional trust boundaries I've missed?
- Which boundary crossings handle the most sensitive data?
- Are there any service-to-service calls that currently lack authentication?"

### 3. Apply STRIDE Threat Analysis

For each major component and trust boundary, systematically evaluate STRIDE categories:

**Spoofing:**
- Can an attacker impersonate a user or service?
- Are authentication mechanisms strong at every trust boundary?
- Is there protection against credential stuffing, token theft, session hijacking?

**Tampering:**
- Can data be modified in transit or at rest without detection?
- Are there integrity checks on critical data flows?
- Can configuration or code be modified by unauthorized parties?

**Repudiation:**
- Can users or services deny performing actions?
- Is there comprehensive audit logging?
- Are logs tamper-proof and centrally stored?

**Information Disclosure:**
- Can sensitive data leak through error messages, logs, or APIs?
- Is data encrypted at rest and in transit?
- Are there data exposure risks in backups, caches, or temporary storage?

**Denial of Service:**
- Can the system be overwhelmed by malicious traffic?
- Are there rate limiting and circuit breaker patterns?
- What are the single points of failure?

**Elevation of Privilege:**
- Can a low-privilege user gain admin access?
- Are authorization checks enforced at every layer?
- Can service accounts be exploited for lateral movement?

Present the analysis to the user and discuss:
"Here's my STRIDE analysis of your system. Let's walk through each category and validate whether these threats apply to your specific context.

[Present STRIDE findings organized by component or trust boundary]

**For each threat, let's discuss:**
- Is this threat realistic for your system?
- Are there existing controls already in place?
- What is the potential business impact if exploited?"

### 4. Build Threat Matrix

Compile threats into a prioritized matrix:

| ID | Component | STRIDE Category | Threat Description | Likelihood | Impact | Risk Level | Existing Controls | Remediation |
|----|-----------|----------------|-------------------|-----------|--------|-----------|-------------------|-------------|
| T-001 | {{component}} | {{category}} | {{description}} | {{H/M/L}} | {{H/M/L}} | {{Critical/High/Medium/Low}} | {{current_controls}} | {{recommended_action}} |

**Risk Level Calculation:**
| | High Impact | Medium Impact | Low Impact |
|---|---|---|---|
| **High Likelihood** | Critical | High | Medium |
| **Medium Likelihood** | High | Medium | Low |
| **Low Likelihood** | Medium | Low | Low |

Discuss with user:
"Here's the threat matrix I've built based on our analysis. Let's review the risk levels together:

**Critical/High threats requiring immediate attention:**
[List critical and high risk threats]

**Questions:**
- Do the risk levels match your intuition about what's most dangerous?
- Are there threats I've missed that you're concerned about?
- Are there any existing controls I haven't accounted for?"

### 5. Generate Threat Modeling Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Asset Inventory & Data Classification

### 2.1 Critical Assets

{{asset_inventory_table}}

### 2.2 Data Classification

{{data_classification_table_with_examples_from_system}}

## 3. Trust Boundaries & Data Flows

### 3.1 Trust Boundary Map

{{trust_boundaries_identified_with_data_flow_descriptions}}

### 3.2 Attack Surface Summary

{{entry_points_and_external_interfaces}}

## 4. Threat Model (STRIDE Analysis)

### 4.1 Threat Matrix

{{threat_matrix_table_with_all_identified_threats}}

### 4.2 Critical Threats

{{detailed_description_of_critical_and_high_risk_threats}}

### 4.3 Risk Heat Map

{{summary_of_threats_by_risk_level}}
```

### 6. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Threat Model based on our analysis.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 5]

**What would you like to do?**
[C] Continue - Save this and proceed to security controls
[R] Revise - Let's adjust the threat model, risk levels, or add missing threats"

### 7. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/security-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-security-controls.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 5.

## SUCCESS METRICS:

✅ System assets identified and data classified
✅ Trust boundaries mapped from architecture documents
✅ STRIDE analysis applied to major components and boundaries
✅ Threat matrix built with realistic likelihood and impact ratings
✅ Existing controls acknowledged, gaps identified
✅ Threats prioritized by risk level
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Generating generic threats without analyzing the specific architecture
❌ Not discussing data classification with the user
❌ Missing trust boundaries from the architecture
❌ Risk levels that don't reflect realistic attack scenarios
❌ Not acknowledging existing security controls
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-03-security-controls.md` to define security controls and mitigation strategies.

Remember: Do NOT proceed to step-03 until user explicitly selects 'C' from the menu and content is saved!
