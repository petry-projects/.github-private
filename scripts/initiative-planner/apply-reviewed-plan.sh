#!/usr/bin/env bash
# apply-reviewed-plan.sh — apply a maintainer-REVIEWED plan.json WITHOUT re-planning.
#
# The plan/apply split (#604): a dry-run uploads an authoritative plan.json
# artifact; a maintainer reviews (optionally hand-edits) it; then the apply run
# is pointed at THAT artifact instead of asking the LLM to plan again. This
# script is the apply-side handoff — it never invokes the BMAD Scrum Master.
# What the maintainer reviewed is what materializes.
#
# It does exactly two things, in order:
#   1. Re-validate the supplied (possibly human-edited) plan with validate-plan.py
#      — a hand-edit could have broken the schema or the DAG, so we never apply
#      an unvalidated artifact.
#   2. Hand it to apply-plan.sh, which owns all materialization (incl. the
#      blocking-open-questions gate, the idempotency/supersede guard, and the
#      `initiative:auto` invariant). DRY_RUN is honored throughout.
#
# Env (PLAN_PATH consumed here; the rest are passed straight through to
# apply-plan.sh — see its header): PLAN_PATH (required), REPO, DISCUSSION_NUMBER,
# DISCUSSION_NODE_ID, FORCE_REPLAN, DRY_RUN / DRY_RUN_LOG.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLAN_PATH="${PLAN_PATH:?PLAN_PATH required (path to the reviewed plan.json)}"
[ -s "$PLAN_PATH" ] || { echo "::error::reviewed plan '$PLAN_PATH' missing or empty" >&2; exit 1; }

echo "==> applying reviewed plan (no re-plan): $PLAN_PATH"

# Re-validate before applying — a reviewed artifact may have been hand-edited.
python3 "$SCRIPT_DIR/validate-plan.py" "$PLAN_PATH"

# Materialize. apply-plan.sh inherits PLAN_PATH and the rest from the environment.
exec bash "$SCRIPT_DIR/apply-plan.sh"
