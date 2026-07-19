# Step 3: Pipeline Stages

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between DevOps peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on stage design, testing strategy, security scanning, quality gates, and environment promotion
- 🎯 ANALYZE loaded architecture, infrastructure, and observability documents — don't assume requirements
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating pipeline stages
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from steps 1-2 are available
- Pipeline architecture decisions from step 2 are in the document
- Input documents already loaded are in memory
- Focus on stage definitions that align with the chosen platform and branching strategy
- Consider team maturity (`{bgr_maturity}`) for testing and security depth

## YOUR TASK:

Collaboratively define end-to-end pipeline stages including source, build, test, security scanning, packaging, staging deployment, verification, production promotion, and post-deploy checks through structured discussion with the user.

## PIPELINE STAGES SEQUENCE:

### 1. Discovery Phase — Testing and Security Maturity

Before designing stages, understand the user's current testing and security posture:

**Questions to discuss:**

- "What testing do you have today? Unit tests, integration tests, e2e tests? What's your current coverage?"
- "How long does your current test suite take to run? Any known flaky tests?"
- "Are you running any security scanning today — SAST, dependency scanning, container scanning?"
- "What's your current deployment verification process? Smoke tests? Manual checks?"
- "Are there compliance or regulatory requirements that mandate specific scanning or approval gates?"

**If observability plan is loaded**, extract:
- SLO definitions for post-deploy verification metrics
- Health check endpoints for smoke tests
- Dashboard links for deployment monitoring

**If security plan is loaded**, extract:
- Required security scanning types and severity thresholds
- Compliance frameworks that mandate specific checks
- Supply chain security requirements

### 2. Source Stage

Define pipeline trigger and source handling:

- **Trigger rules:** Push, PR, tag, schedule, manual dispatch — aligned with branching strategy from step 2
- **Branch filters:** Which branches trigger which pipeline variants
- **Path filters:** Only trigger on relevant file changes (skip docs-only changes, respect mono-repo boundaries)
- **Webhook configuration:** Event filtering, delivery guarantees
- **Checkout depth:** Shallow clone for speed vs full clone for changelog generation

### 3. Build Stage

Define compilation, dependency resolution, and build output:

- **Build tools:** Language-specific build systems (Maven, Gradle, npm, Go, Cargo, etc.)
- **Dependency resolution:** Lock-file enforcement, private registry authentication, proxy/mirror configuration
- **Build caching:** Leveraging cache strategy from step 2 — dependency cache hits, incremental builds
- **Parallelization:** Matrix builds for multi-platform, parallel compilation for mono-repos
- **Build output:** Versioned artifacts with metadata (git SHA, build number, timestamp)
- **Build reproducibility:** Pinned dependencies, deterministic builds, SBOM generation

### 4. Test Stage — Testing Pyramid with Quality Gates

Define the testing strategy with clear pass/fail gates:

| Test Type | Execution Point | Pass Threshold | Timeout | Retry | Blocking |
|-----------|----------------|---------------|---------|-------|----------|
| **Unit tests** | Every push | Coverage ≥ {{min_coverage}}% | {{timeout}} | 0 | Yes — gate the build |
| **Integration tests** | PR + main | All pass | {{timeout}} | 1 (flaky tolerance) | Yes — gate merge |
| **E2E tests** | Post-staging deploy | Critical paths pass | {{timeout}} | 1 | Yes — gate production |
| **Performance tests** | Pre-production | No regression > {{threshold}}% | {{timeout}} | 0 | Configurable |
| **Load tests** | Scheduled / release | Meet capacity targets | {{timeout}} | 0 | Advisory |

**For each test type, discuss with the user:**

- **Pass/fail thresholds:** Coverage minimums, allowed failure counts, performance budgets
- **Parallelization:** Split test suites across runners, parallel test execution
- **Test data:** Fixtures, factories, containerized dependencies, database seeding
- **Flaky test handling:** Quarantine, retry policy, tracking dashboard, ownership assignment

**Maturity-Adaptive Testing Guidance:**

- **Greenfield:** Unit tests + basic integration tests. Focus on building the habit. Coverage target: 60%+
- **Growing:** Add e2e smoke tests, introduce coverage gates. Start dependency scanning. Coverage: 70%+
- **Established:** Full pyramid with performance baselines. All test types in CI. Coverage: 80%+
- **Advanced:** Contract testing, chaos testing integration, mutation testing. Coverage: meaningful, not just high

### 5. Security Scanning Stage

Define security checks integrated into the pipeline:

| Scan Type | Tool | Execution Point | Severity Blocking | Remediation SLA |
|-----------|------|----------------|-------------------|-----------------|
| **SAST** | {{tool}} | Build | Critical + High | {{sla}} |
| **SCA / Dependency** | {{tool}} | Build | Critical (CVSS ≥ 9.0) | {{sla}} |
| **Container scanning** | {{tool}} | Package | Critical + High | {{sla}} |
| **Secrets detection** | {{tool}} | Source (pre-commit + CI) | Any secret = block | Immediate |
| **DAST** | {{tool}} | Post-staging deploy | Critical | {{sla}} |
| **License compliance** | {{tool}} | Build | Per policy | {{sla}} |

**For each scan type, discuss:**

- **Blocking policy:** Which severities block the pipeline vs produce warnings
- **Exception workflow:** How to suppress false positives, temporary exceptions with expiry
- **Reporting:** Where findings are surfaced (PR comments, dashboard, Slack, JIRA)
- **Remediation tracking:** How findings are assigned and tracked to resolution

