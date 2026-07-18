# Step 4: Deployment Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between DevOps peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on deployment patterns, rollback strategy, database migrations, feature flags, GitOps, and zero-downtime
- 🎯 ANALYZE loaded architecture, infrastructure, and incident response documents — don't assume requirements
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating deployment strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document and frontmatter from steps 1-3 are available
- Pipeline architecture and stage definitions from steps 2-3 are in the document
- Input documents already loaded are in memory
- Focus on deployment decisions that complete the pipeline end-to-end
- Consider infrastructure topology and container orchestration choice (`{container_orchestration}`)

## YOUR TASK:

Collaboratively define deployment models per service, rollback strategy, database migration approach, feature flag integration, GitOps patterns, zero-downtime requirements, and release management through structured discussion with the user.

## DEPLOYMENT STRATEGY SEQUENCE:

### 1. Discovery Phase — Deployment Context

Before making recommendations, understand the user's deployment landscape:

**Questions to discuss:**

- "How do you deploy today? Manual, scripted, or automated? What triggers a deploy?"
- "How do you handle rollbacks currently? How long does a rollback take?"
- "Do you have database migrations as part of deployments? How are they managed?"
- "Are you using feature flags? If so, which platform?"
- "What's your zero-downtime requirement? Can you tolerate brief interruptions during deploys?"
- "Do you have multiple services with different deployment needs, or a single deployable?"

**If infrastructure plan is loaded**, extract:
- Deployment targets: Kubernetes, ECS, serverless, VMs, or hybrid
- Environment topology: dev → staging → production (or more complex)
- Container orchestration: native deployment primitives (K8s Deployments, ECS Services)
- Network architecture: load balancers, service mesh, DNS-based routing

**If incident response plan is loaded**, extract:
- Deployment-triggered incident escalation paths
- Rollback authorization: who can trigger, under what conditions
- Communication protocols during failed deployments

### 2. Deployment Pattern Selection

For each service or service group, select and configure a deployment model:

| Strategy | How It Works | Best For | Trade-offs |
|----------|-------------|----------|------------|
| **Rolling** | Replace instances incrementally (maxUnavailable/maxSurge) | Stateless services, most workloads | Gradual rollout; mixed versions during deploy; lower resource cost |
| **Blue-Green** | Run two identical environments, switch traffic atomically | Zero-downtime with instant rollback | 2x resource cost during deployment; database compatibility required |
| **Canary** | Route small % of traffic to new version, validate, expand | Progressive validation, risk-sensitive services | Requires traffic splitting; slower rollout; metric analysis needed |
| **Recreate** | Stop old, start new | Dev environments, batch jobs, single-instance services | Brief downtime; simplest model |
| **Feature Flags** | Deploy code dark, enable via runtime toggle | Decoupling deploy from release; A/B testing; gradual rollout | Requires flag management platform; flag cleanup discipline |

**Per-Service Configuration** (build this table with user):

| Service | Strategy | Traffic Steps | Validation Window | Rollback Trigger |
|---------|----------|--------------|-------------------|-----------------|
| {{service}} | {{strategy}} | {{steps}} | {{window}} | {{trigger}} |

**Maturity-Adaptive Deployment Guidance:**

- **Greenfield:** Rolling deployments — simple, built into every orchestrator. Add health checks
- **Growing:** Canary for critical services, rolling for the rest. Introduce automated rollback
- **Established:** Canary with metric-based promotion. Blue-green for databases. Feature flags for major changes
- **Advanced:** Progressive delivery with Argo Rollouts/Flagger. Automated canary analysis. Multi-region rollout

### 3. Rollback Strategy

Define comprehensive rollback procedures:

**Automated Rollback Triggers:**

| Trigger | Threshold | Action | Monitoring Source |
|---------|-----------|--------|------------------|
| Error rate spike | > {{threshold}}% above baseline | Auto-rollback | Observability platform |
| Latency degradation | p99 > {{threshold}}ms | Auto-rollback | APM / metrics |
| Health check failure | > {{count}} consecutive failures | Auto-rollback | Orchestrator health checks |
| SLO breach | Error budget burn rate > {{threshold}}x | Alert + manual decision | SLO dashboard |
| Crash loop | > {{count}} restarts in {{window}} | Auto-rollback | Orchestrator events |

**Manual Rollback Procedure:**

