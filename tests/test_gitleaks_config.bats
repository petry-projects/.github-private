#!/usr/bin/env bats
# Validate .gitleaks.toml exists and suppresses known false positives from
# the frameworks/ git-subtree directory (removed from tree, present in history).
# See: issue #244 — ci.yml DEGRADED due to gitleaks false positives.
#
# Run with: bats tests/test_gitleaks_config.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
GITLEAKS_CONFIG="$REPO_ROOT/.gitleaks.toml"

@test ".gitleaks.toml exists at repo root" {
  [ -f "$GITLEAKS_CONFIG" ]
}

@test ".gitleaks.toml is valid TOML" {
  python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    tomllib.load(f)
print('valid TOML')
" "$GITLEAKS_CONFIG"
}

@test ".gitleaks.toml allowlist covers frameworks/ path" {
  python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)
all_paths = []
for entry in cfg.get('allowlists', []):
    all_paths.extend(entry.get('paths', []))
if not any('frameworks' in p for p in all_paths):
    print('ERROR: no frameworks/ path found in [[allowlists]] paths', file=sys.stderr)
    sys.exit(1)
print('OK')
" "$GITLEAKS_CONFIG"
}

# Regression guard for the exact false positive that drove this workflow DEGRADED
# (issues #244, #697): the vendored bmad skills knowledge files ship an example
# expired JWT (`const expiredToken = '<JWT>'; // Expired token`) in
# .claude/skills/**/resources/knowledge/api-testing-patterns.md. The default
# generic-api-key rule flags it; an [[allowlists]] entry must suppress it.
@test ".gitleaks.toml allowlist covers .claude/skills api-testing-patterns.md" {
  python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)
for entry in cfg.get('allowlists', []):
    paths = entry.get('paths', [])
    if any('skills' in p and 'api-testing-patterns' in p for p in paths):
        print('OK')
        sys.exit(0)
print('ERROR: no allowlist path covers .claude/skills/**/api-testing-patterns.md', file=sys.stderr)
sys.exit(1)
" "$GITLEAKS_CONFIG"
}

# The example expired JWT, identical to the vendored skills knowledge files.
EXPIRED_JWT='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxNTE2MjM5MDIyfQ.dummdummdummdummdummdummdummdummdummdummdum'

# Build a throwaway git repo containing the committed .gitleaks.toml and a single
# file (at $1) holding the example expired-token line. Echoes the repo path.
_make_token_repo() {
  local relpath="$1" dir
  dir="$(mktemp -d)"
  cp "$GITLEAKS_CONFIG" "$dir/.gitleaks.toml"
  mkdir -p "$dir/$(dirname "$relpath")"
  printf "const expiredToken = '%s'; // Expired token\n" "$EXPIRED_JWT" > "$dir/$relpath"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture
  printf '%s' "$dir"
}

@test "gitleaks suppresses skills api-testing-patterns.md expiredToken false positive" {
  command -v gitleaks >/dev/null 2>&1 || skip "gitleaks binary not installed"
  local dir
  dir="$(_make_token_repo ".claude/skills/bmad-tea/resources/knowledge/api-testing-patterns.md")"
  run gitleaks detect --source "$dir" --config "$dir/.gitleaks.toml" \
    --redact --exit-code 1 --no-banner
  rm -rf "$dir"
  [ "$status" -eq 0 ]
}

# Same token in a non-allowlisted path must still be reported — proves the
# allowlist is path-scoped and does not blanket-suppress real secrets.
@test "gitleaks still detects the expired JWT in a non-allowlisted path" {
  command -v gitleaks >/dev/null 2>&1 || skip "gitleaks binary not installed"
  local dir
  dir="$(_make_token_repo "src/app.js")"
  run gitleaks detect --source "$dir" --config "$dir/.gitleaks.toml" \
    --redact --exit-code 1 --no-banner
  rm -rf "$dir"
  [ "$status" -ne 0 ]
}
