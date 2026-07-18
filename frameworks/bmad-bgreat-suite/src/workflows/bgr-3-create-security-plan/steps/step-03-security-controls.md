# Step 3: Security Controls

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input

- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between security peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on practical security controls that address the threats identified in step 2
- 🎯 BUILD on the threat matrix to define targeted mitigations
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating security controls
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Threat model and data classification from step 2 are in the document
- Input documents and system context are available from earlier steps
- Focus on controls that directly address identified threats
- Adapt recommendations to the user's technology stack and team capabilities

## YOUR TASK:

Collaboratively define authentication/authorization strategy, data protection controls, network security posture, secret management approach, supply chain security, and security testing gates tailored to the user's system and threat model.

## SECURITY CONTROLS SEQUENCE:

### 1. Authentication & Authorization Strategy

Discuss authentication and authorization approach with user:

**Authentication:**
- **User authentication**: OAuth 2.0 / OIDC provider selection, MFA requirements, session management, password policies
- **Service-to-service authentication**: mTLS, JWT validation, API key management
- **Machine/CI authentication**: OIDC federation (GitHub Actions → cloud), short-lived credentials, no long-lived secrets
- **Admin access**: Privileged access management, just-in-time access, break-glass procedures

**Authorization:**
- **Model selection**: RBAC, ABAC, or hybrid — based on complexity needs
- **Enforcement points**: API gateway, service mesh, application layer, database layer
- **Policy as code**: OPA/Rego, Cedar, or application-native — version controlled and tested
- **Least privilege**: Default-deny, explicit grants, regular access reviews

Ask user:
"Based on the threats we identified, let's design your auth strategy:
- What identity provider are you using or planning to use?
- Do you need service-to-service authentication? How many services communicate?
- What authorization granularity do you need? (role-based vs. attribute-based)
- Are there regulatory requirements for access control? (e.g., HIPAA requires audit trails)"

### 2. Data Protection

Define data protection controls aligned with classification from step 2:

**Encryption:**
- At rest: AES-256 for all data stores, KMS-managed keys, key rotation policy
- In transit: TLS 1.2+ minimum, mTLS for internal services, certificate management
- Application-level: Field-level encryption for restricted data, client-side encryption for sensitive uploads

**Data Handling:**
- PII/PHI processing: Tokenization, pseudonymization, data masking for non-production
- Data retention: Policies per classification level, automated purging, legal hold support
- Data access logging: Who accessed what, when, and from where — for all restricted data
- Backup security: Encrypted backups, access-controlled restoration, tested recovery

**Privacy Controls:**
- Consent management: Track and enforce consent per data subject
- Data subject rights: Export, deletion, correction capabilities (if GDPR/CCPA applies)
- Cross-border transfer: Identify data residency requirements, transfer mechanisms

Ask user:
"Let's define data protection for your system:
- What encryption are you currently using (at rest, in transit)?
- Where is your most sensitive data stored? (databases, object storage, caches)
- Do you need to support data subject rights (GDPR right to deletion, data portability)?
- What are your data retention requirements?"

### 3. Network Security

Define network security posture:

**Perimeter Security:**
- WAF rules for internet-facing endpoints
- DDoS protection (cloud-native or third-party)
- API gateway with rate limiting, request validation, IP allowlisting
- Bot detection and mitigation

**Internal Security:**
- Default-deny network policies between services
- Micro-segmentation: Services can only reach the services they need
- Private endpoints for managed services (databases, queues, storage)
- No direct internet access from internal services — egress through controlled proxy

**Zero-Trust Principles:**
- Verify every request regardless of network location
- Identity-aware proxy for internal tools and admin interfaces
- Continuous verification — don't trust sessions indefinitely
- Device posture assessment for privileged access

Ask user:
"For network security:
- What internet-facing endpoints does your system expose?
- Do you have network segmentation today? (VPCs, subnets, security groups)
- Are there internal tools or admin interfaces that need protection?
- Do remote team members need access to internal resources?"

### 4. Secret Management

Define secret management strategy:

**Secret Storage:**
- Centralized secret store: HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, GCP Secret Manager
- No long-lived secrets in environment variables — use short-lived, runtime-injected credentials with strict scoping
- Secret injection at runtime via sidecar, init container, or SDK

**Secret Lifecycle:**
- Automated rotation policy: 90 days for API keys, 365 days for certificates, immediate for compromised credentials
- Secret versioning to support zero-downtime rotation
- Revocation procedures for compromised secrets
- Break-glass access for emergency credential retrieval

**CI/CD Secrets:**
- OIDC federation for cloud access (no long-lived cloud credentials in CI)
- Scoped permissions per pipeline stage
- Secret masking in logs and output
- Separate secret stores per environment

Ask user:
"For secret management:
- How are secrets currently stored and accessed?
- What types of secrets does your system use? (API keys, database credentials, certificates, tokens)
- Do you have a secret rotation process today?
- What CI/CD platform are you using for pipeline secrets?"

### 5. Supply Chain Security

Define supply chain security controls:

**Dependency Management:**
- Software Composition Analysis (SCA) in CI: Snyk, Dependabot, Trivy
- Block builds on critical/high CVEs with configurable policy
- Automated dependency update PRs with security-focused prioritization
- License compliance scanning

**Build Security:**
- SBOM generation: CycloneDX or SPDX format at build time
- Reproducible builds where feasible
- Build provenance attestation (SLSA framework)
- Signed artifacts: Container image signing with cosign or Notary

