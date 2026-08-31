#!/usr/bin/env bats
# Integration tests for the engine-token liveness WRAPPER
# (scripts/engine_liveness.sh, issue #1605).
#
# #1605: under `set -euo pipefail`, the PAT audit extracted the credential's
# scopes with `pat_scopes_seen=$(… | grep -im1 '^x-oauth-scopes:' | …)`. When the
# response carries no `x-oauth-scopes` header — the normal case for a fine-grained
# PAT or a GitHub App token — `grep` exits 1, `pipefail` propagates it, the
# command-substitution assignment exits 1, and `errexit` KILLS the script. That
# abort happens BEFORE section 4, so the report, the `GITHUB_ENV` flags, and the
# fleet-alert body were never written: the fleet-outage alert could never fire and
# the run's exit code contradicted its own Should-fail decision (`Should-fail:
# false` yet exit 1). An absent header is a classification INPUT, not a fatal error.
#
# These tests drive the wrapper end-to-end with a `gh` PATH stub so both defects
# are exercised the way the issue demands — "verify by running", not by reading
# the diff:
#   - a `gh api -i user` response with NO x-oauth-scopes/expiry header must let the
#     script COMPLETE (report + GITHUB_ENV flags written), classifying scope as
#     UNKNOWN / `<none/fine-grained>` rather than aborting;
#   - the workflow-run exit status must equal ENGINE_LIVENESS_SHOULD_FAIL: 0
#     sustained outages -> green; a sustained outage in >=2 repos -> red AND the
#     FLEET alert body actually produced.
#
# Run with: bats tests/test_engine_liveness.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/engine_liveness.sh"

  # BATS_TEST_TMPDIR is created fresh per test and cleaned up afterwards.
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export PATH="$STUB_DIR:$PATH"
  export GH_CALL_LOG="$BATS_TEST_TMPDIR/gh_calls.log"
  : > "$GH_CALL_LOG"

  # Wrapper side-effect sinks — kept out of the repo working tree.
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  : > "$GITHUB_ENV"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step_summary"
  export REPORT_FILE="$BATS_TEST_TMPDIR/report.md"
  export ALERT_BODY_FILE="$BATS_TEST_TMPDIR/alert.md"

  # Drive the repo/stub set explicitly so no consumer manifest or network is
  # needed. Two repos so a fleet-wide (>=2 repos) outage is expressible.
  export ENGINE_LIVENESS_REPOS="petry-projects/repo-a petry-projects/repo-b"
  export ENGINE_LIVENESS_STUBS="dev-lead.yml"
  export GH_TOKEN="dummy-token-for-stub"
}

# env_val <NAME> — echo the value written for NAME in the wrapper's GITHUB_ENV.
env_val() {
  grep -m1 "^$1=" "$GITHUB_ENV" | cut -d= -f2-
}

# workflow_run_outcome — mirror the workflow's final gating step
#   `if: always() && env.ENGINE_LIVENESS_SHOULD_FAIL == 'true'  -> exit 1`
# so the run's exit status can be asserted to equal SHOULD_FAIL (#1605 AC).
workflow_run_outcome() {
  [ "$(env_val ENGINE_LIVENESS_SHOULD_FAIL)" = "true" ] && return 1
  return 0
}

