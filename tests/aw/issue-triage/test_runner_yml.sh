#!/usr/bin/env bash
# tests/aw/issue-triage/test_runner_yml.sh
#
# Structural regression tests for .github/workflows/issue-triage-runner.yml.
# Guards against the failure mode reported in issue #492: the triage job was
# referencing an external action (anthropics/claude-code-action/setup@SHA) that
# became unreachable, causing every run to fail at "Set up job" within 5 s.
#
# Run: bash tests/aw/issue-triage/test_runner_yml.sh  (requires python3 + PyYAML)
set -euo pipefail

PASS=0
FAIL=0
ERRORS=""

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}FAIL  $1: $2"$'\n'; printf 'FAIL  %s: %s\n' "$1" "$2"; }

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
readonly REPO_ROOT
RUNNER="${REPO_ROOT}/.github/workflows/issue-triage-runner.yml"
readonly RUNNER

# Ensure python3 and PyYAML are installed
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required to run these tests." >&2
  exit 1
fi

if ! python3 -c "import yaml" &>/dev/null; then
  echo "Error: PyYAML (python3-yaml) is required to run these tests." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: runner YAML file exists
# ---------------------------------------------------------------------------
if [[ -f "$RUNNER" ]]; then
  ok "runner: file exists"
else
  fail "runner: file exists" "issue-triage-runner.yml not found"
  echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Test 2: top-level permissions: {} restricts the default token
# Missing this block leaves the workflow with write-all defaults, which can
# cause job-setup failures when org policies enforce least-privilege tokens.
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
if 'permissions' not in wf:
    sys.exit(1)
if wf['permissions'] != {}:
    sys.exit(1)
PYEOF
  ok "runner: top-level permissions: {} restricts default token"
else
  fail "runner: top-level permissions: {} restricts default token" \
    "workflow must have 'permissions: {}' at top level — its absence leaves the token with write-all defaults"
fi

# ---------------------------------------------------------------------------
# Test 3: triage job has issues:read (not write) — Claude runs in read-only job
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
triage = wf.get('jobs', {}).get('triage', {})
perms = triage.get('permissions', {}) or {}
if perms.get('issues') != 'read':
    sys.exit(1)
PYEOF
  ok "runner: triage job has issues:read (Claude runs in read-only job)"
else
  fail "runner: triage job has issues:read (Claude runs in read-only job)" \
    "triage job must declare 'issues: read' — Claude should not run with write permissions"
fi

# ---------------------------------------------------------------------------
# Test 4: apply job has issues:write (to post labels and comments)
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
apply = wf.get('jobs', {}).get('apply', {})
perms = apply.get('permissions', {}) or {}
if perms.get('issues') != 'write':
    sys.exit(1)
PYEOF
  ok "runner: apply job has issues:write"
else
  fail "runner: apply job has issues:write" \
    "apply job must declare 'issues: write' to add labels and post the triage comment"
fi

# ---------------------------------------------------------------------------
# Test 5: "Install claude CLI" step uses run:, not an external uses: action
# Regression guard for issue #492: the workflow previously used
#   uses: anthropics/claude-code-action/setup@787c5a0ce96a9a6cfb050ea0c8f4c05f2447c251
# which failed at "Set up job" when the action SHA became unreachable.
# A run: step is self-contained and not subject to external action availability.
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
triage_steps = wf.get('jobs', {}).get('triage', {}).get('steps', [])
install_steps = [
    s for s in triage_steps
    if 'claude' in (s.get('name') or '').lower()
    and 'install' in (s.get('name') or '').lower()
]
if not install_steps:
    print("no 'Install claude' step found in triage job", file=sys.stderr)
    sys.exit(1)
for step in install_steps:
    if 'uses' in step:
        print(f"install step uses external action: {step['uses']}", file=sys.stderr)
        sys.exit(1)
    if 'run' not in step:
        print("install step has neither 'run' nor acceptable form", file=sys.stderr)
        sys.exit(1)
PYEOF
  ok "runner: Install claude CLI uses run: (not an external action)"
else
  fail "runner: Install claude CLI uses run: (not an external action)" \
    "Install claude CLI must use 'run:' — a 'uses: <action>@<sha>' step fails at Set-up-job when the SHA is unreachable (issue #492)"
fi

# ---------------------------------------------------------------------------
# Test 6: CLAUDE_CODE_OAUTH_TOKEN is passed to the Claude invocation step
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
triage_steps = wf.get('jobs', {}).get('triage', {}).get('steps', [])
for step in triage_steps:
    env = step.get('env') or {}
    if 'CLAUDE_CODE_OAUTH_TOKEN' in env:
        sys.exit(0)
sys.exit(1)
PYEOF
  ok "runner: CLAUDE_CODE_OAUTH_TOKEN is forwarded to the invocation step"
else
  fail "runner: CLAUDE_CODE_OAUTH_TOKEN is forwarded to the invocation step" \
    "triage job must pass CLAUDE_CODE_OAUTH_TOKEN via 'env:' on the run step"
fi

# ---------------------------------------------------------------------------
# Test 7: apply job uses two-job pattern (needs triage, conditional on skip)
# ---------------------------------------------------------------------------
if python3 - "$RUNNER" <<'PYEOF'; then
import sys, yaml
with open(sys.argv[1]) as f:
    wf = yaml.safe_load(f)
apply = wf.get('jobs', {}).get('apply', {})
needs = apply.get('needs', [])
if isinstance(needs, str):
    needs = [needs]
if 'triage' not in needs:
    print("apply job does not declare 'needs: triage'", file=sys.stderr)
    sys.exit(1)
if_cond = str(apply.get('if', ''))
if 'skip' not in if_cond:
    print(f"apply 'if' condition does not reference 'skip': {if_cond!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
  ok "runner: apply job depends on triage and gates on skip output"
else
  fail "runner: apply job depends on triage and gates on skip output" \
    "apply job must declare 'needs: triage' and an 'if:' condition that checks the skip output"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  printf '%s' "$ERRORS"
  exit 1
fi
