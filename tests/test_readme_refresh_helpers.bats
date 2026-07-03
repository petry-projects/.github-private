#!/usr/bin/env bats
# Unit tests for pure helper functions in scripts/aw-readme-refresh.sh:
#   extract_readme, overlong_lines, valid_content
#
# Run: bats tests/test_readme_refresh_helpers.bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/aw-readme-refresh.sh"

setup() {
  # Extract only the pure helper function definitions; skip the main body
  # that requires live env vars (GH_TOKEN, PROMPT_TEMPLATE, etc.)
  eval "$(awk '
    /^extract_readme\(\)/  { f=1 }
    /^trim_blank_edges\(\)/{ f=1 }
    /^overlong_lines\(\)/  { f=1 }
    /^valid_content\(\)/   { f=1 }
    f                      { print }
    f && /^\}$/            { f=0 }
  ' "$SCRIPT")"
}

# ── extract_readme ────────────────────────────────────────────────────────────

@test "extract_readme: captures body between markers" {
  raw="$(printf '%s\n' 'preamble' '===README-BEGIN===' '# Hello' 'body line' '===README-END===' 'epilogue')"
  result="$(extract_readme "$raw")"
  [ "$result" = "$(printf '%s\n' '# Hello' 'body line')" ]
}

@test "extract_readme: returns empty when markers are absent" {
  result="$(extract_readme "no markers here")"
  [ -z "$result" ]
}

@test "extract_readme: ignores reasoning preamble and trailing commentary" {
  raw="$(printf '%s\n' 'Some reasoning...' '===README-BEGIN===' 'content' '===README-END===' 'extra')"
  result="$(extract_readme "$raw")"
  [ "$result" = "content" ]
}

@test "extract_readme: markers with trailing whitespace are recognised" {
  raw="$(printf '%s\n' '===README-BEGIN===   ' 'line' '===README-END===  ')"
  result="$(extract_readme "$raw")"
  [ "$result" = "line" ]
}

# ── overlong_lines ────────────────────────────────────────────────────────────

@test "overlong_lines: returns empty when all lines fit within maxlen" {
  result="$(overlong_lines "short line" 120)"
  [ -z "$result" ]
}

@test "overlong_lines: reports the line number of an overlong prose line" {
  long="$(printf '%201s' '' | tr ' ' 'x')"
  content="$(printf '%s\n' 'ok' "$long")"
  result="$(overlong_lines "$content" 200)"
  [ "$result" = "2" ]
}

@test "overlong_lines: reports multiple overlong line numbers as comma list" {
  long="$(printf '%201s' '' | tr ' ' 'x')"
  content="$(printf '%s\n' "$long" 'ok' "$long")"
  result="$(overlong_lines "$content" 200)"
  [ "$result" = "1,3" ]
}

@test "overlong_lines: skips table rows (lines starting with |)" {
  long_table="| $(printf '%300s' '' | tr ' ' 'x') |"
  result="$(overlong_lines "$long_table" 200)"
  [ -z "$result" ]
}

@test "overlong_lines: skips content inside fenced code blocks" {
  long="$(printf '%300s' '' | tr ' ' 'x')"
  content="$(printf '%s\n' '```' "$long" '```')"
  result="$(overlong_lines "$content" 200)"
  [ -z "$result" ]
}

@test "overlong_lines: counts prose lines outside code fence after fence closes" {
  long="$(printf '%201s' '' | tr ' ' 'x')"
  content="$(printf '%s\n' '```' "$long" '```' "$long")"
  result="$(overlong_lines "$content" 200)"
  [ "$result" = "4" ]
}

# ── valid_content ─────────────────────────────────────────────────────────────

@test "valid_content: rejects empty content" {
  run valid_content "" "github-private-repo-readme"
  [ "$status" -ne 0 ]
}

@test "valid_content: rejects the literal string SKIP" {
  run valid_content "SKIP" "github-private-repo-readme"
  [ "$status" -ne 0 ]
}

@test "valid_content: accepts non-empty content for private-readme type (no H1 required)" {
  run valid_content "Some body content" "github-private-repo-readme"
  [ "$status" -eq 0 ]
}

@test "valid_content: rejects org-profile-public with no top-level heading" {
  run valid_content "$(printf '%s\n' '## H2 opener' 'body')" "org-profile-public"
  [ "$status" -ne 0 ]
}

@test "valid_content: accepts org-profile-public with correct H1 first line" {
  run valid_content "$(printf '%s\n' '# Org Name' 'body')" "org-profile-public"
  [ "$status" -eq 0 ]
}

@test "valid_content: rejects github-repo-readme missing top-level heading" {
  run valid_content "$(printf '%s\n' 'no heading here' 'body')" "github-repo-readme"
  [ "$status" -ne 0 ]
}

@test "valid_content: accepts github-repo-readme with H1 first line" {
  run valid_content "$(printf '%s\n' '# Repo Title' 'body')" "github-repo-readme"
  [ "$status" -eq 0 ]
}

@test "valid_content: accepts org-profile-member with any non-empty content" {
  run valid_content "$(printf '%s\n' 'member section' 'more')" "org-profile-member"
  [ "$status" -eq 0 ]
}
