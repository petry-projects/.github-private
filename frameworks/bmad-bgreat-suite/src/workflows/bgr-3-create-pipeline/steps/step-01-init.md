# Step 1: Initialization

## MANDATORY EXECUTION RULES

📖 READ this entire file before taking any action.
🛑 FOLLOW the sequence below exactly — do not skip or reorder.
⏳ WAIT for user input when instructed before proceeding.

---

## 1.1 Check Production Readiness Checklist

Look for `{bgr_artifacts}/production-readiness-checklist.md`:

- If it exists, read it to understand which other workflows have been completed
- Note any completed workflow plans -- their key decisions and cross-references will be loaded in the discovery phase
- If it does not exist, create it from the shared template at `../../../templates/bgr-production-readiness-checklist-template.md` and save to `{bgr_artifacts}/production-readiness-checklist.md`

## 1.2 Load Context from Completed Workflow Artifacts

Check `{bgr_artifacts}/` for previously completed BGreat workflow outputs:

- `*observability*.md` -- If completed, load SLO definitions and health check metrics to inform post-deploy verification gates and canary analysis criteria
- `*incident-response*.md` -- If completed, load severity classification and rollback triggers to align pipeline rollback automation with incident escalation thresholds
- `*infrastructure*.md` -- If completed, load environment topology, container platform, and secrets management to inform deployment targets, runner strategy, and credential injection
- `*security-plan*.md` -- If completed, load security scanning requirements, compliance gates, and auth testing strategy to inform pipeline security stages
- `*disaster-recovery*.md` -- If completed, load DR deployment procedures and failover testing that pipelines must support
- `*capacity-plan*.md` -- If completed, load testing requirements that should be integrated as pipeline stages

For each completed plan found:
- Load the document and extract key decisions relevant to pipeline design
- Surface these as context during the workflow (e.g., "The Infrastructure Plan defines 3 environments with Kubernetes on EKS -- pipeline deployment stages should target these environments")
- Track loaded plans in frontmatter `crossWorkflowContext` array. Each entry should include a `workflow` field identifying the source (e.g., 'observability', 'infrastructure', 'pipeline'). Before adding an entry, check if `crossWorkflowContext` already contains an entry with the same `workflow` field value -- if found, update it with the latest decisions; if not found, append a new entry (upsert by `workflow` field).

## 1.3 Check for Existing Pipeline Document

Scan `{bgr_artifacts}` for any file matching `*pipeline*.md`.

- **If found:** Load `./step-01b-continue.md` instead and follow its instructions. STOP here.
- **If not found:** Continue to 1.4.

## 1.4 Discover Input Documents

Scan `{bgr_artifacts}` and `{project_knowledge}` for these input documents:

| Document | Location Pattern | Required |
|----------|-----------------|----------|
| Architecture | `*architecture*.md` | ✅ Yes |
| Infrastructure | `*infrastructure*.md` | ⚠️ Recommended |
| PRD | `*prd*.md` | Optional |
| Project Context | `*project-context*.md` | Optional |

### Discovery Rules

- **Architecture document is REQUIRED.** If not found, inform the user and ask them to either provide one or run the architecture workflow first. Do NOT proceed without it.
- **Infrastructure plan is RECOMMENDED.** If not found, warn the user that pipeline decisions may need revisiting once infrastructure is defined.
- For each document found, read it and extract relevant context for pipeline planning.

## 1.5 Greet and Summarize

Greet the user by `{user_name}` and present:

- 📄 List of discovered input documents (found / not found)
- 📋 Brief summary of key architectural decisions that affect pipeline design
- 🔧 Any infrastructure constraints relevant to CI/CD

## 1.6 Create Document from Template

Create the pipeline plan document from `../templates/pipeline-template.md`:

- Set `createdDate` and `lastUpdated` to today's date
- Set `status: draft`
- Populate `inputDocuments` with discovered documents
- Save to `{bgr_artifacts}/pipeline.md`

## 1.7 Confirm and Proceed

Ask the user if they are ready to begin designing the pipeline architecture.

---

**Menu:**

- **[C]ontinue** — Proceed to pipeline architecture design
- **[R]evise** — Adjust initialization or provide missing documents

🔄 **Before transitioning:** Update frontmatter `stepsCompleted: [1]`.

➡️ **NEXT:** `./step-02-pipeline-architecture.md`
