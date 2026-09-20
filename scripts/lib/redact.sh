# shellcheck shell=bash
# scripts/lib/redact.sh — the single credential-redaction helper.
#
# Extracted so every caller reuses one definition rather than re-implementing it
# (the drift .github-private#1775 AC #4 exists to prevent). Sourced by
# scripts/dev-lead-fix-reviews.sh and scripts/lib/persona-runner.sh. Defines a
# function only; runs nothing at source time and does not call `set`.

# redact_secrets: scrub common credential token formats from stdin → stdout.
# Defense-in-depth before publishing agent/model output to a PR comment, run
# artifact, or job summary — the text can include curl/gh invocations whose
# stderr leaks tokens, or echoed environment variables. Patterns cover GitHub,
# OpenAI/Anthropic, AWS, Google OAuth, generic bearer tokens, and PEM private
# keys.
redact_secrets() {
  # The PEM range (-----BEGIN ... -----END ...) uses sed's c\ range-change
  # so the *entire* multiline block is replaced — header line alone leaves
  # the key body lines intact and still leakable.
  sed -E \
    -e 's/(gh[opsu]|ghr)_[A-Za-z0-9_]{20,}/***REDACTED-GH-TOKEN***/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/***REDACTED-GH-PAT***/g' \
    -e 's/sk-(ant-)?[A-Za-z0-9_-]{20,}/***REDACTED-API-KEY***/g' \
    -e 's/AKIA[A-Z0-9]{16}/***REDACTED-AWS-KEY***/g' \
    -e 's/AIza[A-Za-z0-9_-]{35}/***REDACTED-GOOGLE-KEY***/g' \
    -e 's|ya29\.[A-Za-z0-9_-]+|***REDACTED-GOOGLE-OAUTH***|g' \
    -e 's/[Bb]earer [A-Za-z0-9._-]{20,}/Bearer ***REDACTED***/g' \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\
***REDACTED-PRIVATE-KEY***'
}
