# Step 1: Cost Optimization Plan Workflow Initialization

## MANDATORY EXECUTION RULES (READ FIRST):

- NEVER generate content without user input
- CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ALWAYS treat this as collaborative discovery between infrastructure peers
- YOU ARE A FACILITATOR, not a content generator
- FOCUS on initialization and setup only - don't look ahead to future steps
- DETECT existing workflow state and handle continuation properly
- Do not estimate software delivery timelines or task durations — but do define operational timing (budget review cadence, anomaly detection windows, reserved instance evaluation schedules) as these are core cost optimization plan outputs
- YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- Share a concise rationale (assumptions, key trade-offs, and decisions) before taking any action
- Initialize document and update frontmatter
- Set up frontmatter `stepsCompleted: [1]` before loading next step
- FORBIDDEN to load next step until setup is complete

## CONTEXT BOUNDARIES:

- Variables from workflow.md are available in memory
- Previous context = what's in output document + frontmatter
- Don't assume knowledge from other steps
- Input document discovery happens in this step

## YOUR TASK:

Initialize the Cost Optimization Plan workflow by detecting continuation state, discovering input documents, and setting up the document for collaborative FinOps planning.

## INITIALIZATION SEQUENCE:

### 1. Check for Existing Workflow

First, check if the output document already exists:

- Look for existing `{bgr_artifacts}/cost-optimization-plan.md` (canonical path first)
- If not found, fall back to `{bgr_artifacts}/*cost-optim*.md` glob
- If multiple files match, STOP and ask the user which file to resume from (or whether to start fresh)
- If a match is found, read the selected file completely including frontmatter
- If no match is found, this is a fresh workflow

<critical>
**FILE OVERWRITE PROTECTION:** If an existing cost optimization plan is found, you MUST NOT overwrite it without explicit user confirmation. Always present the existing file and ask whether to resume, start fresh (with confirmation), or abort.
</critical>

### 2. Handle Continuation (If Document Exists)

If the document found above exists and has frontmatter with `stepsCompleted`:

- **STOP here** and load `./step-01b-continue.md` immediately
- Do not proceed with any initialization tasks
- Let step-01b handle the continuation logic

### 3. Check Production Readiness Checklist

Look for `{bgr_artifacts}/production-readiness-checklist.md`:

- If it exists, read it as-is to understand which other workflows have been completed
- Note any completed workflow plans — their key decisions and cross-references will be loaded in the discovery phase
- If it does not exist, create `{bgr_artifacts}/production-readiness-checklist.md` using the following initial content:

  ```md
  ---
  lastUpdated: {{current_date}}
  completedWorkflows: []
  ---

  # Production Readiness Checklist

  ## Overview

  Last updated: {{current_date}}

  ## Workflow Completion Status

  | Workflow | Status | Completion Date | Output Document |
  |----------|--------|-----------------|-----------------|
  | Observability | Not Started | | |
  | Incident Response | Not Started | | |
  | Infrastructure | Not Started | | |
  | Pipeline | Not Started | | |
  | Capacity Planning | Not Started | | |
  | Cost Optimization | Not Started | | |

  ## Workflow Details

  ### Observability

  - **Status:** Not Started

  ### Incident Response

  - **Status:** Not Started

  ### Infrastructure

  - **Status:** Not Started

  ### Pipeline

  - **Status:** Not Started

  ### Capacity Planning

  - **Status:** Not Started

  ### Cost Optimization

  - **Status:** Not Started

  ### 4.3 Consistency Issues

  No cross-plan consistency issues identified yet.
  ```

### 4. Load Context from Completed Workflow Artifacts

Check `{bgr_artifacts}/` for previously completed BGreat workflow outputs:

- `*infrastructure*.md` — If completed, load environment topology, cloud provider choices, compute resources, and instance types to inform right-sizing recommendations and reserved instance strategy
- `*observability*.md` — If completed, load SLO targets, metrics taxonomy, and alerting thresholds to inform cost-aware SLO trade-offs and anomaly detection alignment
- `*capacity*.md` — If completed, load growth projections, scaling policies, reserved capacity commitments, and cost guardrails to align cost optimization with capacity strategy
- `*pipeline*.md` — If completed, load deployment strategy and environment configurations to identify CI/CD cost optimization opportunities
- `*incident-response*.md` — If completed, load severity classification to align cost anomaly severity with incident response procedures
- `*disaster-recovery*.md` — If completed, load RTO/RPO targets and failover topology to ensure cost optimization does not compromise DR readiness

For each completed plan found:
- Load the document and extract key decisions relevant to cost optimization
- Surface these as context during the workflow (e.g., "The Capacity Plan specifies reserved instances for baseline workloads — this informs our reservation coverage analysis and right-sizing recommendations")
- Track loaded plans in frontmatter `crossWorkflowContext` array. If this workflow already has an entry in `crossWorkflowContext`, update it rather than adding a duplicate (upsert semantics).

### 5. Fresh Workflow Setup (If No Document)

If no document exists or no `stepsCompleted` in frontmatter:

#### A. Input Document Discovery

