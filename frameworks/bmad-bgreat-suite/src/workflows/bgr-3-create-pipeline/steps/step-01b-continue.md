# Step 1b: Continue Existing Pipeline Plan

## MANDATORY EXECUTION RULES

📖 READ this entire file before taking any action.
🛑 FOLLOW the sequence below exactly — do not skip or reorder.
⏳ WAIT for user input when instructed before proceeding.

---

## 1b.1 Load Existing Document

Read the existing pipeline document found at `{bgr_artifacts}/pipeline.md`.

## 1b.2 Assess State

From the frontmatter, determine:

- `status` — current document status
- `stepsCompleted` — which steps have been completed
- `lastUpdated` — when it was last modified

## 1b.3 Present Summary to User

Greet the user by `{user_name}` and present:

- 📄 Existing pipeline plan found
- ✅ Steps already completed
- 📋 Summary of what has been defined so far
- ➡️ Next step that should be resumed

## 1b.4 Offer Options

Ask the user how they want to proceed:

---

**Menu:**

- **[C]ontinue** — Resume from the next incomplete step
- **[R]estart** — Start fresh (will overwrite the existing document)
- **[V]iew** — Display the current document contents before deciding

🔄 **On Continue:** Load the next incomplete step file based on `stepsCompleted`.
🔄 **On Restart:** Return to step-01-init.md section 1.2 and proceed as if no document exists.
