#!/usr/bin/env bats
# Tests for scripts/lib/run-attribution.sh — pure run→role attribution for the
# collapsed agent-ingress (ADR-0007, #1727).
#
# The collapse folds many per-role Class-1 caller stubs into ONE agent-ingress.yml
# with one job per role. Sampling runs by WORKFLOW NAME then lumps every role into
# a single bucket (the ADR-0006-fact-3 attribution regression). These helpers key
# ingress runs on the role-bearing JOB name instead, while legacy per-role
# workflows keep their workflow-name (basename) bucket — so a role that ran both
# before and after the collapse lands in the SAME bucket.
#
# All functions are PURE (args / stdin -> stdout; no network). Run:
#   bats tests/run_attribution.bats
#
# Normalized bucket-input shape: JSON array of {role, conclusion}.
# Bucket TSV (5 fields): role <TAB> total <TAB> success <TAB> failed <TAB> cancelled

setup() {
  # shellcheck source=scripts/lib/run-attribution.sh
  source "${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh"
}

# ---------------------------------------------------------------------------
# attribution_is_ingress <workflow_file>
# ---------------------------------------------------------------------------

@test "attribution_is_ingress: the collapsed ingress basename is ingress" {
  run attribution_is_ingress ".github/workflows/agent-ingress.yml"
  [ "$status" -eq 0 ]
}

@test "attribution_is_ingress: a legacy per-role workflow is NOT ingress" {
  run attribution_is_ingress ".github/workflows/dev-lead.yml"
  [ "$status" -eq 1 ]
}

@test "attribution_is_ingress: an empty path is not ingress" {
  run attribution_is_ingress ""
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# attribution_role_from_workflow <workflow_file>  (legacy path, AC #3)
# ---------------------------------------------------------------------------

@test "attribution_role_from_workflow: strips path and .yml suffix -> role" {
  run attribution_role_from_workflow ".github/workflows/dev-lead.yml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev-lead" ]
}

@test "attribution_role_from_workflow: handles a .yaml suffix" {
  run attribution_role_from_workflow "pr-review-mention.yaml"
  [ "$output" = "pr-review-mention" ]
}

# ---------------------------------------------------------------------------
# attribution_role_from_job <job_name>  (AC #2)
# The jobs API prefixes a reusable-caller job's nested jobs with
# "<caller-key> / <nested>"; the role token is the caller key (first segment).
# ---------------------------------------------------------------------------

@test "attribution_role_from_job: a bare job name is the role" {
  run attribution_role_from_job "dev-lead"
  [ "$output" = "dev-lead" ]
}

@test "attribution_role_from_job: a reusable-nested job keeps only the caller key" {
  run attribution_role_from_job "dev-lead / dispatch"
  [ "$output" = "dev-lead" ]
}

@test "attribution_role_from_job: an empty job name is the loud UNATTRIBUTED sentinel (AC #5)" {
  run attribution_role_from_job ""
  [ "$output" = "$UNATTRIBUTED_ROLE" ]
}

# ---------------------------------------------------------------------------
# normalize_legacy_runs <workflow_file>   (runs JSON on stdin)
# ---------------------------------------------------------------------------

@test "normalize_legacy_runs: maps each completed run to {role, conclusion}" {
  runs='[{"conclusion":"failure"},{"conclusion":"success"},{"conclusion":null}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$runs' | normalize_legacy_runs '.github/workflows/dev-lead.yml'"
  [ "$status" -eq 0 ]
  # null-conclusion (still running) run is dropped, mirroring the fleet metrics loop
  [ "$(printf '%s' "$output" | jq 'length')" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "dev-lead" ]
  [ "$(printf '%s' "$output" | jq -r '[.[]|.conclusion]|sort|join(",")')" = "failure,success" ]
}

# ---------------------------------------------------------------------------
# normalize_ingress_runs   (per-run jobs JSON on stdin)
# Reduces each run to ONE {role, conclusion} PER ROLE present.
# ---------------------------------------------------------------------------

@test "normalize_ingress_runs: keys on the job role, not the workflow name" {
  jobs='[{"run_id":1,"jobs":[{"name":"dev-lead / dispatch","conclusion":"success"}]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "dev-lead" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].conclusion')" = "success" ]
}

