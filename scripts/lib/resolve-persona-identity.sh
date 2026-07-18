#!/usr/bin/env bash
# resolve-persona-identity.sh — print a persona's declared runtime identity.
#
# Usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]
#   field: account (default) | credential
#
# Reads <personas-root>/<persona-id>/persona.yml and prints runtime.identity.<field>.
# This is the SINGLE runtime source of a persona's acting GitHub identity: the
# dev-lead and pr-review workflows resolve BOT_USER from `account` here instead of
# the shared `vars.BOT_USER` that let dev-lead regress to committing as the
# review-only machine user donpetry-bot (.github-private#1316).
#
# Fails LOUD (non-zero, message on stderr) if the manifest, the identity block, or
# the requested field is missing — it never emits a silent fallback identity, which
# is the whole point: an unresolved identity must stop the run, not default.
set -euo pipefail

id="${1:?usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]}"
root="${2:?usage: resolve-persona-identity.sh <persona-id> <personas-root> [field]}"
field="${3:-account}"

case "$field" in
  account | credential) ;;
  *)
    echo "resolve-persona-identity: field must be 'account' or 'credential', got '$field'" >&2
    exit 2
    ;;
esac

manifest="${root%/}/${id}/persona.yml"
if [ ! -f "$manifest" ]; then
  echo "resolve-persona-identity: no manifest at $manifest" >&2
  exit 1
fi

# Prefer PyYAML (same parser validate-personas.py uses); install on demand exactly
# as CI does so a hosted runner without it still resolves rather than guessing.
if ! python3 -c 'import yaml' 2>/dev/null; then
  python3 -m pip install --quiet --disable-pip-version-check pyyaml >&2 || {
    echo "resolve-persona-identity: PyYAML unavailable and could not be installed" >&2
    exit 3
  }
fi

python3 - "$manifest" "$field" <<'PY'
import sys, yaml

manifest, field = sys.argv[1], sys.argv[2]
with open(manifest, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}
identity = ((doc.get("runtime") or {}).get("identity")) or {}
val = identity.get(field)
if not val:
    sys.stderr.write(
        f"resolve-persona-identity: runtime.identity.{field} missing in {manifest}\n"
    )
    sys.exit(4)
print(val)
PY
