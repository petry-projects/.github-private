# Step 4: Container & Orchestration Strategy

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between infrastructure peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on container runtime, orchestration, image strategy, security, and service mesh
- 🎯 BUILD ON the environment and IaC decisions from steps 2-3
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- ⚠️ Present [C]ontinue / [R]evise menu after generating container strategy
- 💾 ONLY save when user chooses C (Continue)
- 📖 Update frontmatter `stepsCompleted: [1, 2, 3, 4]` before loading next step
- 🚫 FORBIDDEN to load next step until C is selected

## CONTEXT BOUNDARIES:

- Current document with IaC and environment strategy from steps 2-3 is available
- Input documents already loaded are in memory
- Focus on container decisions that align with environment topology and IaC choices
- Container strategy may be explicitly deferred if not applicable

## YOUR TASK:

Collaboratively determine the container runtime, orchestration approach, image strategy, security posture, and service mesh evaluation through structured discussion with the user.

## CONTAINER STRATEGY SEQUENCE:

### 1. Container Runtime Evaluation

First, determine if containers are appropriate for this project:

**Options to Evaluate:**

- **Kubernetes (EKS/GKE/AKS)** — Full orchestration, complex but powerful, ecosystem-rich
- **ECS/Fargate** — AWS-native, simpler than K8s, serverless option with Fargate
- **Cloud Run / App Runner** — Serverless containers, minimal infrastructure management
- **Docker Compose** — Simple multi-container, suitable for small deployments
- **No Containers** — VMs, serverless functions, PaaS — containers may not be needed

**Key Questions to Discuss:**

- Does your architecture require container orchestration?
- What's your team's container/Kubernetes experience level?
- How many services need to be orchestrated?
- What are your scaling requirements (burst, steady, predictable)?
- Is there an existing container platform to integrate with?

Present your recommendation:

"Based on your architecture and environment strategy, here's my thinking on container orchestration:

**Recommended:** {{runtime_recommendation}}
**Rationale:** {{why_this_fits}}

If containers aren't needed for your use case, we can explicitly defer this section and move on. What's your preference?"

### 2. Kubernetes Architecture (If Kubernetes Selected)

If Kubernetes is chosen, define the cluster topology:

**Cluster Topology:**

- **Managed vs Self-Managed:** EKS/GKE/AKS vs kubeadm/k3s/RKE
- **Cluster Per Environment:** Separate clusters vs shared cluster with namespace isolation
- **Multi-Tenancy:** Namespace isolation, network policies, resource quotas
- **Node Pools:** System nodes, application nodes, GPU nodes, spot node pools
- **Autoscaling:** Cluster Autoscaler, Karpenter, node auto-provisioning

**Namespace Strategy:**

- Namespace per team, per service, per environment, or hybrid
- Default resource quotas and limit ranges
- Network policy defaults (deny-all baseline)

**Resource Management:**

- CPU/memory requests and limits strategy
- Priority classes for critical workloads
- Pod disruption budgets
- Horizontal and vertical pod autoscaling

### 3. Serverless Container Configuration (If Serverless Selected)

If serverless containers are chosen:

**Service Configuration:**

- Concurrency limits and scaling parameters
- Memory and CPU allocation
- Cold start mitigation (minimum instances, pre-warming)
- Timeout configuration
- VPC connectivity requirements

### 4. Container Image Strategy

Define the image lifecycle:

**Key Decisions:**

- **Base Images:** Approved base images, distroless vs Alpine vs Debian-slim
- **Multi-Stage Builds:** Build pattern standards, layer optimization
- **Image Scanning:** Vulnerability scanning tool (Trivy, Snyk, Prisma), scan timing (build, push, runtime)
- **Registry:** ECR, GCR, ACR, Docker Hub, private (Harbor, Artifactory)
- **Tagging Strategy:** Semantic versioning, Git SHA, environment-based tags
- **Image Retention:** Cleanup policies, untagged image expiration

### 5. Container Security

Define the security posture for containers:

**Key Decisions:**

- **Image Signing:** Cosign/Notary for supply chain security, admission control
- **Runtime Security:** Falco, Sysdig, runtime threat detection
- **Pod Security Standards:** Restricted, Baseline, or Privileged profiles
- **RBAC:** Role definitions, service accounts, least-privilege principles
- **Secrets in Containers:** Mounted secrets, env vars, CSI driver, sidecar injection
- **Network Policies:** Default deny, explicit allow rules, service-to-service policies

### 6. Service Mesh Evaluation

Evaluate whether a service mesh is warranted:

**Options:**

