# GitHub App Setup for PR Review Agent

This is the **recommended approach** for automating PR reviews. GitHub Apps are purpose-built for automation and are more secure than personal access tokens.

## Why GitHub App?

- ✅ No human account needed
- ✅ Fine-grained permissions (not full repo access)
- ✅ JWT tokens expire automatically (more secure)
- ✅ Better audit trail
- ✅ GitHub's recommended approach for automation
- ✅ Can be scoped to specific organizations/repos

## Step 1: Create the GitHub App

1. Go to https://github.com/organizations/petry-projects/settings/apps
2. Click **New GitHub App**
3. Fill in the form:

   **GitHub App name:**
   ```
   petry-projects-pr-review-agent
   ```

   **Homepage URL:**
   ```
   https://github.com/don-petry/pr-review-agent
   ```

   **Webhook URL:**
   ```
   (Leave empty - we don't need webhooks for this bot)
   ```

   **Webhook active:**
   ```
   Uncheck this
   ```

4. Click **Create GitHub App**

## Step 2: Configure Permissions

In the app settings page, scroll to **Permissions & events** section:

### Repository Permissions:
- **Contents:** `Read-only` (to read PR details)
- **Pull requests:** `Read & write` (to post reviews and enable auto-merge)
- **Commit statuses:** `Read-only` (to check CI status)
- **Checks:** `Read-only` (to check CI results)

### Organization Permissions:
- **Members:** `Read-only` (to verify organization membership)

### Subscribe to events:
- ✅ Pull request

## Step 3: Install App to Organization

1. Go to **Install App** tab (left sidebar)
2. Click **Install** next to `petry-projects`
3. Select repositories to install on:
   - Option A: **Only select repositories** → select:
     - pr-review-agent
     - ContentTwin
     - TalkTerm
     - markets
   - Option B: **All repositories** (if you want it to work on all org repos)
4. Click **Install**

## Step 4: Generate and Store Private Key

