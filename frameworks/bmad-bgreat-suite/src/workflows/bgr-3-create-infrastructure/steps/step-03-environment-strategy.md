# Step 3: Environment Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on environment topology, parity, configuration, secrets, cost, and networking
- 🎯 BUILD ON the IaC strategy decisions from step 2
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating environment strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document with IaC strategy from step 2 is available
- Input documents already loaded are in memory
- Focus on environment decisions that align with IaC choices
- Consider cost optimization alongside reliability

## YOUR TASK:

Collaboratively define the environment topology, parity rules, configuration management, secrets management, cost management, and network architecture through structured discussion with the user.

## ENVIRONMENT STRATEGY SEQUENCE:

### 1. Environment Topology

Define the complete set of environments and their purposes:

**Common Environment Types:**

- **Development** — Individual or shared dev environments, rapid iteration
- **Staging** — Pre-production validation, mirrors production
- **Production** — Live customer-facing environment
- **Sandbox** — Experimentation, proof-of-concept, isolated testing
- **Disaster Recovery** — Failover environment for business continuity

**Key Questions to Discuss:**

- Which environments does your project need?
- Should developers have individual environments or share?
- Is there a QA/UAT environment separate from staging?
- Do you need a disaster recovery environment?
- Are there regulatory requirements for environment isolation?

Present a recommendation based on the architecture:

"Based on your architecture and scale, here's the environment topology I'd suggest:

{{environment_topology_recommendation}}

What environments does your team currently use or plan to use?"

### 2. Environment Isolation (MANDATORY)

Before discussing parity, establish hard isolation boundaries. These are non-negotiable:

**Account/Subscription Isolation:**

- Each SDLC environment MUST reside in its own cloud account (AWS), subscription (Azure), or project (GCP)
- No shared accounts between environments — blast radius and compliance require hard boundaries
- A dedicated shared-services account (for CI/CD runners, artifact registries, DNS) is acceptable but must have no direct network path to workload environments

**Network Isolation:**

- No cross-environment VPC/VNet peering, transit gateway attachments/routes, private connectivity, or any other network path is permitted between SDLC environments
- Each SDLC environment must be network-unreachable from every other SDLC environment; peering, transit, and routing decisions may only be considered within a single environment boundary or for separately governed on-prem/shared-services connectivity that does not create environment-to-environment paths
- Data flows between environments (e.g., database seeding for staging) use explicit, audited, offline export/import — never live connections or routed network access between environments

**Secrets Isolation:**

- Each environment has its own secrets store (separate Vault namespace, separate Secrets Manager in its own account, etc.)
- No secret ARN, key path, or credential is shared across environment boundaries
- Rotation schedules are per-environment and independently managed

**IAM Isolation:**

- Service accounts, roles, and policies are scoped to a single environment
- No cross-account role assumptions between SDLC environments except through a dedicated, audited break-glass process
- Human access to production is read-only, time-bound, and audit-logged

**State Isolation:**

- Terraform/IaC state backends are per-environment in separate accounts
- State files for one environment are inaccessible from another

**Key Questions to Discuss:**

- How will you separate cloud accounts per environment?
- Are there any legacy shared resources that need migration to isolated boundaries?
- What break-glass procedure do you need for emergency cross-environment access?

### 3. Environment Parity Rules

Define what differs between environments and what must remain identical:

**Must Be Identical Across Environments:**

- Configuration shape/schema (same keys, different values)
- Network topology patterns (same architecture, different scale)
- Security policies (same rules, same enforcement)
- Deployment process (same pipeline, different targets)
- Monitoring and alerting patterns (same instrumentation)
- IaC module versions (same modules, parameterized per environment)

**Expected Differences Between Environments:**

- Scale (instance counts, sizes, replica counts)
- Data (synthetic/anonymized in non-prod, real in prod)
- External integrations (sandbox/mock APIs in non-prod)
- Cost controls (aggressive in non-prod, reliability-focused in prod)
- Access controls (broader in dev, strict in prod)
- Cloud account/subscription (separate per environment)

### 3. Configuration Management

Define how environment-specific configuration is managed:

**Key Decisions:**

- **Config Injection Pattern:** Environment variables, config files, config maps, parameter store
- **Config Source of Truth:** Git repo, parameter store, secrets manager, config service
- **Config Promotion:** How config changes flow between environments
- **Config Validation:** Schema validation, type checking, required field enforcement
- **Feature Flags:** Flag management system, environment-specific toggles

### 4. Secrets Management

Define how secrets are stored, distributed, and rotated:

**Tools to Consider:**

- **HashiCorp Vault** — Full-featured, dynamic secrets, broad integrations
- **AWS Secrets Manager / Parameter Store** — AWS-native, rotation support
- **Azure Key Vault** — Azure-native, certificate management
- **GCP Secret Manager** — GCP-native, IAM integration
- **SOPS** — Git-friendly encrypted files, key management via KMS
- **External Secrets Operator** — Kubernetes-native, syncs from external stores

**Key Decisions:**

- Secret storage backend
- Secret rotation strategy and automation
- Application secret injection pattern
- Emergency secret rotation procedure
- Secret access auditing

### 5. Cost Management

Define cost controls for infrastructure:

**Key Decisions:**

- **Non-Production Auto-Shutdown:** Schedule-based, idle detection, manual triggers
- **Right-Sizing:** Instance selection strategy, performance testing baseline
- **Spot/Preemptible Instances:** Where appropriate (non-critical workloads, batch processing)
- **Reserved Capacity:** Production commitment strategy, savings plans
- **Cost Visibility:** Tagging strategy, cost allocation, budgets and alerts
- **Resource Cleanup:** Orphaned resource detection, TTL on temporary resources

