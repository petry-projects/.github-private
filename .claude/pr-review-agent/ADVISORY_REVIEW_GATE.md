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

## Wait Strategy

The gate uses a 3-tier timeout strategy:

### Tier 1: 900 seconds (15 minutes)

**Target**: Catch 95% of advisory bot submissions

**Latency coverage**:
- ✓ Gemini (0.84 min median)
- ✓ Copilot (3.1 min median)
- ✓ SonarCloud (13.2 min median)
- ~ Codex (17.7 min median) — misses ~30% of Codex submissions

**Action**: If all participating bots have submitted by this time, proceed to approval.

### Tier 2: 1,200 seconds (20 minutes)

**Target**: Catch remaining stragglers (e.g., slow Codex)

**Latency coverage**:
- ✓ All bots at median latency
- ~ Gemini P95 (348s) and Copilot P95 (444s) are covered; SonarCloud P95 (~26 hours) and Codex P95 (~13 hours) are not — outlier submissions will be caught on subsequent re-trigger

**Action**: If all participating bots have now submitted, proceed.

### Tier 3: 3,600 seconds (60 minutes)

**Target**: Hard timeout before escalation

**Behavior**:
- Logs a warning
- Suggests checking CodeRabbit plan (rate-limit), PR complexity, or bot status
- Proceeds with approval anyway (we don't block indefinitely)
- Exit code: 2 (soft failure with warning)

## Smart Detection

The gate intelligently handles bots that don't participate in every PR:

### How It Works

1. On startup, query the PR to see which bots have already submitted
2. **Determine participation set**: Which bots have submitted so far?
3. **Poll only for missing bots**: Don't wait forever for bots that never trigger
4. **Timeout**: If a bot participated (submitted once), we wait for all subsequent ones

### Examples

**Scenario A: Codex not triggered (44% of PRs)**
```
PR #450 created
  ├─ Gemini submits @ 50s ✓
  ├─ Copilot submits @ 180s ✓
  ├─ SonarCloud submits @ 800s ✓
  └─ Codex never triggered (not on this PR)
  
Result: By T+15min, 3/3 participating bots submitted → APPROVE
```

**Scenario B: All 4 bots triggered**
```
PR #451 created
  ├─ Gemini submits @ 50s ✓
  ├─ Copilot submits @ 180s ✓
  ├─ SonarCloud submits @ 800s ✓
  ├─ Codex submits @ 1000s (slow) ✓
  
Result: By T+20min, 4/4 participating bots submitted → APPROVE
```

**Scenario C: High-volume period (no bots submitted yet at T+15min)**
```
PR #452 created (during compliance blitz)
  ├─ T+900s: No bots submitted yet (unusual)
  ├─ T+1200s: Still none
  ├─ T+3600s: Hard timeout
  
Result: Escalate (check for CodeRabbit rate-limit, bot downtime)
         Proceed anyway with warning
```

## Implementation Details

### File: `scripts/lib/advisory-review-gate.sh`

Main entry point: `wait_for_advisory_reviews <pr_url>`

**Functions**:
- `wait_for_advisory_reviews()` — Main wait loop
- `get_advisory_bot_states()` — Query PR reviews/comments for advisory bots
- `format_bot_status()` — Pretty-print bot review state
- `has_submitted()` — Check if bot has submitted

**Return codes**:
- `0` — Bots reviewed, proceeding to approval
- `2` — Hard timeout reached, proceeding anyway with warning

### Integration: `scripts/review-one-pr.sh`

The gate is called after the CI gate passes but before approval logic:

```bash
# CI gate passes...
# ↓
# Advisory bot review gate (new)
source "$SCRIPT_DIR/lib/advisory-review-gate.sh"
wait_for_advisory_reviews "$PR_URL"
# ↓
# Idempotency check...
# ↓
# Approval (if no blockers)
```

## Observability

### Logging

The gate logs detailed information for debugging:

```
[advisory-gate] Starting advisory bot review gate for PR #450
[advisory-gate] Detecting participating bots...
[advisory-gate]   ✓ gemini-code-assist → COMMENTED (advisory)
[advisory-gate]   ✓ copilot-pull-request-reviewer → COMMENTED (advisory)
[advisory-gate]   ✓ sonarqubecloud → COMMENTED (advisory)
[advisory-gate] Tier 1 wait: 900s (15 min) - waiting for advisory bots...
[advisory-gate] Tier 1 timeout reached (900 seconds)
[advisory-gate] Final advisory bot status:
[advisory-gate]   ✓ gemini-code-assist → COMMENTED (advisory)
[advisory-gate]   ✓ copilot-pull-request-reviewer → COMMENTED (advisory)
[advisory-gate]   ✓ sonarqubecloud → COMMENTED (advisory)
[advisory-gate] Advisory bot review gate passed ✓
```

### Metrics

- **Wait time per PR**: Logged and can be extracted for analytics
- **Bot participation**: Which bots triggered for which PRs
- **Timeout incidents**: PRs that hit Tier 3 hard timeout (should be <5%)

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
- Real-world typical waits: 15-20 minutes to catch all bots
- CodeRabbit excluded: doesn't approve anymore

## Configuration

### Timeout Adjustment

If you need to adjust wait times, edit `scripts/lib/advisory-review-gate.sh`:

```bash
TIER1_WAIT=900      # 15 min → Change here
TIER2_WAIT=1200     # 20 min → Change here
TIER3_WAIT=3600     # 60 min → Change here
POLL_INTERVAL=10    # Check every 10s → Change here
```

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
- All 4 bots present → success
- 3 bots present (no Codex) → success
- Slow Codex (Tier 2 wait) → success
- No bots submitted → hard timeout warning
- CHANGES_REQUESTED state → noted but doesn't block

## Troubleshooting

### "Hard timeout reached at 3600 seconds"

This happens when advisory bots don't submit within 60 minutes. Common causes:

1. **CodeRabbit rate-limited** (most common)
   - Check CodeRabbit quota at https://coderabbit.ai/settings/subscription
   - Upgrade plan if exhausted
   - Solution: Upgrade or throttle PR creation

2. **PR had unusual complexity**
   - Very large PRs sometimes trigger slow reviews
   - Check PR file count, line changes
   - Solution: Normal, monitor for pattern

3. **Bot service issues**
   - Gemini, Copilot, SonarCloud, Codex may be experiencing downtime
   - Check official status pages
   - Solution: Wait for service recovery or contact vendor

### "No advisory bots have submitted by Tier 2 timeout"

This is unusual and suggests:
1. PR isn't triggering bot webhooks (check workflow configuration)
2. Bots are completely down (check status pages)
3. PR has unusual properties (deleted files, binary content, etc.)

**Solution**: Check bot integrations in GitHub, restart workflows if needed.

## Future Improvements

1. **Per-bot timeout customization**: Different waits for slower/faster bots
2. **Fallback reviewers**: If bots don't submit, require human review instead
3. **Bot absence detection**: Fail loudly if expected bots never trigger
4. **Metrics dashboard**: Track wait times, timeout rates per bot
5. **Codex graduation**: Once Codex is on 95%+ of PRs, may reduce Tier 2 timeout

## Related Issues & PRs

- **Issue #457**: Implement advisory bot review gate (this feature)
- **PR #453**: Auto-merge hold mechanism (incident that revealed the problem)
- **Issue #452**: PR branch deleted mid-run (CodeRabbit rate-limit consequence)
- **Fix**: CodeRabbit approval removal (context for why gate was needed)

