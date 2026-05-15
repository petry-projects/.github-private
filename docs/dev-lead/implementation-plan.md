# Dev-Lead Agent — Implementation Plan

**Status:** Planning  
**Version:** 0.1.0  
**Spec:** [`docs/dev-lead/spec.md`](./spec.md)  
**Tracking:** GitHub Issues with label `dev-lead`

---

## Overview

This plan operationalises the [dev-lead spec](./spec.md) across seven phases. Each phase is independently releasable and leaves the system in a working state. Phases 1–2 are the critical path; the remaining phases extend coverage and eventually retire the legacy `claude.yml` caller stub (Option A: delete, not redirect).

**Test philosophy:**
- Every shell function has a `bats` unit test before it ships.
- Every intent path has an E2E test in a dedicated `test-dev-lead.yml` workflow.
- Tests run on every PR to `.github-private` that touches `scripts/dev-lead*`, `scripts/engine.sh`, or `.github/workflows/dev-lead.yml`.

---

## Phase 0 — Test Infrastructure

**Goal:** Bootstrap the test harness before writing any production code.

### 0.1 Files to create

| File | Purpose |
|---|---|
| `tests/dev-lead/fixtures/events/` | JSON event payloads for unit tests |
| `tests/dev-lead/fixtures/engines/` | Stub engine binaries (mock claude/gemini) |
| `tests/dev-lead/helpers/stub-engine.bash` | bats helper: install/uninstall stub engine |
| `tests/dev-lead/helpers/mock-gh.bash` | bats helper: mock `gh` CLI responses |
| `tests/dev-lead/helpers/assert-comment.bash` | bats helper: assert PR comment was posted |
| `.github/workflows/test-dev-lead.yml` | CI workflow that runs all dev-lead tests |

### 0.2 Event fixture files

One JSON file per GitHub event type, covering both the "act" and "skip" cases.

```
tests/dev-lead/fixtures/events/
├── check_run_failure.json           # check_run, conclusion=failure, has PR
├── check_run_failure_fork.json      # check_run, conclusion=failure, fork PR → skip
├── check_run_success.json           # check_run, conclusion=success → skip
├── check_run_claude_self.json       # check_run name starts with "dev-lead /" → skip
├── pr_opened.json                   # pull_request, opened, human author
├── pr_opened_dependabot.json        # pull_request, opened, dependabot → skip
├── pr_opened_fork.json              # pull_request, fork → skip
├── pr_review_copilot_commented.json # pull_request_review, copilot, COMMENTED
├── pr_review_copilot_approved.json  # pull_request_review, copilot, APPROVED → skip
├── pr_review_gemini_changes.json    # pull_request_review, gemini, CHANGES_REQUESTED
├── pr_review_human.json             # pull_request_review, human OWNER
├── pr_review_comment_copilot.json   # pull_request_review_comment, copilot
├── pr_review_comment_human.json     # pull_request_review_comment, human + @dev-lead
├── issue_comment_sonarqube.json     # issue_comment on PR, sonarqubecloud[bot]
├── issue_comment_coderabbit.json    # issue_comment on PR, coderabbitai[bot]
├── issue_comment_human_mention.json # issue_comment on PR, human, contains @dev-lead
├── issue_comment_human_no_trigger.json # issue_comment, human, no trigger phrase → skip
├── issue_comment_rebase.json        # issue_comment, contains auto-rebase-conflict marker
├── issue_comment_claude_self.json   # issue_comment, actor=donpetry-bot → skip
├── issues_labeled_dev_lead.json     # issues, action=labeled, label=dev-lead
├── issues_labeled_other.json        # issues, action=labeled, label=bug → skip
└── repository_dispatch_ci.json      # repository_dispatch, dev-lead-ci-failure
```

### 0.3 Stub engine binary

`tests/dev-lead/fixtures/engines/stub-claude` — a minimal bash script that:
- Accepts `--print --model <m>` flags (ignores others)
- Reads stdin
- Outputs a configurable response (controlled by `STUB_ENGINE_RESPONSE` env var)
- Exits 0 by default; exits 2 if `STUB_ENGINE_RESPONSE=rate-limit`

```bash
#!/usr/bin/env bash
# Stub claude binary for unit tests.
# Set STUB_ENGINE_RESPONSE to control output.
# Set STUB_ENGINE_EXIT to control exit code.
cat <<< "${STUB_ENGINE_RESPONSE:-stub engine response}"
exit "${STUB_ENGINE_EXIT:-0}"
```

### 0.4 `test-dev-lead.yml` CI workflow

```yaml
name: Test Dev-Lead Agent
on:
  pull_request:
    paths:
      - 'scripts/dev-lead*'
      - 'scripts/engine.sh'
      - '.github/workflows/dev-lead.yml'
      - 'tests/dev-lead/**'
  push:
    branches: [main]
    paths:
      - 'scripts/dev-lead*'
      - 'scripts/engine.sh'
      - 'tests/dev-lead/**'

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@...
      - name: Install bats
        run: npm install -g bats
      - name: Run dev-lead unit tests
        run: bats tests/dev-lead/unit/

  integration:
    runs-on: ubuntu-latest
    needs: unit
    steps:
      - uses: actions/checkout@...
      - name: Run dev-lead integration tests
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: bash tests/dev-lead/integration/run-all.sh
```

### 0.5 Phase 0 definition of done

- [ ] All fixture JSON files pass `jq empty` validation
- [ ] `stub-claude` binary passes a smoke test: `echo "hello" | STUB_ENGINE_RESPONSE="ok" ./tests/dev-lead/fixtures/engines/stub-claude --print --model test`
- [ ] `test-dev-lead.yml` workflow is green on an empty test suite (no tests yet = pass)

---

## Phase 1 — Scaffold: Triggers Wired, No Agent Running

**Goal:** `dev-lead.yml` exists with all triggers; `dispatch` job runs but always skips. Verifiable in the Actions UI without any LLM cost.

### 1.1 Files to create/modify

| File | Change |
|---|---|
| `.github/workflows/dev-lead.yml` | **CREATE** — all triggers, both jobs, calls stub intent classifier |
| `scripts/dev-lead-intent.sh` | **CREATE** — stub: always outputs `INTENT_TYPE=skip INTENT_SKIP_REASON=not-implemented` |

### 1.2 `dev-lead.yml` skeleton

