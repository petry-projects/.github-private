#!/usr/bin/env bash
set -euo pipefail
# bootstrap-new-repo.sh — one-shot, DRY_RUN-aware bootstrap that brings a newly
# created repo to full org compliance by ORCHESTRATING the existing apply-*
# scripts. It reimplements no policy (issue #967, epic #964):
#
#   • repo settings + security/GHAS + secret-scanning push protection come from
#     scripts/apply-repo-settings.sh (which sources scripts/lib/push-protection.sh)
#   • the two sanctioned rulesets — pr-quality + code-quality, each carrying the
#     mandatory bypass actors dependabot-automerge-petry (Integration app) +
#     OrganizationAdmin, both bypass_mode "always" — come from
#     scripts/apply-rulesets.sh reading .github/rulesets/*.json. Required status
#     checks are carried in those ruleset JSONs, not wired here. No legacy/ad-hoc
#     `main` ruleset is created.
#   • the standard label set + CODEOWNERS-team verification are bootstrap data,
#     applied/verified here.
#
# Steps run in sequence and FAIL FAST: if repo settings or rulesets fail, the
# remaining steps are skipped and the script exits non-zero with a FAIL summary.
#
# Usage:
#   bash scripts/bootstrap-new-repo.sh owner/new-repo
#   DRY_RUN=true bash scripts/bootstrap-new-repo.sh owner/new-repo
#
# Env:
#   DRY_RUN          "true" → print intent, make no write calls. Bridged onto
#                    apply-repo-settings.sh's DEV_LEAD_DRY_RUN and
#                    apply-rulesets.sh's DRY_RUN from this single flag.
#   GH_TOKEN         classic PAT with repo + admin scope (apply-repo-settings.sh
#                    rejects OAuth app tokens for the check-suites API).
#   CODEOWNERS_TEAM  expected first CODEOWNERS owner (default @petry-projects/org-leads).
#   ORG              passed through to apply-repo-settings.sh (default petry-projects).
#
# Test seams: APPLY_REPO_SETTINGS / APPLY_RULESETS override the sub-script paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

DRY_RUN="${DRY_RUN:-false}"
CODEOWNERS_TEAM="${CODEOWNERS_TEAM:-@petry-projects/org-leads}"
APPLY_REPO_SETTINGS="${APPLY_REPO_SETTINGS:-${SCRIPT_DIR}/apply-repo-settings.sh}"
APPLY_RULESETS="${APPLY_RULESETS:-${SCRIPT_DIR}/apply-rulesets.sh}"

# Standard org label set every repo carries — the labels the shared automation
# keys on. Format: "name|hex-color|description". Applied idempotently (--force).
readonly -a BOOTSTRAP_LABELS=(
  "needs-human-review|d93f0b|Escalated by automation — a human owner must review"
  "ack-test-deletion|5319e7|Maintainer acknowledgement to allow deleting files under tests/"
  "dependencies|0366d6|Dependency updates (Dependabot)"
  "automerge|0e8a16|Eligible for auto-merge once required checks pass"
)

_is_dry() { [ "$DRY_RUN" = "true" ]; }

# pass_summary <repo>
pass_summary() {
  echo ""
  echo "[bootstrap] ====================================================="
  echo "[bootstrap] PASS — ${1} bootstrapped to org compliance${2:+ (${2})}"
  echo "[bootstrap] ====================================================="
}

# fail_summary <repo> <stage>
fail_summary() {
  echo ""
  echo "[bootstrap] ====================================================="
  echo "[bootstrap] FAIL — ${1}: '${2}' step failed; remaining steps skipped"
  echo "[bootstrap] ====================================================="
}

# step_repo_settings <repo> — repo settings + security/GHAS + push protection.
step_repo_settings() {
  local repo="$1" dev_lead_dry=false
  _is_dry && dev_lead_dry=true
  echo "[bootstrap] (1/4) repo settings + security/GHAS + push protection"
  DEV_LEAD_DRY_RUN="$dev_lead_dry" bash "$APPLY_REPO_SETTINGS" "$repo"
}

# step_rulesets <repo> — apply every codified ruleset (pr-quality, code-quality, …).
step_rulesets() {
  local repo="$1" rulesets_dry=false
  _is_dry && rulesets_dry=true
  echo "[bootstrap] (2/4) sanctioned rulesets (pr-quality + code-quality + …)"
  DRY_RUN="$rulesets_dry" bash "$APPLY_RULESETS" --repo "$repo"
}

# step_labels <repo> — apply the standard label set (best-effort, idempotent).
step_labels() {
  local repo="$1" spec name color desc
  echo "[bootstrap] (3/4) standard label set"
  for spec in "${BOOTSTRAP_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"$spec"
    if _is_dry; then
      echo "  [dry-run] would ensure label '${name}' on ${repo}"
      continue
    fi
    if gh label create "$name" --color "$color" --description "$desc" --force --repo "$repo" >/dev/null 2>&1; then
      echo "  ensured label '${name}'"
    else
      echo "  [warn] could not ensure label '${name}' on ${repo}" >&2
    fi
  done
}

# step_codeowners <repo> — verify CODEOWNERS lists $CODEOWNERS_TEAM first. Best-effort.
step_codeowners() {
  local repo="$1" encoded decoded first_owner
  echo "[bootstrap] (4/4) verify CODEOWNERS team (${CODEOWNERS_TEAM} first owner)"
  if _is_dry; then
    echo "  [dry-run] would verify ${CODEOWNERS_TEAM} is the first CODEOWNERS owner on ${repo}"
    return 0
  fi
  encoded=""
  local path
  for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    encoded="$(gh api "repos/${repo}/contents/${path}" --jq '.content' 2>/dev/null || true)"
    [ -n "$encoded" ] && [ "$encoded" != "null" ] && break
    encoded=""
  done
  if [ -z "$encoded" ]; then
    echo "  [warn] CODEOWNERS not found on ${repo} — cannot verify team ownership" >&2
    return 0
  fi
  decoded="$(printf '%s' "$encoded" | base64 -d 2>/dev/null || true)"
  # First owner on the first non-comment, non-blank rule line.
  first_owner="$(printf '%s\n' "$decoded" \
    | sed 's/#.*//' \
    | awk 'NF >= 2 {print $2; exit}')"
  if [ "$first_owner" = "$CODEOWNERS_TEAM" ]; then
    echo "  verified: ${CODEOWNERS_TEAM} is the first CODEOWNERS owner"
  else
    echo "  [warn] CODEOWNERS first owner is '${first_owner:-<none>}', expected ${CODEOWNERS_TEAM}" >&2
  fi
}

main() {
  local repo="${1:-}"
  if [ -z "$repo" ]; then
    echo "::error::usage: $0 owner/new-repo   (DRY_RUN=true for a no-write preview)" >&2
    return 2
  fi

  echo "[bootstrap] repo=${repo} dry_run=${DRY_RUN}"

  if ! step_repo_settings "$repo"; then fail_summary "$repo" "repo-settings"; return 1; fi
  if ! step_rulesets "$repo"; then fail_summary "$repo" "rulesets"; return 1; fi
  if ! step_labels "$repo"; then fail_summary "$repo" "labels"; return 1; fi
  if ! step_codeowners "$repo"; then fail_summary "$repo" "codeowners"; return 1; fi

  pass_summary "$repo" "$([ "$DRY_RUN" = "true" ] && echo "dry-run")"
}

# Source-guard: tests source this to exercise individual step_* helpers.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
