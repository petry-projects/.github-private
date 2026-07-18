# Step 1: Chaos Game Day Workflow Initialization

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

Initialize the Chaos Game Day workflow by detecting continuation state, discovering input documents, and setting up the document for collaborative chaos engineering game day planning.

## INITIALIZATION SEQUENCE:

### 1. Check for Existing Workflow

First, check if the output document already exists:

- Look for existing `{bgr_artifacts}/*chaos*gameday*.md` or `{bgr_artifacts}/*chaos*.md`
- If exists, read the complete file(s) including frontmatter
- If not exists, this is a fresh workflow

### 2. Check Production Readiness Checklist

Look for `{bgr_artifacts}/production-readiness-checklist.md`:

- If it exists, read it to understand which other workflows have been completed
- Note any completed workflow plans — their key decisions and cross-references will be loaded in the discovery phase
- If it does not exist, create it from the shared template at `../../../templates/bgr-production-readiness-checklist-template.md` and save to `{bgr_artifacts}/production-readiness-checklist.md`

### 3. Load Context from Completed Workflow Artifacts

Check `{bgr_artifacts}/` for previously completed BGreat workflow outputs:

- `*observability*.md` — If completed, load SLO definitions and alerting thresholds to use as experiment steady-state hypotheses and observation points
- `*infrastructure*.md` — If completed, load environment topology and service architecture to scope experiments to real failure points
- `*incident-response*.md` — If completed, load severity classification and escalation procedures to align abort conditions with incident escalation
- `*disaster-recovery*.md` — If completed, load RTO/RPO targets and failover procedures to design DR validation experiments

For each completed plan found:
- Load the document and extract key decisions relevant to chaos game day planning
- Surface these as context during the workflow (e.g., "The Observability Plan defines a 99.9% SLO for the checkout service — we should use this as the steady-state hypothesis for our availability experiments")
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
- Architecture Document (`*architecture*.md`)
- Observability Plan (`*observability*.md`)
- Infrastructure Plan (`*infrastructure*.md`)
- Incident Response Plan (`*incident-response*.md`)
- Disaster Recovery Plan (`*disaster-recovery*.md`)
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

**Observability Plan Validation:**

- If no observability plan found: "An observability plan is strongly recommended for chaos engineering. SLOs from the observability plan define the steady-state hypotheses for experiments — without them, we will need to define metrics manually. You can create one with the `bgr-3-create-observability` workflow."
- Proceed without it, but note the gap

**Architecture Document Validation:**

- If no architecture document found: "An architecture document is strongly recommended. It helps identify the services, dependencies, and failure modes that make the most valuable chaos experiment targets. Please consider creating one first or providing the file path."
- Allow proceeding without it, but note the gap

#### C. Create Initial Document

Copy the template from `../templates/chaos-gameday-plan-template.md` to `{bgr_artifacts}/chaos-gameday-plan.md`

#### D. Complete Initialization and Report

Complete setup and report to user:

**Document Setup:**

- Created: `{bgr_artifacts}/chaos-gameday-plan.md` from template
- Initialized frontmatter with workflow state

**Input Documents Discovered:**
Report what was found:
"Welcome {{user_name}}! I've set up your Chaos Engineering Game Day workspace.

**Documents Found:**

- Architecture: {architecture files loaded or "None found - strongly recommended"}
- Observability: {observability files loaded or "None found - strongly recommended for SLO-based hypotheses"}
- Infrastructure: {infrastructure files loaded or "None found - recommended"}
- Incident Response: {incident response files loaded or "None found"}
- Disaster Recovery: {disaster recovery files loaded or "None found"}
- PRD: {PRD files loaded or "None found"}
- Project context: {project_context_rules count of rules for AI agents found}

**Files loaded:** {list of specific file names or "No additional documents found"}

Ready to begin chaos game day planning. Do you have any other documents you'd like me to include?

[C] Continue to hypothesis design and experiment selection
[R] Revise — adjust initialization or provide missing documents

## SUCCESS METRICS:

✅ Existing workflow detected and handed off to step-01b correctly
✅ Fresh workflow initialized with template and frontmatter
✅ Input documents discovered and loaded using sharded-first logic
✅ All discovered files tracked in frontmatter `inputDocuments`
✅ Observability and architecture document recommendations communicated
✅ User confirmed document setup and can proceed
✅ Production readiness checklist found or created
✅ Previously completed workflow artifacts discovered and context loaded

## FAILURE MODES:

❌ Proceeding with fresh initialization when existing workflow exists
❌ Not updating frontmatter with discovered input documents
❌ Creating document without proper template
❌ Not checking sharded folders first before whole files
❌ Not reporting what documents were found to user
❌ Not strongly recommending observability plan when missing
❌ Not loading SLO definitions from observability plan when available

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, only after ensuring all the template output has been created, then load `./step-02-hypothesis-design.md` to define experiment hypotheses and select experiments.

Remember: Do NOT proceed to step-02 until user explicitly selects [C] from the menu and setup is confirmed!
