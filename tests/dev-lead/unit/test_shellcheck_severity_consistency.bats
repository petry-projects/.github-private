#!/usr/bin/env bats
# Regression guard for the test-dev-lead.yml `unit`-job flake class (issue #1502).
#
# The `unit` job runs `bats tests/dev-lead/unit/`. A gate test that invokes
# shellcheck at DEFAULT severity fails on an *info*-level finding (e.g. SC1091
# "Not following: …" on a dynamic `source "$var"`). SC1091 emission depends on
# the working directory and the runner's shellcheck version, so such a test
# flakes the whole workflow. This is exactly how #1502 was triggered: the
# `Advisory gate: shellcheck passes` test ran shellcheck without `--severity`.
#
# Guard: every shellcheck *command invocation* in tests/dev-lead/unit/*.bats
# must pass `--severity` (we standardize on `--severity=warning`) so an info
# finding can never fail the unit job. Directive comments (`# shellcheck …`)
# and `command -v shellcheck` probes are not invocations and are ignored.

setup() {
  UNIT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
}

teardown() {
  unset UNIT_DIR
}

@test "unit shellcheck invocations pass --severity=warning (no info-level flake — #1502)" {
  local offenders=""
  # Command invocations start the line (after indentation) with the tool name.
  # This excludes `# shellcheck …` directives and `command -v shellcheck` probes.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *--severity=warning*) : ;;
      *) offenders="${offenders}${line}"$'\n' ;;
    esac
  done < <(grep -rnE '^[[:space:]]*shellcheck[[:space:]]' "$UNIT_DIR"/*.bats || true)

  if [ -n "$offenders" ]; then
    printf 'shellcheck invocation without --severity=warning (info findings can flake the unit job):\n%s' "$offenders" >&2
    return 1
  fi
}