# make_gh_stub — install a `gh` shim on PATH. Behaviour is env-driven:
#   GH_STUB_PREFLIGHT      failure|success (the "Engine token preflight" step's
#                          conclusion for every inspected run; default success)
#   GH_STUB_EMIT_SCOPES    1 to emit an `x-oauth-scopes` header (classic PAT);
#                          unset/0 omits it (fine-grained PAT / App token — #1605)
#   GH_STUB_EMIT_EXPIRY    1 to emit a `github-authentication-token-expiration`
#                          header; unset/0 omits it.
# The stub emits POST-`--jq` output directly (the script always passes `--jq`),
# matching the repo's other gh-stub tests.
make_gh_stub() {
  cat > "$STUB_DIR/gh" << 'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
[ "$1" = "api" ] || exit 0
shift

resource=""
for a in "$@"; do
  case "$a" in
    -i|--paginate|--jq|-H|--hostname) : ;;   # flags (value-taking flags handled below)
    -*) : ;;                                  # any other flag
    user) resource="user" ;;
    repos/*) resource="$a" ;;
    *) : ;;                                   # jq expression / flag values — ignore
  esac
done

case "$resource" in
  user)
    # Identity response WITH headers (`gh api -i user`). A fine-grained PAT / App
    # token omits x-oauth-scopes entirely — that omission is the #1605 trigger.
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'Server: GitHub.com\r\n'
    if [ "${GH_STUB_EMIT_SCOPES:-0}" = "1" ]; then
      printf 'x-oauth-scopes: repo, workflow\r\n'
    fi
    if [ "${GH_STUB_EMIT_EXPIRY:-0}" = "1" ]; then
      printf 'github-authentication-token-expiration: 2027-12-31 00:00:00 UTC\r\n'
    fi
    printf '\r\n'
    printf '{"login":"don-petry"}\n'
    ;;
  */actions/workflows/*/runs*)
    # Two most-recent COMPLETED runs, both RECENT (inside the default 3-day
    # lookback), post-jq form: "<id>\t<run_started_at_iso>".
    printf '111\t%s\n' "$(date -u -d '-1 hour'  +%Y-%m-%dT%H:%M:%SZ)"
    printf '222\t%s\n' "$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)"
    ;;
  */actions/runs/*/jobs)
    # Per-run job steps, post-jq form: "<step_name>\t<conclusion>".
    printf 'Checkout agent repo\tsuccess\n'
    printf 'Engine token preflight\t%s\n' "${GH_STUB_PREFLIGHT:-success}"
    ;;
  *)
    exit 0
    ;;
esac
STUBEOF
  chmod +x "$STUB_DIR/gh"
}

# ---------------------------------------------------------------------------
# #1605 root cause — an absent x-oauth-scopes / expiry header must be a
# classification input, not a fatal abort.
# ---------------------------------------------------------------------------

@test "no x-oauth-scopes header: script COMPLETES, writes report + GITHUB_ENV flags (not an abort) (#1605)" {
  export GH_STUB_PREFLIGHT=success
  export GH_STUB_EMIT_SCOPES=0   # fine-grained PAT / App token — no scopes header
  export GH_STUB_EMIT_EXPIRY=0   # …and no expiry header either
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The report exists and got past the PAT-audit line that used to abort.
  [ -s "$REPORT_FILE" ]
  grep -q 'Engine-Token Liveness' "$REPORT_FILE"
  grep -q 'monitor complete' <<< "$output"

  # The GITHUB_ENV flags the alert/fail steps gate on were written.
  grep -q '^ENGINE_LIVENESS_ESCALATION='   "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_SHOULD_FAIL='   "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_PAT_SCOPE_STATE='  "$GITHUB_ENV"
  grep -q '^ENGINE_LIVENESS_PAT_EXPIRY_STATE=' "$GITHUB_ENV"

  # An absent header is classified, not fatal: UNKNOWN scope / NO_EXPIRY, and the
  # report shows the designed <none/fine-grained> placeholder.
  [ "$(env_val ENGINE_LIVENESS_PAT_SCOPE_STATE)" = "UNKNOWN" ]
  [ "$(env_val ENGINE_LIVENESS_PAT_EXPIRY_STATE)" = "NO_EXPIRY" ]
  grep -q 'none/fine-grained' "$REPORT_FILE"
}

@test "classic PAT WITH scopes header still classifies OK (no regression) (#1605)" {
  export GH_STUB_PREFLIGHT=success
  export GH_STUB_EMIT_SCOPES=1
  export GH_STUB_EMIT_EXPIRY=1
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(env_val ENGINE_LIVENESS_PAT_SCOPE_STATE)" = "OK" ]
  [ "$(env_val ENGINE_LIVENESS_PAT_EXPIRY_STATE)" = "OK" ]
}

# ---------------------------------------------------------------------------
# #1605 — the run's exit status must equal ENGINE_LIVENESS_SHOULD_FAIL.
# ---------------------------------------------------------------------------

@test "0 sustained outages: exits 0, SHOULD_FAIL=false, escalation NONE; run stays green (#1605)" {
  export GH_STUB_PREFLIGHT=success   # every inspected run passes preflight
  make_gh_stub

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(env_val ENGINE_LIVENESS_SHOULD_FAIL)" = "false" ]
  [ "$(env_val ENGINE_LIVENESS_ESCALATION)" = "NONE" ]
  [ "$(env_val ENGINE_LIVENESS_SUSTAINED_REPOS)" = "0" ]

  # Run exit status == SHOULD_FAIL: false -> green.
  run workflow_run_outcome
  [ "$status" -eq 0 ]

  # No fleet-alert body was produced for an all-clear.
  [ ! -s "$ALERT_BODY_FILE" ] || ! grep -q 'FLEET-WIDE' "$ALERT_BODY_FILE"
}

@test ">=2 repos in sustained outage: FLEET escalation, alert body produced, SHOULD_FAIL=true; run goes red (#1605)" {
  export GH_STUB_PREFLIGHT=failure   # both repos: 2 recent preflight failures each
  make_gh_stub

  run bash "$SCRIPT"
  # The wrapper itself still exits 0 so the workflow's alert step (which lacks
  # always()) remains reachable; the always() fail-step owns the red/green.
  [ "$status" -eq 0 ]

  [ "$(env_val ENGINE_LIVENESS_ESCALATION)" = "FLEET" ]
  [ "$(env_val ENGINE_LIVENESS_SHOULD_FAIL)" = "true" ]
  [ "$(env_val ENGINE_LIVENESS_SUSTAINED_REPOS)" = "2" ]

  # The fleet-alert body — never once produced before this fix — now exists.
  [ -s "$ALERT_BODY_FILE" ]
  grep -qi 'FLEET-WIDE ENGINE-TOKEN OUTAGE' "$ALERT_BODY_FILE"

  # Run exit status == SHOULD_FAIL: true -> red.
  run workflow_run_outcome
  [ "$status" -eq 1 ]
}
