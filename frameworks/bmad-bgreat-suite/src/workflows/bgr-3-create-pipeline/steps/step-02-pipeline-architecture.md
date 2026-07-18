# Step 2: Pipeline Architecture

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between DevOps peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on CI/CD platform selection, branching strategy, runner architecture, artifact management, and pipeline-as-code
- 🎯 ANALYZE loaded architecture and infrastructure documents, don't assume or generate requirements
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating pipeline architecture
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from step 1 are available
- Input documents already loaded are in memory (Architecture doc, Infrastructure plan, etc.)
- Focus on pipeline architectural decisions that support the infrastructure and deployment strategy
- Consider team expertise and operational maturity (`{bgr_maturity}`)

## YOUR TASK:

Collaboratively determine the CI/CD platform, branching strategy, runner/agent architecture, artifact management, and pipeline-as-code approach through structured discussion with the user.

## PIPELINE ARCHITECTURE SEQUENCE:

### 1. Discovery Phase — Current State Assessment

Before making any recommendations, understand the user's current CI/CD landscape:

**Questions to discuss:**

- "What CI/CD tooling are you using today, if any? How well is it working?"
- "How does your team currently build and deploy — manual, scripted, or automated?"
- "What's your source control setup? Mono-repo, multi-repo, or a mix?"
- "Are there existing pipeline definitions we should preserve or migrate?"
- "What are your biggest pain points with the current build and deploy process?"

**If infrastructure plan is loaded**, extract:
- Cloud provider(s) and deployment targets (Kubernetes, ECS, serverless, VMs)
- Environment topology (number of environments, promotion path)
- Container orchestration choice (`{container_orchestration}`)
- Networking and access patterns that affect runner placement

### 2. CI/CD Platform Selection

Evaluate and discuss CI/CD platform options with the user:

**Options to Consider:**

| Platform | Strengths | Considerations |
|----------|-----------|---------------|
| **GitHub Actions** | Native GitHub integration, marketplace, managed runners | GitHub lock-in, runner minute limits |
| **GitLab CI** | Built-in container registry, auto DevOps, integrated security | Self-hosted complexity, resource usage |
| **Jenkins** | Maximum flexibility, plugin ecosystem, mature | Maintenance burden, security patching, upgrade toil |
| **CircleCI** | Fast builds, strong caching, Docker-native | Cost at scale, limited self-hosted |
| **Azure DevOps** | Enterprise features, deep Azure integration | Microsoft ecosystem coupling |
| **Buildkite** | Hybrid model, self-hosted agents, horizontal scale | Smaller community, agent management |

**Maturity-Adaptive Recommendation:**

- **Greenfield:** GitHub Actions or GitLab CI — minimal setup, fast iteration, managed infrastructure
- **Growing:** GitHub Actions with reusable workflows or GitLab CI with shared templates — standardize patterns
- **Established:** Evaluate current platform against pain points — may stay or migrate with clear ROI
- **Advanced:** Multi-platform or self-hosted with advanced orchestration (Buildkite, Tekton, Argo Workflows)

**Selection Criteria to Discuss:**

- Team expertise and learning curve
- Cloud provider alignment (`{cloud_preference}`)
- Cost model: managed runners vs self-hosted at expected scale
- Ecosystem integrations: container registries, artifact stores, notification systems
- Security requirements: secret management, OIDC federation, network isolation
- Multi-platform needs: single platform vs specialized tools for different concerns

Present your recommendation based on loaded documents:

"Based on your architecture and infrastructure decisions, here's what I'm thinking for CI/CD platform:

**Recommended:** {{platform_recommendation}}
**Rationale:** {{why_this_fits}}

What's your team's experience with these tools? Any strong preferences or constraints?"

### 3. Branching Strategy and Pipeline Trigger Mapping

Define the branching model and how it maps to pipeline execution:

**Branching Models:**

| Model | Flow | Best For |
|-------|------|----------|
| **Trunk-based** | Short-lived feature branches → main | Mature teams, continuous deployment, feature flags |
| **GitHub Flow** | Feature branches + PRs → main | Most teams, simple and effective, PR-gated quality |
| **GitFlow** | develop/release/hotfix branches | Release-scheduled products, multiple supported versions |

**Trigger Mapping Table** (to build with user):

| Branch Pattern | Event | Pipeline Stages | Deploy Target |
|----------------|-------|----------------|---------------|
| `feature/*` | Push | Build + Unit Tests | — |
| `feature/*` → `main` | PR | Build + All Tests + Security Scan | Ephemeral preview |
| `main` | Merge | Full pipeline | Staging auto-deploy |
| `v*.*.*` (tag) | Tag push | Full pipeline + Sign | Production promotion |
| — | Schedule (nightly) | Full tests + Security + Performance | — |

Discuss with the user:
- "Which branching model fits your team's release cadence?"
- "Should PRs run the full test suite or just fast checks?"
- "Do you want automatic staging deploys on merge to main, or manual promotion?"

### 4. Runner/Agent Strategy

Define the compute strategy for pipeline execution:

**Key Decisions:**

- **Managed vs self-hosted** — Managed runners for simplicity; self-hosted for cost control, compliance, or network access to private resources
- **Runner sizing** — Match runner specs to job needs: standard runners for most jobs, larger runners for builds, compilation, and integration tests
- **Runner OS and architecture** — Linux x64 as default; ARM for cost savings on supported workloads; macOS/Windows for platform-specific builds

