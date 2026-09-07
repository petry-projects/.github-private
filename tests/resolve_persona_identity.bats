#!/usr/bin/env bats
# Unit tests for persona posting-identity resolution
# (scripts/lib/resolve-persona-identity.sh).
#
# The persona runner posts every advisory under the account named in the
# addressed persona's manifest (runtime.identity), NOT under a hardcoded repo-wide
# default. These tests pin that: the account + credential the runner will
# authenticate as are read from the manifest, offline, with a stub — so a persona
# posting under a human maintainer's PAT (.github-private#1650) cannot regress
# silently. See standards/persona-standards.md §5.1.

RESOLVE() {
  bash "$SCRIPT_DIR/scripts/lib/resolve-persona-identity.sh" "$@"
}

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ROOT="$(mktemp -d "$BATS_TEST_TMPDIR/personas.XXXXXX")"
}

# Write a stub persona manifest declaring a runtime.identity.
_stub_persona() {
  local id="$1" account="$2" credential="$3"
  mkdir -p "$ROOT/$id"
  cat > "$ROOT/$id/persona.yml" <<YAML
id: $id
runtime:
  identity:
    account: $account
    credential: $credential
YAML
}

# --- the runner resolves identity FROM THE MANIFEST, not a default ----------

@test "posting account is read from the manifest, not a hardcoded default" {
  _stub_persona stub-lead donpetry-bot DON_PETRY_BOT_GH_PAT
  run RESOLVE stub-lead "$ROOT" account
  [ "$status" -eq 0 ]
  [ "$output" = "donpetry-bot" ]
}

@test "posting credential is read from the manifest" {
  _stub_persona stub-lead donpetry-bot DON_PETRY_BOT_GH_PAT
  run RESOLVE stub-lead "$ROOT" credential
  [ "$status" -eq 0 ]
  [ "$output" = "DON_PETRY_BOT_GH_PAT" ]
}

@test "a different manifest yields a different identity (no shared fallback)" {
  # Proves the resolver honors whatever the manifest declares — the whole point
  # of #1316/#1317: identity comes from the manifest, never a shared default.
  _stub_persona other-lead someone-else GH_PAT_SOMEONE_ELSE
  run RESOLVE other-lead "$ROOT" account
  [ "$status" -eq 0 ]
  [ "$output" = "someone-else" ]
}

@test "resolution fails loudly (never a silent default) when identity is absent" {
  mkdir -p "$ROOT/no-identity"
  printf 'id: no-identity\n' > "$ROOT/no-identity/persona.yml"
  run RESOLVE no-identity "$ROOT" account
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime.identity"* ]]
}

# --- the live qa-lead manifest must post as a bot, not a human (AC #1) -------

@test "qa-lead posts as the bot identity donpetry-bot, not a human maintainer" {
  run RESOLVE qa-lead "$SCRIPT_DIR/personas" account
  [ "$status" -eq 0 ]
  [ "$output" = "donpetry-bot" ]
}

@test "qa-lead's credential follows the GH_PAT/grandfathered schema for the bot" {
  run RESOLVE qa-lead "$SCRIPT_DIR/personas" credential
  [ "$status" -eq 0 ]
  [ "$output" = "DON_PETRY_BOT_GH_PAT" ]
}
