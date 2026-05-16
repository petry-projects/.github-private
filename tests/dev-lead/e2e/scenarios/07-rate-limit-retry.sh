#!/usr/bin/env bash
# tests/dev-lead/e2e/scenarios/07-rate-limit-retry.sh
#
# Scenario: Rate-limit handling and retry infrastructure
#
# Tests:
#   Part A — run_writer captures stdout and maps rate-limit to exit 2
#   Part B — fix-ci posts status=rate-limited (not status=failed) on engine exit 2
#   Part C — rate-limited markers are retriable (not blocked by idempotency check)
#   Part D — rate-limited markers do NOT count toward exhaustion threshold
#   Part E — dev-lead-retry.sh dry-run scan identifies rate-limited PRs
#   Part F — fix-reviews posts rate-limited marker for all five intent types
#
# Approach: Script-based (no real GitHub API needed — uses stub gh binaries).
set -euo pipefail

SCENARIO_NAME="07-rate-limit-retry"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../lib/helpers.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
FIX_CI_SCRIPT="${REPO_ROOT}/scripts/dev-lead-fix-ci.sh"
FIX_REVIEWS_SCRIPT="${REPO_ROOT}/scripts/dev-lead-fix-reviews.sh"
RETRY_SCRIPT="${REPO_ROOT}/scripts/dev-lead-retry.sh"
STUB_ENGINE_DIR=""
GITHUB_ENV_FILE=""

cleanup() {
  rm -f "$GITHUB_ENV_FILE" 2>/dev/null || true
  rm -rf "$STUB_ENGINE_DIR" 2>/dev/null || true
  rm -f /tmp/dev-lead-rate-limit-reset 2>/dev/null || true
}

trap cleanup EXIT

# ── shared stub helpers ────────────────────────────────────────────────────────

make_rate_limited_engine() {
  local bin_dir="$1" message="${2:-rate limit exceeded}"
  for engine in claude gemini copilot; do
    cat > "${bin_dir}/${engine}" << STUB
#!/usr/bin/env bash
echo "${message}"
exit 1
STUB
    chmod +x "${bin_dir}/${engine}"
  done
}

make_empty_gh_comments() {
  local bin_dir="$1"
  cat > "${bin_dir}/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"graphql"*)
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *"issues/"*"/comments"*)
    echo "[]" ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED: $*"; exit 0 ;;
  *"run view"*) echo "stub run log" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "${bin_dir}/gh"
}

run_script_with_stubs() {
  local script="$1"
  shift
  local bin_dir="$1"
  shift
  local output exit_code
  set +e
  output=$(
    PATH="${bin_dir}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    "$@" bash "${script}" 2>&1
  )
  exit_code=$?
  set -e
  printf '%s' "$output"
  return "$exit_code"
}

