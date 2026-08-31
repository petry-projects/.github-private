#!/usr/bin/env bats
# Unit tests for scripts/lib/stale-base-siblings.sh :: detect_stale_base_siblings
# (#1607, AC #6 — bounded audit).
#
# A stale-base force-push leaves a fingerprint: the discarded commit and the
# commit that replaced it share the SAME parent (dev-lead rebuilt from a cached
# base instead of the branch head). On #1604:
#     75f5850e (maintainer)  parent b7a9fa68
#     e938c584 (dev-lead)    parent b7a9fa68   <- same parent = sibling
# The detector reads "<sha> <parent>" lines and flags any parent with >1 child.

setup() {
  DETECT_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts/lib/stale-base-siblings.sh"
  source "$DETECT_LIB"
}

@test "flags two commits that share a parent (the stale-base fingerprint)" {
  run detect_stale_base_siblings <<'EOF'
75f5850e b7a9fa68
e938c584 b7a9fa68
9b3bc2b0 e938c584
EOF
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "b7a9fa68"
  echo "$output" | grep -q "75f5850e"
  echo "$output" | grep -q "e938c584"
}

@test "linear history (every parent has exactly one child) is clean" {
  run detect_stale_base_siblings <<'EOF'
c1 p0
c2 c1
c3 c2
EOF
  [ "$status" -eq 0 ]
}

@test "only the parent with multiple children is reported" {
  run detect_stale_base_siblings <<'EOF'
a1 root
a2 a1
b1 shared
b2 shared
c1 a2
EOF
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "shared"
  # a1's single child must not be reported as a sibling group.
  ! echo "$output" | grep -q "root"
}

@test "empty input is clean" {
  run detect_stale_base_siblings <<'EOF'
EOF
  [ "$status" -eq 0 ]
}

@test "blank and malformed lines are ignored, not counted as siblings" {
  run detect_stale_base_siblings <<'EOF'

x1 p1

x2 p2
EOF
  [ "$status" -eq 0 ]
}
