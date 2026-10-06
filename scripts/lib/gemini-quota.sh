# shellcheck shell=bash
# scripts/lib/gemini-quota.sh — Gemini quota self-metering + per-key cooldown memory (#2030).
#
# Gemini reports no remaining quota we can rely on, so this library meters it from
# the fleet's OWN token ledger (TOKEN_LOG_FILE, written by emit_token_record) against
# the maintainer-supplied caps in gemini-quota-caps.tsv. Nothing here makes a
# network call, reads a key value, or hard-codes a provider limit.
#
# Keys are identified by INDEX only: 1 = the primary slot (GEMINI_API_KEY /
# GOOGLE_API_KEY), N = GOOGLE_API_KEY_N. A key value never reaches a log, a record,
# or stdout.
#
# Fail direction (deliberately the opposite of the Claude probe's fail-open):
# unknown limits, a missing caps row, or an unreadable/corrupt ledger make a key
# "unknown" — the caller treats it as CONSTRAINED, never as healthy.
#
# Cooldown memory rides the SAME Token Observatory JSONL channel as the usage it
# meters: a kind:"gemini_key_cooldown" record {key_index, model, until} in the
# ledger. Cost reports keep only kind "token_usage", so these records never price.
#
# Sourced (no side effects at source time). Environment (all optional):
#   GEMINI_QUOTA_CAPS   — caps file (default: gemini-quota-caps.tsv alongside this lib)
#   GEMINI_LEDGER_FILE  — ledger to meter (default: TOKEN_LOG_FILE)
#   GEMINI_QUOTA_NOW    — epoch override for the clock (tests)

if [ -z "${GEMINI_QUOTA_CAPS:-}" ]; then
  GEMINI_QUOTA_CAPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gemini-quota-caps.tsv"
fi

# Window lengths are definitions of "per minute" / "per day", not provider limits.
_GQ_MINUTE=60
_GQ_DAY=86400

# gq_now — current epoch seconds, honouring GEMINI_QUOTA_NOW.
gq_now() {
  if [[ "${GEMINI_QUOTA_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$GEMINI_QUOTA_NOW"
  else
    date +%s
  fi
}

# gq_ledger_file — the ledger path being metered (empty when none is configured).
gq_ledger_file() {
  printf '%s' "${GEMINI_LEDGER_FILE:-${TOKEN_LOG_FILE:-}}"
}

# gq_setting <name> — value of a `setting` row in the caps file (empty when absent).
gq_setting() {
  [ -f "$GEMINI_QUOTA_CAPS" ] || return 0
  awk -F'\t' -v n="$1" '$1 == "setting" && $2 == n { print $3; exit }' "$GEMINI_QUOTA_CAPS"
}

# gq_key_index <VAR_NAME> — the key index for a Gemini key variable name.
gq_key_index() {
  case "${1:-}" in
    GEMINI_API_KEY) printf '1' ;;
    # A GOOGLE_API_KEY holding a different credential than GEMINI_API_KEY is its own
    # key: it gets its own index so cooldowns and ledger usage are not merged.
    GOOGLE_API_KEY)
      if [ -n "${GEMINI_API_KEY:-}" ] && [ "${GOOGLE_API_KEY:-}" != "$GEMINI_API_KEY" ]; then
        printf '1b'
      else
        printf '1'
      fi ;;
    GOOGLE_API_KEY_[0-9]*)         printf '%s' "${1#GOOGLE_API_KEY_}" ;;
    *)                             return 1 ;;
  esac
}

# gq_caps_for <key_index> <model> — "tier\trpm\ttpm\trpd" of the most specific caps
# row whose glob matches <model> (most literal characters), or nothing.
gq_caps_for() {
  [ -f "$GEMINI_QUOTA_CAPS" ] || return 0
  awk -F'\t' -v idx="$1" -v model="$2" '
    function glob2re(g,   re) {
      re = g
      gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)
      gsub(/\*/, ".*", re)
      gsub(/\?/, ".", re)
      return "^" re "$"
    }
    /^[[:space:]]*#/ || NF < 6 || $1 != idx { next }
    model ~ glob2re($2) {
      lit = $2; gsub(/[*?]/, "", lit)
      if (!found || length(lit) > best) { best = length(lit); out = $3 "\t" $4 "\t" $5 "\t" $6; found = 1 }
    }
    END { if (found) print out }' "$GEMINI_QUOTA_CAPS"
}