main() {
  log "=== Scenario: ${SCENARIO_NAME} ==="

  for script in "$FIX_CI_SCRIPT" "$FIX_REVIEWS_SCRIPT" "$RETRY_SCRIPT"; do
    if [ ! -f "$script" ]; then
      err "Script not found: ${script}"
      record_result "${SCENARIO_NAME}" "FAIL" "missing script: ${script}"
      exit 1
    fi
  done

  STUB_ENGINE_DIR=$(mktemp -d)
  GITHUB_ENV_FILE=$(mktemp)
  local all_pass=true

  # ── Part A: fix-ci exits 2 when all engines are rate-limited ─────────────
  log ""
  log "Part A: fix-ci posts status=rate-limited on all-engines-rate-limited"

  make_rate_limited_engine "$STUB_ENGINE_DIR" "You've hit your limit · resets 11:20pm (UTC)"
  make_empty_gh_comments "$STUB_ENGINE_DIR"

  local output_a exit_a
  set +e
  output_a=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PR_NUMBER="42" HEAD_SHA="aaa111bbb222" \
    CHECKS_JSON='[{"name":"test-check","conclusion":"failure","details_url":"","app_slug":"github-actions"}]' \
    REPO="petry-projects/test-repo" REVIEW_ENGINE="claude" DEV_LEAD_DRY_RUN="false" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_CI_SCRIPT}" 2>&1
  )
  exit_a=$?
  set -e

  log "Part A exit code: ${exit_a}"
  echo "${output_a}" | sed 's/^/  /'

  if assert_eq "$exit_a" "2" "${SCENARIO_NAME}(A): fix-ci exits 2 on all-rate-limited"; then
    true
  else
    all_pass=false
  fi

  if echo "${output_a}" | grep -qiE "rate.?limited|rate_limited"; then
    echo "[PASS] ${SCENARIO_NAME}(A): output contains rate-limited language"
  else
    echo "[FAIL] ${SCENARIO_NAME}(A): output missing rate-limited language"
    all_pass=false
  fi

  if ! echo "${output_a}" | grep -q "status=failed"; then
    echo "[PASS] ${SCENARIO_NAME}(A): output does not contain status=failed"
  else
    echo "[FAIL] ${SCENARIO_NAME}(A): output incorrectly contains status=failed"
    all_pass=false
  fi

  # ── Part B: rate-limited marker does not count toward exhaustion ──────────
  log ""
  log "Part B: rate-limited markers do not count toward exhaustion threshold"

  # Return 2 pre-existing rate-limited markers but 0 failed markers
  cat > "${STUB_ENGINE_DIR}/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=aaa111 status=rate-limited -->\nrate limited"},
    {"body":"<!-- dev-lead-fix-ci sha=bbb222 status=rate-limited -->\nrate limited again"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) echo "COMMENT_POSTED: $*"; exit 0 ;;
  *"run view"*) echo "stub log" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "${STUB_ENGINE_DIR}/gh"

  local output_b exit_b
  set +e
  output_b=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PR_NUMBER="42" HEAD_SHA="ccc333new" \
    CHECKS_JSON='[{"name":"test-check","conclusion":"failure","details_url":"","app_slug":"github-actions"}]' \
    REPO="petry-projects/test-repo" REVIEW_ENGINE="claude" DEV_LEAD_DRY_RUN="false" \
    MAX_FAIL_ATTEMPTS="2" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_CI_SCRIPT}" 2>&1
  )
  exit_b=$?
  set -e

  log "Part B exit code: ${exit_b}"
  echo "${output_b}" | sed 's/^/  /'

  if assert_eq "$exit_b" "2" "${SCENARIO_NAME}(B): fix-ci exits 2 (rate-limited, not exhausted)"; then
    true
  else
    all_pass=false
  fi

  if ! echo "${output_b}" | grep -q "status=exhausted"; then
    echo "[PASS] ${SCENARIO_NAME}(B): exhaustion marker NOT posted"
  else
    echo "[FAIL] ${SCENARIO_NAME}(B): exhaustion marker was wrongly posted"
    all_pass=false
  fi

  # ── Part C: rate-limited marker is retriable (idempotency check passes) ───
  log ""
  log "Part C: fix-ci with existing rate-limited marker proceeds (not blocked)"

  cat > "${STUB_ENGINE_DIR}/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"issues/42/comments"*) echo '[
    {"body":"<!-- dev-lead-fix-ci sha=aaa111bbb222 status=rate-limited -->\nrate limited"}
  ]' ;;
  *"pr checkout"*) exit 0 ;;
  *"pr comment"*) exit 0 ;;
  *"run view"*) echo "stub log" ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "${STUB_ENGINE_DIR}/gh"

  local output_c exit_c
  set +e
  output_c=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    PR_NUMBER="42" HEAD_SHA="aaa111bbb222" \
    CHECKS_JSON='[{"name":"test-check","conclusion":"failure","details_url":"","app_slug":"github-actions"}]' \
    REPO="petry-projects/test-repo" REVIEW_ENGINE="claude" DEV_LEAD_DRY_RUN="true" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_CI_SCRIPT}" 2>&1
  )
  exit_c=$?
  set -e

  log "Part C exit code: ${exit_c}"
  echo "${output_c}" | sed 's/^/  /'

  if assert_eq "$exit_c" "0" "${SCENARIO_NAME}(C): fix-ci proceeds with existing rate-limited marker"; then
    true
  else
    all_pass=false
  fi

  if echo "${output_c}" | grep -q "\[dry-run\]"; then
    echo "[PASS] ${SCENARIO_NAME}(C): reached dry-run (not blocked by idempotency)"
  else
    echo "[FAIL] ${SCENARIO_NAME}(C): dry-run not reached — blocked by idempotency"
    all_pass=false
  fi

  # ── Part D: fix-reviews posts rate-limited marker on all-rate-limited ─────
  log ""
  log "Part D: fix-reviews posts rate-limited marker for fix-reviews intent"

  make_rate_limited_engine "$STUB_ENGINE_DIR" "rate limit exceeded"
  make_empty_gh_comments "$STUB_ENGINE_DIR"

  local output_d exit_d
  set +e
  output_d=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    INTENT_TYPE="fix-reviews" \
    PR_NUMBER="54" HEAD_SHA="ddd444eee555" \
    REPO="petry-projects/test-repo" REVIEW_ENGINE="claude" DEV_LEAD_DRY_RUN="false" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_REVIEWS_SCRIPT}" 2>&1
  )
  exit_d=$?
  set -e

  log "Part D exit code: ${exit_d}"
  echo "${output_d}" | sed 's/^/  /'

  if assert_eq "$exit_d" "2" "${SCENARIO_NAME}(D): fix-reviews exits 2 on all-rate-limited"; then
    true
  else
    all_pass=false
  fi

  if echo "${output_d}" | grep -qiE "rate.?limited|rate_limited"; then
    echo "[PASS] ${SCENARIO_NAME}(D): output contains rate-limited language"
  else
    echo "[FAIL] ${SCENARIO_NAME}(D): output missing rate-limited language"
    all_pass=false
  fi

  # ── Part E: fix-reviews human intent posts user acknowledgment ────────────
  log ""
  log "Part E: fix-reviews human intent posts user-visible acknowledgment"

  make_rate_limited_engine "$STUB_ENGINE_DIR" "hit your limit"
  make_empty_gh_comments "$STUB_ENGINE_DIR"

  local output_e exit_e
  set +e
  output_e=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    INTENT_TYPE="human" \
    PR_NUMBER="54" HEAD_SHA="ddd444eee555" ACTOR="donpetry" \
    USER_INSTRUCTION="Please fix the tests" \
    REPO="petry-projects/test-repo" REVIEW_ENGINE="claude" DEV_LEAD_DRY_RUN="false" \
    PROMPTS_DIR="${REPO_ROOT}/prompts/dev-lead" \
    bash "${FIX_REVIEWS_SCRIPT}" 2>&1
  )
  exit_e=$?
  set -e

  log "Part E exit code: ${exit_e}"
  echo "${output_e}" | sed 's/^/  /'

  if assert_eq "$exit_e" "2" "${SCENARIO_NAME}(E): fix-reviews human exits 2 on rate-limited"; then
    true
  else
    all_pass=false
  fi

  # human intent: no auto-retry (context can't be reconstructed); must tell user to re-trigger
  if echo "${output_e}" | grep -qiE "rate-limited|re-mention|re-trigger"; then
    echo "[PASS] ${SCENARIO_NAME}(E): output contains rate-limit/re-trigger language"
  else
    echo "[FAIL] ${SCENARIO_NAME}(E): output missing rate-limit/re-trigger acknowledgment"
    all_pass=false
  fi

  # ── Part F: dev-lead-retry.sh dry-run scans and identifies rate-limited PRs
  log ""
  log "Part F: dev-lead-retry.sh dry-run identifies rate-limited PRs"

  cat > "${STUB_ENGINE_DIR}/gh" << 'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"repo list"*)
    echo '[{"nameWithOwner":"petry-projects/test-repo","isFork":false}]' ;;
  *"pulls?state=open"*)
    echo '[{"number":42,"head":{"sha":"aaa111bbb222"}}]' ;;
  *"pulls/42"*)
    echo '{"number":42,"head":{"sha":"aaa111bbb222"}}' ;;
  *"issues/42/comments"*)
    echo '[
      {"body":"<!-- dev-lead-fix-ci sha=aaa111bbb222 status=rate-limited -->\nrate limited"}
    ]' ;;
  *) echo "{}" ;;
