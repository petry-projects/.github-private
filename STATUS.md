# PR Review Agent - Status Report

**Date:** April 26, 2026  
**Status:** ✅ **OPERATIONAL**

## What Was Done

### 1. GitHub App Authentication ✅
- Created GitHub App: `petry-projects-pr-review-agent` (App ID: 3505640)
- Configured permissions: Contents (read), Pull requests (read/write), Checks (read)
- Stored secrets in repository:
  - `APP_ID` = 3505640
  - `APP_INSTALLATION_ID` = 127129996
  - `APP_PRIVATE_KEY` = [.pem file]
- Updated workflows to use `actions/create-github-app-token@v1`

**Why GitHub Apps?**
- No human account required
- Auto-expiring tokens (1 hour) — more secure than PATs
- Fine-grained permissions
- Better audit trail
- GitHub's recommended approach

### 2. Comprehensive Documentation ✅
Created in repository:
- **SETUP.md** — Quick reference guide with configuration, secrets, commands, troubleshooting
- **IMPLEMENTATION.md** — Technical deep dive: architecture, design decisions, stuck PR cleanup
- **DOCUMENTATION.md** — Index linking all documentation
- **Updated README.md** — Status badge and quick links
- **Updated GITHUB_APP_SETUP.md** — Implementation notes with actual app ID and installation details

### 3. Stuck PR Cleanup ✅ (Approvals Posted)
Fixed 24 stuck PRs across three repositories:
- **ContentTwin:** PRs #97-109 (13 PRs)
- **TalkTerm:** PRs #112, #121 (2 PRs)
- **Markets:** PRs #126, #128-130, #133+ (9+ PRs)

**What was the problem?**
Agent was posting comments with `decision=approved` instead of actual GitHub approval reviews. Approval reviews are required for branch protection, comments don't satisfy the requirement.

**How it was fixed:**
`scripts/fix-stuck-prs.sh` identifies PRs with marker comments but no approval reviews, then posts actual approval reviews using the GitHub App token.

**Current Status:**
- ✅ Approval reviews posted to all 24 stuck PRs
- ⚠️ Auto-merge failed (GitHub App lacks `enablePullRequestAutoMerge` permission)
- ❌ PRs still OPEN (approvals in place, but manual merge or permission expansion needed)

**Verification:**
```
ContentTwin #109: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #108: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #107: 1 approval review(s) ✓ (status: OPEN)
ContentTwin #100: 2 approval review(s) ✓ (status: OPEN)
```

**Next Step:** Either:
1. Expand GitHub App permissions to include `Pull requests: read & write & admin` for auto-merge
2. Manually merge the PRs (they now have approvals)
3. Enable auto-merge in branch protection settings (if configured)

## How the System Works

### Hourly Review Cycle
1. Enumerate open PRs authored by don-petry
2. For each PR: triage → deep review → security audit → synthesis
3. Post approval review if PR passes all checks
4. Enable auto-merge (squash strategy)
5. Update labels if needed

### Workflow Files
- `.github/workflows/pr-review.yml` — Main hourly review (runs at :07 every hour)
- `.github/workflows/fix-stuck-prs.yml` — Manual cleanup workflow for stuck PRs

### Scripts
- `scripts/list-prs.sh` — Enumerate candidate PRs
- `scripts/review-one-pr.sh` — Orchestrate review for single PR
- `scripts/post-pr-review.sh` — Post approval and enable auto-merge
- `scripts/fix-stuck-prs.sh` — Fix PRs with comments but no approvals

## Architectural Decisions

### Agent vs Infrastructure Separation
- **Agent:** Analyzes code, outputs verdict JSON
- **Infrastructure:** Executes GitHub operations (posting, rebasing, auto-merge)

This separation makes the system more robust and easier to debug. Agent decisions are content-focused; infrastructure execution is deterministic.

### GitHub App over Bot Account
Previously considered: Create `petry-review-bot` user account with classic PAT.

**Why we switched:**
| Aspect | GitHub App | Bot Account |
|--------|-----------|-----------|
| Account needed | No | Yes |
| Token expiration | 1 hour (auto) | 1 year (manual) |
| Security | Higher | Lower |
| Audit trail | Better | Basic |
| Permissions | Fine-grained | Full repo |

## Configuration

### Required Secrets
```bash
gh secret set APP_ID --repo don-petry/pr-review-agent --body "3505640"
gh secret set APP_INSTALLATION_ID --repo don-petry/pr-review-agent --body "127129996"
gh secret set APP_PRIVATE_KEY --repo don-petry/pr-review-agent < /path/to/file.pem
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo don-petry/pr-review-agent
```

### Optional Variables
```bash
# Engine: claude (default) or copilot
gh variable set REVIEW_ENGINE --repo don-petry/pr-review-agent --body "claude"

# Live mode: true to post reviews, false for dry-run
gh variable set LIVE_MODE --repo don-petry/pr-review-agent --body "true"

# Max reviews per run
gh variable set MAX_PRS --repo don-petry/pr-review-agent --body "10"
```

## Usage

### Check Recent Reviews
```bash
gh run list --repo don-petry/pr-review-agent -w pr-review.yml -L 5
gh run view <run-id> --repo don-petry/pr-review-agent --log
```

### Trigger Manual Review
```bash
# Dry-run (no changes)
gh workflow run pr-review.yml --repo don-petry/pr-review-agent -f dry_run=true

# Review specific PR
gh workflow run pr-review.yml --repo don-petry/pr-review-agent \
  -f pr_url=https://github.com/petry-projects/ContentTwin/pull/123 \
  -f dry_run=false

# Fix stuck PRs
gh workflow run fix-stuck-prs.yml --repo don-petry/pr-review-agent -f dry_run=false
```

## Known Limitations

1. **Auto-merge requires additional permission**: GitHub App currently doesn't have permission to enable auto-merge via `gh pr merge --auto`. Approval reviews post successfully, but auto-merge must be enabled manually or via branch protection automation.

2. **GitHub App scope**: App tokens don't have user identity, so `gh api user` returns 403. This is expected and doesn't affect PR operations.

3. **`@me` in searches**: GitHub App tokens don't support `@me` in search queries. Use explicit author names instead.

## Support & Troubleshooting

See **[SETUP.md](SETUP.md)** for:
- Permission errors and fixes
- Authentication issues
- Workflow failures
- Rate limiting and fallback engines

See **[IMPLEMENTATION.md](IMPLEMENTATION.md)** for:
- Architecture details
- Design rationale
- How each component works
- Future improvement ideas

## Next Steps (Optional)

- [ ] Enable auto-merge permission in GitHub App if auto-merge is needed
- [ ] Expand review engine to handle more repo types
- [ ] Add webhook-based triggering for faster feedback
- [ ] Set up review analytics dashboard
- [ ] Integrate with project management systems (Linear, Jira)

---

**Created by:** Claude Code Agent  
**Repository:** don-petry/pr-review-agent  
**Organization:** petry-projects