1. Go back to app settings (https://github.com/organizations/petry-projects/settings/apps/petry-review-agent)
2. Scroll to **Private keys** section
3. Click **Generate a private key**
4. A `.pem` file will download
5. Store the private key as a repo secret in `don-petry/pr-review-agent`:

   ```bash
   # Read the downloaded .pem file
   cat ~/Downloads/petry-review-agent.*.pem | pbcopy  # macOS
   
   # Add as secret
   gh secret set APP_PRIVATE_KEY --repo don-petry/pr-review-agent
   # Paste the .pem content when prompted
   ```

## Step 5: Get App Credentials

From the app settings page, note these values:

1. **App ID** (at the top of the page)
   ```bash
   gh secret set APP_ID --repo don-petry/pr-review-agent --body "<app-id>"
   ```

2. **Installation ID** (under "Recent deliveries" or from Install App page)
   - Go to **Install App** tab
   - Find the installation for `petry-projects`
   - The URL shows: `/petry-projects/installations/<installation-id>`
   ```bash
   gh secret set APP_INSTALLATION_ID --repo don-petry/pr-review-agent --body "<installation-id>"
   ```

### Verify secrets are set:
```bash
gh secret list --repo don-petry/pr-review-agent
```

Should show:
- `APP_ID`
- `APP_INSTALLATION_ID`
- `APP_PRIVATE_KEY`

## Step 6: Update Workflow to Use GitHub App

Update `.github/workflows/fix-stuck-prs.yml`:

```yaml
name: Fix Stuck PRs

on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: "Dry run (true) or apply fixes (false)"
        required: false
        default: "true"
        type: string

permissions:
  contents: read

jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Generate GitHub App token
        uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: petry-projects

      - name: Fix stuck PRs
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          bash scripts/fix-stuck-prs.sh "${{ inputs.dry_run }}"
```

Also update `pr-review.yml` to use the GitHub App token:

```yaml
env:
  GH_TOKEN: ${{ steps.app-token.outputs.token }}
```

(Add the `Generate GitHub App token` step before any gh commands)

## Step 7: Update Main Workflow

Update `.github/workflows/pr-review.yml` similarly:

```yaml
jobs:
  review:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - name: Checkout agent repo
        uses: actions/checkout@v4

      - name: Generate GitHub App token
        uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: petry-projects

      - name: Install review engine CLIs
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
        run: |
          # ... rest of installation steps
```

And update the env section:
```yaml
env:
  GH_TOKEN: ${{ steps.app-token.outputs.token }}
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  # ... other env vars
```

## Step 8: Test the Setup

```bash
# Test dry-run with GitHub App auth
gh workflow run fix-stuck-prs.yml --repo don-petry/pr-review-agent -f dry_run=true

# Check the logs
gh run view <run-number> --repo don-petry/pr-review-agent --log | grep "Authenticated as"
```

Should show the GitHub App name (e.g., `petry-review-agent[bot]`)

## Step 9: Apply Fixes

Once authentication is verified:

```bash
gh workflow run fix-stuck-prs.yml --repo don-petry/pr-review-agent -f dry_run=false
```

## Advantages Over Bot User Account

| Aspect | GitHub App | Bot User Account |
|--------|-----------|-----------------|
| Setup | Medium (7 steps) | Simple (4 steps) |
| Security | High (JWT tokens) | Medium (long-lived PAT) |
| Permissions | Fine-grained | Full repo access |
| Token expiration | Automatic (1 hour) | Manual (1 year) |
| Audit trail | Better | Basic |
| Account management | No human account needed | Need separate account |
| Cost | Free | Free |

## Troubleshooting

### Issue: "Resource not accessible by integration"
- Check app permissions match what's needed
- Verify app is installed to the organization
- Check the repo is in the selected repos list

### Issue: "Invalid private key"
- Verify the .pem file content was pasted correctly
- Ensure no extra whitespace at beginning/end
- Regenerate the key and try again

### Issue: Authenticated as wrong user
- Verify `APP_ID` and `APP_PRIVATE_KEY` secrets are correct
- Check `APP_INSTALLATION_ID` matches the org where app is installed
- Re-generate app token step output in logs

### Issue: App can't approve PRs in certain repos
- Verify app is installed to that repo (or "All repositories" is selected)
- Check branch protection rules don't block the app
- Verify app has "Pull requests: write" permission

## Security Best Practices

1. **Rotate private key periodically** (quarterly recommended):
   - Regenerate key in app settings
   - Update `APP_PRIVATE_KEY` secret
   - Delete old key

2. **Monitor app activity**:
   - Go to app settings
   - View recent deliveries and logs

3. **Limit permissions**:
   - Only grant needed permissions (no admin)
   - Don't give "full repo" if fine-grained will do

4. **Keep private key secure**:
   - Never commit to repo
   - Never log it
   - Only share via GitHub Secrets

## Removing the Old Bot Account (Optional)

Once GitHub App is working:

1. Remove old `GH_PAT` secret:
   ```bash
   gh secret delete GH_PAT --repo don-petry/pr-review-agent
   ```

2. Remove `petry-review-bot` from organization:
   - Go to https://github.com/organizations/petry-projects/settings/members
   - Click "..." next to petry-review-bot
   - Remove from organization

3. Delete the bot account (optional):
   - Sign in as petry-review-bot
   - Settings → Account → Delete account

## Implementation Notes (don-petry/pr-review-agent)

This repository uses the GitHub App approach for authentication.

**App Details:**
- **App Name:** `petry-projects-pr-review-agent`
- **App ID:** `3505640`
- **Installation ID:** `127129996` (for petry-projects org)
- **Installation URL:** https://github.com/organizations/petry-projects/settings/installations/127129996

**Stored Secrets:**
```bash
APP_ID=3505640
APP_INSTALLATION_ID=127129996
APP_PRIVATE_KEY=<downloaded .pem file>
```

**Workflows Updated:**
- `.github/workflows/pr-review.yml` — Added GitHub App token generation step
- `.github/workflows/fix-stuck-prs.yml` — Added GitHub App token generation step

Both workflows now use `actions/create-github-app-token@v1` to generate JWT tokens instead of relying on static PATs.

**Testing:**
```bash
# Verify authentication
gh run view <run-id> --repo don-petry/pr-review-agent --log | grep "Authenticated as"
# Should show: petry-projects-pr-review-agent[bot]
```

## References

- [GitHub Apps Documentation](https://docs.github.com/en/developers/apps)
- [Creating GitHub App Token Action](https://github.com/actions/create-github-app-token)
- [GitHub App Permissions](https://docs.github.com/en/developers/apps/building-github-apps/permissions-for-github-apps)
