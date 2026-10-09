#!/usr/bin/env bats
# scripts/check-retry-payload-fields.sh (#2081) — fails when the dev-lead retry
# sweep on main sends a client_payload field that scripts/dev-lead-intent.sh at
# the channel pinned by dev-lead.yml's agent_ref does not read.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-retry-payload-fields.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.github/workflows" "$SANDBOX/scripts/lib"
  git -C "$SANDBOX" init -q
  git -C "$SANDBOX" config user.email t@example.com
  git -C "$SANDBOX" config user.name t
}

teardown() {
  rm -rf "$SANDBOX"
}

# write_stub <agent_ref>
write_stub() {
  cat > "$SANDBOX/.github/workflows/dev-lead.yml" <<EOF
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$1
    with:
      agent_ref: $1
EOF
}

# write_intent <field>... — an intent parser that reads each named field.
write_intent() {
  {
    echo '#!/usr/bin/env bash'
    for f in "$@"; do
      echo "x=\$(jq -r '.client_payload.${f} // empty' \"\$EVENT_PATH\")"
    done
  } > "$SANDBOX/scripts/dev-lead-intent.sh"
}

# write_sweep <field>... — a sweep that sends each named field in one payload.
write_sweep() {
  {
    echo '#!/usr/bin/env bash'
    echo 'source "$SCRIPT_DIR/lib/helper.sh"'
    echo "payload=\$(jq -n '{"
    echo '  event_type: "dev-lead-reviews-retry",'
    echo '  client_payload: {'
    local f
    for f in "$@"; do echo "    ${f}: \$${f},"; done
    echo '    checks: [{name: $name, conclusion: "failure",'
    echo '              id: $check_run_id}]'
    echo '  }'
    echo "}')"
  } > "$SANDBOX/scripts/dev-lead-retry.sh"
  [ -f "$SANDBOX/scripts/lib/helper.sh" ] || echo '#!/usr/bin/env bash' > "$SANDBOX/scripts/lib/helper.sh"
}

# tag_channel <tag> — commit the tree and point the channel tag at it.
tag_channel() {
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -qm "release" --allow-empty
  git -C "$SANDBOX" tag -f "$1" >/dev/null
}

@test "passes when every field the sweep sends is read by the pinned parser" {
  write_stub dev-lead/v7-stable
  write_intent pr_number head_sha checks
  write_sweep pr_number head_sha
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# The #2050 defect: main's parser learns the field, the sweep sends it, and the
# pinned channel still points at the old parser.
@test "fails when the sweep sends a field only main's parser reads" {
  write_stub dev-lead/v7-stable
  write_intent pr_number head_sha checks
  write_sweep pr_number head_sha
  tag_channel dev-lead/v7-stable
  write_intent pr_number head_sha checks comment_node_id
  write_sweep pr_number head_sha comment_node_id
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.comment_node_id"* ]]
  [[ "$output" == *"scripts/dev-lead-retry.sh:"* ]]
  [[ "$output" == *"dev-lead/v7-stable"* ]]
  [[ "$output" != *"client_payload.pr_number"* ]]
}

@test "checks the libs the sweep sources, not just the sweep itself" {
  write_stub dev-lead/v7-stable
  write_intent pr_number checks
  write_sweep pr_number
  cat > "$SANDBOX/scripts/lib/helper.sh" <<'EOF'
#!/usr/bin/env bash
payload=$(jq -n '{event_type: "x", client_payload: {pr_number: $p, new_field: $n}}')
EOF
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.new_field"* ]]
  [[ "$output" == *"scripts/lib/helper.sh:2"* ]]
}

@test "catches the gh -f client_payload[field]= form" {
  write_stub dev-lead/v7-stable
  write_intent pr_number checks
  write_sweep pr_number
  echo 'gh api x -f "client_payload[other_field]=1"' >> "$SANDBOX/scripts/dev-lead-retry.sh"
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"client_payload.other_field"* ]]
}

# Nested keys (checks[].name, checks[].id) are read by fix-ci, not the intent
# parser; only top-level client_payload keys are compared.
@test "ignores keys nested inside a top-level field" {
  write_stub dev-lead/v7-stable
  write_intent pr_number checks
  write_sweep pr_number
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" != *"client_payload.name"* ]]
  [[ "$output" != *"client_payload.id"* ]]
}

@test "allowlisted informational fields (repo, attempt) do not fail the check" {
  write_stub dev-lead/v7-stable
  write_intent pr_number checks
  write_sweep pr_number repo attempt
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# AC2: the channel comes from the stub, so a major bump needs no edit here.
@test "follows the stub's agent_ref to another major and channel" {
  write_intent pr_number checks
  write_sweep pr_number
  tag_channel dev-lead/v7-stable
  write_intent pr_number checks comment_node_id
  write_sweep pr_number comment_node_id
  write_stub dev-lead/v8-next
  tag_channel dev-lead/v8-next
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead/v8-next"* ]]
}

@test "exits 2 when the stub has no agent_ref" {
  echo 'jobs: {}' > "$SANDBOX/.github/workflows/dev-lead.yml"
  write_intent pr_number
  write_sweep pr_number
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"agent_ref"* ]]
}

@test "exits 2 when agent_ref is not a dev-lead channel tag" {
  write_stub main
  write_intent pr_number
  write_sweep pr_number
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"main"* ]]
}

@test "exits 2 when the channel tag cannot be resolved" {
  write_stub dev-lead/v9-stable
  write_intent pr_number
  write_sweep pr_number
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dev-lead/v9-stable"* ]]
}

@test "exits 2 when the sweep sends no client_payload fields at all" {
  write_stub dev-lead/v7-stable
  write_intent pr_number
  echo '#!/usr/bin/env bash' > "$SANDBOX/scripts/dev-lead-retry.sh"
  tag_channel dev-lead/v7-stable
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
}

@test "lint.yml runs the check" {
  grep -q 'bash scripts/check-retry-payload-fields.sh' "$REPO_ROOT/.github/workflows/lint.yml"
}

@test "AGENTS.md ordering rule points at the check" {
  grep -q 'check-retry-payload-fields.sh' "$REPO_ROOT/AGENTS.md"
}
