#!/usr/bin/env bash
# apply-plan.sh — materialize a validated initiative plan as a GitHub epic +
# sub-issue DAG. Honors DRY_RUN (see lib/mutations.sh).
#
# What it creates:
#   - 1 epic issue           labelled `initiative`
#   - N story sub-issues      labelled `initiative` (hands_off stories also get
#                             `dev-lead:hands-off` + `initiative:hold`)
#   - native sub-issue links  (each story under the epic)
#   - native blocked_by edges (intra-plan ordering + existing-issue prereqs)
#   - a summary comment back on the source Discussion
#
# What it deliberately does NOT do:
#   - apply `initiative:auto`. The epic is created INERT. A human reviews the
#     real epic/DAG and adds `initiative:auto` to hand it to initiative-driver.
#
# Env:
#   REPO                 owner/repo (required)
#   PLAN_PATH            path to validated plan.json (required)
#   DISCUSSION_NUMBER    source discussion number (for the summary text)
#   DISCUSSION_NODE_ID   source discussion GraphQL node id (optional; if set,
#                        the plan summary is posted back as a comment)
#   DRY_RUN / DRY_RUN_LOG  see lib/mutations.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutations.sh
. "${SCRIPT_DIR}/lib/mutations.sh"

REPO="${REPO:?REPO required}"
PLAN_PATH="${PLAN_PATH:?PLAN_PATH required}"
DISCUSSION_NUMBER="${DISCUSSION_NUMBER:-}"
DISCUSSION_NODE_ID="${DISCUSSION_NODE_ID:-}"

[ -s "$PLAN_PATH" ] || { echo "::error::plan file '$PLAN_PATH' missing or empty" >&2; exit 1; }

# ── epic ──────────────────────────────────────────────────────────────────────
epic_title="$(jq -r '.epic.title' "$PLAN_PATH")"
epic_body="$(jq -r '.epic.body' "$PLAN_PATH")"
src="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
[ -n "$src" ] || src="$DISCUSSION_NUMBER"
if [ -n "$src" ]; then
  epic_body="${epic_body}"$'\n\n'"---"$'\n'"Planned from idea discussion #${src} by the BMAD Scrum Master initiative-planner. **Inert until a maintainer adds \`initiative:auto\`.**"
fi

epic_out="$(create_issue "$REPO" "$epic_title" "$epic_body" "initiative")"
read -r epic_number epic_id <<< "$epic_out"
echo "epic: #${epic_number} (id ${epic_id}) — ${epic_title}"

# ── stories (id order) ────────────────────────────────────────────────────────
# Map: local story id -> created issue number (used to thread blocked_by edges).
declare -A NUM_BY_LOCAL=()

story_count="$(jq '.stories | length' "$PLAN_PATH")"
mapfile -t local_ids < <(jq -r '.stories | sort_by(.id) | .[].id' "$PLAN_PATH")