# gq_default_cooldown_sec — the configured default cooldown. The last-resort value
# when the setting is missing/invalid is one requests-per-minute window.
gq_default_cooldown_sec() {
  local v; v="$(gq_setting default_cooldown_sec)"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
    printf '%s' "$v"
  else
    printf '%s' "$_GQ_MINUTE"
  fi
}

# gq_day_start — epoch where the current requests/day window began: the most recent
# configured daily reset, or (reset unknown) a rolling 24h — which counts at least as
# many calls as any real reset window, so it errs constrained.
gq_day_start() {
  local now t tz d r
  now="$(gq_now)"
  t="$(gq_setting daily_reset_time)"
  tz="$(gq_setting daily_reset_tz)"
  if [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && [ -n "$tz" ] && [ "$tz" != "unknown" ]; then
    d="$(TZ="$tz" date -d "@$now" +%Y-%m-%d 2>/dev/null)" \
      && r="$(TZ="$tz" date -d "$d $t" +%s 2>/dev/null)" \
      && [[ "$r" =~ ^[0-9]+$ ]] && {
        if [ "$r" -gt "$now" ]; then
          # Previous local calendar day (not now-86400: DST days are 23/25h).
          d="$(TZ="$tz" date -d "$d -1 day" +%Y-%m-%d 2>/dev/null)" \
            && r="$(TZ="$tz" date -d "$d $t" +%s 2>/dev/null)" \
            && [[ "$r" =~ ^[0-9]+$ ]] || r=$(( now - _GQ_DAY ))
        fi
        printf '%s' "$r"
        return 0
      }
  fi
  printf '%s' $(( now - _GQ_DAY ))
}

# gq_ledger_rows <key_index> <since_epoch>
# Prints "<epoch>\t<model>\t<tokens>" for every gemini token_usage record of the key
# at/after since_epoch (tokens = input + cache-read + output). Returns 1 and prints a
# one-line reason (and nothing else) when the ledger cannot be trusted: none
# configured, not readable, or any malformed line. A configured ledger file that does
# not exist yet is an EMPTY ledger (a run's ledger is created by its first record).
gq_ledger_rows() {
  local idx="$1" since="$2" f out
  f="$(gq_ledger_file)"
  if [ -z "$f" ]; then
    printf 'no ledger configured — TOKEN_LOG_FILE unset'
    return 1
  fi
  [ -e "$f" ] || return 0
  if [ ! -r "$f" ] || [ -d "$f" ]; then
    printf 'ledger file is not readable'
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'jq unavailable'; return 1; }
  out="$(jq -R -s -r --arg k "$idx" --argjson since "$since" '
      [ split("\n")[] | select(test("\\S")) | (try fromjson catch "__bad__") ] as $recs
      | ($recs | map(select(. == "__bad__")) | length) as $badjson
      | ($recs | map(select(type == "object"
            and (.kind // "token_usage") == "token_usage" and .engine == "gemini"
            and ((.key_index // "" | tostring) == $k)
            and ( ((.ts // "") | try fromdateiso8601 catch null) == null
                  or ([.input_tokens, .cache_read_tokens, .output_tokens]
                      | any(. != null and type != "number")) )))
          | length) as $badrec
      | ($badjson + $badrec) as $bad
      | if $bad > 0 then "BAD\t\($bad)"
        else
          $recs[] | select(type == "object")
          | select((.kind // "token_usage") == "token_usage" and .engine == "gemini")
          | select((.key_index // "" | tostring) == $k)
          | ((.ts // "") | try fromdateiso8601 catch null) as $e
          | select($e != null and $e >= $since)
          | [ $e, (.model // ""),
              ((.input_tokens // 0) + (.cache_read_tokens // 0) + (.output_tokens // 0)) ]
          | @tsv
        end' "$f" 2>/dev/null)" || { printf 'ledger could not be parsed'; return 1; }
  if [[ "$out" == BAD$'\t'* ]]; then
    printf 'ledger has %s malformed line(s)' "${out#BAD$'\t'}"
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# gq_key_pct <key_index> [model]
# Prints the key's usage as an integer percent of its tightest cap — the max over
# its caps rows (all rows, or only rows whose glob matches <model>) and over the
# rpm / tpm / rpd windows. Prints "unknown<TAB><reason>" instead when there is no
# matching row or any matching row has an `unknown` (or invalid) limit (reason
# "limits"), or the ledger is unreadable (reason "ledger: <why>").
gq_key_pct() {
  local idx="$1" model="${2:-}" now day since rows
  now="$(gq_now)"
  day="$(gq_day_start)"
  since=$(( now - _GQ_MINUTE ))
  [ "$day" -lt "$since" ] && since="$day"
  if ! rows="$(gq_ledger_rows "$idx" "$since")"; then
    printf 'unknown\tledger: %s' "$rows"
    return 0
  fi
  local result
  # The "#ledger" sentinel keeps the first input non-empty so FNR == NR is exact.
  result="$(printf '#ledger\n%s\n' "$rows" | awk -F'\t' -v idx="$idx" -v model="$model" \
      -v minute_start=$(( now - _GQ_MINUTE )) -v day="$day" '
    function glob2re(g,   re) {
      re = g
      gsub(/[.[\]()^$+{}|\\]/, "\\\\&", re)
      gsub(/\*/, ".*", re)
      gsub(/\?/, ".", re)
      return "^" re "$"
    }
    # pct_of <cap> <used> — -1 = unknown/invalid, -2 = no cap on this window.
    function pct_of(cap, used) {
      if (cap == "none") return -2
      if (cap !~ /^[0-9]+$/) return -1
      if (cap + 0 == 0) return 100
      return int(used * 100 / cap)
    }
    FNR == NR { if (NF >= 3) { n++; ce[n] = $1; cm[n] = $2; ct[n] = $3 }; next }
    /^[[:space:]]*#/ || NF < 6 || $1 != idx { next }
    {
      re = glob2re($2)
      if (model != "" && model !~ re) next
      rows++
      r1 = 0; t1 = 0; rd = 0
      for (i = 1; i <= n; i++) if (cm[i] ~ re) {
        if (ce[i] >= minute_start) { r1++; t1 += ct[i] }
        if (ce[i] >= day) rd++
      }
      split(pct_of($4, r1) " " pct_of($5, t1) " " pct_of($6, rd), p, " ")
      for (j = 1; j <= 3; j++) {
        if (p[j] == -1) unknown = 1
        else if (p[j] > best) best = p[j]
      }
    }
    END { if (rows == 0 || unknown) print "unknown"; else print best + 0 }
  ' - "$GEMINI_QUOTA_CAPS" 2>/dev/null)"
  if [ -z "$result" ] || [ "$result" = "unknown" ]; then
    printf 'unknown\tlimits'
    return 0
  fi
  printf '%s' "$result"
}

# gq_engine_headroom <threshold> <key_index>...
# Engine-level verdict over the configured keys. Prints one '|'-separated line ('|',
# not TAB: `read` would collapse an empty middle field between two tabs):
#   ok|<pct>                           — some key has measured headroom (pct = best key)
#   over|<pct>                         — every key is metered and at/above threshold
#   unknown|<limits_keys>|<ledger_why> — no key with measured headroom and at least
#                                        one key is unknown (comma-separated indexes
#                                        with unknown limits; ledger reason, if any)
gq_engine_headroom() {
  local threshold="$1"; shift
  local idx pct best="" unknown_keys="" ledger_why=""
  for idx in "$@"; do
    pct="$(gq_key_pct "$idx")"
    if [[ "$pct" == unknown* ]]; then
      case "${pct#unknown$'\t'}" in
        "ledger: "*) ledger_why="${pct#unknown$'\t'ledger: }" ;;
        *)           unknown_keys="${unknown_keys:+$unknown_keys,}$idx" ;;
      esac
      continue
    fi
    if [ -z "$best" ] || [ "$pct" -lt "$best" ]; then best="$pct"; fi
  done
  if [ -n "$best" ] && [ "$best" -lt "$threshold" ]; then
    printf 'ok|%s\n' "$best"
  elif [ -z "$unknown_keys" ] && [ -z "$ledger_why" ] && [ -n "$best" ]; then
    printf 'over|%s\n' "$best"
  else
    printf 'unknown|%s|%s\n' "$unknown_keys" "$ledger_why"
  fi
}

# gq_record_cooldown <key_index> <model> <seconds> <reason>
# Appends a kind:"gemini_key_cooldown" record (deadline = now + seconds) to the
# ledger. No-op when no ledger is configured; never fails the caller.
gq_record_cooldown() {
  local idx="$1" model="$2" secs="$3" reason="${4:-}" f now
  f="$(gq_ledger_file)"
  [ -n "$f" ] || return 0
  [[ "$secs" =~ ^[0-9]+$ ]] || secs="$(gq_default_cooldown_sec)"
  now="$(gq_now)"
  jq -cn --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
    --arg workflow "${TOKEN_WORKFLOW:-unknown}" --arg run_id "${GITHUB_RUN_ID:-}" \
    --arg k "$idx" --arg model "$model" --argjson until $(( now + 10#$secs )) --arg reason "$reason" \
    '{ kind: "gemini_key_cooldown", ts: $ts, workflow: $workflow, engine: "gemini",
       key_index: ($k | tonumber? // $k), model: $model, until: $until,
       reason: $reason, run_id: $run_id }' 2>/dev/null >> "$f" || true
}

# gq_cooldown_until <key_index> <model>
# Prints the latest still-active cooldown deadline (epoch) for the key on <model>,
# or nothing. An unreadable ledger reads as "no cooldown" — the headroom gate already
# treats every key as constrained in that case.
gq_cooldown_until() {
  local idx="$1" model="$2" f now
  f="$(gq_ledger_file)"
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 0
  now="$(gq_now)"
  jq -R -r --arg k "$idx" --arg m "$model" --argjson now "$now" '
      try fromjson catch empty
      | select(type == "object" and .kind == "gemini_key_cooldown")
      | select((.key_index | tostring) == $k and .model == $m)
      | .until | numbers | select(. > $now)' "$f" 2>/dev/null \
    | sort -n | tail -1
}

# gq_retry_hint_sec <file>... — seconds the provider asked us to wait (rounded up),
# from a google.rpc.RetryInfo `retryDelay` or "retry in/after Ns" text. Prints
# nothing when no hint is present.
gq_retry_hint_sec() {
  local files=() f hint
  for f in "$@"; do [ -n "$f" ] && [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  hint="$(grep -ohiE 'retryDelay"?[[:space:]]*:[[:space:]]*"?[0-9]+(\.[0-9]+)?s|retry[ -](in|after):?[[:space:]]*[0-9]+(\.[0-9]+)?' \
    "${files[@]}" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)" || true
  [ -n "$hint" ] || return 0
  awk -v h="$hint" 'BEGIN { s = int(h); if (h > s) s++; print s }'
}

# gq_rotation_plan <model> <threshold> <VAR_NAME>...
# Orders the configured keys for one model. Prints, one per line:
#   cool\t<VAR_NAME>\t<index>\t<until_epoch>  — skip: cooling down on this model
#   use\t<VAR_NAME>\t<index>                  — try, in this order: keys with measured
#                                              headroom first, then constrained ones
#                                              (unknown limits / at-or-above threshold)
gq_rotation_plan() {
  local model="$1" threshold="$2"; shift 2
  local name idx until pct now first="" mid="" last="" _dep=", ${GEMINI_DEPLETED_KEYS:-}, "
  now="$(gq_now)"
  for name in "$@"; do
    idx="$(gq_key_index "$name")" || continue
    until="$(gq_cooldown_until "$idx" "$model")"
    if [ -n "$until" ] && [ "$until" -gt "$now" ]; then
      printf 'cool\t%s\t%s\t%s\n' "$name" "$idx" "$until"
      continue
    fi
    pct="$(gq_key_pct "$idx" "$model")"
    if [[ "$_dep" == *", ${name}, "* ]]; then
      # Billing-depleted keys stay last resort whatever their measured headroom (#1777).
      last="${last}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    elif [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -lt "$threshold" ]; then
      first="${first}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    else
      mid="${mid}use"$'\t'"${name}"$'\t'"${idx}"$'\n'
    fi
  done
  printf '%s%s%s' "$first" "$mid" "$last"
}
