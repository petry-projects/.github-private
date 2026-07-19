# Step 2: Infrastructure as Code Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on IaC tooling, state management, module strategy, policy-as-code, and drift detection
- 🎯 ANALYZE loaded architecture document, don't assume or generate requirements
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating IaC strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (Architecture doc, PRD, etc.)
- Focus on IaC decisions that support the architectural choices
- Consider team expertise and operational maturity

## YOUR TASK:

Collaboratively determine the IaC tooling, state management, module strategy, policy-as-code approach, and drift detection strategy through structured discussion with the user.

## IaC STRATEGY SEQUENCE:

### 1. IaC Tool Selection

Evaluate and discuss IaC tooling options with the user:

**Options to Consider:**

- **Terraform** — Mature ecosystem, provider-agnostic, HCL syntax, large community
- **Pulumi** — General-purpose languages (TypeScript, Python, Go), testing-friendly, state management built-in
- **CloudFormation/CDK** — AWS-native, deep service integration, CDK enables programming languages
- **Crossplane** — Kubernetes-native, GitOps-friendly, composition-based
- **Combination** — Different tools for different layers (e.g., Terraform for infra + Helm for K8s)

**Selection Criteria to Discuss:**

- Team expertise and learning curve
- Multi-cloud requirements vs single-provider
- State management complexity tolerance
- Ecosystem maturity and community support
- Testing and validation capabilities
- CI/CD integration patterns
- Drift detection capabilities

Present your recommendation based on the architecture document and discuss:

"Based on your architecture, here's what I'm thinking for IaC tooling:

**Recommended:** {{tool_recommendation}}
**Rationale:** {{why_this_fits}}

What's your team's experience with these tools? Any strong preferences or constraints?"

### 2. State Management Strategy

Define how IaC state will be managed:

**Key Decisions:**

- **Remote Backend:** S3+DynamoDB, GCS, Azure Blob, Terraform Cloud, Pulumi Cloud
- **State Locking:** Mechanism to prevent concurrent modifications
- **State Per Environment:** Separate state files per environment vs shared state
- **Secrets in State:** How to handle sensitive values (encryption at rest, state access controls)
- **State Recovery:** Backup strategy, import/move procedures

### 3. Module/Component Strategy

Define the composability approach:

**Key Decisions:**

- **Module Granularity:** Atomic modules vs opinionated compositions
- **Module Versioning:** Semantic versioning, pinning strategy, upgrade process
- **Registry Strategy:** Public registry, private registry, Git-based modules
- **Composition Pattern:** Root modules, workspaces, stacks, or environments referencing shared modules
- **Documentation:** Module READMEs, input/output documentation, usage examples

### 4. Policy-as-Code Approach

Define guardrails and compliance automation:

**Tools to Consider:**

- **OPA/Rego** — General-purpose policy engine, Conftest for IaC
- **Checkov** — Static analysis for IaC, broad framework support
- **tfsec/trivy** — Security-focused scanning for Terraform
- **Sentinel** — HashiCorp native policy framework (Terraform Cloud/Enterprise)
- **Kyverno** — Kubernetes-native policy engine

**Policy Categories:**

- Security policies (encryption, public access, IAM)
- Cost policies (instance sizes, resource limits)
- Compliance policies (tagging, naming conventions, regions)
- Architectural policies (approved services, network patterns)

### 5. Drift Detection & Remediation

Define how infrastructure drift will be managed:

**Key Decisions:**

- **Detection Frequency:** Continuous, scheduled, on-demand
- **Detection Method:** Plan-based comparison, cloud API scanning, agent-based
- **Alerting:** How drift is reported (Slack, PagerDuty, dashboard)
- **Remediation Strategy:** Auto-remediate, manual review, hybrid by severity
- **Exceptions:** How to handle intentional drift (emergency changes, experiments)

### 6. Generate IaC Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Infrastructure as Code

### 2.1 Tool Selection

| Tool | Purpose | Version | Notes |
|------|---------|---------|-------|
| {{tool}} | {{purpose}} | {{version}} | {{notes}} |

**Selection Rationale:** {{rationale}}

### 2.2 State Management

**Backend:** {{backend_choice}}
**Locking:** {{locking_mechanism}}
**Environment Isolation:** {{state_per_env_strategy}}
**Secrets Handling:** {{secrets_in_state_approach}}
**Recovery:** {{backup_and_recovery_strategy}}

### 2.3 Module Strategy

**Granularity:** {{module_granularity}}
**Versioning:** {{versioning_approach}}
**Registry:** {{registry_strategy}}
**Composition:** {{composition_pattern}}

### 2.4 Policy as Code

| Tool | Scope | Enforcement | Notes |
|------|-------|-------------|-------|
| {{tool}} | {{scope}} | {{enforcement_level}} | {{notes}} |

**Policy Categories:**
{{policy_categories_and_rules}}

### 2.5 Drift Detection

**Detection Method:** {{detection_approach}}
**Frequency:** {{detection_frequency}}
**Alerting:** {{alert_channels}}
**Remediation:** {{remediation_strategy}}
**Exception Handling:** {{drift_exception_process}}
```

### 7. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Infrastructure as Code strategy based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 6]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to Environment Strategy
[R] Revise - Let's adjust specific sections before continuing"

### 8. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Tool Selection / State Management / Module Strategy / Policy as Code / Drift Detection)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/infrastructure.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-environment-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 6.

## SUCCESS METRICS:

✅ IaC tool selected with clear rationale tied to architecture
✅ State management strategy fully defined
✅ Module/component strategy documented with versioning approach
✅ Policy-as-code approach defined with enforcement levels
✅ Drift detection and remediation strategy documented
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Selecting tools without considering team expertise
❌ Not defining state management completely
❌ Missing drift detection strategy
❌ Not discussing policy-as-code enforcement levels
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-03-environment-strategy.md` to define environment topology and configuration management.

Remember: Do NOT proceed to step-03 until user explicitly selects [C] from the menu and content is saved!
