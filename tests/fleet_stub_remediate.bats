#!/usr/bin/env bats
# Tests for scripts/fleet_stub_remediate.sh — the pure remediation-plan builder
# for the Actions Fleet Monitor stub-drift remediation (#1149, epic #1148).
#
# The module derives a network-free remediation plan from the DRIFTED set emitted
# as fleet_stub_drift.json: for each DRIFTED entry {repo, status, repo_sha,
# canonical_sha, stub, stub_file}, it names the consumer repo, the stub, the
# per-repo stub_file path, and the canonical source (CANONICAL_STUB_REPO +
# the stub's canonical_path from STUB_REGISTRY) — excluding ALIGNED/MISSING
# entries and a never-overwrite REMEDIATION_ALLOWLIST.
#
# All assertions here are PURE (no network): they exercise the plan builder,
# the canonical-source resolver, and the allowlist predicate over synthetic
# fleet_stub_drift.json fixtures. Run:
#   bats tests/fleet_stub_remediate.bats

PLANNER_STUB=".github/workflows/initiative-planner.yml"
DRIVER_STUB=".github/workflows/initiative-driver.yml"

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/fleet_stub_remediate.sh"

setup() {
  # shellcheck source=scripts/fleet_stub_remediate.sh
  source "${BATS_TEST_DIRNAME}/../scripts/fleet_stub_remediate.sh"

  # A fleet_stub_drift.json fixture mixing DRIFTED (remediable), ALIGNED, and
  # MISSING entries across both tracked stubs. Only the DRIFTED rows are
  # remediable (AC #2); ALIGNED/MISSING must never reach the plan.
  DRIFT_JSON="$(mktemp)"
  cat > "$DRIFT_JSON" <<JSON
[
  { "repo": "petry-projects/bravo", "status": "DRIFTED", "repo_sha": "bbbb", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/alpha", "status": "ALIGNED", "repo_sha": "aaaa", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/charlie", "status": "MISSING", "repo_sha": "", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/delta", "status": "DRIFTED", "repo_sha": "dddd", "canonical_sha": "cccc", "stub": "Initiative-driver", "stub_file": "${DRIVER_STUB}" }
]
JSON

  # ── gh shim harness (network-driver tests) ──────────────────────────────────
  # A gh stub on PATH logs every write (branch create / contents PUT / pr create)
  # to $CALLS and answers reads deterministically so the driver's branch+PUT+PR
  # sequence can be asserted with no network. Tunable via env the shim reads at
  # call time: EXISTING_PR (pr list result), BASE_SHA, CANON_B64, CANON_SHA,
  # WRITTEN_SHA (the post-PUT blob SHA — defaults to CANON_SHA ⇒ byte-identity).
  STUB_BIN="$(mktemp -d "${BATS_TEST_TMPDIR}/stub_bin.XXXXXX")"
  export PATH="$STUB_BIN:$PATH"
  CALLS="$STUB_BIN/calls.log"; export CALLS
  cat > "$STUB_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
args="$*"
: "${CALLS:?}"
canon_b64="${CANON_B64:-$(printf 'name: canon\n' | base64 | tr -d '\n')}"
canon_sha="${CANON_SHA:-cafebabecafebabecafebabecafebabecafebabe}"
case "$args" in
  *"pr list"*)              printf '%s' "${EXISTING_PR:-}" ;;
  *"pr create"*)            printf 'pr create %s\n' "${args//$'\n'/ }" >> "$CALLS"; echo "https://example/pr/1" ;;
  *"git/refs"*)             echo "branch $args" >> "$CALLS"; echo '{}' ;;   # POST create branch
  *"--method PUT"*)         echo "put $args" >> "$CALLS"; echo '{}' ;;      # contents PUT
  *"git/ref/heads/"*)       printf '%s' "${BASE_SHA:-basesha0000000000000000000000000000000000}" ;;
  *"contents/"*".content"*) printf '%s' "$canon_b64" ;;                     # canonical bytes
  *"contents/"*"?ref="*)    printf '%s' "${WRITTEN_SHA:-$canon_sha}" ;;     # consumer read/verify .sha
  *"contents/"*)            printf '%s' "$canon_sha" ;;                     # canonical .sha
  *)                        echo '{}' ;;
esac
SHIM
  chmod +x "$STUB_BIN/gh"
}

teardown() {
  rm -f "${DRIFT_JSON:-}"
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  return 0
}

# ---------------------------------------------------------------------------
# resolve_canonical_path <stub_file> — maps a per-repo stub path to the
# canonical org-template path from STUB_REGISTRY (AC #1).
# ---------------------------------------------------------------------------

@test "resolve_canonical_path: planner stub resolves to its canonical path" {
  run resolve_canonical_path "$PLANNER_STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/initiative-planner.yml" ]
}