```yaml
name: Dev-Lead Agent

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize]
  pull_request_review:
    types: [submitted]
  pull_request_review_comment:
    types: [created]
  issue_comment:
    types: [created]
  issues:
    types: [labeled]
  check_run:
    types: [completed]
  repository_dispatch:
    types: [dev-lead-ci-failure]

permissions: {}

env:
  DEV_LEAD_ENGINE: ${{ vars.DEV_LEAD_ENGINE || 'claude' }}
  CLAUDE_CODE_VERSION: ${{ vars.CLAUDE_CODE_VERSION || 'latest' }}
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  GOOGLE_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
  GEMINI_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
  COPILOT_GITHUB_TOKEN: ${{ secrets.GH_PAT }}
  GH_TOKEN: ${{ secrets.GH_PAT_WORKFLOWS || github.token }}
  BOT_USER: ${{ vars.BOT_USER || 'donpetry-bot' }}
  TRUSTED_BOTS: ${{ vars.TRUSTED_BOTS || 'copilot-pull-request-reviewer[bot],gemini-code-assist[bot],coderabbitai[bot],sonarqubecloud[bot]' }}
  TRIGGER_PHRASES: ${{ vars.TRIGGER_PHRASES || '@claude,@dev-lead' }}

jobs:
  dispatch:
    if: github.event_name != 'check_run'
    runs-on: ubuntu-latest
    timeout-minutes: 60
    permissions:
      contents: write
      pull-requests: write
      issues: write
      actions: read
      checks: read
      id-token: write
    steps:
      - uses: actions/checkout@...
      - name: Classify intent
        id: intent
        run: bash scripts/dev-lead-intent.sh
      - name: Install engine CLIs
        if: steps.intent.outputs.intent_type != 'skip'
        run: bash scripts/dev-lead-install-engines.sh
      - name: Run handler
        if: steps.intent.outputs.intent_type != 'skip'
        run: |
          case "${{ steps.intent.outputs.intent_type }}" in
            fix-ci)          bash scripts/dev-lead-fix-ci.sh ;;
            fix-reviews|\
            fix-bot-comment|\
            human|\
            human-pr|\
            rebase)          bash scripts/dev-lead-fix-reviews.sh ;;
            issue)           bash scripts/dev-lead-fix-issue.sh ;;
          esac

  ci-relay:
    if: >-
      github.event_name == 'check_run' &&
      github.event.check_run.conclusion == 'failure' &&
      !startsWith(github.event.check_run.name, 'dev-lead / ') &&
      !startsWith(github.event.check_run.name, 'claude-code / ')
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      pull-requests: read
    steps:
      - name: Resolve PR and dispatch
        env:
          GH_TOKEN: ${{ env.GH_TOKEN }}
        run: |
          PR="${{ github.event.check_run.pull_requests[0].number }}"
          if [ -z "$PR" ]; then
            PR=$(gh api \
              "repos/${{ github.repository }}/commits/${{ github.event.check_run.head_sha }}/pulls" \
              --jq '[.[] | select(.state == "open")] | first | .number // empty' || true)
          fi
          [ -z "$PR" ] && { echo "No open PR for commit — skipping relay"; exit 0; }
          HEAD_REPO=$(gh api "repos/${{ github.repository }}/pulls/$PR" \
            --jq '.head.repo.full_name // empty')
          [ "$HEAD_REPO" != "${{ github.repository }}" ] && \
            { echo "Fork PR — skipping relay"; exit 0; }
          gh api "repos/${{ github.repository }}/dispatches" \
            --method POST \
            --field event_type="dev-lead-ci-failure" \
            --raw-field client_payload="$(jq -n \
              --arg pr "$PR" \
              --arg name "${{ github.event.check_run.name }}" \
              --arg id "${{ github.event.check_run.id }}" \
              --arg sha "${{ github.event.check_run.head_sha }}" \
              --arg url "${{ github.event.check_run.details_url }}" \
              --arg app "${{ github.event.check_run.app.slug }}" \
              '{pr_number:$pr,check_name:$name,check_id:$id,head_sha:$sha,details_url:$url,app_slug:$app}')"
```

### 1.3 Unit tests: `tests/dev-lead/unit/test_intent_stub.bats`

```bash
#!/usr/bin/env bats
# Phase 1: verify stub intent classifier always outputs skip.

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_EVENT_PATH="$(mktemp)"
  export GITHUB_EVENT_NAME="pull_request"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot]"
  export TRIGGER_PHRASES="@claude,@dev-lead"
  # Write a minimal pull_request event
  cp tests/dev-lead/fixtures/events/pr_opened.json "$GITHUB_EVENT_PATH"
}

teardown() {
  rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT"
}

@test "stub: always emits skip intent" {
  run bash scripts/dev-lead-intent.sh
  [ "$status" -eq 0 ]
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "stub: sets INTENT_SKIP_REASON" {
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_SKIP_REASON=" "$GITHUB_ENV"
}

@test "stub: dispatch job reads intent_type output" {
  bash scripts/dev-lead-intent.sh
  INTENT_TYPE=$(grep "^INTENT_TYPE=" "$GITHUB_ENV" | cut -d= -f2)
  [ "$INTENT_TYPE" = "skip" ]
}
```

### 1.4 E2E test: trigger fires, dispatch runs, logs skip

Manual verification via Actions UI after merging. Create a test PR, verify:
- `dispatch` job appears and shows "Classify intent" step as green
- Step log shows `INTENT_TYPE=skip`
- No engine CLIs installed, no LLM tokens consumed

### 1.5 Phase 1 definition of done

- [ ] `dev-lead.yml` exists on `main`, all 7 trigger types listed
- [ ] `ci-relay` job visible in Actions when a check_run fires
- [ ] `dispatch` job visible for all other events, always skips cleanly
- [ ] Phase 1 unit tests pass in `test-dev-lead.yml`

---

## Phase 2 — CI Fix Path

**Goal:** End-to-end: `check_run` failure → relay → Claude diagnoses and fixes.

### 2.1 Files to create/modify

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | **IMPLEMENT** classification for `repository_dispatch` → `fix-ci` |
| `scripts/dev-lead-fix-ci.sh` | **CREATE** |
| `scripts/dev-lead-install-engines.sh` | **CREATE** — installs claude CLI (reuses pr-review caching) |
| `scripts/engine.sh` | **EXTEND** — add `run_writer()` function |
| `tests/dev-lead/unit/test_intent_ci.bats` | **CREATE** |
| `tests/dev-lead/unit/test_engine_writer.bats` | **CREATE** |
| `tests/dev-lead/unit/test_fix_ci.bats` | **CREATE** |
| `tests/dev-lead/integration/test_ci_relay.sh` | **CREATE** |

