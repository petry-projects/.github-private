#!/usr/bin/env bats
# scripts/check-model-pins.sh (#1979) — fails when a concrete Claude model id is
# hard-pinned outside the allowed files, so callers name a family instead.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-model-pins.sh"

setup() {
  SANDBOX="$(mktemp -d)"
}

teardown() {
  rm -rf "$SANDBOX"
}

# A concrete id (a real digit-versioned model) under a scanned dir is a violation.
@test "check: a hard-pinned id under scripts/ fails and prints file:line" {
  mkdir -p "$SANDBOX/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'claude --model claude-sonnet-4-6' > "$SANDBOX/scripts/foo.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/foo.sh:2"* ]]
}

# The legacy version-first form (claude-3-5-sonnet-20241022) is a concrete
# pin too and must not slip past the family-first pattern.
@test "check: a legacy version-first id fails too" {
  mkdir -p "$SANDBOX/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'claude --model claude-3-5-sonnet-20241022' > "$SANDBOX/scripts/foo.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/foo.sh:2"* ]]
}

# A family name is the sanctioned form and must pass.
@test "check: a family name passes" {
  mkdir -p "$SANDBOX/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'model="$(ai_model_for_family sonnet)"' > "$SANDBOX/scripts/foo.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# A line carrying the model-pin-ok marker is exempt.
@test "check: a model-pin-ok line is exempt" {
  mkdir -p "$SANDBOX/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'JUDGE="claude-sonnet-4-6" # model-pin-ok: eval judge held fixed' \
    > "$SANDBOX/scripts/foo.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# The resolver file is allow-listed (it defines the family→id mapping).
@test "check: allowed file (engine-models.sh) may name concrete ids" {
  mkdir -p "$SANDBOX/scripts/lib"
  printf '%s\n' 'claude:deep) printf "claude-opus-5-5" ;;' > "$SANDBOX/scripts/lib/engine-models.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# The price table is allow-listed (historical/recorded data).
@test "check: allowed file (model-pricing.tsv) may name concrete ids" {
  mkdir -p "$SANDBOX/scripts/lib"
  printf '%s\n' 'claude-haiku-4-5-20251001	1.0' > "$SANDBOX/scripts/lib/model-pricing.tsv"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# Compiled gh-aw lock files are generated output and are allow-listed.
@test "check: allowed file (.github/workflows/*.lock.yml) may name concrete ids" {
  mkdir -p "$SANDBOX/.github/workflows"
  printf '%s\n' 'model: claude-opus-5-5' > "$SANDBOX/.github/workflows/foo.lock.yml"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 0 ]
}

# fable ids are covered by the same regex.
@test "check: a fable id is also flagged" {
  mkdir -p "$SANDBOX/scripts"
  printf '%s\n' 'x=claude-fable-5' > "$SANDBOX/scripts/foo.sh"
  run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 1 ]
}

# The final gate: the real repository must be clean.
@test "check: the repository has no unmarked hard pins" {
  run bash "$CHECK" "$SCRIPT_DIR"
  [ "$status" -eq 0 ]
}

# A grep scan error (exit >1) must fail loud with status 2, never a false clean.
# A PATH shim forces the error so the case also holds when tests run as root
# (where chmod 000 would not block the read).
@test "check: a grep scan error fails loud (exit 2), not a false clean" {
  mkdir -p "$SANDBOX/scripts" "$SANDBOX/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'claude --model claude-sonnet-4-6' > "$SANDBOX/scripts/foo.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$SANDBOX/bin/grep"
  chmod +x "$SANDBOX/bin/grep"
  PATH="$SANDBOX/bin:$PATH" run bash "$CHECK" "$SANDBOX"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot certify clean"* ]]
}