for lid in "${local_ids[@]}"; do
  title="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .title' "$PLAN_PATH")"
  hands_off="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .hands_off // false' "$PLAN_PATH")"
  # Compose the story body in the BMAD create-story template order:
  # Story / Acceptance Criteria / Tasks-Subtasks / Dev Notes / Project Structure
  # Notes / References. (See prompts/bmad/skills/create-story/template.md.)
  body="$(jq -r --argjson i "$lid" '
    .stories[] | select(.id==$i)
    | "## Story\n"
      + "As a " + .user_story.role + ",\nI want " + .user_story.action + ",\nso that " + .user_story.benefit + ".\n"
      + "\n## Acceptance Criteria\n"
      + ([.acceptance_criteria | to_entries[] | "\(.key + 1). \(.value)"] | join("\n"))
      + "\n\n## Tasks / Subtasks\n"
      + ([.tasks[]
          | "- [ ] " + .task
            + (if (.ac_refs // []) | length > 0 then " (AC: " + ([.ac_refs[] | "#\(.)"] | join(", ")) + ")" else "" end)
            + (if (.subtasks // []) | length > 0 then "\n" + ([.subtasks[] | "  - [ ] " + .] | join("\n")) else "" end)
         ] | join("\n"))
      + "\n\n## Dev Notes\n" + ([.dev_notes[] | "- " + .] | join("\n"))
      + (if .project_structure_notes then "\n\n### Project Structure Notes\n" + .project_structure_notes else "" end)
      + (if (.references // []) | length > 0 then "\n\n### References\n" + ([.references[] | "- " + .] | join("\n")) else "" end)
      + (if (.target_surface // []) | length > 0 then "\n\n### Likely target surface\n" + ([.target_surface[] | "- `" + . + "`"] | join("\n")) else "" end)
  ' "$PLAN_PATH")"
  body="${body}"$'\n\n'"_Story prepared by the BMAD Scrum Master (Bob) for epic #${epic_number}. Status: ready-for-dev._"

  labels="initiative"
  if [ "$hands_off" = "true" ]; then
    labels="initiative,dev-lead:hands-off,initiative:hold"
  fi

  story_out="$(create_issue "$REPO" "$title" "$body" "$labels")"
  read -r s_number s_id <<< "$story_out"
  NUM_BY_LOCAL[$lid]="$s_number"
  echo "  story[$lid]: #${s_number} (id ${s_id}) — ${title}$(if [ "$hands_off" = "true" ]; then echo ' [hands-off]'; fi)"

  link_sub_issue "$REPO" "$epic_number" "$s_id"
done

# ── dependency edges ──────────────────────────────────────────────────────────
for lid in "${local_ids[@]}"; do
  issue_num="${NUM_BY_LOCAL[$lid]}"

  # intra-plan blockers (local ids -> created numbers)
  while IFS= read -r dep_local; do
    [ -n "$dep_local" ] || continue
    add_blocked_by "$REPO" "$issue_num" "${NUM_BY_LOCAL[$dep_local]}"
    echo "  edge: #${issue_num} blocked_by #${NUM_BY_LOCAL[$dep_local]} (plan-local ${lid}<-${dep_local})"
  done < <(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | (.blocked_by // [])[]' "$PLAN_PATH")

  # existing-issue prerequisites (real numbers as-is)
  while IFS= read -r dep_existing; do
    [ -n "$dep_existing" ] || continue
    add_blocked_by "$REPO" "$issue_num" "$dep_existing"
    echo "  edge: #${issue_num} blocked_by existing #${dep_existing}"
  done < <(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | (.blocked_by_existing_issues // [])[]' "$PLAN_PATH")
done

# ── post the plan back to the discussion ──────────────────────────────────────
if [ -n "$DISCUSSION_NODE_ID" ]; then
  rows=""
  for lid in "${local_ids[@]}"; do
    t="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .title' "$PLAN_PATH")"
    sz="$(jq -r --argjson i "$lid" '.stories[] | select(.id==$i) | .size' "$PLAN_PATH")"
    rows="${rows}- #${NUM_BY_LOCAL[$lid]} (${sz}) — ${t}"$'\n'
  done
  oq="$(jq -r '(.open_questions // []) | if length>0 then "\n**Open questions for review:**\n" + ([.[] | "- " + .] | join("\n")) else "" end' "$PLAN_PATH")"
  comment="$(printf '<!-- initiative-planner -->\n**📋 Initiative planned by the BMAD Scrum Master (Bob).**\n\nEpic **#%s** — %s\n\n%s stories created (inert — labelled `initiative`, NOT `initiative:auto`):\n\n%s\n%s\n---\nReview the epic and its sub-issue DAG, adjust as needed, then add **`initiative:auto`** to epic #%s to hand it to `initiative-driver` for auto-implementation.' \
    "$epic_number" "$epic_title" "$story_count" "$rows" "$oq" "$epic_number")"
  comment_on_discussion "$DISCUSSION_NODE_ID" "$comment"
  echo "posted plan summary to discussion #${DISCUSSION_NUMBER:-?}"
fi

# ── step summary ──────────────────────────────────────────────────────────────
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Initiative plan applied$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
    echo "- Epic: #${epic_number} — ${epic_title}"
    echo "- Stories: ${story_count}"
    echo "- Epic is **inert** (no \`initiative:auto\`); add it manually to activate."
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "done. epic=#${epic_number} stories=${story_count} dry_run=${DRY_RUN:-0}"