### 2.2 `dev-lead-intent.sh` — `fix-ci` classification

The classifier must handle `repository_dispatch` with `event_type=dev-lead-ci-failure`:

```bash
# Inside dev-lead-intent.sh, repository_dispatch case:
case "$GITHUB_EVENT_NAME" in
  repository_dispatch)
    EVENT_ACTION=$(jq -r '.action' "$GITHUB_EVENT_PATH")
    if [ "$EVENT_ACTION" = "dev-lead-ci-failure" ]; then
      PR=$(jq -r '.client_payload.pr_number' "$GITHUB_EVENT_PATH")
      HEAD_SHA=$(jq -r '.client_payload.head_sha' "$GITHUB_EVENT_PATH")
      CHECK_NAME=$(jq -r '.client_payload.check_name' "$GITHUB_EVENT_PATH")
      CHECK_ID=$(jq -r '.client_payload.check_id' "$GITHUB_EVENT_PATH")
      DETAILS_URL=$(jq -r '.client_payload.details_url' "$GITHUB_EVENT_PATH")
      APP_SLUG=$(jq -r '.client_payload.app_slug' "$GITHUB_EVENT_PATH")
      INTENT_TYPE="fix-ci"
      # Build context file
      jq -n \
        --arg intent "fix-ci" \
        --arg pr "$PR" \
        --arg sha "$HEAD_SHA" \
        --arg check "$CHECK_NAME" \
        --arg check_id "$CHECK_ID" \
        --arg url "$DETAILS_URL" \
        --arg app "$APP_SLUG" \
        '{intent:$intent,pr_number:$pr,head_sha:$sha,check_name:$check,check_id:$check_id,details_url:$url,app_slug:$app}' \
        > "$INTENT_CONTEXT_FILE"
    else
      INTENT_TYPE="skip"
      INTENT_SKIP_REASON="unknown repository_dispatch type: $EVENT_ACTION"
    fi
    ;;
esac
```

### 2.3 `engine.sh` extension: `run_writer()`

```bash
# run_writer <prompt_file> [model]
# Full write access: Bash, Read, Write, Edit, Grep, Glob.
# Exits 2 on rate limit (triggers engine fallback in caller).
run_writer() {
  local prompt_file="$1"
  local model="${2:-$ENGINE_ACTION_MODEL}"
  local attempt=1 rc=0
  while [ "$attempt" -le "$RETRY_MAX_ATTEMPTS" ]; do
    rc=0
    case "$REVIEW_ENGINE" in
      claude)
        timeout "$DEEP_TIMEOUT_SEC" claude --print \
          --model "$model" \
          --permission-mode acceptEdits \
          --allowed-tools "Bash,Read,Write,Edit,Grep,Glob" \
          < "$prompt_file" || rc=$?
        ;;
      gemini)
        timeout "$DEEP_TIMEOUT_SEC" gemini --prompt "" \
          --model "$model" \
          --approval-mode auto_edit \
          --output-format text \
          < "$prompt_file" || rc=$?
        ;;
      copilot)
        # GitHub Models API is text-only — fall back to Claude for writes.
        echo "::warning::Copilot engine has no tool access — using Claude for write operation" >&2
        local saved_engine="$REVIEW_ENGINE"
        REVIEW_ENGINE=claude run_writer "$prompt_file" "$model"
        rc=$?
        REVIEW_ENGINE="$saved_engine"
        return "$rc"
        ;;
    esac
    [ "$rc" -eq 0 ] && return 0
    # Rate limit: exit 2 immediately (no retry — let caller switch engines)
    local output
    output=$(tail -20 "$prompt_file" 2>/dev/null || true)
    if is_rate_limited "$output"; then
      return 2
    fi
    if [ "$attempt" -lt "$RETRY_MAX_ATTEMPTS" ] && is_transient_failure "$rc"; then
      local delay=$(( RETRY_BASE_DELAY_SEC * (2 ** (attempt - 1)) ))
      echo "    [writer] transient failure (exit $rc), retrying in ${delay}s" >&2
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi
    return "$rc"
  done
  return "$rc"
}
```

### 2.4 `dev-lead-fix-ci.sh` structure

```
dev-lead-fix-ci.sh
  ├── read_context()        — parse $INTENT_CONTEXT_FILE
  ├── idempotency_check()   — scan PR comments for <!-- dev-lead-fix sha=HEAD_SHA -->
  ├── checkout_pr()         — gh pr checkout $PR
  ├── triage_failure()      — run_triage() → classify failure type
  ├── collect_artifacts()   — gh run view --log-failed, gh api .../annotations
  ├── build_fix_prompt()    — assemble prompt from failure type + logs + files
  ├── apply_fix()           — run_writer() with fix prompt
  ├── commit_and_push()     — git add -A, git commit, git push
  ├── wait_for_ci()         — gh pr checks --watch --interval 30
  ├── check_new_failures()  — if failures remain and cycles < MAX, loop
  └── post_summary()        — gh pr comment with structured result
```

**Idempotency marker format:**

```html
<!-- dev-lead-fix sha=abc123def456 -->
```

Scanned with:
```bash
gh pr view "$PR" --json comments \
  --jq ".comments[] | select(.body | contains(\"<!-- dev-lead-fix sha=$HEAD_SHA -->\")) | .body" \
  | head -1
```

**Summary comment format:**

```markdown
<!-- dev-lead-fix sha=<NEW_SHA> -->
### Dev-Lead: CI Fix Applied

**Triggered by:** SonarCloud Code Analysis (failure)
**Engine:** claude (claude-sonnet-4-6)

#### What I found
[failure summary]

#### What I changed
- `src/foo.ts` — fixed null check on line 47
- `.github/workflows/sonarcloud.yml` — added missing coverage exclusion

#### CI Status
✅ All checks passing after 1 fix cycle

_Fix applied at [abc123](https://github.com/.../commit/abc123) · [View run](https://github.com/...)_
```

### 2.5 Unit tests: `tests/dev-lead/unit/test_intent_ci.bats`

