# Implementation Details

This document describes the current implementation of the PR Review Agent and key architectural decisions.

## Authentication

### Current Approach: GitHub App

**Why GitHub Apps?**
- ✅ No human account required (no `petry-review-bot` user account)
- ✅ Auto-expiring JWT tokens (1 hour) — more secure than PATs
- ✅ Fine-grained permissions scoped to specific repos
- ✅ Better audit trail — all actions logged and visible in app settings
- ✅ GitHub's recommended approach for automation

**Previous Approach (Deprecated):**
- `petry-review-bot` user account with classic PAT
- Required creating and maintaining a separate GitHub user
- Long-lived tokens (1 year) required manual rotation
- Less visibility into what the bot was doing

### Token Generation

Both workflows generate fresh JWT tokens at runtime:
```yaml
- name: Generate GitHub App token
  uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: petry-projects

env:
  GH_TOKEN: ${{ steps.app-token.outputs.token }}
```

The token is scoped to the `petry-projects` organization and expires after 1 hour.

## PR Enumeration

### Finding Candidate PRs

`scripts/list-prs.sh` finds open PRs authored by the authenticated user using:

```bash
gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --json url,number,repository
```

**Important:** The authored PR search does NOT filter on `--checks`, allowing review of PRs that haven't passed CI yet (e.g., compliance-related PRs).

External reviews are filtered by `--checks success` to ensure the agent doesn't approve PRs with failing CI.

### No-op Detection

A PR is skipped (no-op) if the agent has already posted an approval review to it. This prevents duplicate reviews and respects the "already reviewed" state.

## Review Pipeline

The agent evaluates PRs through four sequential phases:

1. **Triage** (`prompts/triage.md`)
   - Quick scope assessment
   - Decides: proceed to deep review, security audit, or immediate rejection
   - Output: `{decision, reason, proceed_with}`

2. **Deep Review** (`prompts/deep-review.md`)
   - Code quality analysis
   - Correctness, style, test coverage
   - Output: `{issues, severity, recommendation}`

3. **Security Audit** (`prompts/security-audit.md`)
   - Vulnerability scanning
   - Permission model, dependencies, secrets
   - Output: `{vulnerabilities, risk_level, recommendation}`

4. **Synthesis** (`prompts/synthesize.md`)
   - Combines triage, deep review, and security findings
   - Makes approval/rejection decision
   - Generates review body with actionable feedback

### Verdict JSON

Instead of the agent directly posting reviews, the agent outputs JSON:

```json
{
  "verdict": "approved",
  "review_body": "Reviewed PR...\n\n✓ Code quality looks good...",
  "should_rebase": false,
  "labels_to_remove": ["needs-human-review"]
}
```

This JSON is captured by `scripts/review-one-pr.sh` and passed to `scripts/post-pr-review.sh` for execution.

## Approval and Auto-Merge

### Why Not Agent-Driven Posting?

Earlier versions attempted to have the agent execute bash commands:
```bash
gh pr review "$PR_URL" --approve --body "$BODY"
gh pr merge "$PR_URL" --auto --squash
```

This approach failed because:
- Agents are unreliable at executing bash from high-level prompts
- Token management is complex within agent context
- Error handling is difficult to reason about

### Current Approach: Deterministic Scripts

`scripts/post-pr-review.sh` is a pure bash script handling all GitHub operations:

```bash
#!/usr/bin/env bash
gh pr review "$PR_URL" --approve --body "$(cat "$BODY_FILE")" || true
gh api -X PUT "repos/$OWNER_REPO/pulls/$PR_NUM/update-branch"
gh pr merge "$PR_URL" --auto --squash
gh pr edit "$PR_URL" --remove-label needs-human-review
```

Benefits:
- ✅ Deterministic — no AI decision-making on edge cases
- ✅ Testable — can be run standalone
- ✅ Observable — direct access to gh CLI output and errors
- ✅ Recoverable — can be re-run if it fails

### Separation of Concerns

- **Agent responsibility:** Analyze code and output decision as JSON
- **Infrastructure responsibility:** Execute GitHub operations reliably

This separation makes the system more robust and easier to debug.

## Stuck PR Cleanup

### The Problem

An earlier bug caused the agent to post comments with `decision=approved` instead of actual approval reviews. This meant:
- PRs had agent approval markers
- But no actual GitHub approval review
- So auto-merge didn't trigger

### The Solution

`scripts/fix-stuck-prs.sh` identifies and fixes these PRs:

