# shellcheck shell=bash
# scripts/lib/engine-models.sh — the model list of each provider (AI_MODELS_<PROVIDER>).
#
# One Actions variable per provider holds every model it uses, so a retired or
# renamed model is a variable edit rather than a code change and a release:
#
#   AI_MODELS_CLAUDE   triage=… ; deep=… ; audit=… ; action=… ; single=… ; duck=…
#   AI_MODELS_GEMINI   (the same keys)
#   AI_MODELS_COPILOT  (the same keys)
#
# Each entry is <key>=<model>[,<fallback>,…]. Entries are separated by ';' or
# newlines; spaces are ignored; keys are case-insensitive. A key that is left out
# keeps its default (ai_models_default). Chains are walked left to right on a
# rate limit, before any cross-provider fallback (AI_ENGINES).
#
# Every provider takes the same keys, one per task:
#   triage  classify the PR            deep    agentic review
#   audit   security audit             action  dev-lead writer
#   single  single-reviewer mode
#   duck    the model used when this provider is the rubber duck (one model;
#           default: Claude sonnet 4.6, Gemini and Copilot the triage model)
# Copilot takes one model per key: the GitHub Models client has no in-engine
# chain. A duck key, or any Copilot key, given several models warns and keeps
# the first.
#
# Precedence per key, highest first:
#   1. the env vars kept for existing callers:
#        Claude   CLAUDE_<TIER>_MODEL_CHAIN (the whole chain);
#        Gemini   GEMINI_FLASH_MODEL_CHAIN (triage + action) and
#                 GEMINI_PRO_MODEL_CHAIN (deep + audit + single) replace the
#                 whole chain; GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL replace
#                 only its first model;
#        Copilot  COPILOT_API_MODEL (every key);
#   2. AI_MODELS_<PROVIDER>;
#   3. ai_models_default.
# An unknown key or a malformed model id drops that entry (its default applies);
# ai_models_problems reports it so engine.sh can warn once.
#
# Sourced by engine.sh. Defines functions only; runs nothing at source time.

# ai_models_default <provider> <key> — the built-in chain for <provider>/<key>.
#
# Claude notes:
#   - Sonnet 5 (#1100, epic #1095) is the default sonnet across triage, deep and
#     action, replacing claude-sonnet-4-6. The id is `claude-sonnet-5`: the
#     `claude-sonnet-5-0` spelling shipped by #1100 does not exist and 404s, so
#     every sonnet hop silently fell through to the next model (#1957).
#   - Deep swapped opus-4-8 → opus-5-5 (#1898, epic #1895 Phase 2). opus-4-8 is
#     the known-good 2nd hop (#1957), so a throttled or unavailable opus-5-5
#     degrades to the model it replaced instead of failing; sonnet 5 is last.
#   - Audit and single swapped fable-5 → opus-5-5 (#1901, epic #1895 Phase 3),
#     deprecating Fable 5: the engine no longer depends on Fable, which opus-5-5
#     outperforms at lower cost, so reviews run one current model family end to
#     end. Both keep opus-4-8 as the known-good 2nd hop and opus-4-7 as the last.
#   - opus-5-5's CLI/API default reasoning effort is `medium` (levels
#     low/medium/high/xhigh/max); the deep, audit and single tiers pin
#     `--effort high` in engine.sh's run_agentic so moving off Fable does not
#     silently lower their reasoning effort (triage/action keep the default).
#     Min cacheable prefix opus-4-8 = 4096 tok.
#   - Fable 5 is deprecated but not removed: a chain that still names a
#     claude-fable-* model (AI_MODELS_CLAUDE or CLAUDE_<TIER>_MODEL_CHAIN) is
#     honoured as a stop-gap and warns once per run (ai_models_fable_deprecation);
#     its price rows stay in model-pricing.tsv for historical token records.
#   - The subscription cap is shared across Claude models (#206), so an
#     in-Claude chain only helps with per-model RPM/TPM limits.
ai_models_default() {
  case "${1:-}:${2:-}" in
    claude:triage) printf '%s' "claude-haiku-4-5-20251001,claude-sonnet-5" ;;
    claude:deep)   printf '%s' "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ;;
    claude:audit)  printf '%s' "claude-opus-5-5,claude-opus-4-8,claude-opus-4-7" ;;
    claude:action) printf '%s' "claude-sonnet-5,claude-opus-4-8" ;;
    claude:single) printf '%s' "claude-opus-5-5,claude-opus-4-8,claude-opus-4-7" ;;
    claude:duck)   printf '%s' "claude-sonnet-4-6" ;;
    # gemini-2.5-pro is withdrawn for new keys ("no longer available to new
    # users … use models/gemini-3.1-pro-preview", #1960), so the quality tier
    # uses 3.1-pro-preview and degrades to the flash model that is known to work.
    # No gemini/copilot duck default: the duck follows the triage model.
    gemini:triage|gemini:action)
      printf '%s' "gemini-3.8-flash,gemini-3.1-pro-preview" ;;
    gemini:deep|gemini:audit|gemini:single)
      printf '%s' "gemini-3.1-pro-preview,gemini-3.8-flash" ;;
    copilot:triage|copilot:deep|copilot:audit|copilot:action|copilot:single)
      printf '%s' "openai/o4-mini" ;;
  esac
}