### 6. Promotion Gates & Change Control

Define the gates that govern how changes flow between environments:

**Promotion Gate Requirements:**

- **Dev → Staging**: Automated tests pass, security scans clean, IaC plan reviewed
- **Staging → Production**: All of the above PLUS manual signoff from a reviewer who did not author the change, SLO compliance verified, rollback plan confirmed
- **Hotfix Path**: Expedited pipeline with minimum smoke tests + security scan + signoff, followed by mandatory post-deploy review within 24 hours

**Key Decisions:**

- **Signoff mechanism**: Pipeline approval gates (GitHub Environments, GitLab approvals, etc.)
- **Signoff requirements**: Minimum reviewer count, role requirements (e.g., must include SRE)
- **Automated gate criteria**: Test coverage thresholds, scan severity thresholds, policy compliance
- **Audit trail**: All promotions and approvals recorded with timestamp, approver, and artifact version
- **No-bypass enforcement**: Pipeline configuration prevents skipping gates, even for admins

**Anti-Pattern Check:**

- Are there ANY paths to production that bypass the pipeline? Flag and eliminate them.
- Can anyone deploy directly via console, CLI, or SSH? If yes, this must be blocked.
- Are there shared credentials that could be used to push changes outside the pipeline? Remediate.

### 7. Network Architecture

Define the networking foundation:

**Key Decisions:**

- **VPC/VNet Design:** CIDR planning, one VPC/VNet per environment in its own account/subscription
- **Subnet Strategy:** Public/private/data tiers, availability zone distribution
- **Within-Environment Connectivity:** Peering and transit gateways are for connecting services within a single environment or to shared-services accounts only — NEVER between SDLC environments
- **External Connectivity:** VPN, Direct Connect/ExpressRoute for on-premises integration, scoped per environment
- **DNS Strategy:** Public DNS, private DNS zones per environment, service discovery
- **Load Balancing:** ALB/NLB/CLB, Ingress controllers, global load balancing
- **Network Security:** Security groups, NACLs, network policies, WAF, default-deny between environments

### 7. Generate Environment Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 3. Environment Strategy

### 3.1 Environment Topology

| Environment | Purpose | Scale | Data | Auto-Shutdown | Cloud Account/Subscription |
|-------------|---------|-------|------|---------------|---------------------------|
| {{env}} | {{purpose}} | {{scale}} | {{data_type}} | {{auto_shutdown}} | {{account_id}} |

### 3.2 Environment Isolation

**Account Separation:**
{{account_isolation_strategy}}

**Network Isolation:**
{{network_isolation_strategy}}

**Secrets Isolation:**
{{secrets_isolation_strategy}}

**IAM Isolation:**
{{iam_isolation_strategy}}

**State Isolation:**
{{state_isolation_strategy}}

### 3.3 Environment Parity Rules

**Identical Across All Environments:**
{{parity_identical_list}}

**Expected Differences:**
{{parity_differences_list}}

### 3.4 Configuration Management

**Injection Pattern:** {{config_injection_pattern}}
**Source of Truth:** {{config_source}}
**Promotion Flow:** {{config_promotion_flow}}
**Validation:** {{config_validation_approach}}
**Feature Flags:** {{feature_flag_strategy}}

### 3.5 Secrets Management

**Backend:** {{secrets_backend}}
**Rotation Strategy:** {{rotation_approach}}
**Injection Pattern:** {{secret_injection_pattern}}
**Audit:** {{secret_audit_approach}}

### 3.6 Promotion Gates & Change Control

**Environment Promotion Flow:**
{{promotion_flow}}

**Gate Requirements per Boundary:**
{{gate_requirements}}

**Signoff Requirements:**
{{signoff_requirements}}

**No-Bypass Enforcement:**
{{bypass_prevention}}

### 3.7 Cost Management

**Non-Production Controls:**
{{non_prod_cost_controls}}

**Production Optimization:**
{{prod_cost_optimization}}

**Visibility & Governance:**
{{cost_visibility_strategy}}

## 4. Network Architecture

### 4.1 VPC/VNet Design

{{vpc_design}}

### 4.2 Subnet Strategy

{{subnet_strategy}}

### 4.3 DNS & Load Balancing

**DNS:** {{dns_strategy}}
**Load Balancing:** {{lb_strategy}}
**Network Security:** {{network_security_approach}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Environment Strategy and Network Architecture based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to Container Strategy
[R] Revise - Let's adjust specific sections before continuing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Environment Topology / Parity Rules / Configuration / Secrets / Cost / Network)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/infrastructure.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-container-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Environment topology documented with clear purpose for each environment
✅ Environment isolation enforced — separate accounts, networks, secrets, IAM, and state per environment
✅ No cross-environment resource sharing identified or all shared resources flagged for remediation
✅ Parity rules defined — what's identical vs what differs
✅ Configuration management strategy documented with injection patterns
✅ Secrets management strategy defined with rotation approach per environment
✅ Promotion gates defined at every environment boundary with signoff requirements
✅ No-bypass enforcement documented — no path to production outside the pipeline
✅ Cost management approach documented with non-prod controls
✅ Network architecture documented with VPC, subnets, DNS, and LB
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Not enforcing environment isolation (shared accounts, networks, secrets, or IAM across environments)
❌ Allowing any manual change path to production
❌ Missing promotion gates or signoff requirements between environments
❌ Not considering cost implications of environment strategy
❌ Missing secrets management or rotation strategy
❌ Not defining parity rules between environments
❌ Ignoring network security in architecture
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation
❌ Cross-environment network connectivity without explicit justification and compensating controls

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-04-container-strategy.md` to define container and orchestration strategy.

Remember: Do NOT proceed to step-04 until user explicitly selects [C] from the menu and content is saved!