@test "normalize_ingress_runs: a role's nested jobs reduce to ONE record (failure precedence)" {
  # A single ingress run whose dev-lead reusable expands to several nested jobs
  # must count as ONE dev-lead run (parity with a legacy per-role run), and any
  # failed nested job makes the role's run a failure.
  jobs='[{"run_id":1,"jobs":[
    {"name":"dev-lead / dispatch","conclusion":"success"},
    {"name":"dev-lead / relay","conclusion":"failure"},
    {"name":"dev-lead / resume","conclusion":"success"}]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "dev-lead" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].conclusion')" = "failure" ]
}

@test "normalize_ingress_runs: a role skipped by the if: event filter produces no bucket" {
  # pr-review-mention was excluded by the event filter -> it did not run -> no record.
  jobs='[{"run_id":1,"jobs":[
    {"name":"dev-lead","conclusion":"success"},
    {"name":"pr-review-mention","conclusion":"skipped"}]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "dev-lead" ]
}

@test "normalize_ingress_runs: a run whose role ran but has no name is UNATTRIBUTED, never dropped (AC #5)" {
  jobs='[{"run_id":1,"jobs":[{"name":"","conclusion":"failure"}]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "$UNATTRIBUTED_ROLE" ]
}

@test "normalize_ingress_runs: completed non-standard conclusions are retained, not dropped (parity with legacy)" {
  # Legacy attribution keeps every non-null run; the ingress path must likewise
  # keep completed conclusions like neutral/stale/startup_failure, or ingress
  # totals undercount runs legacy retains. Only skipped/null (did-not-run) drop.
  jobs='[{"run_id":1,"jobs":[{"name":"dev-lead / dispatch","conclusion":"neutral"}]},
         {"run_id":2,"jobs":[{"name":"dev-lead / dispatch","conclusion":"startup_failure"}]},
         {"run_id":3,"jobs":[{"name":"dev-lead / dispatch","conclusion":"stale"}]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 3 ]
  [ "$(printf '%s' "$output" | jq -r '[.[]|.conclusion]|sort|join(",")')" = "neutral,stale,startup_failure" ]
}

@test "normalize_ingress_runs: a completed run with NO jobs is UNATTRIBUTED, never silently vanishing (AC #5)" {
  jobs='[{"run_id":1,"jobs":[]}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$jobs' | normalize_ingress_runs"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.[0].role')" = "$UNATTRIBUTED_ROLE" ]
}

# ---------------------------------------------------------------------------
# attribution_buckets   (normalized {role,conclusion} JSON on stdin)
# ---------------------------------------------------------------------------

@test "attribution_buckets: aggregates per role, sorted, with counts" {
  norm='[{"role":"pr-review-mention","conclusion":"success"},
         {"role":"dev-lead","conclusion":"failure"},
         {"role":"dev-lead","conclusion":"success"},
         {"role":"dev-lead","conclusion":"cancelled"}]'
  run bash -c "source '${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh'; printf '%s' '$norm' | attribution_buckets"
  [ "$status" -eq 0 ]
  # sorted by role: dev-lead first
  first="$(printf '%s\n' "$output" | head -1)"
  [ "$first" = "$(printf 'dev-lead\t3\t1\t1\t1')" ]
  second="$(printf '%s\n' "$output" | sed -n 2p)"
  [ "$second" = "$(printf 'pr-review-mention\t1\t1\t0\t0')" ]
}

# ---------------------------------------------------------------------------
# attribution_role_present <buckets_tsv> <role>   (loud MISSING guard, AC #5)
# ---------------------------------------------------------------------------

@test "attribution_role_present: present role returns 0, absent role returns non-zero" {
  tsv="$(mktemp)"
  printf 'dev-lead\t2\t1\t1\t0\n' > "$tsv"
  run attribution_role_present "$tsv" "dev-lead"
  [ "$status" -eq 0 ]
  run attribution_role_present "$tsv" "pr-review-mention"
  [ "$status" -eq 1 ]
  rm -f "$tsv"
}

# ---------------------------------------------------------------------------
# PARITY (AC #4): a role that ran pre-collapse (legacy dev-lead.yml) AND
# post-collapse (ingress job dev-lead) lands in the SAME bucket with combined
# counts. A MISSING bucket must fail as loudly as a wrong one (AC #5).
# ---------------------------------------------------------------------------

