#!/usr/bin/env bats
# Per-target-repo channel gate for the dev-lead retry sweep (#2086).
#
# The sweep runs one release of scripts/ (the channel this repo's dev-lead.yml
# pins, #2050) but dispatches to every repo in the org, and each target runs its
# harness at ITS OWN dev-lead.yml pin. A target pinned to an older channel can
# receive a client_payload field its harness cannot read (#2017 skew, across
# repos). The gate reads each target's pin and skips — loudly — any repo whose
# channel lacks commits the sweep's channel has. These tests pin:
#   • agent_ref parsing (channel tags only; same regex as dev-lead-retry.yml);
#   • pin reads: found / no stub (404) / read error / malformed;
#   • the ancestry compare: identical|behind → dispatch, ahead|diverged → skip,
#     compare failure → skip (fail closed), same ref → no API call, cached;
#   • main(): an older-pinned repo is skipped with a warning while others scan,
#     and an unresolvable sweep pin keeps today's scan-everything behaviour.
#
# Run: bats tests/dev-lead/unit/test_dispatch_channel_gate.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
RETRY_SCRIPT="$REPO_ROOT/scripts/dev-lead-retry.sh"

setup() {
  MOCK_BIN="$(mktemp -d)"
  export MOCK_BIN
  export PATH="$MOCK_BIN:$PATH"
  mkdir -p "$MOCK_BIN/stubs"
  : >"$MOCK_BIN/compare"
  : >"$MOCK_BIN/calls"
  export DRY_RUN="true"
  export DISPATCH_DELAY_SEC="0"
  export TARGET_ORG="petry-projects"
  export DCG_HOST_REPO="petry-projects/.github-private"
  unset SWEEP_AGENT_REF DELEGATION_ORGS GITHUB_REPOSITORY

  # gh stub. Every call is logged to $MOCK_BIN/calls.
  #   contents/.github/workflows/dev-lead.yml for owner/name
  #       -> $MOCK_BIN/stubs/<owner>__<name>; missing file -> HTTP 404;
  #          a file containing exactly ERROR -> HTTP 502
  #   compare/<base>...<head> -> status from "$MOCK_BIN/compare" lines
  #       "<base>...<head> <status>"; no line -> HTTP 500
  #   repo list -> $REPO_LIST_JSON (post-jq array of nameWithOwner)
  cat >"$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_BIN/calls"
args="$*"
case "$args" in
  "repo list"*) printf '%s' "${REPO_LIST_JSON:-[]}"; exit 0 ;;
  *contents/.github/workflows/dev-lead.yml*)
    repo="${args#*repos/}"; repo="${repo%%/contents/*}"
    f="$MOCK_BIN/stubs/${repo//\//__}"
    if [ ! -f "$f" ]; then
      printf '{"message":"Not Found","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ "$(cat "$f")" = "ERROR" ]; then
      echo "gh: Bad Gateway (HTTP 502)" >&2
      exit 1
    fi
    cat "$f"; exit 0 ;;
  *compare/*)
    bh="${args#*compare/}"; bh="${bh%% *}"
    st="$(awk -v k="$bh" '$1 == k {print $2}' "$MOCK_BIN/compare")"
    if [ -z "$st" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    printf '%s\n' "$st"; exit 0 ;;
  *) echo "[]" ;;
esac
GHEOF
  chmod +x "$MOCK_BIN/gh"

  # shellcheck disable=SC1090
  source "$RETRY_SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# _pin <owner/name> <agent_ref>: give a repo a dev-lead.yml caller stub.
_pin() {
  cat >"$MOCK_BIN/stubs/${1//\//__}" <<EOF
jobs:
  dev-lead:
    uses: petry-projects/.github-private/.github/workflows/dev-lead-reusable.yml@$2  # NOSONAR
    with:
      agent_ref: $2
EOF
}

# _compare <base> <head> <status>
_compare() {
  printf '%s...%s %s\n' "$1" "$2" "$3" >>"$MOCK_BIN/compare"
}

_compare_calls() {
  grep -c 'compare/' "$MOCK_BIN/calls" || true
}

# ── dcg_parse_agent_ref ──────────────────────────────────────────────────────

@test "parse: returns the agent_ref of a caller stub, for any major and tier" {
  local ch out
  for ch in dev-lead/v139-stable dev-lead/v1-next dev-lead/v7-ring0 dev-lead/v12-ring1; do
    _pin o/r "$ch"
    out="$(dcg_parse_agent_ref <"$MOCK_BIN/stubs/o__r")"
    [ "$out" = "$ch" ]
  done
}

@test "parse: accepts a quoted agent_ref with a trailing comment" {
  out="$(printf '    with:\n      agent_ref: "dev-lead/v139-ring1"  # pin\n' | dcg_parse_agent_ref)"
  [ "$out" = "dev-lead/v139-ring1" ]
}

@test "parse: reads this repo's live dev-lead.yml stub" {
  run dcg_parse_agent_ref <"$REPO_ROOT/.github/workflows/dev-lead.yml"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^dev-lead/v[0-9]+-(next|ring0|ring1|stable)$ ]]
}

@test "parse: rejects a missing or non-channel agent_ref" {
  run dcg_parse_agent_ref <<<'jobs: {}'
  [ "$status" -ne 0 ]
  local bad
  for bad in main dev-lead/v139 dev-lead/vX-stable dev-lead/v139-canary pr-review/v1-stable 'dev-lead/v139-stable;x' '../../x'; do
    run dcg_parse_agent_ref <<<"      agent_ref: $bad"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

# ── dcg_read_repo_pin ────────────────────────────────────────────────────────

@test "read pin: returns the repo's agent_ref" {
  _pin petry-projects/markets dev-lead/v139-ring1
  run dcg_read_repo_pin petry-projects/markets
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v139-ring1" ]
}

@test "read pin: a repo with no dev-lead.yml returns 2" {
  run dcg_read_repo_pin petry-projects/no-stub
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "read pin: a read error returns 1 (not mistaken for no stub)" {
  echo ERROR >"$MOCK_BIN/stubs/petry-projects__flaky"
  run dcg_read_repo_pin petry-projects/flaky
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "read pin: a malformed agent_ref returns 1" {
  _pin petry-projects/odd main
  run dcg_read_repo_pin petry-projects/odd
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ── dcg_pin_compat ───────────────────────────────────────────────────────────

@test "compat: same ref → compatible without any API call" {
  run dcg_pin_compat dev-lead/v139-stable dev-lead/v139-stable
  [ "$status" -eq 0 ]
  [ "$(_compare_calls)" -eq 0 ]
}

@test "compat: target identical to or newer than the sweep → compatible" {
  _compare dev-lead/v139-ring0 dev-lead/v139-stable identical
  run dcg_pin_compat dev-lead/v139-ring0 dev-lead/v139-stable
  [ "$status" -eq 0 ]
  _compare dev-lead/v139-ring1 dev-lead/v139-stable behind
  run dcg_pin_compat dev-lead/v139-ring1 dev-lead/v139-stable
  [ "$status" -eq 0 ]
}

@test "compat: target older than the sweep (sweep ahead) → older" {
  _compare dev-lead/v1-stable dev-lead/v139-stable ahead
  run dcg_pin_compat dev-lead/v1-stable dev-lead/v139-stable
  [ "$status" -eq 1 ]
}

@test "compat: diverged channels (e.g. a rollback) → older" {
  _compare dev-lead/v139-ring1 dev-lead/v139-stable diverged
  run dcg_pin_compat dev-lead/v139-ring1 dev-lead/v139-stable
  [ "$status" -eq 1 ]
}

@test "compat: compare against the dev-lead host repo" {
  _compare dev-lead/v1-stable dev-lead/v139-stable ahead
  dcg_pin_compat dev-lead/v1-stable dev-lead/v139-stable || true
  grep -q 'repos/petry-projects/.github-private/compare/dev-lead/v1-stable...dev-lead/v139-stable' "$MOCK_BIN/calls"
}

@test "compat: compare failure → unknown (2)" {
  run dcg_pin_compat dev-lead/v138-stable dev-lead/v139-stable
  [ "$status" -eq 2 ]
}

@test "compat: result is cached per target ref within a sweep" {
  _compare dev-lead/v1-stable dev-lead/v139-stable ahead
  dcg_pin_compat dev-lead/v1-stable dev-lead/v139-stable || true
  dcg_pin_compat dev-lead/v1-stable dev-lead/v139-stable || true
  dcg_pin_compat dev-lead/v1-stable dev-lead/v139-stable || true
  [ "$(_compare_calls)" -eq 1 ]
}

# ── dcg_repo_dispatch_allowed ────────────────────────────────────────────────

@test "allowed: same pin as the sweep → scan" {
  _pin petry-projects/markets dev-lead/v139-stable
  run dcg_repo_dispatch_allowed petry-projects/markets dev-lead/v139-stable
  [ "$status" -eq 0 ]
}

@test "allowed: older pin → skip with a warning naming both channels" {
  _pin petry-projects/broodly dev-lead/v1-stable
  _compare dev-lead/v1-stable dev-lead/v139-stable ahead
  run dcg_repo_dispatch_allowed petry-projects/broodly dev-lead/v139-stable
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"petry-projects/broodly"* ]]
  [[ "$output" == *"dev-lead/v1-stable"* ]]
  [[ "$output" == *"dev-lead/v139-stable"* ]]
}

@test "allowed: no dev-lead.yml → skip (nothing would receive a dispatch)" {
  run dcg_repo_dispatch_allowed petry-projects/no-stub dev-lead/v139-stable
  [ "$status" -eq 1 ]
  [[ "$output" == *"no dev-lead.yml"* ]]
}

@test "allowed: unreadable pin → skip with a warning (fail closed)" {
  echo ERROR >"$MOCK_BIN/stubs/petry-projects__flaky"
  run dcg_repo_dispatch_allowed petry-projects/flaky dev-lead/v139-stable
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

@test "allowed: compare failure → skip with a warning (fail closed)" {
  _pin petry-projects/odd dev-lead/v138-stable
  run dcg_repo_dispatch_allowed petry-projects/odd dev-lead/v139-stable
  [ "$status" -eq 1 ]
  [[ "$output" == *"::warning::"* ]]
}

# ── dcg_resolve_sweep_ref ────────────────────────────────────────────────────

@test "sweep ref: read from the host repo's dev-lead.yml" {
  _pin petry-projects/.github-private dev-lead/v139-stable
  run dcg_resolve_sweep_ref
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v139-stable" ]
}

@test "sweep ref: SWEEP_AGENT_REF overrides, and must be a channel tag" {
  _pin petry-projects/.github-private dev-lead/v139-stable
  SWEEP_AGENT_REF=dev-lead/v139-ring1 run dcg_resolve_sweep_ref
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead/v139-ring1" ]
  SWEEP_AGENT_REF=main run dcg_resolve_sweep_ref
  [ "$status" -ne 0 ]
}

# ── main() wiring ────────────────────────────────────────────────────────────

@test "main: older-pinned repo is skipped, same-pinned repo is scanned" {
  export REPO_LIST_JSON='["petry-projects/.github-private","petry-projects/broodly","petry-projects/markets"]'
  _pin petry-projects/.github-private dev-lead/v139-stable
  _pin petry-projects/broodly dev-lead/v1-stable
  _pin petry-projects/markets dev-lead/v139-ring1
  _compare dev-lead/v1-stable dev-lead/v139-stable ahead
  _compare dev-lead/v139-ring1 dev-lead/v139-stable behind
  scan_repo() { echo "SCANNED $1"; }

  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCANNED petry-projects/.github-private"* ]]
  [[ "$output" == *"SCANNED petry-projects/markets"* ]]
  [[ "$output" != *"SCANNED petry-projects/broodly"* ]]
  [[ "$output" == *"::warning::"*"petry-projects/broodly"* ]]
}

@test "main: unresolvable sweep pin → warn and scan every repo (today's behaviour)" {
  export REPO_LIST_JSON='["petry-projects/a","petry-projects/b"]'
  scan_repo() { echo "SCANNED $1"; }

  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"SCANNED petry-projects/a"* ]]
  [[ "$output" == *"SCANNED petry-projects/b"* ]]
}