1. **Detection:** Who notices, how they're alerted
2. **Decision:** Who authorizes rollback, criteria for deciding
3. **Execution:** Step-by-step rollback process (re-deploy previous image tag, revert traffic routing)
4. **Verification:** Confirm rollback success — health checks pass, error rate returns to baseline
5. **Communication:** Notify team, update status page, open incident if needed

**Rollback Testing:**

- Schedule regular rollback drills (quarterly or per release train)
- Verify rollback procedure works with current database state
- Measure rollback time — target: under {{rollback_target}} minutes

### 4. Database Migration Strategy

Define how database changes are managed alongside application deployments:

**Migration Approach:**

| Approach | Description | When to Use |
|----------|-------------|-------------|
| **Expand-Contract** | Add new → migrate data → remove old | Breaking schema changes, column renames |
| **Forward-only** | All migrations move forward; undo via compensating migrations | Simple additions, non-breaking changes |
| **Blue-green DB** | Replicate to new schema, cut over | Major schema overhauls (rare) |

**Safety Rules:**

- Schema changes MUST be backward-compatible with both old and new application versions (during rolling deploy window)
- **Never drop columns** in the same deploy that removes the code reading them — separate deploys
- Run migrations BEFORE application deployment (expand phase)
- Remove old columns in a SUBSEQUENT deploy after all instances are on new code (contract phase)
- Migration dry-run: test against a copy of production data before executing

**Migration Execution:**

- **Pre-deploy:** Run forward migrations as a pipeline stage before app deployment
- **Verification:** Row count validation, constraint checks, query plan analysis
- **Large migrations:** Online schema change tools appropriate to your database engine for tables exceeding safe direct-DDL thresholds
- **Migration timeout:** Set per-migration timeouts; if exceeded, investigate before retrying (migrations may not be idempotent)
- **Rollback plan:** Compensating migration ready before executing, tested in staging

### 5. Feature Flag Integration

Define how feature flags support deployment strategy:

**Feature Flag Architecture:**

- **Platform:** LaunchDarkly, Unleash, Flipt, Flagsmith, or application-native
- **Flag types:** Release (deploy/release decoupling), Experiment (A/B), Ops (kill switch), Permission (gradual access)
- **Targeting:** Percentage rollout, user segment targeting, environment-specific flags

**Flag Lifecycle Management:**

| Phase | Action | Owner |
|-------|--------|-------|
| Create | Define flag with description, default value, planned removal date | Developer |
| Rollout | Progressive percentage increase with metric monitoring | Developer + SRE |
| Full release | 100% enabled, begin cleanup timer | Developer |
| Cleanup | Remove flag from code, delete from platform | Developer |
| Audit | Verify no stale flags older than {{max_age}} days | Automated scan |

**Maturity-Adaptive Guidance:**

- **Greenfield:** Environment variables or config-based flags. Simple on/off per environment
- **Growing:** Introduce a flag platform. Use for major features. Enforce cleanup
- **Established:** Percentage rollout with metric correlation. Experiment flags for A/B testing
- **Advanced:** Multi-variate flags, audience targeting, automated flag impact analysis

### 6. Deployment Automation and GitOps

Define how deployments are triggered and managed:

**GitOps Model:**

| Model | Description | Best For |
|-------|-------------|----------|
| **Push-based** | CI pipeline pushes changes to deployment target | Simpler setup, traditional CI/CD, serverless |
| **Pull-based** | Agent in cluster watches Git repo, syncs state (ArgoCD, Flux) | Kubernetes, declarative infrastructure, strong audit trail |
| **Hybrid** | CI builds + pushes artifacts; GitOps agent deploys from manifest repo | Best of both — CI handles build, GitOps handles deploy |

**Key Decisions:**

- **Manifest management:** Kustomize overlays, Helm charts, raw YAML, or Jsonnet
- **Environment promotion:** PR-based promotion (merge to env branch) vs automated promotion with gates
- **Drift detection:** How to detect and reconcile manual changes to deployed state
- **Secrets management:** Sealed Secrets, External Secrets Operator, Vault, or SOPS — never plain text in Git

### 7. Zero-Downtime Deployment Requirements

Define requirements for maintaining availability during deployments:

**Connection Handling:**

- **Connection draining:** Graceful handling of in-flight requests — drain period before termination
- **Graceful shutdown:** SIGTERM handling with configurable timeout (default: {{shutdown_timeout}} seconds)
- **In-flight request completion:** Long-running requests finish before pod/instance is removed

**Health Check Timing:**

