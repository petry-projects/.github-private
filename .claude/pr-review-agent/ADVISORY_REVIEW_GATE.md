# Advisory Bot Review Gate

## Overview

The advisory bot review gate ensures that the pr-review agent waits for code review feedback from advisory bots before posting approval. This prevents the situation where approval is posted before valid review feedback arrives.

**Related**: Issue #457, PR #453 incident

## Problem Context

### The Incident (PR #453)

- **02:51:35** — pr-review agent posted APPROVED
- **02:52:18** — Copilot bot review arrived (43 seconds too late) with valid feedback
- **Result**: Valid review feedback was never incorporated because approval already posted

### Root Cause

The pr-review workflow triggers on `check_suite` (completed) event and approves immediately after CI checks pass, without checking if advisory bots have submitted their reviews yet.

## Participating Bots

The gate waits for reviews from these bots:

1. **Gemini Code Assist** (`gemini-code-assist`)
   - Latency: Median 50 seconds
   - Participation: 80% of PRs
   - Reliability: Excellent (100% success rate)
   - Limitation: Cannot process `.yml`, `.yaml`, `.toml` files (returns UNSUPPORTED)

2. **Copilot PR Reviewer** (`copilot-pull-request-reviewer`)
   - Latency: Median 186 seconds (3.1 minutes)
   - Participation: 80% of PRs
   - Reliability: Excellent (100% success rate)
   - No rate-limiting

3. **SonarCloud** (`sonarqubecloud`)
   - Latency: Median 794 seconds (13.2 minutes)
   - Participation: 80% of PRs
   - Reliability: Excellent (100% success rate)
   - May have slow outliers (26+ hours) from high-volume periods

4. **Codex** (`chatgpt-codex-connector`)
   - Latency: Median 1,059 seconds (17.7 minutes)
   - Participation: 44% of PRs (newer bot, not on all PRs yet)
   - Reliability: Good (100% when triggered)
   - No rate-limiting

### CodeRabbit Status

⚠️ **CodeRabbit does NOT approve** (recent fix). It's treated as optional since it no longer provides the approval decision. The gate does not wait for CodeRabbit submissions.

## Check Strategy

The gate uses a **non-blocking instant check** with a re-trigger pattern. There are no polling loops or blocking waits.

### How It Works

1. When the pr-review workflow fires (e.g., on `check_suite` completion), the gate makes a single API call
2. **If all detected bots have submitted** → return 0, proceed to approval
3. **If bots are still pending** → return 1, skip this run (`exit 100`)
4. When a bot submits its review, the `pull_request_review` event fires and re-triggers the pr-review workflow
5. The gate runs again and, once all bots have submitted, returns 0 and allows approval

This avoids long-running workflow blocks while still ensuring approval doesn't race ahead of valid bot feedback.

**Cost**: ~75% savings vs. blocking (2–3 min runs vs. 10–60 min blocks)

## Smart Detection

The gate intelligently handles bots that don't participate in every PR:

### How It Works

1. On each check, query the PR to see which bots have already submitted
2. **Determine participation set**: Which bots have submitted so far?
3. **Only bots that have submitted** form the "participating set" — absent bots are not waited for indefinitely
4. The latest submission per bot is used (not the first), so if a bot revises its review, the most recent state is evaluated

### Examples

**Scenario A: Codex not triggered (44% of PRs)**
```
PR #450 created
  ├─ Gemini submits @ 50s ✓
  ├─ Copilot submits @ 180s ✓
  ├─ SonarCloud submits @ 800s ✓
  └─ Codex never triggered (not on this PR)

On next pull_request_review event (SonarCloud submission):
  Gate sees 3 submitted bots, Codex absent → return 0 → APPROVE
```

**Scenario B: All 4 bots triggered**
```
PR #451 created
  ├─ Gemini submits @ 50s → gate re-triggers, sees only Gemini, defers
  ├─ Copilot submits @ 180s → gate re-triggers, sees 2/4, defers
  ├─ SonarCloud submits @ 800s → gate re-triggers, sees 3/4, defers
  └─ Codex submits @ 1000s → gate re-triggers, sees 4/4 → APPROVE
```

**Scenario C: SonarCloud/Codex outlier (P95 outlier: hours/days)**
```
PR #452 created (high-volume period)
  ├─ Gemini submits @ 50s ✓
  ├─ Copilot submits @ 180s ✓
  ├─ SonarCloud: outlier (>26 hours)
  └─ Codex: outlier (>13 hours)

Result: Gate defers on each re-trigger until SonarCloud/Codex eventually submit.
        The PR is not blocked — other PRs continue to be reviewed.
        Note: P95 outliers (SonarCloud ~26h, Codex ~13h) are NOT covered by any
        fixed timeout; only re-triggering on submission events resolves them.
```

## Implementation Details

### File: `scripts/lib/advisory-review-gate.sh`

Main entry point: `check_advisory_reviews <pr_url>`

**Functions**:
- `check_advisory_reviews()` — Instant non-blocking check; returns 0 (ready) or 1 (waiting)
- `get_advisory_bot_states()` — Query PR reviews/comments for advisory bots, returning the latest submission per bot
- `format_bot_status()` — Pretty-print bot review state

**Return codes**:
- `0` — All detected bots have submitted; proceed to approval
- `1` — Waiting for bots; caller should skip (`exit 100`) and re-check on next review event

### Integration: `scripts/review-one-pr.sh`