esac
GHEOF
  chmod +x "${STUB_ENGINE_DIR}/gh"

  local output_f exit_f
  set +e
  output_f=$(
    PATH="${STUB_ENGINE_DIR}:${PATH}" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    GITHUB_OUTPUT="/dev/null" \
    TARGET_ORG="petry-projects" \
    DRY_RUN="true" \
    DISPATCH_DELAY_SEC="0" \
    NOW_ISO="2026-05-16T20:00:00Z" \
    bash "${RETRY_SCRIPT}" 2>&1
  )
  exit_f=$?
  set -e

  log "Part F exit code: ${exit_f}"
  echo "${output_f}" | sed 's/^/  /'

  if assert_eq "$exit_f" "0" "${SCENARIO_NAME}(F): retry script exits 0"; then
    true
  else
    all_pass=false
  fi

  if echo "${output_f}" | grep -qi "dry.run\|would dispatch"; then
    echo "[PASS] ${SCENARIO_NAME}(F): retry script identified rate-limited PR and would dispatch"
  else
    echo "[FAIL] ${SCENARIO_NAME}(F): retry script did not identify rate-limited PR"
    all_pass=false
  fi

  # ── Result ─────────────────────────────────────────────────────────────────
  if [ "${all_pass}" = "true" ]; then
    log "[PASS] ${SCENARIO_NAME}: rate-limit retry infrastructure works correctly"
    record_result "${SCENARIO_NAME}" "PASS" \
      "rate-limited-exit2 no-exhaustion-count retriable-idempotency fix-reviews-marker human-ack retry-scan"
    exit 0
  else
    err "[FAIL] ${SCENARIO_NAME}: one or more assertions failed"
    record_result "${SCENARIO_NAME}" "FAIL" \
      "exitA=${exit_a} exitB=${exit_b} exitC=${exit_c} exitD=${exit_d} exitE=${exit_e} exitF=${exit_f}"
    exit 1
  fi
}

main "$@"