**Container Security:**
- Minimal base images: distroless or Alpine — no unnecessary packages
- No root processes in containers
- Read-only root filesystems
- Image scanning in CI and continuous scanning in registry

Ask user:
"For supply chain security:
- What package managers and languages does your project use?
- Do you currently scan dependencies for vulnerabilities?
- Are you using containers? What base images?
- What is your appetite for build pipeline strictness? (block on vulnerabilities vs. warn)"

### 6. Security Testing Strategy

Define security testing gates:

**Pre-Commit / Local:**
- Secret scanning (git-secrets, truffleHog, gitleaks)
- Pre-commit hooks for common security patterns

**CI Pipeline:**
- SAST: Static analysis (Semgrep, CodeQL, SonarQube) — fail on high/critical
- SCA: Dependency scanning — fail on critical CVEs
- Container scanning: Image vulnerability scan before push to registry
- IaC scanning: Checkov, tfsec, or equivalent for infrastructure code

**Pre-Production:**
- DAST: Dynamic analysis against staging (OWASP ZAP)
- Integration security tests: Auth bypass, injection, authorization boundary tests

**Periodic:**
- Annual penetration test by third-party vendor
- Quarterly access review
- Bug bounty program (for mature organizations)

**Security Review Gates:**

| Change Type | Review Required |
|------------|----------------|
| New authentication/authorization flow | Mandatory security review |
| New external integration | Mandatory security review |
| New data store or data type | Mandatory security review |
| Infrastructure changes | IaC scan + review if network/IAM changes |
| Dependency major version updates | SCA scan + review |
| Routine code changes | Automated scanning only |

Ask user:
"For security testing:
- What CI/CD platform are you using?
- Do you have any security scanning in place today?
- What is your tolerance for pipeline speed vs. security thoroughness?
- Would you consider a bug bounty program in the future?"

### 7. Generate Security Controls Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 5. Authentication & Authorization

### 5.1 Authentication Strategy

{{authentication_approach_for_users_services_and_machines}}

### 5.2 Authorization Model

{{authorization_model_enforcement_points_and_policy_management}}

### 5.3 Session & Token Management

{{session_policies_token_lifetimes_and_refresh_strategy}}

## 6. Data Protection

### 6.1 Encryption Strategy

{{encryption_at_rest_in_transit_and_application_level}}

### 6.2 Data Handling Procedures

{{pii_handling_retention_masking_and_access_logging}}

### 6.3 Privacy Controls

{{consent_management_data_subject_rights_if_applicable}}

## 7. Network Security

### 7.1 Perimeter Security

{{waf_ddos_api_gateway_and_rate_limiting}}

### 7.2 Internal Network Controls

{{segmentation_private_endpoints_and_egress_controls}}

### 7.3 Zero-Trust Implementation

{{identity_aware_access_and_continuous_verification}}

## 8. Secret Management

### 8.1 Secret Storage & Access

{{centralized_vault_injection_method_and_access_controls}}

### 8.2 Secret Lifecycle

{{rotation_policies_versioning_and_revocation}}

### 8.3 CI/CD Secret Strategy

{{pipeline_secret_management_and_oidc_federation}}

## 9. Supply Chain Security

### 9.1 Dependency Management

{{sca_scanning_update_policy_and_license_compliance}}

### 9.2 Build & Artifact Security

{{sbom_generation_provenance_and_signing}}

### 9.3 Container Security

{{base_images_scanning_and_runtime_hardening}}

## 10. Security Testing Strategy

### 10.1 Testing Pipeline

{{sast_sca_dast_and_container_scanning_integration}}

### 10.2 Security Review Gates

{{change_types_requiring_security_review}}

### 10.3 Periodic Assessments

{{pen_testing_access_reviews_and_bug_bounty}}

### Control-to-Threat Traceability

| Threat ID | Threat Description | Control IDs | Control Owner | Status |
|-----------|-------------------|-------------|---------------|--------|
{{for_each_threat_map_to_mitigating_controls_with_owner_and_implementation_status}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Security Controls based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this and proceed to compliance mapping
[R] Revise - Let's adjust the security controls, auth strategy, or testing approach"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask what specific areas need adjustment
- Collaborate on revisions
- Present updated content
- Return to [C]/[R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/security-plan.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-compliance-mapping.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Authentication strategy defined for users, services, and machines
✅ Authorization model selected and enforcement points identified
✅ Data protection controls aligned with data classification from step 2
✅ Network security posture defined with zero-trust principles
✅ Secret management strategy with lifecycle policies
✅ Supply chain security controls defined
✅ Security testing gates integrated into CI/CD pipeline
✅ All controls mapped back to threats from step 2
✅ [C]/[R] menu presented and handled correctly
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Proposing controls without connecting them to identified threats
❌ Setting up an auth strategy incompatible with the user's tech stack
❌ Ignoring data classification when defining protection controls
❌ Generic network security without considering the actual architecture
❌ Not addressing secret management for CI/CD pipelines
❌ Security testing that is too heavy or too light for the team
❌ Not presenting [C]/[R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects 'C' and content is saved to document, load `./step-04-compliance-mapping.md` to map security controls to regulatory frameworks.

Remember: Do NOT proceed to step-04 until user explicitly selects 'C' from the menu and content is saved!