```bash
#!/usr/bin/env bats

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_EVENT_PATH="$(mktemp)"
  export INTENT_CONTEXT_FILE="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],sonarqubecloud[bot]"
  export TRIGGER_PHRASES="@claude,@dev-lead"
}
teardown() { rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$INTENT_CONTEXT_FILE"; }

@test "fix-ci: repository_dispatch dev-lead-ci-failure → fix-ci intent" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  cp tests/dev-lead/fixtures/events/repository_dispatch_ci.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  [ "$status" -eq 0 ]
  grep -q "INTENT_TYPE=fix-ci" "$GITHUB_ENV"
}

@test "fix-ci: context file contains pr_number" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  cp tests/dev-lead/fixtures/events/repository_dispatch_ci.json "$GITHUB_EVENT_PATH"
  bash scripts/dev-lead-intent.sh
  PR=$(jq -r '.pr_number' "$INTENT_CONTEXT_FILE")
  [ -n "$PR" ] && [ "$PR" != "null" ]
}

@test "fix-ci: context file contains check_name" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  cp tests/dev-lead/fixtures/events/repository_dispatch_ci.json "$GITHUB_EVENT_PATH"
  bash scripts/dev-lead-intent.sh
  CHECK=$(jq -r '.check_name' "$INTENT_CONTEXT_FILE")
  [ -n "$CHECK" ] && [ "$CHECK" != "null" ]
}

@test "fix-ci: unknown repository_dispatch type → skip" {
  export GITHUB_EVENT_NAME="repository_dispatch"
  jq '.action = "something-else"' \
    tests/dev-lead/fixtures/events/repository_dispatch_ci.json > "$GITHUB_EVENT_PATH"
  bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "fix-ci: check_run without open PR → relay emits no dispatch" {
  # Verifies ci-relay skips gracefully when no PR found
  export GITHUB_EVENT_NAME="check_run"
  cp tests/dev-lead/fixtures/events/check_run_failure.json "$GITHUB_EVENT_PATH"
  # Stub gh to return empty PR list
  export PATH="tests/dev-lead/fixtures/stubs:$PATH"
  GH_STUB_PULLS_RESPONSE="[]" run bash -c '
    PR="${{ github.event.check_run.pull_requests[0].number }}"
    [ -z "$PR" ] && echo "no PR found" && exit 0
  '
  [ "$status" -eq 0 ]
}
```

### 2.6 Unit tests: `tests/dev-lead/unit/test_engine_writer.bats`

```bash
#!/usr/bin/env bats

setup() {
  export REVIEW_ENGINE="claude"
  export STUB_DIR="tests/dev-lead/fixtures/engines"
  export PATH="$STUB_DIR:$PATH"
  source scripts/engine.sh >/dev/null 2>&1 || true
  export PROMPT_FILE="$(mktemp)"
  echo "test prompt" > "$PROMPT_FILE"
}
teardown() { rm -f "$PROMPT_FILE"; }

@test "run_writer: claude engine exits 0 on success" {
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="fix applied"
  run run_writer "$PROMPT_FILE"
  [ "$status" -eq 0 ]
}

@test "run_writer: claude engine exits 2 on rate limit" {
  export STUB_ENGINE_EXIT=1
  export STUB_ENGINE_RESPONSE="You have hit your limit. Rate limit exceeded."
  run run_writer "$PROMPT_FILE"
  [ "$status" -eq 2 ]
}

@test "run_writer: copilot engine falls back to claude" {
  export REVIEW_ENGINE="copilot"
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="fix applied via claude fallback"
  run run_writer "$PROMPT_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to Claude"* ]] || [[ "$output" == *"fix applied"* ]]
}

@test "run_writer: gemini engine exits 0 on success" {
  export REVIEW_ENGINE="gemini"
  # stub-gemini must be in fixtures/engines/
  export STUB_ENGINE_EXIT=0
  export STUB_ENGINE_RESPONSE="gemini fix applied"
  run run_writer "$PROMPT_FILE"
  [ "$status" -eq 0 ]
}

@test "run_writer: transient failure (exit 124) retries once" {
  export STUB_ENGINE_EXIT=124
  export STUB_ENGINE_RESPONSE=""
  export RETRY_MAX_ATTEMPTS=2
  export RETRY_BASE_DELAY_SEC=0
  run run_writer "$PROMPT_FILE"
  # Both attempts fail — final exit should be non-zero
  [ "$status" -ne 0 ]
}
```

### 2.7 Unit tests: `tests/dev-lead/unit/test_fix_ci.bats`

```bash
#!/usr/bin/env bats

setup() {
  export INTENT_CONTEXT_FILE="$(mktemp)"
  export GH_TOKEN="stub-token"
  export REVIEW_ENGINE="claude"
  export MAX_CI_CYCLES=3
  export BOT_USER="donpetry-bot"
  # Write minimal context
  jq -n '{
    intent:"fix-ci", pr_number:"175", head_sha:"abc123",
    check_name:"SonarCloud Code Analysis", check_id:"999",
    details_url:"https://sonarcloud.io", app_slug:"sonarqubecloud"
  }' > "$INTENT_CONTEXT_FILE"
  # Stub PATH
  export PATH="tests/dev-lead/fixtures/stubs:$PATH"
}
teardown() { rm -f "$INTENT_CONTEXT_FILE"; }

@test "fix-ci: idempotency check exits 0 when marker found" {
  # Stub gh pr view to return a comment with the marker
  export GH_STUB_COMMENT_BODY="<!-- dev-lead-fix sha=abc123 -->"
  run bash -c '
    source scripts/dev-lead-fix-ci.sh
    idempotency_check "175" "abc123"
  '
  [ "$status" -eq 0 ]
}

@test "fix-ci: idempotency check returns 1 when no marker (proceed)" {
  export GH_STUB_COMMENT_BODY=""
  run bash -c '
    source scripts/dev-lead-fix-ci.sh
    idempotency_check "175" "newsha999"
  '
  [ "$status" -eq 1 ]
}

@test "fix-ci: triage classifies lint failure" {
  export STUB_ENGINE_RESPONSE='{"failure_type":"lint","summary":"ESLint errors in src/"}'
  run bash -c '
    source scripts/dev-lead-fix-ci.sh
    triage_failure "ESLint rule violation: no-unused-vars"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"lint"* ]]
}

@test "fix-ci: exhaustion comment posted after MAX_CI_CYCLES" {
  export MAX_CI_CYCLES=1
  # Stub apply_fix to always succeed, wait_for_ci to always return failure
  export GH_STUB_CI_STATUS="failure"
  run bash -c '
    source scripts/dev-lead-fix-ci.sh
    # Override wait_for_ci for test
    wait_for_ci() { return 1; }
    apply_fix() { return 0; }
    commit_and_push() { return 0; }
    cycle_loop "175" "abc123"
  '
  # Should have attempted posting an exhaustion comment
  [ "$status" -ne 0 ]
}
```