- **Istio** — Feature-rich, mTLS, traffic management, observability, complex
- **Linkerd** — Lightweight, simple, fast, Rust-based data plane
- **Cilium** — eBPF-based, network policy + service mesh, high performance
- **No Service Mesh** — Simpler architecture, application-level TLS, manual traffic management

**Assessment Criteria:**

- Do you need mTLS between all services?
- Do you need advanced traffic management (canary, mirroring, fault injection)?
- How many services will communicate?
- Is the operational complexity of a service mesh justified?
- Can observability needs be met without a mesh?

"Service mesh adds significant value for mTLS and traffic management but also adds operational complexity. Based on your {{service_count}} services, here's my assessment:

**Recommendation:** {{mesh_recommendation}}
**Rationale:** {{complexity_vs_value_assessment}}"

### 7. Generate Container Strategy Content

Prepare the content to append to the document:

#### Content Structure:

```markdown
## 5. Container Strategy

### 5.1 Runtime Selection

**Runtime:** {{selected_runtime}}
**Rationale:** {{selection_rationale}}

{if_no_containers}
**Note:** Container orchestration has been explicitly deferred for this project. Rationale: {{deferral_reason}}
{/if_no_containers}

### 5.2 Cluster Architecture

{if_kubernetes}
**Cluster Topology:**
| Cluster | Environment | Node Pools | Autoscaling | Notes |
|---------|-------------|------------|-------------|-------|
| {{cluster}} | {{env}} | {{pools}} | {{autoscaling}} | {{notes}} |

**Namespace Strategy:** {{namespace_approach}}
**Resource Quotas:** {{quota_strategy}}
**Network Policies:** {{network_policy_defaults}}
{/if_kubernetes}

{if_serverless}
**Service Configuration:**
{{serverless_config_details}}

**Scaling Parameters:**
{{scaling_config}}

**Cold Start Mitigation:**
{{cold_start_strategy}}
{/if_serverless}

### 5.3 Image Strategy

**Base Images:** {{approved_base_images}}
**Build Pattern:** {{multi_stage_build_standard}}
**Scanning:** {{vulnerability_scanning_tool_and_timing}}
**Registry:** {{registry_choice}}
**Tagging:** {{tagging_strategy}}
**Retention:** {{image_retention_policy}}

### 5.4 Security

**Image Signing:** {{signing_approach}}
**Runtime Security:** {{runtime_security_tool}}
**Pod Security:** {{pod_security_standard}}
**RBAC:** {{rbac_strategy}}
**Network Policies:** {{network_policy_approach}}

### 5.5 Service Mesh

**Decision:** {{mesh_decision}}
**Rationale:** {{mesh_rationale}}
{if_mesh_selected}
**Tool:** {{mesh_tool}}
**Configuration:** {{mesh_config_details}}
{/if_mesh_selected}
```

### 8. Present Content and Menu

Show the generated content and present choices:

"I've drafted the Container & Orchestration Strategy based on our discussion.

**Here's what I'll add to the document:**

[Show the complete markdown content from step 7]

**What would you like to do?**
[C] Continue - Save this strategy and proceed to Validation
[R] Revise - Let's adjust specific sections before continuing"

### 9. Handle Menu Selection

#### If 'R' (Revise):

- Ask: "Which section would you like to revise? (Runtime Selection / Cluster Architecture / Image Strategy / Security / Service Mesh)"
- Discuss the specific section with the user
- Update the content based on feedback
- Return to [C] / [R] menu

#### If 'C' (Continue):

- Append the final content to `{bgr_artifacts}/infrastructure.md`
- Update frontmatter: `stepsCompleted: [1, 2, 3, 4]`
- Load `./step-05-validation.md`

## APPEND TO DOCUMENT:

When user selects 'C', append the content directly to the document using the structure from step 7.

## SUCCESS METRICS:

✅ Container runtime evaluated and selected (or explicitly deferred)
✅ Cluster architecture defined if Kubernetes chosen
✅ Image strategy documented with scanning and retention
✅ Container security posture defined with RBAC and policies
✅ Service mesh evaluated with clear complexity-vs-value assessment
✅ User confirmed all decisions through discussion
✅ Content properly appended to document when C selected

## FAILURE MODES:

❌ Assuming containers are required without evaluating alternatives
❌ Not evaluating service mesh complexity vs value
❌ Missing container security strategy
❌ Not defining image scanning and retention policies
❌ Generating content without real discussion with user
❌ Not presenting [C] / [R] menu after content generation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] and content is saved to document, load `./step-05-validation.md` to validate and finalize the infrastructure plan.

Remember: Do NOT proceed to step-05 until user explicitly selects [C] from the menu and content is saved!
