#!/usr/bin/env bash
# Deterministic PR safety checks for the review cascade (issue #305).
#
# Re-implements the mechanical half of PR #131's 7 safety checks against the
# CURRENT architecture. The design principle is determinism-first: every check
# that can be pattern-matched is computed here in shell so it is reproducible and
# unit-testable, rather than left to the LLM to "eyeball". The genuinely semantic
# checks (critical-path tracing, duplication adjudication, dependency-risk
# narrative) live in prompts/deep-review.md — this lib only does the mechanical
# work and hands the LLM a pre-computed verdict.
#
# Like scripts/lib/downstream-impact.sh, this lib performs NO network / `gh` I/O:
# it takes PR_METADATA (JSON from `gh pr view`) and PR_DIFF (a unified diff) and
# emits a structured SAFETY_CHECKS block. That block carries two hard-stop flags
# — CI_WEAKENING_DETECTED and PROMPT_INJECTION_DETECTED — plus the large-PR
# verdict, description-missing count, and dependency-risk findings.
#
# The block is inlined into the Tier 1 (triage) prompt by review-one-pr.sh via
# safety_checks_triage_section (triage has NO tools, so verdicts must be inlined
# as text — mirroring ADVISORY_BOT_FEEDBACK / DOWNSTREAM_IMPACT), and written to
# SAFETY_CHECKS_FILE for Tier 2/3 to read.