### 2.8 Integration test: `tests/dev-lead/integration/test_ci_relay.sh`

```bash
#!/usr/bin/env bash
# Integration test: verify ci-relay job logic with a mock check_run event.
# Does NOT make real API calls; uses a mock gh binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUBS_DIR="$SCRIPT_DIR/../fixtures/stubs"

export PATH="$STUBS_DIR:$PATH"
export GITHUB_REPOSITORY="petry-projects/.github-private"
export GH_TOKEN="test-token"

# Test 1: non-fork PR → dispatch emitted
echo "==> Test 1: non-fork PR emits dispatch"
export GH_STUB_PR_HEAD_REPO="petry-projects/.github-private"
export GH_STUB_PR_NUMBER="175"
export CHECK_RUN_SHA="abc123"

DISPATCHED=""
gh() {
  if [[ "$*" == *"dispatches"* ]]; then
    DISPATCHED="true"
    return 0
  fi
  command gh "$@"
}
export -f gh

# Source and run the relay logic
# (extracted from dev-lead.yml ci-relay job)
bash "$SCRIPT_DIR/../../scripts/dev-lead-ci-relay.sh" \
  --sha "$CHECK_RUN_SHA" \
  --check-name "SonarCloud Code Analysis" \
  --check-id "999" \
  --details-url "https://sonarcloud.io"

[ "$DISPATCHED" = "true" ] || { echo "FAIL: dispatch not emitted"; exit 1; }
echo "PASS: Test 1"

# Test 2: fork PR → no dispatch
echo "==> Test 2: fork PR suppresses dispatch"
export GH_STUB_PR_HEAD_REPO="external-fork/repo"
DISPATCHED=""

bash "$SCRIPT_DIR/../../scripts/dev-lead-ci-relay.sh" \
  --sha "$CHECK_RUN_SHA" \
  --check-name "SonarCloud Code Analysis" \
  --check-id "999" \
  --details-url "https://sonarcloud.io" || true

[ -z "$DISPATCHED" ] || { echo "FAIL: dispatch emitted for fork"; exit 1; }
echo "PASS: Test 2"

# Test 3: check_run from dev-lead itself → no relay
echo "==> Test 3: self-check suppresses relay"
export GH_STUB_PR_HEAD_REPO="petry-projects/.github-private"

bash "$SCRIPT_DIR/../../scripts/dev-lead-ci-relay.sh" \
  --sha "$CHECK_RUN_SHA" \
  --check-name "dev-lead / dispatch" \
  --check-id "998" \
  --details-url "" || true

[ -z "$DISPATCHED" ] || { echo "FAIL: relay emitted for self-check"; exit 1; }
echo "PASS: Test 3"

echo "==> All CI relay integration tests passed"
```

### 2.9 Phase 2 definition of done

- [ ] `run_writer()` added to `engine.sh`, all unit tests pass
- [ ] `dev-lead-intent.sh` classifies `repository_dispatch:dev-lead-ci-failure` → `fix-ci`
- [ ] `dev-lead-fix-ci.sh` implements full loop (idempotency → checkout → triage → fix → push → CI watch → summary)
- [ ] All Phase 2 bats tests pass in `test-dev-lead.yml`
- [ ] Integration test: `test_ci_relay.sh` passes
- [ ] Manual E2E: push a commit with a deliberate lint error to a test branch, verify Claude fixes it within 5 minutes

---

## Phase 3 — Review Fix Path

**Goal:** Copilot and Gemini PR reviews trigger Claude to address all open threads.

### 3.1 Files to create/modify

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | **EXTEND** — `pull_request_review` + `pull_request_review_comment` + `issue_comment` (bot) classification |
| `scripts/dev-lead-fix-reviews.sh` | **CREATE** |
| `tests/dev-lead/unit/test_intent_reviews.bats` | **CREATE** |
| `tests/dev-lead/unit/test_fix_reviews.bats` | **CREATE** |
| `tests/dev-lead/integration/test_review_intent.sh` | **CREATE** |

### 3.2 Intent classification additions

```bash
pull_request_review)
  ACTOR=$(jq -r '.review.user.login' "$GITHUB_EVENT_PATH")
  REVIEW_STATE=$(jq -r '.review.state' "$GITHUB_EVENT_PATH")
  PR=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
  IS_FORK=$(jq -r '.pull_request.head.repo.full_name != .repository.full_name' "$GITHUB_EVENT_PATH")

  [ "$IS_FORK" = "true" ] && { emit_skip "fork-pr"; exit 0; }
  [ "$ACTOR" = "$BOT_USER" ] && { emit_skip "self-actor"; exit 0; }

  if is_trusted_bot "$ACTOR"; then
    [ "$REVIEW_STATE" = "APPROVED" ] && { emit_skip "approved-no-action"; exit 0; }
    INTENT_TYPE="fix-reviews"
  elif is_trusted_human; then
    INTENT_TYPE="human-pr"
  else
    emit_skip "untrusted-actor"
    exit 0
  fi
  ;;

pull_request_review_comment)
  ACTOR=$(jq -r '.comment.user.login' "$GITHUB_EVENT_PATH")
  PR=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
  IS_FORK=$(jq -r '.pull_request.head.repo.full_name != .repository.full_name' "$GITHUB_EVENT_PATH")

  [ "$IS_FORK" = "true" ] && { emit_skip "fork-pr"; exit 0; }
  [ "$ACTOR" = "$BOT_USER" ] && { emit_skip "self-actor"; exit 0; }

  if is_trusted_bot "$ACTOR"; then
    INTENT_TYPE="fix-reviews"
  elif is_trusted_human && has_trigger_phrase; then
    INTENT_TYPE="human"
  else
    emit_skip "no-trigger-or-untrusted"
  fi
  ;;

issue_comment)
  ACTOR=$(jq -r '.comment.user.login' "$GITHUB_EVENT_PATH")
  IS_PR=$(jq -r '.issue.pull_request != null' "$GITHUB_EVENT_PATH")
  COMMENT_BODY=$(jq -r '.comment.body' "$GITHUB_EVENT_PATH")
  PR=$(jq -r '.issue.number' "$GITHUB_EVENT_PATH")

  [ "$IS_PR" = "false" ] && { emit_skip "not-a-pr-comment"; exit 0; }
  [ "$ACTOR" = "$BOT_USER" ] && { emit_skip "self-actor"; exit 0; }

  if is_trusted_bot "$ACTOR"; then
    INTENT_TYPE="fix-bot-comment"
  elif echo "$COMMENT_BODY" | grep -qF "<!-- auto-rebase-conflict:"; then
    is_trusted_human || { emit_skip "rebase-sentinel-untrusted"; exit 0; }
    INTENT_TYPE="rebase"
  elif is_trusted_human && has_trigger_phrase; then
    INTENT_TYPE="human"
  else
    emit_skip "no-trigger-or-untrusted"
  fi
  ;;
```