```bash
# Find PRs with marker comments
MARKER_COUNT=$(gh pr view "$url" --json comments \
  --jq '[.comments[] | select(.body | contains("pr-review-agent v1"))] | length')

# Check if approval review exists
APPROVAL_COUNT=$(gh pr view "$url" --json reviews \
  --jq '[.reviews[] | select(.state == "APPROVED")] | length')

# If marker but no approval, post review
if [ "$MARKER_COUNT" -gt 0 ] && [ "$APPROVAL_COUNT" -eq 0 ]; then
  gh pr review "$url" --approve
  gh pr merge "$url" --auto --squash
fi
```

This script runs with GitHub App token credentials that can approve PRs across the organization.

**GitHub App Token Compatibility Fixes:**

1. **Author Search:** Changed from `--author "@me"` to explicit `--author "don-petry"` because GitHub App tokens don't have user identity (no "me")
2. **Subshell Scope:** Fixed while loop from pipe to process substitution to preserve counter variables (`PROBLEM_PRS`, `FIXED_PRS`). Piped input created a subshell where variable increments didn't persist.
3. **Auth Check:** Silenced `gh api user` error (returns 403 as GitHub App tokens lack user scope). Script continues successfully with app-token identity.

## Rate Limiting and Fallback

The `pr-review.yml` workflow includes fallback logic:

```bash
if [ "$rc" -eq 2 ] && [ "${REVIEW_ENGINE:-claude}" = "claude" ]; then
  echo "Claude rate limit hit — switching to Copilot engine for remaining PRs"
  export REVIEW_ENGINE=copilot
  bash scripts/review-one-pr.sh "$pr_url" || rc=$?
fi
```

If Claude hits rate limits, the workflow switches to GitHub Copilot for remaining PRs in the batch. This ensures reviews continue even under high load.

## Metrics and Monitoring

Key metrics tracked in workflow logs:
- **Reviews posted:** Number of PRs actually approved
- **No-ops skipped:** PRs already reviewed, not re-reviewed
- **Failures:** PRs that had errors during review
- **Engine fallbacks:** Times Claude rate limit triggered Copilot fallback

View recent runs:
```bash
gh run list --repo don-petry/pr-review-agent -w pr-review.yml -L 5
```

Check specific run output:
```bash
gh run view <run-id> --repo don-petry/pr-review-agent --log
```

## Configuration

### Environment Variables (in workflows)

| Variable | Default | Purpose |
|----------|---------|---------|
| `REVIEW_ENGINE` | `claude` | Primary review engine |
| `DRY_RUN` | `true` | If true, don't post reviews |
| `MAX_PRS` | `10` | Max reviews per run |
| `CANDIDATE_LIMIT` | `100` | Max candidates scanned |
| `MAX_REVIEW_CYCLES` | `3` | Max review iterations before human escalation |
| `DELEGATION_ORGS` | Empty | Orgs where AI can auto-fix findings |

### Secrets

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code authentication |
| `APP_ID` | GitHub App ID (3505640) |
| `APP_INSTALLATION_ID` | App installation (127129996) |
| `APP_PRIVATE_KEY` | GitHub App private key (.pem) |
| `COPILOT_GITHUB_TOKEN` | GitHub Copilot fallback token |

## File Structure

```
├── .github/workflows/
│   ├── pr-review.yml              # Main hourly review workflow
│   └── fix-stuck-prs.yml          # Cleanup workflow
│
├── scripts/
│   ├── list-prs.sh                # Enumerate candidate PRs
│   ├── review-one-pr.sh           # Orchestrate single PR review
│   ├── post-pr-review.sh          # Post approval and auto-merge
│   └── fix-stuck-prs.sh           # Fix PRs with comments but no reviews
│
├── prompts/
│   ├── shared.md                  # Shared context for all reviews
│   ├── triage.md                  # Quick scope assessment
│   ├── deep-review.md             # Code quality analysis
│   ├── security-audit.md          # Vulnerability scanning
│   ├── synthesize.md              # Combine findings, make decision
│   └── cascade-action.md          # Review coordination (legacy)
│
├── SETUP.md                       # Quick start guide
├── GITHUB_APP_SETUP.md            # Detailed GitHub App setup
├── IMPLEMENTATION.md              # This file
└── README.md                       # Overview
```

## Future Improvements

- [ ] Webhook-based triggering instead of hourly cron (faster feedback)
- [ ] Per-repo configuration for review strictness
- [ ] Machine learning to learn from human review feedback
- [ ] Integration with issue tracking systems (Linear, Jira)
- [ ] Custom review templates per organization
- [ ] Review history and analytics dashboard
