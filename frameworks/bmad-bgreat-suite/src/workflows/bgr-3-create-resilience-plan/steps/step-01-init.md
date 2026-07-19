# Step 1: Resilience Testing Plan Workflow Initialization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between reliability peers
- 📋 YOU ARE A FACILITATOR, not a content generator
- 💬 FOCUS on initialization and setup only - don't look ahead to future steps
- 🚪 DETECT existing workflow state and handle continuation properly
- ⚠️ ABSOLUTELY NO TIME ESTIMATES - AI development speed has fundamentally changed
- ✅ YOU MUST ALWAYS SPEAK OUTPUT In your Agent communication style with the config `{communication_language}`

## EXECUTION PROTOCOLS:

- 🎯 Show your analysis before taking any action
- 💾 Initialize document and update frontmatter
- 📖 Set up frontmatter `stepsCompleted: [1]` before loading next step
- 🚫 FORBIDDEN to load next step until setup is complete

## CONTEXT BOUNDARIES:

- Variables from workflow.md are available in memory
- Previous context = what's in output document + frontmatter
- Don't assume knowledge from other steps
- Input document discovery happens in this step

## YOUR TASK:

Initialize the Resilience Testing Plan workflow by detecting continuation state, discovering input documents, and setting up the document for collaborative resilience planning.

## INITIALIZATION SEQUENCE:

### 1. Check for Existing Workflow

First, check if the output document already exists:

- Look for existing {bgr_artifacts}/`*resilience*`
- If exists, read the complete file(s) including frontmatter
- If not exists, this is a fresh workflow

### 2. Check Production Readiness Checklist

Look for `{bgr_artifacts}/production-readiness-checklist.md`:

- If it exists, read it to understand which other workflows have been completed
- Note any completed workflow plans — their key decisions and cross-references will be loaded in the discovery phase
- If it does not exist, create it from the shared template at `../../../templates/bgr-production-readiness-checklist-template.md` and save to `{bgr_artifacts}/production-readiness-checklist.md`

### 3. Load Context from Completed Workflow Artifacts

Check `{bgr_artifacts}/` for previously completed BGreat workflow outputs:

- `*observability*.md` — If completed, note SLO targets, metrics definitions, and alerting thresholds that resilience testing should validate
- `*incident-response*.md` — If completed, note severity classification and runbook procedures that game days should exercise
- `*infrastructure*.md` — If completed, note environment topology and failure domains for experiment design
- `*pipeline*.md` — If completed, note rollback mechanisms, canary strategy, and deployment gates that experiments should validate

For each completed plan found:
- Load the document and extract key decisions relevant to resilience planning
- Surface these as context during the workflow (e.g., "The Observability Plan defines SLOs for the checkout service — these become steady-state hypotheses for chaos experiments")
- Track loaded plans in frontmatter `crossWorkflowContext` array. Each entry should include a `workflow` field identifying the source (e.g., 'observability', 'infrastructure', 'incident-response'). Before adding an entry, check if `crossWorkflowContext` already contains an entry with the same `workflow` field value -- if found, update it with the latest decisions; if not found, append a new entry (upsert by `workflow` field).

### 4. Handle Continuation (If Document Exists)

If the document from step 1 exists and has frontmatter with `stepsCompleted`:

- **STOP here** and load `./step-01b-continue.md` immediately
- Do not proceed with any initialization tasks
- Let step-01b handle the continuation logic

### 5. Fresh Workflow Setup (If No Document)

If no document exists or no `stepsCompleted` in frontmatter:

#### A. Input Document Discovery

Discover and load context documents using smart discovery. Documents can be in the following locations:
- {bgr_artifacts}/**
- {project_knowledge}/**
- {project-root}/docs/**

Also - when searching - documents can be a single markdown file, or a folder with an index and multiple files. For example, if searching for `*foo*.md` and not found, also search for a folder called *foo*/index.md (which indicates sharded content)

Try to discover the following:
- Architecture Document (`*architecture*.md`) — **REQUIRED**
- Observability Plan (`*observability*.md`) — Recommended
- Incident Response Plan (`*incident-response*.md`) — Recommended
- Infrastructure Plan (`*infrastructure*.md`) — Recommended
- Pipeline Plan (`*pipeline*.md`) — Recommended

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

- If no Architecture document found: "Resilience testing requires architecture decisions to identify failure domains. Please run the architecture workflow first."
- Do NOT proceed without an Architecture document

**Other Input that might exist:**

- Observability Plan: "Provides SLO targets and metrics for steady-state hypothesis definition"
- Incident Response Plan: "Provides severity classification and runbooks for game day exercise design"
- Infrastructure Plan: "Provides environment topology for failure scenario mapping"

#### C. Create Initial Document

Copy the template from `../templates/resilience-plan-template.md` to `{bgr_artifacts}/resilience-plan.md`

#### D. Complete Initialization and Report

Complete setup and report to user:

**Document Setup:**

- Created: `{bgr_artifacts}/resilience-plan.md` from template
- Initialized frontmatter with workflow state

**Input Documents Discovered:**
Report what was found:
"Welcome {{user_name}}! I've set up your Resilience Testing Plan workspace for {{project_name}}.

**Documents Found:**

- Architecture: {number of architecture files loaded or "None found - REQUIRED"}
- Observability Plan: {number of observability files loaded or "None found"}
- Incident Response Plan: {number of incident response files loaded or "None found"}
- Infrastructure Plan: {number of infrastructure files loaded or "None found"}

**Files loaded:** {list of specific file names or "No additional documents found"}

Ready to begin resilience testing planning. Do you have any other documents you'd like me to include?

[C] Continue to steady-state hypothesis definition

## SUCCESS METRICS:

✅ Existing workflow detected and handed off to step-01b correctly
✅ Fresh workflow initialized with template and frontmatter
✅ Input documents discovered and loaded using sharded-first logic
✅ All discovered files tracked in frontmatter `inputDocuments`
✅ Architecture requirement validated and communicated
✅ User confirmed document setup and can proceed
✅ Production readiness checklist found or created
✅ Previously completed workflow artifacts discovered and context loaded

## FAILURE MODES:

❌ Proceeding with fresh initialization when existing workflow exists
❌ Not updating frontmatter with discovered input documents
❌ Creating document without proper template
❌ Not checking sharded folders first before whole files
❌ Not reporting what documents were found to user
❌ Proceeding without validating Architecture requirement

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, only after ensuring all the template output has been created, then load `./step-02-steady-state.md` to begin defining steady-state hypotheses.

Remember: Do NOT proceed to step-02 until user explicitly selects [C] from the menu and setup is confirmed!