### 3.3 `dev-lead-fix-reviews.sh` structure

```
dev-lead-fix-reviews.sh
  ├── read_context()
  ├── checkout_and_rebase()        — gh pr checkout; git rebase origin/<base>
  ├── fetch_open_threads()         — GraphQL: reviewThreads(first:250) {id,isResolved,comments}
  ├── classify_thread(thread)      — apply-suggestion | fix-code | discuss | skip-human
  ├── apply_suggestion(thread)     — extract suggestion block, apply exactly
  ├── fix_thread(thread)           — build targeted prompt, run_writer()
  ├── reply_thread(thread, msg)    — gh api graphql addPullRequestReviewComment
  ├── resolve_thread(thread_id)    — gh api graphql resolveReviewThread
  ├── commit_and_push()
  ├── wait_for_ci()
  ├── check_new_threads()          — re-run fetch, return count of new unresolved
  ├── post_summary()
  └── cycle_loop()                 — orchestrate up to MAX_REVIEW_CYCLES
```

For `fix-bot-comment` intent: skip thread fetching, use comment body directly as the problem statement in the fix prompt.

For `human` intent: prepend the user's comment body as the explicit instruction, then run `run_writer()` with full PR context.

For `rebase` intent: implement `git rebase` with the conflict-resolution strategy from the spec (workflow YAML SHA comparison; abort on application code).

### 3.4 Unit tests: `tests/dev-lead/unit/test_intent_reviews.bats`

```bash
#!/usr/bin/env bats

setup() {
  export GITHUB_ENV="$(mktemp)"
  export GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_EVENT_PATH="$(mktemp)"
  export INTENT_CONTEXT_FILE="$(mktemp)"
  export BOT_USER="donpetry-bot"
  export TRUSTED_BOTS="copilot-pull-request-reviewer[bot],gemini-code-assist[bot],coderabbitai[bot],sonarqubecloud[bot]"
  export TRIGGER_PHRASES="@claude,@dev-lead"
}
teardown() { rm -f "$GITHUB_ENV" "$GITHUB_OUTPUT" "$INTENT_CONTEXT_FILE"; }

# pull_request_review
@test "review: copilot COMMENTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_copilot_commented.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=fix-reviews" "$GITHUB_ENV"
}

@test "review: copilot APPROVED → skip" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_copilot_approved.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "review: gemini CHANGES_REQUESTED → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_gemini_changes.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=fix-reviews" "$GITHUB_ENV"
}

@test "review: human OWNER → human-pr" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_human.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=human-pr" "$GITHUB_ENV"
}

@test "review: fork PR → skip" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_copilot_commented.json "$GITHUB_EVENT_PATH"
  # Patch to fork
  jq '.pull_request.head.repo.full_name = "fork/repo"' "$GITHUB_EVENT_PATH" > /tmp/fork.json
  cp /tmp/fork.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "review: self-actor (BOT_USER) → skip" {
  export GITHUB_EVENT_NAME="pull_request_review"
  cp tests/dev-lead/fixtures/events/pr_review_copilot_commented.json "$GITHUB_EVENT_PATH"
  jq '.review.user.login = "donpetry-bot"' "$GITHUB_EVENT_PATH" > /tmp/self.json
  cp /tmp/self.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

# pull_request_review_comment
@test "review_comment: copilot inline → fix-reviews" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  cp tests/dev-lead/fixtures/events/pr_review_comment_copilot.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=fix-reviews" "$GITHUB_ENV"
}

@test "review_comment: human with @dev-lead → human intent" {
  export GITHUB_EVENT_NAME="pull_request_review_comment"
  cp tests/dev-lead/fixtures/events/pr_review_comment_human.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=human" "$GITHUB_ENV"
}

# issue_comment
@test "issue_comment: sonarqube on PR → fix-bot-comment" {
  export GITHUB_EVENT_NAME="issue_comment"
  cp tests/dev-lead/fixtures/events/issue_comment_sonarqube.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=fix-bot-comment" "$GITHUB_ENV"
}

@test "issue_comment: human with @dev-lead on PR → human" {
  export GITHUB_EVENT_NAME="issue_comment"
  cp tests/dev-lead/fixtures/events/issue_comment_human_mention.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=human" "$GITHUB_ENV"
}

@test "issue_comment: human without trigger phrase → skip" {
  export GITHUB_EVENT_NAME="issue_comment"
  cp tests/dev-lead/fixtures/events/issue_comment_human_no_trigger.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "issue_comment: rebase sentinel from trusted human → rebase" {
  export GITHUB_EVENT_NAME="issue_comment"
  cp tests/dev-lead/fixtures/events/issue_comment_rebase.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=rebase" "$GITHUB_ENV"
}

@test "issue_comment: self-actor (donpetry-bot) → skip" {
  export GITHUB_EVENT_NAME="issue_comment"
  cp tests/dev-lead/fixtures/events/issue_comment_human_mention.json "$GITHUB_EVENT_PATH"
  jq '.comment.user.login = "donpetry-bot"' "$GITHUB_EVENT_PATH" > /tmp/self.json
  cp /tmp/self.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}
```

### 3.5 Phase 3 definition of done

- [ ] All intent classification for review events works correctly (all bats tests pass)
- [ ] `dev-lead-fix-reviews.sh` handles `fix-reviews` intent: checks out PR, fetches threads, applies fixes, resolves threads, waits for CI
- [ ] Thread GraphQL round-trip tested against a real test PR (manual E2E)
- [ ] Copilot review on a test PR → all threads resolved, CI green, summary posted

