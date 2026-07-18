# Step 1: Security Plan Workflow Initialization

## MANDATORY EXECUTION RULES (READ FIRST):

- 🛑 NEVER generate content without user input
- 📖 CRITICAL: ALWAYS read the complete step file before taking any action - partial understanding leads to incomplete decisions
- 🔄 CRITICAL: When loading next step with 'C', ensure the entire file is read and understood before proceeding
- ✅ ALWAYS treat this as collaborative discovery between security peers
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

Initialize the Security Plan workflow by detecting continuation state, discovering input documents, and setting up the document for collaborative security planning.

## INITIALIZATION SEQUENCE:

### 1. Check for Existing Workflow

First, check if the output document already exists:

- First, check for `{bgr_artifacts}/security-plan.md` (exact path)
- If not found at exact path, fall back to glob: `{bgr_artifacts}/*security-plan*.md`
  - If glob matches exactly one file, proceed with that file automatically
  - If multiple files match, present the list to the user and ask them to select the correct one
- If exists, read the complete file(s) including frontmatter
- If not exists, this is a fresh workflow

### 2. Handle Continuation (If Document Exists)

Evaluate `stepsCompleted` using mutually exclusive conditions:

**Condition A — Valid non-empty array** (e.g., `stepsCompleted: [1]` or `stepsCompleted: [1, 2]`):
- The frontmatter contains a `stepsCompleted` field that is a valid array with at least one element
- **STOP here** and load `./step-01b-continue.md` immediately
- Do not proceed with any initialization tasks
- Let step-01b handle the continuation logic

**Condition B — Missing, empty, or invalid** (e.g., `stepsCompleted` key absent, `stepsCompleted: []`, or malformed value):
- The frontmatter either lacks `stepsCompleted`, has an empty array, or has a non-array value
- **Do NOT overwrite the file automatically**
- Warn the user: "I found an existing `security-plan.md` but it has no valid workflow state (missing `stepsCompleted` frontmatter). This could be a manually created file or a partially completed workflow."
- Present options:
  - **[O] Overwrite** — Start fresh and replace the existing file with a clean template
  - **[R] Recovery** — Load `./step-01b-continue.md` to attempt continuation from the existing content
  - **[A] Abort** — Stop and let the user manually inspect or back up the file first
- **Only proceed with fresh initialization if the user explicitly selects [O]**

### 3. Fresh Workflow Setup (If No Document Exists)

If no document exists at all:

#### A. Input Document Discovery

Discover and load context documents using smart discovery. Documents can be in the following locations:
- {bgr_artifacts}/**
- {project_knowledge}/**
- {project-root}/docs/**

Also - when searching - documents can be a single markdown file, or a folder with an index and multiple files. For example, when searching for `*foo*`, first check for a folder called `*foo*/index.md` (which indicates sharded content), and if not found then search for a single markdown file matching `*foo*.md`

Try to discover the following:
- Architecture Document (`*architecture*.md`)
- Product Requirements Document (`*prd*.md`)
- Infrastructure Plan (`*infrastructure*.md`)
- Observability Plan (`*observability*.md`)
- Project Context (`**/project-context.md`)

> **CRITICAL:** Confirm what you have found with the user, along with asking if the user wants to provide anything else. Only after this confirmation will you proceed to follow the loading rules.

**Loading Rules:**

- Load ALL discovered files completely that the user confirmed or provided (no offset/limit)
- If there is a project context, whatever is relevant should try to be biased in the remainder of this whole workflow process
- For sharded folders, load ALL files to get complete picture, using the index first to potentially know the potential of each document
- index.md is a guide to what's relevant whenever available
- If any file fails to load (permission denied, corrupted, or exceeds 500KB), log a warning and skip it — do not halt initialization. Report skipped files in the initialization summary.
- Track all successfully loaded files in frontmatter `inputDocuments` array

#### B. Validate Required Inputs

Before proceeding, verify we have the essential inputs:

**Architecture Document Validation:**

- If no architecture document found: "An architecture document is strongly recommended. It helps identify components, data flows, and trust boundaries that form the basis of threat modeling. Please consider creating one first or providing the file path."
- Allow proceeding without it, but note the gap

**PRD Validation:**

- If no PRD found: "A PRD helps identify sensitive data, user roles, and business-critical flows that need security attention. You can proceed without one, but security planning will be more thorough with it."
- Proceed without it

#### C. Create Initial Document

Copy the template from `../templates/security-plan-template.md` to `{bgr_artifacts}/security-plan.md`

Immediately update the frontmatter:
- Set `createdDate` to today's date
- Set `lastUpdated` to today's date
- Set `status` to `draft`
- Set `stepsCompleted: [1]` to mark Step 1 complete
- Set `inputDocuments` to the array of successfully loaded file paths from step A

#### D. Complete Initialization and Report

Complete setup and report to user:

**Document Setup:**

- Created: `{bgr_artifacts}/security-plan.md` from template
- Initialized frontmatter with workflow state

**Input Documents Discovered:**
Report what was found:
"Welcome {{user_name}}! I've set up your Security Plan workspace.

**Documents Found:**

- Architecture: {architecture files loaded or "None found - strongly recommended"}
- PRD: {PRD files loaded or "None found - recommended"}
- Infrastructure: {infrastructure files loaded or "None found"}
- Observability: {observability files loaded or "None found"}
- Project context: {project_context_rules} directive sections found in project-context.md

**Files loaded:** {list of specific file names or "No additional documents found"}

Ready to begin security planning. Do you have any other documents you'd like me to include?

[C] Continue to threat modeling

## SUCCESS METRICS:

✅ Existing workflow detected and handed off to step-01b correctly
✅ Existing document without valid frontmatter detected and user prompted before overwrite
✅ Fresh workflow initialized with template and frontmatter
✅ Input documents discovered and loaded using sharded-first logic
✅ All discovered files tracked in frontmatter `inputDocuments`
✅ Architecture and PRD document recommendations communicated
✅ User confirmed document setup and can proceed

## FAILURE MODES:

❌ Proceeding with fresh initialization when existing workflow exists
❌ Overwriting an existing security-plan.md without explicit user confirmation
❌ Not updating frontmatter with discovered input documents
❌ Creating document without proper template
❌ Not checking sharded folders first before whole files
❌ Not reporting what documents were found to user
❌ Not recommending architecture document when missing

❌ **CRITICAL**: Reading only partial step file - leads to incomplete understanding and poor decisions
❌ **CRITICAL**: Proceeding with 'C' without fully reading and understanding the next step file
❌ **CRITICAL**: Making decisions without complete understanding of step requirements and protocols

## NEXT STEP:

After user selects [C] to continue, only after ensuring all the template output has been created, then load `./step-02-threat-modeling.md` to begin threat analysis.

Verify that the document frontmatter has been properly initialized (createdDate, status: draft, stepsCompleted: [1]) before proceeding.

Remember: Do NOT proceed to step-02 until user explicitly selects [C] from the menu and setup is confirmed!
