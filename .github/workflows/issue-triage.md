---
on:
  issues:
    types: [opened]
engine: claude-sonnet-4-6
permissions:
  issues: read
safe-outputs:
  add-labels:
    # needs-human-review is intentionally NOT here (#1778). It is a *hold* label
    # (scripts/lib/hold-gate.sh) owned by the PR-review escalation path
    # (scripts/lib/pr-automation-budget.sh); its GitHub description is "Flagged by
    # automated PR review agent". Triage classifies an issue but must never apply a
    # hold — a fresh, well-specified report has nothing awaiting a human decision.
    # Keeping it out of this set makes the rule code-enforced (safe-output rejects
    # it) rather than prompt-only, which drifts.
    allowed:
      - bug
      - enhancement
      - documentation
      - question
      - good first issue
      - security
    max: 3
---

# Issue Triage

You are triaging a new GitHub issue for the `${REPO}` repository.

## Context

- **Repository:** `${REPO}`
- **Issue:** [#${ISSUE_NUMBER}](${ISSUE_URL}): ${ISSUE_TITLE}
- **Labels already applied:** ${ISSUE_LABELS}

**Issue body:**

${ISSUE_BODY}

## Task

1. **Classify** the issue into the best-fit category:
   - `bug` — something is not working as expected
   - `enhancement` — request for new or extended functionality
   - `documentation` — unclear, missing, or incorrect docs
   - `question` — user asking how to do something
   - `security` — potential security vulnerability
   - `good first issue` — simple enough for a first-time contributor

2. **Select ≤ 3 labels** from the allowed set:
   `bug`, `enhancement`, `documentation`, `question`,
   `good first issue`, `security`.
   - These are **classification** labels only. Do **not** apply any hold label
     (`needs-human-review`) — it is not in the allowed set. Triage's job is to
     classify and ask a clarifying question, not to park the issue; a fresh
     report has nothing awaiting a human decision yet. If a report is too vague
     to classify, still classify it as best you can and let the clarifying
     comment below solicit the missing detail — the reporter's answer is what
     should gate later work, not the act of filing (#1778).
   - Add `good first issue` only when the scope is clearly small and
     self-contained.

3. **Write one welcoming comment** that:
   - Opens warmly and thanks the contributor.
   - Asks the **single most important** clarifying question for this issue type:
     - Bug → steps to reproduce + expected vs actual behaviour
     - Feature → use case / motivation
     - Question → what docs they checked and where they got stuck
     - Documentation → which page or section is unclear and what they expected
     - Security → (do not ask for details publicly; ask them to use the
       private security advisory channel)
   - Does **not** ask multiple unrelated questions.
   - Is concise (≤ 5 sentences).

## Output format

Output **exactly one** JSON object — no markdown fences, no preamble:

{"labels": ["label1", "label2"], "comment": "Your welcoming comment here."}