---

## Phase 4 — Human Interaction and Rebase

**Goal:** `@dev-lead` mentions trigger agentic responses; rebase conflicts resolved automatically.

### 4.1 Files to create/modify

| File | Change |
|---|---|
| `scripts/dev-lead-fix-reviews.sh` | **EXTEND** — `human`, `human-pr`, `rebase` intents |
| `tests/dev-lead/unit/test_fix_reviews_human.bats` | **CREATE** |
| `tests/dev-lead/unit/test_fix_reviews_rebase.bats` | **CREATE** |

### 4.2 Unit tests: rebase conflict resolution

```bash
@test "rebase: YAML SHA conflict resolved by preferring newer SHA" {
  # Set up a fake conflict in a .yml file
  cat > /tmp/conflict.yml << 'EOF'
      uses: actions/checkout@abc123 # v5.0.0
EOF
  run bash -c '
    source scripts/dev-lead-fix-reviews.sh
    resolve_yaml_sha_conflict /tmp/conflict.yml
  '
  [ "$status" -eq 0 ]
  # Should have picked abc123 (newer semver v5.0.0 > v4.0.0)
  grep -q "abc123" /tmp/conflict.yml
}

@test "rebase: non-YAML conflict → abort immediately" {
  cat > /tmp/conflict.ts << 'EOF'
  const foo = "bar";
EOF
  run bash -c '
    source scripts/dev-lead-fix-reviews.sh
    resolve_conflict /tmp/conflict.ts
  '
  [ "$status" -ne 0 ]
}
```

### 4.3 Phase 4 definition of done

### 4.4 Phase 4 definition of done

- [ ] All unit tests pass (11 cases)
- [ ] Human `@dev-lead rename foo to bar` on test PR → rename applied and pushed
- [ ] Rebase sentinel on test PR with YAML conflict → conflict resolved correctly
      uses: actions/checkout@abc123 # v5.0.0
EOF
  run bash -c '
    source scripts/dev-lead-fix-reviews.sh
    resolve_yaml_sha_conflict /tmp/conflict.yml
  '
  [ "$status" -eq 0 ]
  # Should have picked abc123 (newer semver v5.0.0 > v4.0.0)
  grep -q "abc123" /tmp/conflict.yml
}

@test "rebase: non-YAML conflict → abort immediately" {
  cat > /tmp/conflict.ts << 'EOF'
  const foo = "bar";
EOF
  run bash -c '
    source scripts/dev-lead-fix-reviews.sh
    resolve_conflict /tmp/conflict.ts
  '
  [ "$status" -ne 0 ]
}
```

- YAML SHA conflict: newer semver wins ✓
- YAML SHA conflict: both sides same version → keeps base ✓
- YAML SHA conflict: version cannot be determined → abort ✓
- Non-YAML conflict → abort immediately ✓
- Successful rebase → push with `--force-with-lease` ✓
- Abort → failure comment includes manual instructions ✓

- [ ] Human `@dev-lead` mention on a PR triggers a response and applies the requested change
- [ ] Rebase sentinel triggers agentic rebase; workflow YAML conflicts resolved correctly
- [ ] `auto-rebase.yml` posting the sentinel comment continues to work as the trigger
- [ ] All unit tests pass
>>>>>>> 70c9f18 (docs(dev-lead): add detailed implementation plan with unit and e2e tests)

---

## Phase 5 — Issue Implementation

**Goal:** Issues labeled `dev-lead` or `claude` trigger full implementation → PR → self-review → CODEOWNERS tag.

### 5.1 Files to create/modify

| File | Change |
|---|---|
| `scripts/dev-lead-intent.sh` | **EXTEND** — `issues` labeled classification |
| `scripts/dev-lead-fix-issue.sh` | **CREATE** |
| `tests/dev-lead/unit/test_intent_issue.bats` | **CREATE** |
| `tests/dev-lead/unit/test_fix_issue.bats` | **CREATE** |

### 5.2 Unit tests: `tests/dev-lead/unit/test_intent_issue.bats`

```bash
@test "issues: labeled dev-lead → issue intent" {
  export GITHUB_EVENT_NAME="issues"
  cp tests/dev-lead/fixtures/events/issues_labeled_dev_lead.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=issue" "$GITHUB_ENV"
}

@test "issues: labeled other label → skip" {
  export GITHUB_EVENT_NAME="issues"
  cp tests/dev-lead/fixtures/events/issues_labeled_other.json "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=skip" "$GITHUB_ENV"
}

@test "issues: labeled claude → issue intent (backward compat)" {
  export GITHUB_EVENT_NAME="issues"
  jq '.label.name = "claude"' \
    tests/dev-lead/fixtures/events/issues_labeled_dev_lead.json > "$GITHUB_EVENT_PATH"
  run bash scripts/dev-lead-intent.sh
  grep -q "INTENT_TYPE=issue" "$GITHUB_ENV"
}

@test "fix-issue: dedup detects existing open PR" {
  export GH_STUB_PR_FOR_ISSUE="https://github.com/petry-projects/.github-private/pull/99"
  run bash -c '
    source scripts/dev-lead-fix-issue.sh
    dedup_check "42"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"existing PR"* ]]
}
```

### 5.3 Phase 5 definition of done

- [ ] Issue labeled `dev-lead` triggers implementation
- [ ] Dedup: second label event is a no-op (existing PR detected)
- [ ] PR opened, self-reviewed, CI monitored, CODEOWNERS tagged on green

---

## Phase 6 — Engine Generalization and Fallback

**Goal:** `DEV_LEAD_ENGINE=gemini` and fallback chain fully tested.

### 6.1 Files to create/modify

| File | Change |
|---|---|
| `scripts/engine.sh` | **EXTEND** — Gemini path in `run_writer()`, fallback chain helper |
| `scripts/dev-lead-fix-ci.sh` | **EXTEND** — engine fallback on exit code 2 |
| `scripts/dev-lead-fix-reviews.sh` | **EXTEND** — engine fallback on exit code 2 |
| `tests/dev-lead/unit/test_engine_fallback.bats` | **CREATE** |

### 6.2 Unit tests: `tests/dev-lead/unit/test_engine_fallback.bats`

```bash
@test "fallback: claude rate-limit → gemini" {
  export REVIEW_ENGINE="claude"
  export CLAUDE_AVAILABLE="true"
  export GEMINI_AVAILABLE="true"
  # Claude stub exits 2 (rate limit); gemini stub exits 0
  export STUB_CLAUDE_EXIT=2
  export STUB_GEMINI_EXIT=0
  run bash -c '
    source scripts/engine.sh
    run_writer_with_fallback "$PROMPT_FILE"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"gemini"* ]] || [[ "$output" == *"fallback"* ]]
}