@test "parity: legacy dev-lead.yml and ingress dev-lead job produce the SAME bucket" {
  src="${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh"

  # Pre-collapse: dev-lead ran as its own workflow, one failure.
  legacy_runs='[{"conclusion":"failure"}]'
  legacy_norm="$(printf '%s' "$legacy_runs" | bash -c "source '$src'; normalize_legacy_runs '.github/workflows/dev-lead.yml'")"

  # Post-collapse: dev-lead ran as the agent-ingress.yml dev-lead job, one failure.
  ingress_jobs='[{"run_id":9,"jobs":[{"name":"dev-lead / dispatch","conclusion":"failure"}]}]'
  ingress_norm="$(printf '%s' "$ingress_jobs" | bash -c "source '$src'; normalize_ingress_runs")"

  # Both must derive the identical role key -> the SAME bucket, not two.
  [ "$(printf '%s' "$legacy_norm"  | jq -r '.[0].role')" = "dev-lead" ]
  [ "$(printf '%s' "$ingress_norm" | jq -r '.[0].role')" = "dev-lead" ]

  combined="$(jq -s 'add' <(printf '%s' "$legacy_norm") <(printf '%s' "$ingress_norm"))"
  tsv="$(printf '%s' "$combined" | bash -c "source '$src'; attribution_buckets")"

  # Exactly ONE bucket, keyed by the role, with the two runs summed.
  [ "$(printf '%s\n' "$tsv" | grep -c .)" -eq 1 ]
  [ "$tsv" = "$(printf 'dev-lead\t2\t0\t2\t0')" ]

  # The bucket MUST exist — a silently absent role is the ADR-0006-fact-3 regression.
  tsvf="$(mktemp)"; printf '%s\n' "$tsv" > "$tsvf"
  run bash -c "source '$src'; attribution_role_present '$tsvf' 'dev-lead'"
  [ "$status" -eq 0 ]
  rm -f "$tsvf"
}

@test "parity negative: keying ingress by workflow name would drop the role bucket (AC #5)" {
  src="${BATS_TEST_DIRNAME}/../scripts/lib/run-attribution.sh"
  # Prove the regression is caught: an ingress run correctly attributes to
  # dev-lead, so a monitor that instead bucketed it under the workflow name
  # ("agent-ingress") would leave the dev-lead bucket MISSING.
  ingress_jobs='[{"run_id":1,"jobs":[{"name":"dev-lead","conclusion":"failure"}]}]'
  norm="$(printf '%s' "$ingress_jobs" | bash -c "source '$src'; normalize_ingress_runs")"
  tsv="$(printf '%s' "$norm" | bash -c "source '$src'; attribution_buckets")"
  tsvf="$(mktemp)"; printf '%s\n' "$tsv" > "$tsvf"
  # The role IS present (correct behavior) ...
  run bash -c "source '$src'; attribution_role_present '$tsvf' 'dev-lead'"
  [ "$status" -eq 0 ]
  # ... and the workflow-name bucket is NOT how it is keyed (regression would).
  run bash -c "source '$src'; attribution_role_present '$tsvf' 'agent-ingress'"
  [ "$status" -eq 1 ]
  rm -f "$tsvf"
}

# ---------------------------------------------------------------------------
# generate_attribution_report <buckets_tsv> [heading]
# ---------------------------------------------------------------------------

@test "generate_attribution_report: renders a per-role table" {
  tsv="$(mktemp)"
  printf 'dev-lead\t3\t1\t1\t1\n' > "$tsv"
  run generate_attribution_report "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-lead"* ]]
  [[ "$output" == *"| Role |"* ]]
  rm -f "$tsv"
}

@test "generate_attribution_report: an empty/missing file prints nothing (section omitted)" {
  run generate_attribution_report ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "generate_attribution_report: an UNATTRIBUTED bucket is surfaced loudly (AC #5)" {
  tsv="$(mktemp)"
  printf '%s\t1\t0\t1\t0\n' "$UNATTRIBUTED_ROLE" > "$tsv"
  run generate_attribution_report "$tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNATTRIBUTED"* ]] || [[ "$output" == *"$UNATTRIBUTED_ROLE"* ]]
  rm -f "$tsv"
}
