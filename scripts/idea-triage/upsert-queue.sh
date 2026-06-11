#!/usr/bin/env bash
# upsert-queue.sh — find-or-create the single "Idea Promotion Queue" tracking
# issue and replace its body with the freshly-ranked shortlist. Idempotent:
# one issue, rewritten each run. Honors DRY_RUN.
#
# The queue issue is purely informational — a human reads it and decides which
# ideas to bless by adding `idea:approved` to the corresponding Discussion
# (which then fires initiative-planner.yml). Triage never auto-approves.
#
# Env:
#   REPO             owner/repo (required)
#   QUEUE_BODY_PATH  file holding the new issue body markdown (required)
#   QUEUE_TITLE      tracking issue title (default below)
#   QUEUE_LABEL      tracking issue label (default: idea-triage)
#   DRY_RUN / DRY_RUN_LOG  "1" => log instead of mutate
set -euo pipefail

REPO="${REPO:?REPO required}"
QUEUE_BODY_PATH="${QUEUE_BODY_PATH:?QUEUE_BODY_PATH required}"
QUEUE_TITLE="${QUEUE_TITLE:-🧭 Idea Promotion Queue}"
QUEUE_LABEL="${QUEUE_LABEL:-idea-triage}"

[[ -s "$QUEUE_BODY_PATH" ]] || { echo "::error::queue body '$QUEUE_BODY_PATH' missing or empty" >&2; exit 1; }

_is_dry_run() { [[ "${DRY_RUN:-0}" = "1" ]]; }
_dry_log() { printf '%s\n' "$1" >>"${DRY_RUN_LOG:-./dry-run.jsonl}"; }

# Locate an existing open queue issue by exact title (scoped by label).
existing=""
if ! _is_dry_run; then
  if ! existing="$(gh issue list --repo "$REPO" --label "$QUEUE_LABEL" --state open \
    --json number,title --jq \
    --arg t "$QUEUE_TITLE" 'map(select(.title == $t)) | (.[0].number // "")' 2>/dev/null)"; then
    echo "::error::failed to query existing queue issues in ${REPO}" >&2
    exit 1
  fi
fi

if _is_dry_run; then
  _dry_log "$(jq -nc --arg op upsert_queue --arg title "$QUEUE_TITLE" \
    --arg label "$QUEUE_LABEL" --rawfile body "$QUEUE_BODY_PATH" \
    '{op:$op, title:$title, label:$label, body_len:($body|length)}')"
  echo "[dry-run] would upsert queue issue '${QUEUE_TITLE}'"
  exit 0
fi

if [[ -n "$existing" ]]; then
  gh issue edit "$existing" --repo "$REPO" --body-file "$QUEUE_BODY_PATH" >/dev/null
  echo "updated queue issue #${existing}"
else
  # Ensure the label exists (ignore failure if it already does).
  gh label create "$QUEUE_LABEL" --repo "$REPO" \
    --description "Idea-triage tracking issue" --color ededed 2>/dev/null || true
  url="$(gh issue create --repo "$REPO" --title "$QUEUE_TITLE" \
    --label "$QUEUE_LABEL" --body-file "$QUEUE_BODY_PATH")"
  echo "created queue issue ${url}"
fi
