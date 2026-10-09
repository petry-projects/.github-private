#!/usr/bin/env bash
set -euo pipefail
# scripts/check-retry-payload-fields.sh (#2081) — fail when the dev-lead retry
# sweep sends a client_payload field that the pinned channel's intent parser
# does not read.
#
# The sweep (scripts/dev-lead-retry.sh and the libs it sources) dispatches
# repository_dispatch events whose client_payload is parsed by
# scripts/dev-lead-intent.sh at the channel tag dev-lead.yml pins via agent_ref,
# not at main. A field the sweep on main sends but the pinned parser ignores is
# dropped, and the dispatched run fails or misroutes (#2050: comment_node_id
# broke every fix-bot-comment retry). Order: harness support reaches the pinned
# channel first, the sweep change merges second (AGENTS.md "Caller-stub input
# forwarding across channel pins").
#
# The channel is read from the stub's agent_ref, so a major bump needs no edit
# here. Only top-level client_payload keys are compared; nested keys (e.g.
# checks[].details_url) are consumed downstream of the parser.
#
# Usage: check-retry-payload-fields.sh [root]   (root defaults to the repo root)
# Exit:  0 every sent field is read · 1 one or more unread fields (each printed)
#        2 setup error (agent_ref missing/malformed, tag unresolvable, nothing
#          parsed), so the sweep cannot be certified

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STUB=".github/workflows/dev-lead.yml"
SWEEP="scripts/dev-lead-retry.sh"
PARSER="scripts/dev-lead-intent.sh"

# Fields the sweep sends for logs and audit only; no harness code reads them, at
# any channel. Adding a field here asserts that nothing downstream needs it.
#   repo    — redundant with the dispatch target repository
#   attempt — retry counter carried for the run log (#781)
INFORMATIONAL_FIELDS=(repo attempt)

die() { echo "check-retry-payload-fields: $*" >&2; exit 2; }

[ -f "$ROOT/$STUB" ] || die "$STUB not found under $ROOT"
channel=$(sed -n 's/^[[:space:]]*agent_ref:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]#]*\).*/\1/p' "$ROOT/$STUB" | head -n1)
[ -n "$channel" ] || die "no agent_ref in $STUB"
[[ "$channel" =~ ^dev-lead/v[0-9]+-(next|ring0|ring1|stable)$ ]] \
  || die "agent_ref '$channel' in $STUB is not a dev-lead channel tag"

# CI checkouts carry no tags, and a local tag may be stale after a promote, so
# refresh from origin when there is one. A failed fetch falls back to the local
# tag; a missing tag is a setup error.
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  git -C "$ROOT" fetch --quiet --force --depth=1 origin "refs/tags/${channel}:refs/tags/${channel}" 2>/dev/null \
    || echo "check-retry-payload-fields: warning: could not fetch ${channel} from origin; using the local tag" >&2
fi
parser_src=$(git -C "$ROOT" show "refs/tags/${channel}:${PARSER}" 2>/dev/null) \
  || die "cannot read ${PARSER} at ${channel}"

# The sweep plus every lib it sources (transitively), relative to ROOT.
files=()
queue=("$SWEEP")
while [ "${#queue[@]}" -gt 0 ]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  case " ${files[*]-} " in *" $f "*) continue ;; esac
  [ -f "$ROOT/$f" ] || die "$f not found under $ROOT"
  files+=("$f")
  while IFS= read -r lib; do
    queue+=("scripts/$lib")
  done < <(sed -n 's/^[[:space:]]*\(source\|\.\)[[:space:]]\{1,\}"\$SCRIPT_DIR\/\([^"]*\.sh\)".*/\2/p' "$ROOT/$f")
done

# Emit "<file>:<line> <field>" for every top-level key the sweep sends, from jq
# object literals (`client_payload: { key: …, … }`, keys at depth 1 only) and
# the gh -f form (`client_payload[key]=`).
sent=$(
  for f in "${files[@]}"; do
    awk -v file="$f" '
      {
        line = $0
        while (match(line, /client_payload\[[A-Za-z_][A-Za-z0-9_]*\]/)) {
          k = substr(line, RSTART + 15, RLENGTH - 16)
          print file ":" NR " " k
          line = substr(line, RSTART + RLENGTH)
        }
        i = 1
        if (!inblk) {
          if (!match($0, /client_payload[[:space:]]*:[[:space:]]*\{/)) next
          inblk = 1; depth = 1; expect = 1; tok = ""
          i = RSTART + RLENGTH
        }
        n = length($0)
        for (; i <= n && inblk; i++) {
          c = substr($0, i, 1)
          if (c == "{" || c == "[" || c == "(") { depth++; tok = ""; expect = 0; continue }
          if (c == "}" || c == "]" || c == ")") {
            if (depth == 1 && expect && tok != "") print file ":" NR " " tok
            depth--; tok = ""
            if (depth == 0) inblk = 0
            continue
          }
          if (depth != 1) continue
          if (c == ",") {
            if (expect && tok != "") print file ":" NR " " tok
            expect = 1; tok = ""; continue
          }
          if (!expect) continue
          if (c == ":") { if (tok != "") print file ":" NR " " tok; expect = 0; tok = ""; continue }
          if (c ~ /[A-Za-z0-9_]/) { tok = tok c; continue }
          if (c == "$" || c == "\"" || c ~ /[[:space:]]/) continue
          expect = 0; tok = ""
        }
      }' "$ROOT/$f"
  done
)
[ -n "$sent" ] || die "no client_payload fields found in ${files[*]}; the parser may need updating"

read_fields=$(grep -oE 'client_payload\.[A-Za-z_][A-Za-z0-9_]*' <<<"$parser_src" | sed 's/^client_payload\.//' | sort -u || true)

missing=0
while read -r loc field; do
  case " ${INFORMATIONAL_FIELDS[*]} " in *" $field "*) continue ;; esac
  if ! grep -qxF "$field" <<<"$read_fields"; then
    echo "client_payload.${field} (sent at ${loc}) is not read by ${PARSER} at ${channel}"
    missing=1
  fi
done <<<"$sent"

if [ "$missing" -ne 0 ]; then
  echo "Land the parser change and promote ${channel} before the sweep sends these fields (AGENTS.md \"Caller-stub input forwarding across channel pins\")."
  exit 1
fi
echo "OK: every client_payload field the sweep sends is read by ${PARSER} at ${channel}"