@test "resolve_canonical_path: driver stub resolves to its canonical path" {
  run resolve_canonical_path "$DRIVER_STUB"
  [ "$status" -eq 0 ]
  [ "$output" = "standards/workflows/initiative-driver.yml" ]
}

@test "resolve_canonical_path: an unknown stub_file is unresolved (non-zero)" {
  run resolve_canonical_path ".github/workflows/nope.yml"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# remediation_allowlisted <repo> <stub_file> — never-overwrite predicate,
# keyed by repo or repo+stub_file (AC #3).
# ---------------------------------------------------------------------------

@test "remediation_allowlisted: a whole-repo allowlist entry matches any stub in that repo" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo")
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -eq 0 ]
}

@test "remediation_allowlisted: a repo+stub_file entry matches only that file" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo|${PLANNER_STUB}")
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -eq 0 ]
  # A different stub_file in the same repo is NOT allowlisted.
  run remediation_allowlisted "petry-projects/bravo" "$DRIVER_STUB"
  [ "$status" -ne 0 ]
}

@test "remediation_allowlisted: a non-allowlisted repo returns non-zero" {
  REMEDIATION_ALLOWLIST=()
  run remediation_allowlisted "petry-projects/bravo" "$PLANNER_STUB"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# build_remediation_plan <json_file> — the pure plan builder (AC #1, #2, #3).
# ---------------------------------------------------------------------------

@test "build_remediation_plan: selects only DRIFTED entries (ALIGNED/MISSING excluded)" {
  REMEDIATION_ALLOWLIST=()
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 2 ]
  repos=$(printf '%s' "$output" | jq -r '.[].repo' | sort | tr '\n' ',')
  [ "$repos" = "petry-projects/bravo,petry-projects/delta," ]
  # The ALIGNED and MISSING repos must not appear.
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/alpha")' >/dev/null
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/charlie")' >/dev/null
}

@test "build_remediation_plan: each entry names repo, stub, stub_file, and canonical source" {
  REMEDIATION_ALLOWLIST=()
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The bravo planner entry carries the canonical source of record.
  entry=$(printf '%s' "$output" | jq -c '.[] | select(.repo == "petry-projects/bravo")')
  [ "$(printf '%s' "$entry" | jq -r '.stub')" = "Initiative-planner" ]
  [ "$(printf '%s' "$entry" | jq -r '.stub_file')" = "$PLANNER_STUB" ]
  [ "$(printf '%s' "$entry" | jq -r '.canonical_repo')" = "petry-projects/.github" ]
  [ "$(printf '%s' "$entry" | jq -r '.canonical_path')" = "standards/workflows/initiative-planner.yml" ]
  # The driver entry resolves to the driver canonical path.
  driver=$(printf '%s' "$output" | jq -c '.[] | select(.repo == "petry-projects/delta")')
  [ "$(printf '%s' "$driver" | jq -r '.canonical_path')" = "standards/workflows/initiative-driver.yml" ]
}

@test "build_remediation_plan: an allowlisted repo never appears in the plan (AC #3)" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo")
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  len=$(printf '%s' "$output" | jq 'length')
  [ "$len" -eq 1 ]
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/bravo")' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.[0].repo')" = "petry-projects/delta" ]
}

@test "build_remediation_plan: an allowlisted repo+stub_file excludes only that file (AC #3)" {
  REMEDIATION_ALLOWLIST=("petry-projects/bravo|${PLANNER_STUB}")
  run build_remediation_plan "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # bravo's planner stub is excluded; delta's driver stub remains.
  printf '%s' "$output" | jq -e 'all(.[]; .repo != "petry-projects/bravo")' >/dev/null
  printf '%s' "$output" | jq -e 'any(.[]; .repo == "petry-projects/delta")' >/dev/null
}

@test "build_remediation_plan: an empty array yields an empty plan" {
  empty="$(mktemp)"
  echo "[]" > "$empty"
  run build_remediation_plan "$empty"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  rm -f "$empty"
}

@test "build_remediation_plan: an absent file yields an empty plan" {
  run build_remediation_plan "/nonexistent/fleet_stub_drift.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "build_remediation_plan: malformed (non-array) input fails loud, not silently empty" {
  bad="$(mktemp)"
  echo '{ "not": "an array" }' > "$bad"
  run build_remediation_plan "$bad"
  [ "$status" -ne 0 ]                       # must NOT be a silent exit 0
  [[ "$output" == *"not a readable JSON array"* ]]
  rm -f "$bad"
}

# ---------------------------------------------------------------------------
# Source-guard idiom (AC #4): sourcing exposes the pure helpers without
# executing the CLI driver.
# ---------------------------------------------------------------------------

