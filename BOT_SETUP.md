# petry-review-bot Setup Instructions

This guide sets up the bot account that posts PR approvals on behalf of the PR Review Agent.

**Why a separate bot account?** GitHub blocks self-approvals — a user cannot approve their own PR. The bot account acts as a reviewer, allowing don-petry's PRs to be auto-approved and auto-merged.

## Step 1: Create the Bot Account

1. Sign out of GitHub (use private browser window or different browser)
2. Go to https://github.com/signup
3. Create account with:
   - **Username:** `petry-review-bot`
   - **Email:** Use a dedicated alias (e.g., `you+petry-review-bot@gmail.com`)
4. Verify the email address
5. Sign back in as **don-petry**

## Step 2: Add Bot to Organization

1. Go to https://github.com/organizations/petry-projects/settings/members
2. Click **Invite member**
3. Enter `petry-review-bot`
4. Select Role: **Member**
5. Send invitation
6. Sign in as **petry-review-bot** and accept the invitation
7. Sign back in as **don-petry**

## Step 3: Create Classic PAT for Bot Account

A classic PAT is required (fine-grained PATs cannot bypass GitHub rulesets).

1. Sign in as **petry-review-bot**
2. Go to **Settings → Developer settings → Personal access tokens → Tokens (classic)**
3. Click **Generate new token (classic)**
4. Fill in:
   - **Note:** `pr-review-agent`
   - **Expiration:** 1 year (set calendar reminder to rotate)
   - **Scopes:** Check ✅ `repo` (full control of repositories)
5. Click **Generate token**
6. **Copy the token immediately** (you won't see it again)
7. Store it temporarily (we'll add to repo secret next)

## Step 4: Add GH_PAT Secret to Repo

1. Sign back in as **don-petry**
2. Go to https://github.com/don-petry/pr-review-agent/settings/secrets/actions
3. Click **New repository secret**
4. Fill in:
   - **Name:** `GH_PAT`
   - **Value:** Paste the bot token from Step 3
5. Click **Add secret**

**Verify:** The secret should now appear in the list as `GH_PAT`

## Step 5: Add Bot to Branch Protection Rules

The bot needs to be allowed as an approver in branch protection settings.

1. Go to https://github.com/don-petry/pr-review-agent/settings/branches
2. Click on the `main` branch protection rule (or create one)
3. In "Require pull request reviews before merging":
   - Make sure the bot is **NOT** in the "Dismiss stale pull request approvals" dismissal restrictions
   - Add `petry-review-bot` to the list of **allowed approvers** if that field exists
4. Save

**Alternative:** If using GitHub Rulesets instead of branch protection:
1. Go to https://github.com/don-petry/pr-review-agent/rules
2. Edit the main branch ruleset
3. Under "Require reviews," ensure `petry-review-bot` can post approvals
4. Save

## Step 6: Configure Across Multiple Repos

Repeat **Step 5** for any other repos where the bot should approve PRs:
- `petry-projects/ContentTwin`
- `petry-projects/TalkTerm`
- `petry-projects/markets`
- Any other repos in the `petry-projects` org

## Step 7: Test the Setup

1. Trigger a dry-run to verify authentication:
   ```bash
   gh workflow run fix-stuck-prs.yml --repo don-petry/pr-review-agent -f dry_run=true
   ```

2. Check the workflow logs:
   ```bash
   gh run view <run-number> --repo don-petry/pr-review-agent --log
   ```

3. Should show:
   ```
   GH_TOKEN set: yes-masked
   Authenticated as: petry-review-bot
   ```

4. If authentication is correct, run the actual fixes:
   ```bash
   gh workflow run fix-stuck-prs.yml --repo don-petry/pr-review-agent -f dry_run=false
   ```

## Troubleshooting

### Issue: Still authenticating as `don-petry`
- Verify `GH_PAT` secret contains the **bot account's** PAT, not don-petry's token
- Check the PAT was generated from petry-review-bot's account, not don-petry's

### Issue: "Review Can not approve your own pull request"
- The PAT is don-petry's token (causes self-approval attempts)
- Generate a fresh PAT from petry-review-bot's account

### Issue: Bot can't approve PRs in certain repos
- Verify bot is a member of the organization
- Check branch protection rules aren't blocking the bot
- Verify bot has `repo` scope in its PAT

## Rotating the Token (Annually)

1. Sign in as **petry-review-bot**
2. Go to **Settings → Developer settings → Tokens (classic)**
3. Generate a new token with same settings
4. Update the `GH_PAT` secret in the repo with the new token
5. Delete the old token
6. Set a new calendar reminder for next year

## Security Notes

- The `GH_PAT` is a secret and should never be logged or committed
- The bot account should only be used for automated reviews, not manual work
- Rotate the token annually
- If the token is compromised, delete it immediately and generate a new one
