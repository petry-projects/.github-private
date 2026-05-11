# Machine User Setup for PR Review Agent

This project authenticates via a **machine user account** with a fine-grained PAT. This replaces the previous GitHub App approach, which could not satisfy CODEOWNERS approval requirements (see [issue #27](https://github.com/petry-projects/.github-private/issues/27)).

## Why Machine User?

- Can be added to an org team listed in CODEOWNERS
- Approvals count as code owner reviews
- Simple PAT-based auth — no JWT generation step needed
- Works identically to a human reviewer from GitHub's perspective

## Step 1: Create the Machine User Account

1. Create a new GitHub account (e.g., `donpetry-bot`) with a shared org email alias
2. Add the account to the `petry-projects` organization
3. Create an org team (e.g., `petry-projects/pr-reviewers`) and add the machine user

## Step 2: Configure CODEOWNERS

In each target repo, add the team to `CODEOWNERS`:

```
# .github/CODEOWNERS
* @petry-projects/pr-reviewers
```

Or use path-specific rules as needed.

## Step 3: Generate a Fine-Grained PAT

1. Sign in as the machine user account
2. Go to **Settings → Developer settings → Fine-grained personal access tokens**
3. Create a new token:
   - **Token name:** `pr-review-agent`
   - **Expiration:** 90 days (set a calendar reminder to rotate)
   - **Resource owner:** `petry-projects`
   - **Repository access:** All repositories (or select specific repos)
   - **Permissions:**
     - **Repository → Contents:** Read-only
     - **Repository → Pull requests:** Read and write
     - **Repository → Commit statuses:** Read-only
     - **Repository → Checks:** Read-only
     - **Organization → Members:** Read-only

## Step 4: Store the PAT as an Org Secret

```bash
gh secret set DON_PETRY_BOT_GH_PAT --org petry-projects --body "<paste-token>"
```

Or store at repo level if preferred:

```bash
gh secret set DON_PETRY_BOT_GH_PAT --repo petry-projects/.github-private --body "<paste-token>"
```

### Verify the secret is set:

```bash
gh secret list --repo petry-projects/.github-private
```

Should show `DON_PETRY_BOT_GH_PAT` in the list.

## Step 5: Test the Setup

```bash
# Test dry-run
gh workflow run fix-stuck-prs.yml --repo petry-projects/.github-private -f dry_run=true

# Check the logs
gh run view <run-number> --repo petry-projects/.github-private --log | grep "Logged in"
```

Should show the machine user account name.

## Step 6: Clean Up Old GitHub App Secrets

Once the migration is validated:

```bash
gh secret delete APP_ID --repo petry-projects/.github-private
gh secret delete APP_INSTALLATION_ID --repo petry-projects/.github-private
gh secret delete APP_PRIVATE_KEY --repo petry-projects/.github-private
```

Optionally uninstall/delete the GitHub App from [org settings](https://github.com/organizations/petry-projects/settings/apps).

## PAT Rotation

Fine-grained PATs have a configurable expiry (90-day recommended). To rotate:

1. Sign in as the machine user
2. Generate a new fine-grained PAT with the same scopes
3. Update the secret: `gh secret set DON_PETRY_BOT_GH_PAT --repo petry-projects/.github-private --body "<new-token>"`
4. Revoke the old token

## Trade-offs vs GitHub App

| Aspect | Machine User (PAT) | GitHub App (previous) |
|--------|-------------------|----------------------|
| CODEOWNERS support | Yes | No |
| Token expiry | Manual (90-day fine-grained) | Automatic (1-hour JWT) |
| Permissions | PAT scopes | Fine-grained App manifest |
| Account overhead | Requires a GitHub seat | No human account |
| Setup complexity | Simple | Medium |

## Troubleshooting

### Issue: "Resource not accessible by integration"
- Verify the PAT has the required scopes
- Check the machine user has access to the target repos
- Ensure `DON_PETRY_BOT_GH_PAT` secret is set correctly

### Issue: Approval doesn't satisfy code owner requirement
- Verify the machine user is in the team listed in CODEOWNERS
- Check the repo's CODEOWNERS file is valid (`gh api repos/OWNER/REPO/codeowners/errors`)
- Ensure branch protection has `require_code_owner_review: true`

### Issue: Token expired
- Generate a new fine-grained PAT and update the `DON_PETRY_BOT_GH_PAT` secret

## References

- [GitHub: Managing CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [GitHub: Fine-grained PATs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens)
- [Issue #27: Why GitHub Apps can't be in CODEOWNERS](https://github.com/petry-projects/.github-private/issues/27)