# _ai_models_keys <provider> — the keys AI_MODELS_<PROVIDER> accepts (the same
# for every provider).
_ai_models_keys() {
  case "${1:-}" in
    claude|gemini|copilot) printf '%s' "triage deep audit action single duck" ;;
  esac
}

# _ai_models_trim <text> — <text> without leading/trailing whitespace. Whitespace
# inside a model id is kept, so the id is then rejected rather than glued together.
_ai_models_trim() {
  local t="${1:-}"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# _ai_models_var <provider> — the variable name, e.g. AI_MODELS_CLAUDE.
# (tr, not ${var^^}: scripts stay runnable on Bash 3.2, as engine-chain.sh is.)
_ai_models_var() {
  printf 'AI_MODELS_%s' "$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
}

# _ai_models_scan <provider> <mode> [key]
#   mode=get      prints the normalised chain for [key] ("" when not configured)
#   mode=problems prints one line per unusable entry
# The last entry for a key wins; when it is unusable, the default applies.
_ai_models_scan() {
  local provider="$1" mode="$2" want="${3:-}" var spec entry key value m chain found=""
  local -a entries=() models=()
  var="$(_ai_models_var "$provider")"
  spec="${!var:-}"
  [ -n "${spec//[[:space:];]/}" ] || return 0
  spec="${spec//$'\r'/;}"
  spec="${spec//$'\n'/;}"
  IFS=';' read -r -a entries <<< "$spec"
  for entry in ${entries[@]+"${entries[@]}"}; do
    entry="$(_ai_models_trim "$entry")"
    [ -n "$entry" ] || continue
    if [[ "$entry" != *=* ]]; then
      [ "$mode" = problems ] && printf "%s: '%s' is not <key>=<models> — ignored\n" "$var" "$entry"
      continue
    fi
    key="$(_ai_models_trim "${entry%%=*}" | tr '[:upper:]' '[:lower:]')"
    value="${entry#*=}"
    if [[ " $(_ai_models_keys "$provider") " != *" $key "* ]]; then
      [ "$mode" = problems ] && printf "%s: unknown key '%s' (expected: %s) — ignored\n" \
        "$var" "$key" "$(_ai_models_keys "$provider")"
      continue
    fi
    IFS=',' read -r -a models <<< "$value"
    chain=""
    for m in ${models[@]+"${models[@]}"}; do
      m="$(_ai_models_trim "$m")"
      [ -n "$m" ] || continue
      if [[ ! "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then
        chain=""
        [ "$mode" = problems ] && printf "%s: '%s' has an invalid model id '%s' — default used\n" "$var" "$key" "$m"
        break
      fi
      [[ ",$chain," == *",$m,"* ]] || chain="${chain:+$chain,}$m"
    done
    if [ -z "$chain" ]; then
      [ "$mode" = problems ] && [[ "$value" =~ ^[,[:space:]]*$ ]] && printf "%s: '%s' lists no model — default used\n" "$var" "$key"
      # The last entry for a key wins even when unusable: drop an earlier one so
      # the default applies, as the warning says.
      [ "$key" = "$want" ] && found=""
      continue
    fi
    if [[ "$chain" == *,* ]] && { [ "$key" = duck ] || [ "$provider" = copilot ]; }; then
      [ "$mode" = problems ] && printf "%s: '%s' takes one model — only '%s' is used\n" "$var" "$key" "${chain%%,*}"
      chain="${chain%%,*}"
    fi
    [ "$key" = "$want" ] && found="$chain"
  done
  [ "$mode" = get ] && printf '%s' "$found"
  return 0
}

# ai_models_configured <provider> <key> — the chain AI_MODELS_<PROVIDER> sets for
# <key>, or nothing when it is not configured (or unusable).
ai_models_configured() {
  _ai_models_scan "${1:-}" get "${2:-}"
}

# ai_models_chain <provider> <key> — the configured chain, else the default.
ai_models_chain() {
  local c
  c="$(ai_models_configured "$1" "$2")"
  [ -n "$c" ] || c="$(ai_models_default "$1" "$2")"
  printf '%s' "$c"
}

# ai_models_replace_first <first> <chain> — <chain> with its first model replaced
# by <first> (the GEMINI_FLASH_MODEL / GEMINI_PRO_MODEL override: swap the primary,
# keep the rest of the chain as fallbacks, so a retired primary is not retried).
ai_models_replace_first() {
  local first="$1" chain="$2" out="$1" m
  local -a others=()
  IFS=',' read -r -a others <<< "$chain"
  for m in ${others[@]+"${others[@]:1}"}; do
    [ -n "$m" ] && [ "$m" != "$first" ] && out="$out,$m"
  done
  printf '%s' "$out"
}

# ai_models_gemini_chain <key> — the Gemini chain for <key>, resolved when it is
# used rather than stored, so a child shell that re-sources engine.sh gets the
# same answer. triage and action honour GEMINI_FLASH_MODEL_CHAIN /
# GEMINI_FLASH_MODEL; deep, audit and single honour GEMINI_PRO_MODEL_CHAIN /
# GEMINI_PRO_MODEL; duck is AI_MODELS_GEMINI duck=…, else the triage chain's
# first model.
ai_models_gemini_chain() {
  local key="${1:-}" group first c
  case "$key" in
    triage|action)      group="${GEMINI_FLASH_MODEL_CHAIN:-}"; first="${GEMINI_FLASH_MODEL:-}" ;;
    deep|audit|single)  group="${GEMINI_PRO_MODEL_CHAIN:-}";   first="${GEMINI_PRO_MODEL:-}" ;;
    duck)
      c="$(ai_models_configured gemini duck)"
      [ -n "$c" ] || { c="$(ai_models_gemini_chain triage)"; c="${c%%,*}"; }
      printf '%s' "$c"
      return 0 ;;
    *) return 0 ;;
  esac
  if [ -n "${group//[[:space:],]/}" ]; then
    printf '%s' "${group//[[:space:]]/}"
    return 0
  fi
  c="$(ai_models_chain gemini "$key")"
  first="${first//[[:space:]]/}"
  [ -z "$first" ] || c="$(ai_models_replace_first "$first" "$c")"
  printf '%s' "$c"
}

