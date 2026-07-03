#!/usr/bin/env bash
set -euo pipefail
# validate-caller-inputs.sh — CI guard (#1052, Part A) against release-channel
# skew in reusable-workflow calls. For every workflow that calls a reusable via
#   uses: <owner>/<repo>/.github/workflows/<wf>.yml@<ref>
# WITH a `with:` block, it resolves the reusable AT <ref> (not HEAD) and asserts:
#   (a) every forwarded `with:` key is a declared `workflow_call` input there, and
#   (b) every `required: true` input there is forwarded.
#
# Why AT <ref>: `pull_request` CI runs workflows from the base branch, and GitHub
# validates a caller's `with:` against the reusable ONLY at startup, against the
# PINNED ref. So a stub that pins a same-repo channel tag (e.g. @pr-review/next)
# and forwards a key the PR only added to the reusable on HEAD passes every
# same-repo/HEAD check yet ends the first real run in `startup_failure` — the
# #1034 incident. actionlint only input-checks LOCAL `./` reusable refs, so it
# cannot catch this pinned-remote-ref skew; this guard is the coverage.
#
# Resolution:
#   • same-repo channel tags (pr-review/*, dev-lead/*, …): `git fetch` the ref and
#     read the reusable at it.
#   • cross-repo (auto-rebase → petry-projects/.github, feature-ideation, …):
#     `gh api` contents at the ref.
# FAIL LOUD on any forwarded key not declared / any required input not forwarded.
# Only SOFT-PASS (logged `::warning::`) when a ref genuinely can't be resolved
# (transient cross-repo read, missing token) — never silently.
#
# The pure helpers (YAML extraction + set-difference validators) are defined at
# the top level so tests can `source` this file without executing it (see the
# source-guard at the bottom and tests/dev-lead/unit/test_validate_caller_inputs.bats).

# The repo whose channel tags resolve via local git rather than the cross-repo API.
SELF_REPO="${GITHUB_REPOSITORY:-petry-projects/.github-private}"

# ── pure helpers (sourced by tests; no network) ──────────────────────────────

# extract_declared_inputs_tsv <reusable_file> — print "name<TAB>required" for
# every input declared under on.workflow_call.inputs. Pure: reads a local file.
# A small indentation state machine (comments/blank lines ignored for block
# boundaries) walks on: → workflow_call: → inputs: and lists the input keys at
# the first child indent, marking any with a nested `required: true`.
extract_declared_inputs_tsv() {
  awk '
    function indent(s,   t){ t=s; sub(/[^ ].*/,"",t); return length(t) }
    { line=$0; sub(/\r$/,"",line) }
    line ~ /^[[:space:]]*$/  { next }
    line ~ /^[[:space:]]*#/  { next }
    {
      ind=indent(line)
      if (ind==0) {
        on = (line ~ /^on:([[:space:]]|$)/) ? 1 : 0
        wc=0; inp=0; key_indent=-1
        next
      }
      if (!on) next
      if (!wc) {
        if (line ~ /^[[:space:]]*workflow_call:([[:space:]]|$)/) { wc=1; wc_ind=ind }
        next
      }
      if (ind <= wc_ind) { wc=0; inp=0; key_indent=-1; next }
      if (!inp) {
        if (line ~ /^[[:space:]]*inputs:([[:space:]]|$)/) { inp=1; inp_ind=ind }
        next
      }
      if (ind <= inp_ind) { inp=0; key_indent=-1; next }
      if (key_indent < 0) key_indent=ind
      if (ind == key_indent) {
        name=line; sub(/^[[:space:]]*/,"",name); sub(/:.*$/,"",name)
        cur=name; req[cur]="false"; order[++n]=cur
      } else if (ind > key_indent) {
        if (line ~ /^[[:space:]]*required:[[:space:]]*true([[:space:]]|$)/) req[cur]="true"
      }
    }
    END { for (i=1;i<=n;i++) printf "%s\t%s\n", order[i], req[order[i]] }
  ' "$1"
}

# extract_declared_inputs <reusable_file> — declared input names, one per line.
extract_declared_inputs() { extract_declared_inputs_tsv "$1" | cut -f1; }

