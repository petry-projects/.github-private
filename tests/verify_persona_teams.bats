#!/usr/bin/env bats
# Hermetic unit + fixture tests for scripts/verify-persona-teams.sh (#1280).
#
# verify-persona-teams.sh is the LIVE, network-touching half of persona addressing
# validation: for every personas/<id>/persona.yml that declares an `address` block,
# it verifies the team named by address.handle EXISTS, is `privacy: closed` (secret
# teams are unmentionable), and is `notification_setting: notifications_disabled`
# (the handle routes a webhook, it must not page members). It FAILS CLOSED — an API
# error is never read as "the team is fine" (#755).
#
# These tests stay hermetic (the sibling of the hermetic validate-personas suite):
# the network call goes through `gh`, which is stubbed here to return canned team
# JSON or an error. NO real teams API is ever contacted.
#
# Run with: bats tests/verify_persona_teams.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/verify-persona-teams.sh"
  TMP="$BATS_TEST_TMPDIR"
  # shellcheck source=/dev/null
  source "$SCRIPT"

  # Stub gh so vpt_team_api never touches the network. It emulates
  # gh api orgs/<org>/teams/<slug>: echo VPT_TEST_TEAM_JSON, or fail if
  # VPT_TEST_GH_FAIL=1 (an API/HTTP error, e.g. 404 for a nonexistent team).
  gh() {
    if [ "${VPT_TEST_GH_FAIL:-0}" = "1" ]; then
      return 1
    fi
    printf '%s' "${VPT_TEST_TEAM_JSON:-}"
  }
  export -f gh
}

# make_persona <id> [handle] — write a minimal personas/<id>/persona.yml fixture.
# With a handle, it carries an `address` block; without, it has none.
make_persona() {
  local id="$1" handle="${2:-}"
  mkdir -p "$TMP/personas/$id"
  {
    printf 'id: %s\nname: %s\n' "$id" "$id"
    if [ -n "$handle" ]; then
      printf 'address:\n  handle: %s\n  aliases: []\n' "$handle"
    fi
  } > "$TMP/personas/$id/persona.yml"
}

# ---------------------------------------------------------------------------
# vpt_check_team — verify one live team (the core assertion, fails closed)
# ---------------------------------------------------------------------------

@test "vpt_check_team passes a closed, notifications-disabled team" {
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","privacy":"closed","notification_setting":"notifications_disabled"}'
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -eq 0 ]
}

@test "vpt_check_team fails a secret team (unmentionable)" {
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","privacy":"secret","notification_setting":"notifications_disabled"}'
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -ne 0 ]
  [[ "$output" == *"privacy"* ]]
  [[ "$output" == *"closed"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "vpt_check_team fails a team that pages its members" {
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","privacy":"closed","notification_setting":"notifications_enabled"}'
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -ne 0 ]
  [[ "$output" == *"notification_setting"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "vpt_check_team fails CLOSED when the teams API errors" {
  export VPT_TEST_GH_FAIL=1
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read team"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "vpt_check_team fails a team JSON missing privacy" {
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","notification_setting":"notifications_disabled"}'
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]]
}

@test "vpt_check_team fails when the API returns non-JSON" {
  export VPT_TEST_TEAM_JSON='not json at all'
  run vpt_check_team "personas/qa-lead/persona.yml" qa-lead
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]]
}

# ---------------------------------------------------------------------------
# vpt_list_addresses — extract (slug, manifest) only for address-carrying personas
# ---------------------------------------------------------------------------

@test "vpt_list_addresses emits slug+manifest only for personas with an address" {
  make_persona qa-lead petry-projects/qa-lead
  make_persona no-addr
  run vpt_list_addresses "$TMP/personas"
  [ "$status" -eq 0 ]
  [[ "$output" == *"qa-lead"* ]]
  [[ "$output" != *"no-addr"* ]]
}

@test "vpt_list_addresses reports a malformed handle without a traceback" {
  make_persona bad "no-slash-handle"
  run vpt_list_addresses "$TMP/personas"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]]
}

# ---------------------------------------------------------------------------
# vpt_run — end-to-end orchestration over a fixture personas tree
# ---------------------------------------------------------------------------

@test "vpt_run verifies a persona whose team is closed + notifications-disabled" {
  make_persona qa-lead petry-projects/qa-lead
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","privacy":"closed","notification_setting":"notifications_disabled"}'
  run vpt_run "$TMP/personas"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "vpt_run fails when a persona's team is secret" {
  make_persona qa-lead petry-projects/qa-lead
  export VPT_TEST_TEAM_JSON='{"slug":"qa-lead","privacy":"secret","notification_setting":"notifications_disabled"}'
  run vpt_run "$TMP/personas"
  [ "$status" -ne 0 ]
}

@test "vpt_run fails CLOSED when the teams API errors for a declared address" {
  make_persona qa-lead petry-projects/qa-lead
  export VPT_TEST_GH_FAIL=1
  run vpt_run "$TMP/personas"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read team"* ]]
}

@test "vpt_run passes a persona with no address block (address is optional)" {
  make_persona no-addr
  run vpt_run "$TMP/personas"
  [ "$status" -eq 0 ]
}

@test "vpt_run is a no-op when there is no personas root" {
  run vpt_run "$TMP/nonexistent"
  [ "$status" -eq 0 ]
}

@test "vpt_run reports a malformed handle without a traceback" {
  make_persona bad "no-slash-handle"
  run vpt_run "$TMP/personas"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Traceback"* ]]
}