# ai_models_copilot_model <key> — the one GitHub Models id Copilot uses for
# <key>: COPILOT_API_MODEL when the caller set it (every key), else
# AI_MODELS_COPILOT, else the default; duck falls back to the triage model.
# engine.sh defaults COPILOT_API_MODEL to the triage model and records that
# default in COPILOT_API_MODEL_DEFAULTED, so a value it set itself (inherited by
# a child shell) is not mistaken for the caller's.
ai_models_copilot_model() {
  local key="${1:-}" m=""
  if [ -n "${COPILOT_API_MODEL:-}" ] && [ "$COPILOT_API_MODEL" != "${COPILOT_API_MODEL_DEFAULTED:-}" ]; then
    m="$COPILOT_API_MODEL"
  else
    m="$(ai_models_configured copilot "$key")"
    [ -n "$m" ] || [ "$key" != duck ] || key=triage
    [ -n "$m" ] || m="$(ai_models_chain copilot "$key")"
  fi
  m="${m%%,*}"
  printf '%s' "${m//[[:space:]]/}"
}

# ai_models_problems — one line per unusable AI_MODELS_* entry, all providers.
ai_models_problems() {
  local p
  for p in claude gemini copilot; do
    _ai_models_scan "$p" problems
  done
}

# ai_models_fable_deprecation — one deprecation line when a *configured* Claude
# chain still names a claude-fable-* model, else nothing. Fable 5 is deprecated
# (#1901, epic #1895 Phase 3): audit/single now default to claude-opus-5-5. A
# configured Fable model is still HONOURED as a stop-gap (this warns, it does not
# reject), so an operator can pin it while migrating. Sources checked: the
# per-tier CLAUDE_<TIER>_MODEL_CHAIN envs and AI_MODELS_CLAUDE.
ai_models_fable_deprecation() {
  local key chain var found=""
  for key in triage deep audit action single; do
    var="CLAUDE_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')_MODEL_CHAIN"
    chain="${!var:-}"
    case ",${chain// /}," in *,claude-fable-*) found=1 ;; esac
  done
  for key in triage deep audit action single duck; do
    chain="$(ai_models_configured claude "$key")"
    case ",$chain," in *,claude-fable-*) found=1 ;; esac
  done
  [ -n "$found" ] || return 0
  printf '%s' "claude-fable-* is deprecated (#1901): audit/single now default to claude-opus-5-5 (chain claude-opus-5-5,claude-opus-4-8,claude-opus-4-7). The configured Fable model is still honoured as a stop-gap — repoint it to claude-opus-5-5."
}