# extract_required_inputs <reusable_file> — names of required:true inputs.
extract_required_inputs() { extract_declared_inputs_tsv "$1" | awk -F'\t' '$2=="true"{print $1}'; }

# extract_with_keys <caller_file> — keys of the `with:` block belonging to the
# FIRST reusable-workflow call in the file (the caller-stub shape: one reusable
# job per stub). Pure: reads a local file.
extract_with_keys() {
  awk '
    function indent(s,   t){ t=s; sub(/[^ ].*/,"",t); return length(t) }
    {
      line=$0; sub(/\r$/,"",line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*#/) next
      ind=indent(line)
      if (phase==0) {
        if (line ~ /uses:[[:space:]]*[^[:space:]]+\/\.github\/workflows\/[^[:space:]]+\.yml@/) {
          phase=1; uses_ind=ind
        }
        next
      }
      if (phase==1) {
        if (ind < uses_ind) { exit }
        if (ind==uses_ind && line ~ /^[[:space:]]*with:([[:space:]]|$)/) { phase=2; with_ind=ind; child_ind=-1; next }
        next
      }
      if (phase==2) {
        if (ind <= with_ind) { exit }
        if (child_ind<0) child_ind=ind
        if (ind==child_ind) {
          k=line; sub(/^[[:space:]]*/,"",k); sub(/:.*$/,"",k); print k
        }
        next
      }
    }
  ' "$1"
}

# extract_reusable_uses <caller_file> — every reusable-workflow `uses:` value
# (owner/repo/.github/workflows/<wf>.yml@<ref>), one per line. Third-party action
# refs (which have no /.github/workflows/…yml@ path) are ignored.
extract_reusable_uses() {
  awk '
    { line=$0; sub(/\r$/,"",line)
      if (line ~ /^[[:space:]]*#/) next
      if (line ~ /uses:[[:space:]]*[^[:space:]]+\/\.github\/workflows\/[^[:space:]]+\.yml@/) {
        v=line; sub(/^.*uses:[[:space:]]*/,"",v); sub(/[[:space:]].*$/,"",v); print v
      }
    }
  ' "$1"
}

# parse_caller_uses <uses> — split a reusable uses value into
# "owner/repo<TAB>workflow.yml<TAB>ref". The ref may itself contain slashes
# (channel tags like pr-review/next), so split on the single '@'.
parse_caller_uses() {
  local u="$1" path ref wf orr
  path="${u%@*}"
  ref="${u#*@}"
  wf="${path##*/}"
  orr="${path%/.github/workflows/*}"
  printf '%s\t%s\t%s\n' "$orr" "$wf" "$ref"
}

# inputs_not_declared <declared_newline> <forwarded_newline> — print each
# forwarded key that is NOT in the declared set; return 1 if any, 0 otherwise.
inputs_not_declared() {
  local declared="$1" forwarded="$2" k rc=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$declared" | grep -qxF -- "$k"; then
      printf '%s\n' "$k"
      rc=1
    fi
  done <<< "$forwarded"
  return "$rc"
}

# required_not_forwarded <required_newline> <forwarded_newline> — print each
# required input that is NOT forwarded; return 1 if any, 0 otherwise.
required_not_forwarded() {
  local required="$1" forwarded="$2" k rc=0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    if ! printf '%s\n' "$forwarded" | grep -qxF -- "$k"; then
      printf '%s\n' "$k"
      rc=1
    fi
  done <<< "$required"
  return "$rc"
}

# ── network resolver (driver only) ───────────────────────────────────────────
# resolve_reusable_at_ref <owner/repo> <workflow.yml> <ref> — write the reusable
# workflow's content AT <ref> to stdout. Same-repo refs resolve via local git
# (fetching the tag/ref); cross-repo refs resolve via `gh api` contents. Returns
# non-zero (empty output) when the ref genuinely can't be resolved so the caller
# can soft-pass with a `::warning::` rather than fail the job on a transient read.
resolve_reusable_at_ref() {
  local orr="$1" wf="$2" ref="$3" content=""
  if [ "$orr" = "$SELF_REPO" ]; then
    # Fetch the channel tag (channel tags carry slashes, e.g. pr-review/next),
    # then fall back to a branch/SHA ref, then read the reusable at it.
    if git fetch --quiet --force --depth=1 origin "refs/tags/${ref}:refs/tags/${ref}" 2>/dev/null; then
      content="$(git show "refs/tags/${ref}:.github/workflows/${wf}" 2>/dev/null || true)"
    fi
    if [ -z "$content" ] && git fetch --quiet --force --depth=1 origin "${ref}" 2>/dev/null; then
      content="$(git show "FETCH_HEAD:.github/workflows/${wf}" 2>/dev/null || true)"
    fi
  else
    content="$(gh api "repos/${orr}/contents/.github/workflows/${wf}?ref=${ref}" \
      --jq '.content' 2>/dev/null | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } || true)"
  fi
  [ -n "$content" ] || return 1
  printf '%s\n' "$content"
}

# ── CLI driver (network) ─────────────────────────────────────────────────────
main() {
  local cmd
  for cmd in awk git gh; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "::error::${cmd} is required but not installed." >&2; return 1; }
  done

  local wf_glob="${1:-.github/workflows}"
  local fail=0 checked=0 file uses orr rwf ref reusable declared required forwarded missing missing_req tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  echo "Caller-input skew check — forwarded with: keys vs inputs declared at the pinned ref:"
  local f
  for f in "$wf_glob"/*.yml "$wf_glob"/*.yaml; do
    [ -f "$f" ] || continue
    file="$f"
    # Only the FIRST reusable call per stub (the caller-stub shape).
    uses="$(extract_reusable_uses "$file" | head -1)"
    [ -n "$uses" ] || continue
    forwarded="$(extract_with_keys "$file")"
    [ -n "$forwarded" ] || continue   # no with: block → nothing GitHub validates

    IFS=$'\t' read -r orr rwf ref <<< "$(parse_caller_uses "$uses")"

    if ! reusable="$(resolve_reusable_at_ref "$orr" "$rwf" "$ref")"; then
      echo "::warning file=${file}::Could not resolve ${orr}/.github/workflows/${rwf}@${ref} to validate forwarded inputs — skipping (transient/cross-repo read). This is a soft-pass, not a green light."
      continue
    fi

    printf '%s' "$reusable" > "$tmp"
    declared="$(extract_declared_inputs "$tmp")"
    required="$(extract_required_inputs "$tmp")"
    checked=$((checked + 1))

    if missing="$(inputs_not_declared "$declared" "$forwarded")"; then
      : # all forwarded keys declared
    else
      fail=1
      local k
      while IFS= read -r k; do
        [ -n "$k" ] || continue
        echo "::error file=${file}::Forwarded input '${k}' is NOT declared by ${orr}/.github/workflows/${rwf} at the pinned ref '${ref}'. GitHub validates the caller's with: against the reusable AT THE PIN at startup, so this green-passes PR CI but will fail the first real run with startup_failure (the #1034 class). Land the input in the reusable and advance the pinned channel to a commit that declares it BEFORE forwarding it (see AGENTS.md 'Caller-stub input forwarding across channel pins')."
      done <<< "$missing"
    fi

    if missing_req="$(required_not_forwarded "$required" "$forwarded")"; then
      : # all required inputs forwarded
    else
      fail=1
      local r
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        echo "::error file=${file}::Required input '${r}' of ${orr}/.github/workflows/${rwf}@${ref} is not forwarded by this caller — the reusable call will fail to start."
      done <<< "$missing_req"
    fi

    echo "  ✓ ${file} → ${rwf}@${ref}: $(printf '%s' "$forwarded" | grep -c . || true) forwarded key(s) checked against $(printf '%s' "$declared" | grep -c . || true) declared input(s)."
  done

  if [ "$checked" -eq 0 ]; then
    echo "No channel-pinned reusable callers could be resolved for validation (all soft-passed)."
  fi
  return "$fail"
}

# Source-guard: tests source this to exercise the pure helpers; CI executes it.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
