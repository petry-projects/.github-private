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

# ── blocking open-questions gate ──────────────────────────────────────────────
# Bob routes anything he can't resolve to `open_questions`. A question shaped as
# an object with `blocking:true` means the idea is not yet plannable — building
# an epic + story DAG now would just create throwaway issues a human must close
# and re-plan (see #682; incidents #650→#659, #666→#667). So if ANY blocking
# question is present we create NOTHING: post the questions back to the source
# discussion with "not yet planned" framing and exit cleanly (DRY_RUN honored
# via comment_on_discussion). Re-running once the questions are answered then
# materializes the real plan. Plain-string questions stay advisory only.
blocking_count="$(jq '[(.open_questions // [])[] | select(type=="object" and .blocking==true)] | length' "$PLAN_PATH")"
if [ "$blocking_count" -gt 0 ]; then
  src_g="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
  [ -n "$src_g" ] || src_g="$DISCUSSION_NUMBER"
  if [ -n "$DISCUSSION_NODE_ID" ]; then
    blocking_list="$(jq -r '[(.open_questions // [])[] | select(type=="object" and .blocking==true) | .question] | map("- " + .) | join("\n")' "$PLAN_PATH")"
    other_list="$(jq -r '(.open_questions // []) | map(select((type=="string") or (type=="object" and .blocking != true))) | map(if type=="string" then . else .question end) | if length>0 then "\n\n_Also worth confirming (non-blocking):_\n" + (map("- " + .) | join("\n")) else "" end' "$PLAN_PATH")"
    printf -v gate_comment '<!-- initiative-planner -->\n**⏸️ Not yet planned — the BMAD Scrum Master (Bob) has blocking open questions.**\n\nThis idea cannot be turned into an epic until these are answered:\n\n%s%s\n\n---\n**No epic or stories were created.** Answer the questions above, then re-approve / re-dispatch the planner and Bob will materialize the full epic + sub-issue DAG.' \
      "$blocking_list" "$other_list"
    comment_on_discussion "$DISCUSSION_NODE_ID" "$gate_comment"
    echo "posted 'not yet planned' open-questions back to discussion #${DISCUSSION_NUMBER:-?}"
  fi
  echo "::warning::initiative-planner: idea #${src_g:-?} has ${blocking_count} blocking open question(s) — no epic created. Answer them and re-dispatch."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Initiative not yet planned — needs answers$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
      echo "- Source discussion: #${src_g:-?}"
      echo "- Blocking open questions: ${blocking_count}"
      echo "- **No epic or stories were created.** Answer the questions and re-dispatch the planner."
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  echo "gated: ${blocking_count} blocking open question(s); created nothing. dry_run=${DRY_RUN:-0}"
  exit 0
fi

# ── epic ──────────────────────────────────────────────────────────────────────
epic_title="$(jq -r '.epic.title' "$PLAN_PATH")"
epic_body="$(jq -r '.epic.body' "$PLAN_PATH")"
src="$(jq -r '.source_discussion // empty' "$PLAN_PATH")"
[ -n "$src" ] || src="$DISCUSSION_NUMBER"
if [ -n "$src" ]; then
  # idem_key is the idempotency back-reference embedded in every epic body and
  # reused verbatim as the search key by find_existing_epic.
  idem_key="Planned from idea discussion #${src}"
  epic_body="${epic_body}"$'\n\n'"---"$'\n'"${idem_key} by the BMAD Scrum Master initiative-planner. **Inert until a maintainer adds \`initiative:auto\`.**"

  # Idempotency guard: a second dispatch/auto-trigger for the same idea must not
  # create a duplicate epic + DAG. If an open initiative epic already carries the
  # back-reference, this is a benign re-run — skip creation and exit 0.
  existing_epic="$(find_existing_epic "$REPO" "$idem_key")"
  if [ -n "$existing_epic" ]; then
    echo "already planned (epic #${existing_epic}) for idea discussion #${src} — skipping creation"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "## Initiative plan skipped$(if [ "${DRY_RUN:-0}" = "1" ]; then echo " (DRY_RUN)"; fi)"
        echo "- Already planned: epic #${existing_epic} for idea discussion #${src}"
        echo "- No issues created (idempotency guard)."
      } >>"$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
fi

# Untracked prerequisites: real prereqs that are NOT issues (a discussion, an
# external dependency) — rendered as a maintainer-tickable checklist on the epic,
# distinct from the blocked_by_existing_issues edges (which cover prereqs that ARE
# issues). Guarded so an empty/absent array leaves epic_body byte-for-byte as-is.
untracked_prereqs="$(jq -r '(.epic.untracked_prerequisites // []) | map("- [ ] " + .) | join("\n")' "$PLAN_PATH")"
if [ -n "$untracked_prereqs" ]; then
  epic_body="${epic_body}"$'\n\n'"## Untracked prerequisites"$'\n'"${untracked_prereqs}"
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
  oq="$(jq -r '(.open_questions // []) | map(if type=="string" then . else .question end) | if length>0 then "\n**Open questions for review:**\n" + (map("- " + .) | join("\n")) else "" end' "$PLAN_PATH")"
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