| Probe Type | Purpose | Initial Delay | Period | Failure Threshold |
|------------|---------|---------------|--------|-------------------|
| **Startup** | Slow-starting apps | {{delay}} | {{period}} | {{threshold}} |
| **Readiness** | Accept traffic? | {{delay}} | {{period}} | {{threshold}} |
| **Liveness** | Restart needed? | {{delay}} | {{period}} | {{threshold}} |

**Dependency Readiness:**

- Cache warming: pre-populate hot caches before accepting traffic
- Connection pool establishment: database, Redis, message broker connections ready
- Downstream dependency health: verify critical dependencies are reachable

**Session Handling:**

- Stateless design (preferred): no session affinity needed
- If stateful: session migration strategy, sticky session configuration, or external session store

### 8. Post-Deployment Verification and Monitoring

Define the monitoring window after deployment completes:

- **Monitoring window duration:** {{monitoring_window}} minutes of heightened observation
- **Key metrics to watch:** Error rate, latency (p50/p95/p99), throughput, saturation
- **If observability plan is loaded:** Use defined SLO metrics as deployment health indicators
- **Alerting during deploy:** Tighter alert thresholds during monitoring window
- **Deployment status dashboard:** Real-time view of deployment progress, health signals, rollback status

### 9. Release Management

Define the release management process:

- **Versioning scheme:** Semantic versioning (major.minor.patch), CalVer, or custom
- **Changelog generation:** Automated from conventional commits, PR titles, or commit messages
- **Release notes:** Auto-generated with manual summary; audience-appropriate (technical vs user-facing)
- **Release approval:** Who approves production releases, what criteria, emergency release process
- **Release cadence:** Continuous deployment, scheduled releases, or train-based (weekly/biweekly)

### 10. Generate Deployment Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 4. Deployment Strategy

### 4.1 Deployment Model per Service

| Service | Strategy | Rollback | Health Check | Notes |
|---------|----------|----------|-------------|-------|
| {{service}} | {{strategy}} | {{rollback}} | {{health_check}} | {{notes}} |

### 4.2 Rollback Procedures

**Automated Triggers:**

| Trigger | Threshold | Action |
|---------|-----------|--------|
| {{trigger}} | {{threshold}} | {{action}} |

**Manual Rollback Procedure:** {{procedure_summary}}
**Rollback Target:** Under {{rollback_target}} minutes

### 4.3 Database Migrations

**Approach:** {{migration_approach}}
**Safety Rule:** Backward-compatible schemas required during deploy window
**Large Migrations:** {{large_migration_strategy}}

### 4.4 Zero-Downtime Requirements

**Graceful Shutdown Timeout:** {{shutdown_timeout}} seconds
**Health Check Configuration:** Startup / Readiness / Liveness probes configured
**Session Handling:** {{session_strategy}}
**Feature Flags:** {{flag_platform}} — {{flag_types_used}}

## 5. Release Management

### 5.1 Versioning

{{versioning_scheme}}

### 5.2 Changelog & Release Notes

{{changelog_approach}}

### 5.3 Release Approval Process

{{approval_process}}
```

### 11. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Deployment Strategy and Release Management based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 10]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to Validation
[R] Revise - Let's adjust specific sections before continuing"

### 12. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Deployment Models / Rollback / Database Migrations / Feature Flags / GitOps / Zero-Downtime / Release Management)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/pipeline.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 10.

## SUCCESS METRICS:

✅ Deployment model selected per service with clear rationale
✅ Rollback strategy defined with automated triggers and manual procedures
✅ Database migration strategy documented with safety rules and expand-contract pattern
✅ Feature flag integration defined with lifecycle management and cleanup policy
✅ GitOps/deployment automation approach documented
✅ Zero-downtime requirements fully specified (probes, draining, graceful shutdown)
✅ Release management process defined with versioning and approval
✅ Cross-workflow context loaded from infrastructure and incident response plans
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Selecting deployment strategies without considering infrastructure topology
❌ Missing rollback strategy or treating it as an afterthought
❌ Not addressing database migration safety (leads to production outages)
❌ Ignoring feature flag cleanup (leads to flag debt and complexity)
❌ Not defining zero-downtime requirements (leads to user-facing interruptions)
❌ Not loading cross-workflow context from infrastructure and incident response plans
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-05-validation.md` for quality gate validation and production readiness checklist update.

Remember: Do NOT proceed to step-05 until user explicitly selects [C] from the menu and content is saved!
