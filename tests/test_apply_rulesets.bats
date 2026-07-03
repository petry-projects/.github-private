#!/usr/bin/env bats
# Unit tests for scripts/apply-rulesets.sh — codified, idempotent ruleset apply
# (initiative #495, issue #868).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
APPLY="$SCRIPT_DIR/scripts/apply-rulesets.sh"
# This repo's LOCAL ruleset dir — holds only release-channel-tags.json since the
# fleet rulesets (code-quality, pr-quality) were relocated to petry-projects/.github
# under #575. Passed explicitly via RULESETS_DIR to apply the repo-local ruleset;
# with RULESETS_DIR unset the applier is in fleet mode (materializes from .github).
RULESETS_DIR="$SCRIPT_DIR/.github/rulesets"

setup() {
  STUB_BIN="$(mktemp -d)"; export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
}
teardown() {
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${FLEET_DIR:-}" ] && rm -rf "$FLEET_DIR"
  return 0
}

# _fleet_fixture — a stand-in for petry-projects/.github standards/rulesets/. The
# authoritative fleet JSON content lives there (relocated under #575); this fixture
# only needs valid .name fields to exercise fleet-mode resolution + apply.
_fleet_fixture() {
  FLEET_DIR="$(mktemp -d)"
  printf '{"name":"code-quality","target":"branch","enforcement":"active"}\n' > "$FLEET_DIR/code-quality.json"
  printf '{"name":"pr-quality","target":"branch","enforcement":"active"}\n'   > "$FLEET_DIR/pr-quality.json"
  export FLEET_RULESETS_DIR="$FLEET_DIR"
}

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
  run env RULESETS_DIR="$RULESETS_DIR" RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" release-channel-tags
  [ "$status" -eq 0 ]
  grep -q "method POST" "$CALLS"
  ! grep -q "method PUT" "$CALLS"
}

@test "apply: updates the ruleset when present (PUT by id)" {
  _stub_gh
  export RULESETS_LIST='[{"id":17432201,"name":"release-channel-tags"}]'
  run env RULESETS_DIR="$RULESETS_DIR" RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" release-channel-tags
  [ "$status" -eq 0 ]
  grep -q "method PUT" "$CALLS"
  grep -q "rulesets/17432201" "$CALLS"
  ! grep -q "method POST" "$CALLS"
}

@test "apply: --dry-run makes no write calls" {
  _stub_gh
  export RULESETS_LIST='[]'
  run env RULESETS_DIR="$RULESETS_DIR" RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" --dry-run release-channel-tags
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "apply: unknown ruleset name errors" {
  _stub_gh
  run env RULESETS_DIR="$RULESETS_DIR" RULESETS_REPO="petry-projects/.github-private" bash "$APPLY" no-such-ruleset
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

# ── fleet mode: source code-quality + pr-quality from .github (via FLEET_RULESETS_DIR) ──
@test "fleet mode: --repo applies code-quality + pr-quality (2), never release-channel-tags" {
  _stub_gh
  export RULESETS_LIST='[]'
  _fleet_fixture
  run bash "$APPLY" --repo petry-projects/acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-quality"* ]]
  [[ "$output" == *"pr-quality"* ]]
  [[ "$output" != *"release-channel-tags"* ]]
  [[ "$output" == *"done (2 ruleset(s))"* ]]
  # exactly two creates (POST), one per fleet ruleset
  [ "$(grep -c 'method POST' "$CALLS" || true)" -eq 2 ]
}

@test "fleet mode: --dry-run previews both fleet rulesets and makes no writes" {
  _stub_gh
  export RULESETS_LIST='[]'
  _fleet_fixture
  run bash "$APPLY" --dry-run --repo petry-projects/acme
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
  [[ "$output" == *"code-quality"* ]]
  [[ "$output" == *"pr-quality"* ]]
}

@test "fleet mode: missing FLEET_RULESETS_DIR errors clearly" {
  _stub_gh
  run env FLEET_RULESETS_DIR="/no/such/fleet/dir" bash "$APPLY" --repo petry-projects/acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"FLEET_RULESETS_DIR not found"* ]]
}