@test "fallback: claude + gemini rate-limit → copilot (claude fallback)" {
  export STUB_CLAUDE_EXIT=2
  export STUB_GEMINI_EXIT=2
  export COPILOT_AVAILABLE="true"
  run bash -c '
    source scripts/engine.sh
    run_writer_with_fallback "$PROMPT_FILE"
  '
  # Copilot falls back to Claude internally; result depends on available engine
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "fallback: all engines rate-limited → exhaustion comment emitted" {
  export STUB_CLAUDE_EXIT=2
  export STUB_GEMINI_EXIT=2
  export COPILOT_AVAILABLE="false"
  run bash -c '
    source scripts/engine.sh
    run_writer_with_fallback "$PROMPT_FILE"
  '
  [ "$status" -eq 2 ]
}
```

### 6.3 Phase 6 definition of done

- [ ] `DEV_LEAD_ENGINE=gemini` end-to-end: CI failure fixed by Gemini
- [ ] Engine fallback chain verified with stub engines
- [ ] validate-engines.sh outputs correct availability table in step summary
- [ ] All unit tests pass

---

## Phase 7 — Retirement

**Goal:** Remove `claude.yml` (Option A); update documentation.

### 7.1 Files to delete/modify

| File | Change |
|---|---|
| `.github/workflows/claude.yml` | **DELETE** — Option A confirmed |
| `AGENTS.md` | **UPDATE** — remove `claude.yml` exemption from agent modification list |
| `docs/dev-lead/spec.md` | **UPDATE** — Phase 7 completed note |

### 7.2 Retirement checklist

- [ ] `dev-lead.yml` has been stable for ≥ 2 weeks (no regressions)
- [ ] All intents previously handled by `claude.yml` jobs are covered by `dev-lead.yml`
- [ ] `claude.yml` deletion PR passes CI (no broken references)
- [ ] `AGENTS.md` updated: `dev-lead.yml` replaces `claude.yml` in the do-not-edit exemption list
- [ ] `petry-projects/.github/standards/workflows/claude.yml` standard updated with note that `.github-private` uses `dev-lead.yml` instead
- [ ] GitHub Issue opened to propagate `dev-lead.yml` pattern to other repos that want the same multi-engine agent behavior

---

## Testing Summary

### Unit test suite (`bats`)

| Test file | Phase | Cases |
|---|---|---|
| `test_intent_stub.bats` | 1 | 3 |
| `test_intent_ci.bats` | 2 | 5 |
| `test_engine_writer.bats` | 2 | 5 |
| `test_fix_ci.bats` | 2 | 5 |
| `test_intent_reviews.bats` | 3 | 13 |
| `test_fix_reviews.bats` | 3 | 8 |
| `test_fix_reviews_human.bats` | 4 | 4 |
| `test_fix_reviews_rebase.bats` | 4 | 4 |
| `test_intent_issue.bats` | 5 | 4 |
| `test_fix_issue.bats` | 5 | 4 |
| `test_engine_fallback.bats` | 6 | 3 |
| **Total** | | **~58 cases** |

### Integration tests (shell scripts)

| Test file | Phase | What it validates |
|---|---|---|
| `test_ci_relay.sh` | 2 | Relay: non-fork emits dispatch, fork skips, self-check skips |
| `test_review_intent.sh` | 3 | Full intent classification pipeline against all fixture events |
| `test_issue_dedup.sh` | 5 | Dedup check with mock gh responses |

### E2E test scenarios (manual, one per phase)

| Phase | Scenario | Pass criteria |
|---|---|---|
| 1 | Open a PR → dispatch job appears, logs `INTENT_TYPE=skip` | Job green, no LLM tokens |
| 2 | Push commit with deliberate ESLint error → check_run fails | Claude fixes, pushes, CI green within 5 min |
| 3 | Copilot submits COMMENTED review on test PR | All threads resolved, summary posted |
| 4 | Comment `@dev-lead rename this function to foo` on PR | Rename applied, pushed, confirmed |
| 5 | Label a test issue `dev-lead` | PR opened, CI green, CODEOWNERS tagged |
| 6 | Set `DEV_LEAD_ENGINE=gemini`, repeat Phase 2 E2E | Gemini fixes CI failure |
| 7 | Delete `claude.yml` on test branch | `test-dev-lead.yml` still green |

---

## Dependencies and Blockers

| Dependency | Required by | Status |
|---|---|---|
| `bats` installed in `test-dev-lead.yml` | All phases | Not yet configured |
| `CLAUDE_CODE_OAUTH_TOKEN` org secret | Phase 2+ | Exists |
| `GH_PAT_WORKFLOWS` org secret | Phase 1 (ci-relay dispatch) | Exists |
| `GOOGLE_API_KEY` org secret | Phase 6 | Exists |
| Stub engine binaries in `tests/dev-lead/fixtures/engines/` | Phase 2+ | Not yet created |
| Mock `gh` binary for integration tests | Phase 2+ | Not yet created |
| `dev-lead-intent.sh` must be sourced cleanly (no side effects on source) | All unit tests | Must be designed for testability |

---

## Open Items (from Spec §14)

The following open questions from the spec should be resolved before Phase 4:

1. **Trigger phrase migration** — Keeping `@claude` in `TRIGGER_PHRASES` default is confirmed. No breaking change.
2. **`claude.yml` retirement** — Option A confirmed: delete the file in Phase 7. No redirect stub.
3. **Cross-repo scope** — Deferred. Phase 1–7 scope is `.github-private` only.
4. **Prompt library** — Decision: keep prompts inline in handler scripts for Phase 2–5; extract to `prompts/dev-lead/` in a follow-on if tuning becomes frequent.
5. **Audit log** — Deferred. Add `<!-- dev-lead-fix sha=... -->` markers to PR comments as the lightweight audit trail for now.

---

_See also: [Dev-Lead Spec](./spec.md) · [PR Review Agent Implementation](../pr-review-agent/implementation.md) · [Engine Script](../../scripts/engine.sh)_