**Caching Strategy:**

| Cache Type | Scope | Invalidation | Impact |
|------------|-------|-------------|--------|
| Dependency cache | Per lock-file hash | Lock file change | Build speed (2-5x faster) |
| Build cache | Per branch + hash | Source change | Incremental builds |
| Docker layer cache | Per Dockerfile hash | Layer change | Image build speed |
| Test cache | Per test file hash | Test/source change | Test execution speed |

**Security Isolation:**

- Ephemeral runners for sensitive workloads (destroy after each job)
- Secret access scoping: which jobs can access which secrets
- Network segmentation: runners that need private network access vs public
- OIDC federation for cloud provider authentication (no long-lived credentials)

**Scaling:**

- Auto-scaling policies: min/max runners, scale-up triggers, cooldown periods
- Concurrency limits: max parallel jobs per workflow, per repo, per org
- Queue management: priority queues for production hotfixes vs feature builds

### 5. Artifact Management

Define artifact handling across the pipeline lifecycle:

**Container Registry:**

- Registry choice: cloud-native (ECR, GCR, ACR) vs platform (GHCR, GitLab) vs third-party (Docker Hub, Artifactory)
- Tagging strategy: `<branch>-<sha>` for development, semver for releases, `latest` policy
- Vulnerability scanning: scan on push, block deployment above severity threshold
- Image signing: Cosign/Notation for supply chain verification
- Retention: auto-delete untagged images after N days, keep tagged releases for M months

**Package Registry:**

- Language-specific registries (npm, PyPI, Maven, NuGet, Go modules)
- Private package hosting for internal libraries
- Version pinning and lock-file requirements

**Build Artifact Storage:**

- Test reports, coverage data, SBOM outputs
- Retention policies: PR artifacts (7 days), release artifacts (1 year), compliance artifacts (per policy)
- Artifact promotion: development → staging → production registries

### 6. Pipeline-as-Code Approach

Define how pipelines are authored, shared, and maintained:

**Key Decisions:**

- **Definition format:** YAML (GitHub Actions, GitLab CI) vs Groovy (Jenkins) vs programming language (Pulumi, Dagger)
- **Shared templates / reusable workflows:** Common patterns extracted to shared repository or organization templates
- **Versioning:** Pin shared workflow versions, controlled rollout of pipeline changes
- **Validation:** Pipeline linting (`actionlint`, `gitlab-ci-lint`), dry-run capability, schema validation
- **Documentation:** Pipeline architecture diagrams, onboarding guide for pipeline changes

**Maturity-Adaptive Guidance:**

- **Greenfield:** Single pipeline definition per repo, keep it simple
- **Growing:** Extract common patterns into reusable workflows, document conventions
- **Established:** Shared workflow library with versioning, automated pipeline validation in CI
- **Advanced:** Pipeline-as-code platform (Dagger, Earthly), automated pipeline testing, self-service templates

### 7. Generate Pipeline Architecture Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 2. Pipeline Architecture

### 2.1 Platform & Tooling

| Tool | Purpose | Version | Notes |
|------|---------|---------|-------|
| {{platform}} | {{purpose}} | {{version}} | {{notes}} |

**Selection Rationale:** {{rationale}}

### 2.2 Branching & Trigger Strategy

**Model:** {{branching_model}}

| Branch Pattern | Event | Pipeline Stages | Deploy Target |
|----------------|-------|----------------|---------------|
| {{branch}} | {{event}} | {{stages}} | {{target}} |

### 2.3 Runner Strategy

**Runner Type:** {{managed_or_self_hosted}}
**Security Model:** {{security_isolation}}
**Scaling:** {{scaling_approach}}

**Caching:**

| Cache Type | Scope | Invalidation |
|------------|-------|-------------|
| {{cache_type}} | {{scope}} | {{invalidation}} |

### 2.4 Artifact Management

**Container Registry:** {{registry_choice}}
**Tagging Strategy:** {{tagging_strategy}}
**Image Signing:** {{signing_approach}}
**Retention:** {{retention_policies}}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Pipeline Architecture based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this architecture and proceed to Pipeline Stages
[R] Revise - Let's adjust specific sections before continuing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Platform / Branching / Runners / Artifacts / Pipeline-as-Code)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/pipeline.md`
- Update frontmatter: `stepsCompleted: [1, 2]`
- Load `./step-03-pipeline-stages.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ CI/CD platform selected with rationale tied to team expertise and infrastructure
✅ Branching strategy defined with complete trigger-to-stage mapping
✅ Runner/agent strategy documented with caching, security, and scaling
✅ Artifact management fully defined with registries, tagging, and retention
✅ Pipeline-as-code approach documented with sharing and validation strategy
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Selecting a platform without considering team expertise or cloud alignment
❌ Not defining branch-to-pipeline trigger mapping
❌ Missing caching strategy (results in slow, expensive pipelines)
❌ Not addressing artifact retention and cleanup
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-03-pipeline-stages.md` to define end-to-end pipeline stages with testing, security scanning, and quality gates.

Remember: Do NOT proceed to step-03 until user explicitly selects [C] from the menu and content is saved!