@test "module is sourced (not executed): pure helpers are available as functions" {
  run type -t build_remediation_plan
  [ "$output" = "function" ]
  run type -t resolve_canonical_path
  [ "$output" = "function" ]
  run type -t remediation_allowlisted
  [ "$output" = "function" ]
}

# ---------------------------------------------------------------------------
# Network driver main() — DRY_RUN gate, branch+PUT+PR sequence, idempotency,
# one-PR-per-repo grouping, SHA byte-identity verify, fail-closed scope guard.
# The gh shim (setup) logs writes to $CALLS; reads are deterministic.
# ---------------------------------------------------------------------------

@test "driver: DRY_RUN is the default — logs intent and makes ZERO write API calls (AC #2)" {
  run bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # No branch create / contents PUT / pr create was ever invoked.
  [ ! -f "$CALLS" ]
  # The intended mutations are logged per repo.
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"petry-projects/bravo"* ]]
  [[ "$output" == *"petry-projects/delta"* ]]
}

@test "driver: --dry-run also forces dry-run even when DRY_RUN=false in env" {
  run env DRY_RUN=false bash "$SCRIPT" --dry-run --repo petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "driver: a live drifted repo runs branch → PUT → one PR (AC #1, #4)" {
  run env DRY_RUN=false bash "$SCRIPT" --repo petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [ -f "$CALLS" ]
  # Branch created on the consumer repo, the drifted stub PUT, and exactly one PR.
  grep -q "branch .*petry-projects/bravo/git/refs" "$CALLS"
  grep -q "put .*petry-projects/bravo/contents/${PLANNER_STUB}" "$CALLS"
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  # The PR targets the consumer default branch (a proposal, never a direct push).
  grep -q "pr create .*--base" "$CALLS"
  # The out-of-scope drifted repo (delta) is never touched.
  run grep -q "petry-projects/delta" "$CALLS"
  [ "$status" -eq 1 ]
}

@test "driver: PR title/body cite the canonical source of record (AC #4)" {
  run env DRY_RUN=false bash "$SCRIPT" --repo petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  # The single PR references the canonical repo + path the drift was measured against.
  grep -q "pr create" "$CALLS"
  grep "pr create" "$CALLS" | grep -q "petry-projects/.github"
  grep "pr create" "$CALLS" | grep -q "standards/workflows/initiative-planner.yml"
}

@test "driver: an already-open remediation PR is skipped — no writes (AC #3)" {
  run env DRY_RUN=false EXISTING_PR=77 bash "$SCRIPT" --repo petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"77"* ]]
  # Idempotent: no branch create, no PUT, no second pr create.
  if [ -f "$CALLS" ]; then
    run grep -q "pr create" "$CALLS"
    [ "$status" -eq 1 ]
    run grep -q "put " "$CALLS"
    [ "$status" -eq 1 ]
  fi
}

@test "driver: two drifted stubs in one repo yield ONE branch, two PUTs, ONE PR (AC #1)" {
  multi="$(mktemp "${BATS_TEST_TMPDIR}/multi.XXXXXX")"
  cat > "$multi" <<JSON
[
  { "repo": "petry-projects/echo", "status": "DRIFTED", "repo_sha": "1111", "canonical_sha": "aaaa", "stub": "Initiative-planner", "stub_file": "${PLANNER_STUB}" },
  { "repo": "petry-projects/echo", "status": "DRIFTED", "repo_sha": "2222", "canonical_sha": "cccc", "stub": "Initiative-driver", "stub_file": "${DRIVER_STUB}" }
]
JSON
  run env DRY_RUN=false bash "$SCRIPT" --repo petry-projects/echo "$multi"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'branch .*petry-projects/echo/git/refs' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'put .*petry-projects/echo/contents/' "$CALLS")" -eq 2 ]
  [ "$(grep -c 'pr create' "$CALLS")" -eq 1 ]
  rm -f "$multi"
}

@test "driver: a post-PUT blob SHA that != canonical SHA fails the repo and opens NO PR (AC #5)" {
  run env DRY_RUN=false WRITTEN_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    bash "$SCRIPT" --repo petry-projects/bravo "$DRIFT_JSON"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatch"* || "$output" == *"::error::"* ]]
  # Wrote the file but the byte-identity check caught the mismatch → no misleading PR.
  if [ -f "$CALLS" ]; then
    run grep -q "pr create" "$CALLS"
    [ "$status" -eq 1 ]
  fi
}

@test "driver: DRY_RUN=false with NO repo scope stays dry-run + warns (fail-closed, AC #7)" {
  run env DRY_RUN=false bash "$SCRIPT" "$DRIFT_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  # Fail-closed: no writes despite DRY_RUN=false, because no scope was supplied.
  [ ! -f "$CALLS" ]
}