# ---------------------------------------------------------------------------
# Check 1 — CI weakening (deterministic, hard-stop)
# ---------------------------------------------------------------------------
# Scans a unified diff for signals that test/CI coverage is being weakened on
# ADDED (+) lines: skip/disable markers, `if: false`, `continue-on-error: true`,
# and lowered numeric coverage/CI thresholds (a removed threshold value paired
# with a smaller added value for the same key).
# Prints one finding line per signal: "<file>:<line>\t<message>". Empty => none.
sc_ci_weakening() {
  local diff="${1:-}"
  printf '%s' "$diff" | awk '
    function report(msg){ printf "%s:%d\t%s\n", f, line, msg }
    function num(s){ if (match(s, /[0-9]+(\.[0-9]+)?/)) return substr(s, RSTART, RLENGTH)+0; return -1 }
    function thkey(s,  l, k){ l=tolower(s); if (match(l, /coverage|fail[_-]under|threshold|min[_-]?cov/)) { k=substr(l, RSTART, RLENGTH); gsub(/[_-]/, "", k); return k } return "" }
    /^\+\+\+ /{ f=$0; sub(/^\+\+\+ [ab]\//, "", f); sub(/\t.*/, "", f); line=0; in_hunk=0; delete rem
      iswf=(f~/^\.github\/workflows\/.*\.(yml|yaml)$/) ? 1 : 0; next }
    /^@@/ { m=$0; sub(/^@@ -[0-9,]+ \+/, "", m); sub(/[, ].*/, "", m); line=m+0; in_hunk=1; next }
    !in_hunk { next }
    /^-/ && !/^---/ {
      c=substr($0,2); k=thkey(c)
      if (k != "") { v=num(c); if (v >= 0) rem[k]=v }
      next
    }
    /^\+/ && !/^\+\+\+/ {
      c=substr($0,2)
      if (c ~ /(it|test|describe|context)\.skip|\.skip[[:space:]]*\(|\.only[[:space:]]*\(|((^|[^a-zA-Z0-9_])xit([^a-zA-Z0-9_]|$))|((^|[^a-zA-Z0-9_])xdescribe([^a-zA-Z0-9_]|$))|\.todo[[:space:]]*\(|@Ignore|@Disabled|pytest\.mark\.skip|unittest\.skip|t\.Skip[[:space:]]*\(/)
        report("test skip/disable marker added: " c)
      if (c ~ /if:[[:space:]]*false([[:space:]]|$)/)
        report("step disabled (if: false): " c)
      if (c ~ /continue-on-error:[[:space:]]*true/)
        report("failure suppressed (continue-on-error: true): " c)
      if (iswf && c ~ /^[[:space:]]*#[[:space:]]*-[[:space:]]+(run|uses):/)
        report("commented-out CI step: " c)
      k=thkey(c)
      if (k != "" && (k in rem)) { v=num(c); if (v >= 0 && v < rem[k]) report("lowered numeric threshold (" rem[k] " -> " v "): " c) }
      line++
      next
    }
    /^ / { line++; next }
  '
}

# ---------------------------------------------------------------------------
# Check 2 — Prompt injection in workflows (deterministic, hard-stop)
# ---------------------------------------------------------------------------
# Scans changed `.github/workflows/*.yml` for the classic injection smells:
# user-controlled `github.event.*` fields (body/title/label/ref/...) interpolated
# into a step, `pull_request_target`, and over-broad `write-all` token perms.
# Only workflow files are considered. Prints "<file>:<line>\t<message>" per hit.
sc_prompt_injection() {
  local diff="${1:-}"
  printf '%s' "$diff" | awk '
    function report(msg){ printf "%s:%d\t%s\n", f, line, msg }
    function get_indent(s,   i){ i=0; while(substr(s,i+1,1)==" ") i++; return i }
    function update_run_state(raw,   ind, stripped, val) {
      ind=get_indent(raw)
      stripped=raw; gsub(/^[[:space:]]+/,"",stripped)
      if (in_run) {
        if (run_inline) { in_run=0; run_ind=-1; run_inline=0 }
        else if (stripped != "" && ind <= run_ind) { in_run=0; run_ind=-1 }
      }
      if (stripped ~ /^(-[[:space:]]+)?run:[[:space:]]/) {
        in_run=1; run_ind=ind
        val=stripped; sub(/^(-[[:space:]]+)?run:[[:space:]]*/,"",val)
        run_inline=(val != "" && val != "|" && val != ">") ? 1 : 0
      }
    }
    /^\+\+\+ /{
      f=$0; sub(/^\+\+\+ [ab]\//, "", f); sub(/\t.*/, "", f); line=0; in_hunk=0
      iswf=(f~/^\.github\/workflows\/.*\.(yml|yaml)$/) ? 1 : 0
      in_run=0; run_ind=-1; run_inline=0
      next
    }
    /^@@/ { m=$0; sub(/^@@ -[0-9,]+ \+/, "", m); sub(/[, ].*/, "", m); line=m+0; in_hunk=1; next }
    !in_hunk { next }
    /^-/ && !/^---/ { next }
    /^\+/ && !/^\+\+\+/ {
      c=substr($0,2)
      if (iswf) {
        update_run_state(c)
        if (in_run && (c ~ /github\.event\.[a-zA-Z0-9_.]*(body|title|label|email|login|user\.name)|github\.event\.[a-zA-Z0-9_.]*head\.ref|github\.head_ref/))
          report("untrusted github.event.* field interpolated into a run step: " c)
        if (c ~ /pull_request_target/)
          report("pull_request_target trigger (PR-head code runs with write token): " c)
        if (c ~ /write-all/)
          report("over-broad token permissions (write-all): " c)
      }
      line++
      next
    }
    /^ / {
      if (iswf && in_hunk) update_run_state(substr($0,2))
      line++
      next
    }
  '
}

# ---------------------------------------------------------------------------
# Check 7 (deterministic half) — Dependency risk parse
# ---------------------------------------------------------------------------
# Scans added lines in lockfiles/manifests for unpinned version ranges
# (`^`, `~`, `>=`, `latest`, bare `*`). The LLM narrative / CVE interpretation
# lives in prompts/deep-review.md; this only flags the mechanical signal.
# Prints "<file>:<line>\t<message>" per unpinned dependency added.
sc_dependency_risk() {
  local diff="${1:-}"
  printf '%s' "$diff" | awk '
    function report(msg){ printf "%s:%d\t%s\n", f, line, msg }
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^\+\+\+ /{
      f=$0; sub(/^\+\+\+ [ab]\//, "", f); sub(/\t.*/, "", f); line=0; in_hunk=0
      b=f; sub(/^.*\//, "", b)
      ismanifest = (b ~ /^(package\.json|composer\.json|Cargo\.toml|go\.mod|Gemfile|Pipfile|pom\.xml|build\.gradle)$/ || b ~ /^requirements.*\.txt$/) ? 1 : 0
      next
    }
    /^@@/ { m=$0; sub(/^@@ -[0-9,]+ \+/, "", m); sub(/[, ].*/, "", m); line=m+0; in_hunk=1; next }
    !in_hunk { next }
    /^-/ && !/^---/ { next }
    /^\+/ && !/^\+\+\+/ {
      c=substr($0,2)
      if (ismanifest) {
        if (c ~ /(\^|~>?|>=?)[[:space:]]*[0-9]/ || c ~ /"[[:space:]]*latest[[:space:]]*"/ || c ~ /[=:][[:space:]]*"\*"/ || c ~ /[=:][[:space:]]*latest([[:space:]]|$)/)
          report("unpinned dependency range added: " trim(c))
      }
      line++
      next
    }
    /^ / { line++; next }
  '
}

# ---------------------------------------------------------------------------
# Check 3 — Large-PR gate (deterministic, from metadata)
# ---------------------------------------------------------------------------
# Numeric gate from PR_METADATA: a PR over the file OR line threshold WITHOUT an
# implementation-plan / breakdown section in its body is gated (escalate).
# Prints one line: "true|<reason>" (gated) or "false|<reason>".
sc_large_pr() {
  local meta="${1:-}"
  local max_files="${LARGE_PR_MAX_FILES:-50}"
  local max_lines="${LARGE_PR_MAX_LINES:-1000}"
  local files add del body
  files=$(jq -r '.changedFiles? // 0' <<< "$meta" 2>/dev/null || echo 0)
  add=$(jq -r '.additions? // 0' <<< "$meta" 2>/dev/null || echo 0)
  del=$(jq -r '.deletions? // 0' <<< "$meta" 2>/dev/null || echo 0)
  body=$(jq -r '.body? // ""' <<< "$meta" 2>/dev/null || echo "")
  [[ "$files" =~ ^[0-9]+$ ]] || files=0
  [[ "$add" =~ ^[0-9]+$ ]] || add=0
  [[ "$del" =~ ^[0-9]+$ ]] || del=0
  local churn=$((add + del))

  local is_large=0
  if [ "$files" -ge "$max_files" ] || [ "$churn" -ge "$max_lines" ]; then
    is_large=1
  fi

  local has_plan=0
  if grep -qiE '^#{1,6}[[:space:]].*(implementation|breakdown|approach|design|steps|plan)|implementation (plan|breakdown)|## *plan' <<< "$body"; then
    has_plan=1
  fi

  if [ "$is_large" -eq 1 ] && [ "$has_plan" -eq 0 ]; then
    printf 'true|%s changed files, %s changed lines, no implementation-plan section in description\n' "$files" "$churn"
  else
    printf 'false|%s changed files, %s changed lines, plan_section=%s\n' "$files" "$churn" "$([ "$has_plan" -eq 1 ] && echo present || echo absent)"
  fi
}

# ---------------------------------------------------------------------------
# Check 4 — Description quality (deterministic, from metadata)
# ---------------------------------------------------------------------------
# Counts how many of the 5 required description sections are missing from the PR
# body: problem statement, risk category, test plan, rollback, monitoring.
# Prints one line: "<missing_count>|<comma-separated missing section keys>".
sc_description_missing() {
  local meta="${1:-}"
  local body
  body=$(jq -r '.body? // ""' <<< "$meta" 2>/dev/null || echo "")

  local missing=0 csv=""
  _sc_desc_has() { grep -qiE "$1" <<< "$body"; }
  local -a keys=(problem risk test-plan rollback monitoring)
  local -a pats=(
    'problem|background|motivation|context|summary|## *what'
    'risk'
    'test plan|testing|tests?:|how.*test|test coverage|verif'
    'rollback|revert|back ?out'
    'monitor|observ|metric|alert|dashboard|telemetry'
  )
  local i
  for i in "${!keys[@]}"; do
    if ! _sc_desc_has "${pats[$i]}"; then
      missing=$((missing + 1))
      csv="${csv:+$csv,}${keys[$i]}"
    fi
  done
  unset -f _sc_desc_has
  printf '%s|%s\n' "$missing" "$csv"
}

# ---------------------------------------------------------------------------
# Aggregate — compute_safety_checks emits the structured SAFETY_CHECKS block
# ---------------------------------------------------------------------------
# compute_safety_checks <pr_metadata_json> <pr_diff>
#   Composes every deterministic check into a single block on stdout. Always
#   exits 0; degrades to a well-formed block on malformed metadata / empty diff.
compute_safety_checks() {
  local meta="${1:-}" diff="${2:-}"

  local ci pi dep large desc
  ci=$(sc_ci_weakening "$diff" || true)
  pi=$(sc_prompt_injection "$diff" || true)
  dep=$(sc_dependency_risk "$diff" || true)
  large=$(sc_large_pr "$meta" || true)
  desc=$(sc_description_missing "$meta" || true)

  local ci_flag="false" pi_flag="false"
  [ -n "$ci" ] && ci_flag="true"
  [ -n "$pi" ] && pi_flag="true"

  local large_bool="${large%%|*}"
  local large_reason="${large#*|}"
  [ -n "$large_bool" ] || large_bool="false"
  local desc_count="${desc%%|*}"
  local desc_csv="${desc#*|}"
  [[ "$desc_count" =~ ^[0-9]+$ ]] || desc_count=0

  local dep_count=0
  [ -n "$dep" ] && dep_count=$(grep -c . <<< "$dep" || true)
  [[ "$dep_count" =~ ^[0-9]+$ ]] || dep_count=0

  # Assemble the human/LLM-readable findings list.
  local findings=""
  local l
  if [ -n "$ci" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      findings+="  - [blocking] ci-weakening: ${l#*$'\t'} (${l%%$'\t'*})"$'\n'
    done <<< "$ci"
  fi
  if [ -n "$pi" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      findings+="  - [blocking] prompt-injection: ${l#*$'\t'} (${l%%$'\t'*})"$'\n'
    done <<< "$pi"
  fi
  if [ "$large_bool" = "true" ]; then
    findings+="  - [escalate] large-pr: $large_reason"$'\n'
  fi
  if [ "$desc_count" -ge 3 ]; then
    findings+="  - [escalate] description-quality: $desc_count of 5 required sections missing ($desc_csv)"$'\n'
  fi
  if [ -n "$dep" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      findings+="  - [warn] dependency-risk: ${l#*$'\t'} (${l%%$'\t'*})"$'\n'
    done <<< "$dep"
  fi
  [ -n "$findings" ] || findings="  (none)"$'\n'

  printf 'CI_WEAKENING_DETECTED: %s\n' "$ci_flag"
  printf 'PROMPT_INJECTION_DETECTED: %s\n' "$pi_flag"
  printf 'LARGE_PR: %s\n' "$large_bool"
  printf 'DESCRIPTION_MISSING: %s\n' "$desc_count"
  printf 'DEPENDENCY_RISK: %s unpinned\n' "$dep_count"
  printf '\nFindings:\n%s' "$findings"
}

# assemble_safety_checks <pr_metadata_json> <pr_diff> [out_file]
#   Writes the SAFETY_CHECKS block to <out_file> and exports its path as
#   SAFETY_CHECKS_FILE for the deep/audit tiers (mirroring DOWNSTREAM_IMPACT_FILE
#   / ADVISORY_BOT_FEEDBACK_FILE). Always exits 0.
assemble_safety_checks() {
  local meta="${1:-}" diff="${2:-}"
  local out_file="${3:-${SAFETY_CHECKS_FILE:-/tmp/cascade/safety-checks.txt}}"
  mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
  compute_safety_checks "$meta" "$diff" > "$out_file" || true
  export SAFETY_CHECKS_FILE="$out_file"
  return 0
}

# safety_checks_triage_section [sc_file]
#   Emits the SAFETY_CHECKS section that review-one-pr.sh inlines into the triage
#   prompt. Triage has NO tools, so the pre-computed verdicts must be inlined as
#   text (mirroring ADVISORY_BOT_FEEDBACK / DOWNSTREAM_IMPACT).
#
#   Gating: these checks are safety-critical, so the flag DEFAULTS ON. The
#   section is emitted unless SAFETY_CHECKS_ENABLED is explicitly "false", in
#   which case it emits NOTHING so the triage prompt is byte-identical to
#   pre-feature behavior (rollback + holdout-eval stability).
safety_checks_triage_section() {
  [ "${SAFETY_CHECKS_ENABLED:-true}" = "true" ] || return 0
  local sc_file="${1:-${SAFETY_CHECKS_FILE:-}}"
  local block=""
  if [ -n "$sc_file" ] && [ -f "$sc_file" ]; then
    block=$(cat "$sc_file")
  fi
  printf '\nSAFETY_CHECKS (deterministic, pre-computed — you have NO tools; CONSUME these verdicts, do not re-derive them. If CI_WEAKENING_DETECTED or PROMPT_INJECTION_DETECTED is true it is a HARD STOP: force "escalate": true and NEVER approve. LARGE_PR true or DESCRIPTION_MISSING >= 3 also force escalate):\n%s\n' "$block"
}
