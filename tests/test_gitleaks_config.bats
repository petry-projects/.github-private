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