# ai_model_label <model> — a short name for log lines:
#   claude-haiku-4-5-20251001 → haiku 4.5, claude-opus-5-5 → opus 5.5,
#   claude-sonnet-5 → sonnet 5, openai/o4-mini → o4-mini; others unchanged.
ai_model_label() {
  local m="${1:-}" family ver
  m="${m#*/}"
  case "$m" in
    claude-*)
      m="${m#claude-}"
      [[ "$m" =~ -[0-9]{8}$ ]] && m="${m%-*}"
      family="${m%%-*}"
      ver="${m#"$family"}"
      ver="${ver#-}"
      if [ -n "$ver" ]; then printf '%s %s' "$family" "${ver//-/.}"; else printf '%s' "$family"; fi
      ;;
    *) printf '%s' "$m" ;;
  esac
}

# ai_models_label_chain <chain> — "first [fallback, …]" for log lines.
ai_models_label_chain() {
  local chain="${1:-}" first fallbacks="" m
  local -a ms=()
  IFS=',' read -r -a ms <<< "$chain"
  first="$(ai_model_label "${ms[0]:-}")"
  for m in ${ms[@]+"${ms[@]:1}"}; do
    [ -n "$m" ] && fallbacks="${fallbacks:+$fallbacks, }$(ai_model_label "$m")"
  done
  if [ -n "$fallbacks" ]; then printf '%s [%s]' "$first" "$fallbacks"; else printf '%s' "$first"; fi
}