Discover and load context documents using smart discovery. Documents can be in the following locations:
- {bgr_artifacts}/**
- {project_knowledge}/**
- {project-root}/docs/**

Discovery order for each document type: try the exact path in `{bgr_artifacts}/` first (e.g., `{bgr_artifacts}/architecture.md`), then fall back to a glob pattern (e.g., `*architecture*.md`) across the search locations, then check for a sharded folder (e.g., `*architecture*/index.md` which indicates sharded content across multiple files).

Try to discover the following:
- Architecture Document (`*architecture*.md`) — **REQUIRED**
- Infrastructure Document (`*infrastructure*.md`) — **STRONGLY RECOMMENDED**
- Capacity Plan (`*capacity*.md`)
- Observability Plan (`*observability*.md`)
- Product Requirements Document (`*prd*.md`)
- Project Context (`**/project-context.md`)

<critical>Confirm what you have found with the user, along with asking if the user wants to provide anything else. Only after this confirmation will you proceed to follow the loading rules</critical>

**Loading Rules:**

- Load ALL discovered files completely that the user confirmed or provided (no offset/limit)
- If there is a project context, whatever is relevant should try to be biased in the remainder of this whole workflow process
- For sharded folders, load ALL files to get complete picture, using the index first to potentially know the potential of each document
- index.md is a guide to what's relevant whenever available
- Track all successfully loaded files in frontmatter `inputDocuments` array

#### B. Validate Required Inputs

Before proceeding, verify we have the essential inputs:

**Architecture Validation:**

- If no Architecture document found: "Cost optimization planning requires understanding the system architecture to identify resource usage patterns and optimization opportunities. Please run the architecture workflow first or provide the architecture document path."
- Do NOT proceed without an Architecture document

**Infrastructure Validation:**

- If no Infrastructure document found: "An infrastructure plan is strongly recommended for cost optimization. It defines compute resources, instance types, and environment topology that directly inform right-sizing and reservation strategies. You can create one with the `bgr-3-create-infrastructure` workflow."
- Allow proceeding without it, but note the gap

**Capacity Plan Validation:**

- If no Capacity Plan found: "A capacity plan provides growth projections and scaling policies that inform reserved instance commitments and cost forecasting. Consider creating one with the `bgr-3-create-capacity-plan` workflow."
- Allow proceeding without it, but note the gap

**Other Input that might exist:**

- Observability Plan: "Provides SLO targets and metrics that inform cost-aware SLO trade-offs and cost anomaly detection"
- PRD: "Provides business context, expected growth, and budget constraints"

#### C. Create Initial Document

<critical>
**FILE OVERWRITE PROTECTION:** Before creating the document, perform a final check that `{bgr_artifacts}/cost-optimization-plan.md` does not already exist. If it does, STOP and ask the user for confirmation before overwriting.
</critical>

Copy the template from `../templates/cost-optimization-plan-template.md` to `{bgr_artifacts}/cost-optimization-plan.md`

Immediately update frontmatter in `{bgr_artifacts}/cost-optimization-plan.md`:
- Set `stepsCompleted: [1]`
- Set `lastUpdated: {{current_date}}`

#### D. Complete Initialization and Report

Complete setup and report to user:

**Document Setup:**

- Created: `{bgr_artifacts}/cost-optimization-plan.md` from template
- Initialized frontmatter with workflow state

**Input Documents Discovered:**
Report what was found:
"Welcome {{user_name}}! I've set up your Cost Optimization Plan workspace.

**Documents Found:**

- Architecture: {architecture files loaded or "None found - REQUIRED"}
- Infrastructure: {infrastructure files loaded or "None found - strongly recommended"}
- Capacity Plan: {capacity files loaded or "None found - recommended"}
- Observability: {observability files loaded or "None found"}
- PRD: {PRD files loaded or "None found"}
- Project context: {project_context_rules_count or "None found"}

**Files loaded:** {list of specific file names or "No additional documents found"}

Ready to begin cost optimization planning. Do you have any other documents you'd like me to include?

[C] Continue to cost baseline analysis
[R] Revise — adjust initialization or provide missing documents

## SUCCESS METRICS:

✅ Existing workflow detected and handed off to step-01b correctly
✅ Fresh workflow initialized with template and frontmatter
✅ Input documents discovered using exact-path-first, then glob fallback, then sharded folder check
✅ All discovered files tracked in frontmatter `inputDocuments`
✅ Architecture requirement validated and communicated
✅ Infrastructure recommendation communicated
✅ Capacity plan recommendation communicated
✅ User confirmed document setup and can proceed
✅ Production readiness checklist loaded if present, or created with initial structure if absent
✅ Previously completed workflow artifacts discovered and context loaded
✅ File overwrite protection enforced — no silent overwrites

## FAILURE MODES:

❌ Proceeding with fresh initialization when existing workflow exists
❌ Not updating frontmatter with discovered input documents
❌ Creating document without proper template
❌ Not following the discovery order: exact path first, then glob fallback, then sharded folder check
❌ Not reporting what documents were found to user
❌ Proceeding without validating Architecture requirement
❌ Overwriting an existing cost optimization plan without user confirmation

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, only after ensuring all the template output has been created, then load `./step-02-cost-baseline.md` to establish the current cost baseline and resource inventory.

Remember: Do NOT proceed to step-02 until user explicitly selects [C] from the menu and setup is confirmed!