**Maturity-Adaptive Security Guidance:**

- **Greenfield:** Secrets detection + dependency scanning. Block on critical vulnerabilities only
- **Growing:** Add SAST and container scanning. Block on critical + high. Introduce exception workflow
- **Established:** Full scanning suite including DAST. Define remediation SLAs. Track mean-time-to-remediate
- **Advanced:** Supply chain attestation (SLSA), SBOM distribution, automated remediation PRs

### 6. Package Stage

Define artifact packaging and registry publication:

- **Container image build:** Multi-stage Dockerfiles, minimal base images (distroless, Alpine, scratch)
- **Artifact versioning:** Semantic version from tags, git SHA for development builds, build metadata
- **Image/artifact signing:** Cosign, Notation, or Sigstore for supply chain verification
- **Registry push:** Aligned with artifact management decisions from step 2
- **SBOM generation:** CycloneDX or SPDX format, attached to image as attestation

### 7. Staging Deployment and Verification

Define how code reaches staging and is validated:

**Staging Deployment:**

- Automated deployment triggered by successful package stage (for main branch)
- Environment provisioning: pre-provisioned vs ephemeral (aligned with infrastructure plan)
- Database migration execution: run migrations before application deployment
- Configuration injection: environment-specific secrets, feature flag state

**Staging Verification:**

- Smoke tests against deployed staging environment — critical user journeys
- Synthetic monitoring: health check endpoints, key transaction paths
- **If observability plan is loaded:** Verify SLO metrics are within expected ranges post-deploy
- Manual QA checkpoint if applicable (human gate before production)
- Performance validation against baseline: response time, throughput, error rate

### 8. Production Promotion

Define the gate between staging and production:

- **Approval gates:** Manual approval, automated policy checks, or hybrid (auto-approve if all checks pass)
- **Deployment strategy execution:** Aligned with deployment strategy to be detailed in step 4
- **Traffic shifting schedule:** Progressive rollout percentages and validation windows
- **Communication:** Change management notifications, deployment calendar, stakeholder alerts
- **Emergency fast-track:** Expedited process for critical hotfixes (reduced gates, post-deploy review)

### 9. Post-Deploy Verification

Define production health validation after deployment:

- **Production smoke tests:** Critical path validation — login, core transaction, key API endpoints
- **SLO monitoring window:** Watch error rate, latency percentiles, availability for {{monitoring_window}} minutes
- **Automated rollback triggers:** Error rate > {{threshold}}%, latency p99 > {{threshold}}ms, health check failures
- **If incident response plan is loaded:** Deployment-triggered incidents follow defined escalation paths
- **Post-deploy notification:** Status reporting to team channel, deployment dashboard update

### 10. Generate Pipeline Stages Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 3. Pipeline Stages

### 3.1 Source

{{source_stage_details}}

### 3.2 Build

{{build_stage_details}}

### 3.3 Test

| Test Type | Stage Gate | Timeout | Retry | Notes |
|-----------|-----------|---------|-------|-------|
| {{test_type}} | {{gate}} | {{timeout}} | {{retry}} | {{notes}} |

**Flaky Test Policy:** {{flaky_test_handling}}
**Test Data Strategy:** {{test_data_approach}}

### 3.4 Security Scanning

| Scan Type | Tool | Stage | Blocking | Owner | Notes |
|-----------|------|-------|----------|-------|-------|
| {{scan_type}} | {{tool}} | {{stage}} | {{blocking}} | {{owner}} | {{notes}} |

**Exception Workflow:** {{exception_process}}

### 3.5 Package

{{package_stage_details}}

### 3.6 Deploy to Staging

{{staging_deploy_details}}

### 3.7 Staging Verification

**Smoke Tests:** {{smoke_test_scope}}
**SLO Monitoring:** {{slo_check_details}}
**Manual Gate:** {{manual_qa_requirement}}

### 3.8 Production Promotion

**Approval Model:** {{approval_approach}}
**Monitoring Window:** {{monitoring_window}} minutes

### 3.9 Post-Deploy Verification

**Rollback Triggers:** {{automated_rollback_criteria}}
**SLO Watch:** {{slo_monitoring_details}}
```

### 11. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Pipeline Stages based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 10]

**What would you like to do?**
[C] Continue - Save these stages and proceed to Deployment Strategy
[R] Revise - Let's adjust specific stages before continuing"

### 12. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Testing / Security Scanning / Staging / Production Promotion / Post-Deploy)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/pipeline.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3]`
- Load `./step-04-deployment-strategy.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 10.

## SUCCESS METRICS:

✅ All pipeline stages defined from source through post-deploy verification
✅ Testing pyramid defined with clear pass/fail thresholds and timeouts
✅ Security scanning configured with severity blocking policies and remediation SLAs
✅ Staging deployment and verification process documented
✅ Production promotion gates and monitoring windows defined
✅ Cross-workflow context loaded from observability and security plans where available
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Defining stages without understanding current testing maturity
❌ Missing security scanning stage or treating it as optional
❌ Not defining pass/fail thresholds (vague quality gates)
❌ Skipping post-deploy verification (deploy-and-pray)
❌ Not loading cross-workflow context from observability and security plans
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-04-deployment-strategy.md` to define deployment models, rollback procedures, database migrations, and release management.

Remember: Do NOT proceed to step-04 until user explicitly selects [C] from the menu and content is saved!
