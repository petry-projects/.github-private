#!/usr/bin/env bats
# Unit tests for scripts/apply-rulesets.sh — codified, idempotent ruleset apply
# (initiative #495, issue #868).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
APPLY="$SCRIPT_DIR/scripts/apply-rulesets.sh"
RULESETS_DIR="$SCRIPT_DIR/.github/rulesets"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
}
teardown() { [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"; return 0; }

# gh stub: records every write (POST/PUT) to $CALLS; for the rulesets LIST it
# returns $RULESETS_LIST (default empty array → "create" path).
_stub_gh() {
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"--method POST"*|*"--method PUT"*) echo "\$args" >> "$CALLS"; echo '{}' ;;
  *"rulesets"*) printf '%s' "\${RULESETS_LIST:-[]}" ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$STUB_BIN/gh"
}

# ── codified JSON shape ───────────────────────────────────────────────────────
@test "release-channel-tags.json: valid, tag target, protects pr-review/** + dev-lead/**" {
  run jq -e '.target == "tag" and .enforcement == "active"' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
  run jq -e '.conditions.ref_name.include | (index("refs/tags/dev-lead/**") and index("refs/tags/pr-review/**"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
  # update + deletion restricted
  run jq -e '[.rules[].type] | (index("update") and index("deletion"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
  # bypass = OrganizationAdmin + the Integration app
  run jq -e '[.bypass_actors[].actor_type] | (index("OrganizationAdmin") and index("Integration"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$status" -eq 0 ]
}

@test "dev-lead/** glob covers the ring channels (next/ring0/ring1) — no per-channel rule needed" {
  # The include is a glob; assert the codified pattern is the ** form that matches rings.
  run jq -r '.conditions.ref_name.include[] | select(startswith("refs/tags/dev-lead"))' "$RULESETS_DIR/release-channel-tags.json"
  [ "$output" = "refs/tags/dev-lead/**" ]
}

# ── apply behavior (create vs update, dry-run) ────────────────────────────────
@test "apply: creates the ruleset when absent (POST)" {
  _stub_gh
  export RULESETS_LIST='[]'
  run env RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" release-channel-tags
  [ "$status" -eq 0 ]
  grep -q "method POST" "$CALLS"
  ! grep -q "method PUT" "$CALLS"
}

@test "apply: updates the ruleset when present (PUT by id)" {
  _stub_gh
  export RULESETS_LIST='[{"id":17432201,"name":"release-channel-tags"}]'
  run env RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" release-channel-tags
  [ "$status" -eq 0 ]
  grep -q "method PUT" "$CALLS"
  grep -q "rulesets/17432201" "$CALLS"
  ! grep -q "method POST" "$CALLS"
}

@test "apply: --dry-run makes no write calls" {
  _stub_gh
  export RULESETS_LIST='[]'
  run env RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" --dry-run release-channel-tags
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "apply: unknown ruleset name errors" {
  _stub_gh
  run env RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" no-such-ruleset
  [ "$status" -ne 0 ]
}

@test "ruleset_id_by_name: resolves id from the list" {
  _stub_gh
  export RULESETS_LIST='[{"id":42,"name":"release-channel-tags"},{"id":7,"name":"code-quality"}]'
  run bash -c "source '$APPLY' && ruleset_id_by_name petry-projects/.github-private code-quality"
  [ "$status" -eq 0 ]; [ "$output" = "7" ]
}

@test "apply: --repo without a value errors with a message" {
  _stub_gh
  run bash "$APPLY" --repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo requires a value"* ]]
}
