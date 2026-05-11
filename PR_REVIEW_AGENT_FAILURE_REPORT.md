# PR Review Agent Workflow Failure Analysis

**Date:** 2026-04-19  
**Failures Analyzed:** 9 consecutive failed runs (16:20 UTC through 08:30 UTC)  
**Current Status:** All recent runs failing with 100% failure rate

## Executive Summary

All recent PR Review Agent workflow runs are **failing at the PR enumeration step** due to a single critical bug in `scripts/list-prs.sh`. The root cause is a breaking change in the `gh` CLI's `--checks` flag value.

---

## Failure Breakdown

### Category 1: Invalid `--checks` Flag Value (CRITICAL)
**Affected Runs:** ALL 9 analyzed (100%)  
**Exit Code:** 1 (hard failure, no PR enumeration completes)

**Error:**
```
invalid argument "passing" for "--checks" flag: valid values are {pending|success|failure}
```

**Root Cause:**
- File: `scripts/list-prs.sh` (lines 23 and 32)
- Current code: `--checks passing`
- Required by current `gh` CLI: `--checks {pending|success|failure}`
- The value `passing` is not recognized by `gh search prs`

**Impact:**
- The workflow fails during the "Enumerate candidate PRs" step
- No PRs are ever enumerated or reviewed
- The entire batch processing loop is skipped
- This is a **blocking issue** that prevents any review work

**Fix Required:**
Replace `--checks passing` with `--checks success` in `scripts/list-prs.sh` (lines 23 and 32)

---

### Category 2: Missing Token Scope (`read:org`)
**Severity:** Medium (potential secondary blocker)  
**Status:** Detected but not currently blocking enumeration

**Diagnostic Output:**
```
- Token scopes: 'read:audit_log', 'read:packages', 'read:user', 'repo', 'write:discussion'
! Missing required token scopes: 'read:org'
```

**Why This Matters:**
- The `read:org` scope is typically required for cross-org PR searches
- While the enumeration is failing due to the `--checks` bug, the missing scope could cause secondary failures once that's fixed
- GitHub's `gh search prs` may require org visibility for filtered searches

**Current Token Scopes (in `.github/workflows/pr-review.yml`):**
- `read:audit_log`
- `read:packages`
- `read:user`
- `repo`
- `write:discussion`

**Missing Scope:**
- `read:org` (needed for org-level visibility in PR searches)

**Recommendation:**
Update the GH_PAT token to include the `read:org` scope before the next test run.

---

## Verification of Root Cause

### Evidence from Recent Run (2026-04-19T16:20:54Z)

**Step 1: Install engines** ✓ PASS
```
added 2 packages in 5s
```

**Step 2: Verify auth** ⚠️ WARNING (but auth succeeds)
```
✓ Logged in to github.com account don-petry (GH_TOKEN)
! Missing required token scopes: 'read:org'
```

**Step 3: Enumerate candidate PRs** ✗ FAIL
```
invalid argument "passing" for "--checks" flag: valid values are {pending|success|failure}
Process completed with exit code 1.
```

The workflow exits at step 3 because `list-prs.sh` crashes when running:
```bash
gh search prs \
  --state open \
  --author "@me" \
  --draft=false \
  --checks passing      # ❌ INVALID - should be "success"
  --limit 100 \
  --json url \
  --jq '.[].url'
```

---

## Recommended Actions

### Immediate (Critical)
1. **Fix `scripts/list-prs.sh`:**
   - Line 23: Change `--checks passing` → `--checks success`
   - Line 32: Change `--checks passing` → `--checks success`
   - Test the fix by running a manual workflow dispatch

### Short-term (High Priority)
2. **Update GH_PAT token:**
   - Add `read:org` scope to the GitHub PAT
   - Update the secret in GitHub: `gh secret set GH_PAT --repo don-petry/self`
   - Verify with: `gh auth status` (should show `read:org` in scopes)

### Optional (Documentation)
3. **Update workflow comments** in `.github/workflows/pr-review.yml`:
   - Line 31-32: Note that `GH_PAT` must have at least these scopes:
     - `read:audit_log`
     - `read:org` (NEW)
     - `read:packages`
     - `read:user`
     - `repo`
     - `write:discussion`

---

## Test Strategy

1. **Fix the `--checks` bug** in `list-prs.sh`
2. **Run manual workflow dispatch:**
   ```bash
   gh workflow run pr-review.yml --repo don-petry/self
   ```
3. **Verify enumeration succeeds** (should list candidate PRs)
4. **Monitor next hourly run** (scheduled for :07 past each hour)

---

## Root Cause Summary

| Issue | Severity | Status | Type | Fix |
|-------|----------|--------|------|-----|
| `--checks passing` invalid | CRITICAL | Blocking all runs | gh CLI API change | Change to `success` |
| Missing `read:org` scope | Medium | Will fail after primary fix | Token permission | Add scope to PAT |
| Submodule cleanup warning | Low | Non-critical cleanup error | Post-job cleanup | Expected, no action needed |

---

## Conclusion

The PR Review Agent workflow is **100% blocked** due to a single line bug in `scripts/list-prs.sh` where the `gh` CLI's valid values for `--checks` have changed. The fix is simple: replace `passing` with `success` in two locations.

Once the `--checks` bug is fixed, add the `read:org` scope to the GH_PAT token to prevent secondary auth failures during PR enumeration across organizations.
