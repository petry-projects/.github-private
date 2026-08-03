#!/usr/bin/env bats
# Validate .markdownlint-cli2.jsonc excludes vendored dependencies so the CI
# "Lint Markdown" step does not fail on third-party markdown.
# See: issue #1455 — ci.yml DEGRADED. Commit e2a42cf (#1435) accidentally
# committed package.json + node_modules/bats/**, and markdownlint (globbing
# **/*.md) flagged node_modules/bats/README.md (MD033/MD004/MD051), turning
# the Lint job red on every main push. This mirrors the #244 gitleaks-config
# regression guard (tests/test_gitleaks_config.bats).
#
# Run with: bats tests/test_markdownlint_config.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MDL_CONFIG="$REPO_ROOT/.markdownlint-cli2.jsonc"

# Parse the JSONC config (strip full-line // comments and trailing commas) and
# print the requested python expression against the loaded dict `cfg`.
_load_cfg() {
  python3 - "$MDL_CONFIG" "$1" <<'PY'
import json, re, sys
path, expr = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("//"))
text = re.sub(r",(\s*[}\]])", r"\1", text)
cfg = json.loads(text)
sys.stdout.write(str(eval(expr)))
PY
}

@test ".markdownlint-cli2.jsonc exists at repo root" {
  [ -f "$MDL_CONFIG" ]
}

@test ".markdownlint-cli2.jsonc is valid JSONC" {
  run _load_cfg "type(cfg).__name__"
  [ "$status" -eq 0 ]
  [ "$output" = "dict" ]
}

# Regression guard for #1455: the ignores list must exclude node_modules so
# markdownlint never lints vendored dependency markdown.
@test ".markdownlint-cli2.jsonc ignores node_modules" {
  run _load_cfg "'node_modules/**' in cfg.get('ignores', [])"
  [ "$status" -eq 0 ]
  [ "$output" = "True" ]
}

# Regression guard for the accidental commit (e2a42cf/#1435): the vendored
# node_modules/ tree must not be tracked by git. bats in CI is installed via
# apt-get, so nothing depends on a committed node_modules/.
@test "node_modules/ is not tracked by git" {
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git work tree"
  run git -C "$REPO_ROOT" ls-files node_modules
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run git -C "$REPO_ROOT" check-ignore --no-index -q -- node_modules/somepkg/README.md
  [ "$status" -eq 0 ]
}

# Behavioral guard: run the real linter against a fixture tree containing both a
# node_modules/*.md with inline HTML (must be ignored) and a non-ignored doc
# with the same violation (must still be reported). Proves the ignore is scoped
# and does not blanket-suppress real findings. Skips if the binary is absent,
# mirroring the gitleaks behavioral test.
@test "markdownlint ignores node_modules markdown but still flags non-ignored files" {
  command -v markdownlint-cli2 >/dev/null 2>&1 || skip "markdownlint-cli2 not installed"
  cp "$MDL_CONFIG" "$BATS_TEST_TMPDIR/.markdownlint-cli2.jsonc"
  mkdir -p "$BATS_TEST_TMPDIR/node_modules/somepkg" "$BATS_TEST_TMPDIR/docs"
  printf '# Pkg\n\n<div>inline html</div>\n' > "$BATS_TEST_TMPDIR/node_modules/somepkg/README.md"
  printf '# Doc\n\n<div>inline html</div>\n' > "$BATS_TEST_TMPDIR/docs/bad.md"
  run bash -c "cd '$BATS_TEST_TMPDIR' && markdownlint-cli2 '**/*.md' 2>&1"
  # The non-ignored doc violation is reported (linter exits non-zero)...
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "docs/bad.md"
  # ...and the vendored node_modules markdown is never linted. Match the fixture
  # file path specifically, not the bare string "node_modules/", so the ignore
  # glob echoed on the informational "Finding:" line is not a false positive.
  run grep -q "node_modules/somepkg/README.md" <<< "$output"
  [ "$status" -eq 1 ]
}