The gate is called after the CI gate passes but before approval logic:

```bash
# CI gate passes...
# ↓
# Advisory bot review gate (non-blocking instant check)
{
  source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
  check_advisory_reviews "$PR_URL"
} || {
  gate_rc=$?
  if [ $gate_rc -eq 1 ]; then
    # Bots not yet submitted — skip, re-check on next pull_request_review event
    exit 100
  fi
}
# ↓
# Idempotency check...
# ↓
# Approval (if no blockers)
```

## Observability

### Logging

The gate logs detailed information for debugging:

```
[advisory-gate] Checking advisory bot review status for PR #450 (instant check, no polling)
[advisory-gate] Advisory bots detected: copilot-pull-request-reviewer gemini-code-assist sonarqubecloud
[advisory-gate]   ✓ copilot-pull-request-reviewer → COMMENTED (advisory)
[advisory-gate]   ✓ gemini-code-assist → COMMENTED (advisory)
[advisory-gate]   ✓ sonarqubecloud → COMMENTED (advisory)
[advisory-gate] All detected advisory bots have submitted ✓
[advisory-gate] Advisory bot review gate check PASSED ✓
```

When bots haven't submitted yet:

```
[advisory-gate] WARNING: No advisory bot reviews detected yet
[advisory-gate] WARNING: Will re-check when bots submit their reviews (pull_request_review event)
```

### Metrics

- **Wait time per PR**: Logged and can be extracted for analytics
- **Bot participation**: Which bots triggered for which PRs
- **Outlier incidents**: PRs where SonarCloud/Codex P95 outliers delayed the gate for many hours

## Historical Data

Analysis of 50 recent merged PRs (May 23 - June 7, 2026):

### Latency Statistics (Clean Data)

Excluding: CodeRabbit rate-limits, PRs blocked by CodeRabbit

| Bot | Min | Median | P95 | Max | Samples |
|-----|-----|--------|-----|-----|---------|
| **Gemini** | 3s | 50s | 348s | 408s | 36 |
| **Copilot** | 52s | 186s | 444s | 558s | 36 |
| **SonarCloud** | 38s | 794s | 93,996s | 417,729s | 36 |
| **Codex** | 170s | 1,059s | 47,360s | 93,463s | 36 |

**Notes**:
- SonarCloud/Codex P95+ outliers from compliance blitz period (not typical)
- Real-world typical approvals: 15–20 minutes to catch all bots at median latency
- P95 outliers for SonarCloud (~26 hours) and Codex (~13 hours) are resolved by the re-trigger
  pattern rather than by any fixed timeout — they will be covered eventually, not within 20 minutes
- CodeRabbit excluded: doesn't approve anymore

## Configuration

### Bot Customization

To add/remove bots, edit the `ADVISORY_BOTS` map:

```bash
declare -A ADVISORY_BOTS=(
  [gemini-code-assist]="Gemini Code Assist (advisory)"
  [copilot-pull-request-reviewer]="Copilot PR Reviewer (advisory)"
  [sonarqubecloud]="SonarCloud (advisory)"
  [chatgpt-codex-connector]="Codex (advisory, newer bot)"
  # Add new bots here
)
```

## Testing

Run the advisory gate tests:

```bash
bats tests/dev-lead/unit/test_advisory_review_gate.bats
```

Test scenarios:
- All 4 bots present → return 0 (success)
- 3 bots present (no Codex) → return 0 (success)
- No bots submitted → return 1 (waiting)
- CHANGES_REQUESTED state → noted but doesn't block
- Non-blocking design assertions (no TIER*_WAIT, no POLL_INTERVAL, no sleep)

## Troubleshooting

### "Advisory bots still reviewing" (gate returns 1 repeatedly)

This is expected behavior for slow bots. The gate will re-check each time a bot submits.
If bots never submit, common causes:

1. **PR isn't triggering bot webhooks**
   - Check workflow configuration and bot integrations in GitHub
   - Restart workflows if needed

2. **Bots are experiencing downtime**
   - Check official status pages for Gemini, Copilot, SonarCloud, Codex
   - Wait for service recovery or contact vendor

3. **PR has unusual properties**
   - Deleted files, binary content, or unsupported file types may prevent bot review
   - Gemini returns UNSUPPORTED for `.yml`/`.yaml`/`.toml` files — this is handled gracefully

### "No advisory bot reviews detected yet"

This is normal at the start of a PR review cycle. The gate will return 1 and the workflow
will re-check when the first bot submits its review.

### Forcing a review before all bots submit

Set `FORCE_REVIEW=true` in the workflow environment to bypass the gate. This is intended
for mention-triggered and dispatch-triggered runs where the author explicitly requests
a review regardless of bot status.

## Future Improvements

1. **Per-bot timeout customization**: Different waits for slower/faster bots
2. **Fallback reviewers**: If bots don't submit, require human review instead
3. **Bot absence detection**: Fail loudly if expected bots never trigger
4. **Metrics dashboard**: Track wait times, timeout rates per bot
5. **Codex graduation**: Once Codex is on 95%+ of PRs, may reduce its mandatory participation window

## Related Issues & PRs

- **Issue #457**: Implement advisory bot review gate (this feature)
- **PR #453**: Auto-merge hold mechanism (incident that revealed the problem)
- **Issue #452**: PR branch deleted mid-run (CodeRabbit rate-limit consequence)
- **Fix**: CodeRabbit approval removal (context for why gate was needed)

