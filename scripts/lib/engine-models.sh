# shellcheck shell=bash
# scripts/lib/engine-models.sh — the model list of each provider (AI_MODELS_<PROVIDER>).
#
# One Actions variable per provider holds every model it uses, so a retired or
# renamed model is a variable edit rather than a code change and a release:
#
#   AI_MODELS_CLAUDE   triage=… ; deep=… ; audit=… ; action=… ; single=… ; duck=…
#   AI_MODELS_GEMINI   flash=… ; pro=… ; duck=…
#   AI_MODELS_COPILOT  model=…
#
# Each entry is <key>=<model>[,<fallback>,…]. Entries are separated by ';' or
# newlines; spaces are ignored; keys are case-insensitive. A key that is left out
# keeps its default (ai_models_default). Chains are walked left to right on a
# rate limit, before any cross-provider fallback (AI_ENGINES).
#
#   Claude tiers  triage (classify)   deep (agentic review)   audit (security)
#                 action (dev-lead writer)   single (single-reviewer mode)
#                 duck (model when Claude is the rubber duck; one model)
#   Gemini        flash → triage + action;   pro → deep + audit + single;
#                 duck (model when Gemini is the rubber duck; default: flash's first)
#   Copilot       model (GitHub Models id for every tier; one model — the
#                 GitHub Models client has no in-engine chain)
#   A duck or model key given several models warns and keeps the first.
#
# Precedence per key, highest first:
#   1. the specific env var kept for existing callers: CLAUDE_<TIER>_MODEL_CHAIN,
#      GEMINI_FLASH_MODEL_CHAIN / GEMINI_PRO_MODEL_CHAIN, GEMINI_FLASH_MODEL /
#      GEMINI_PRO_MODEL (replace only the first model), COPILOT_API_MODEL;
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
#   - Fable 5 (honoured by the claude CLI automatically): adaptive thinking only
#     (budget_tokens/temperature/top_p/top_k removed); omit the thinking param
#     entirely (disabled returns 400); min cacheable prefix fable-5 = 2048 tok,
#     opus-4-8 = 4096 tok.
#   - The subscription cap is shared across Claude models (#206), so an
#     in-Claude chain only helps with per-model RPM/TPM limits.
ai_models_default() {
  case "${1:-}:${2:-}" in
    claude:triage) printf '%s' "claude-haiku-4-5-20251001,claude-sonnet-5" ;;
    claude:deep)   printf '%s' "claude-opus-5-5,claude-opus-4-8,claude-sonnet-5" ;;
    claude:audit)  printf '%s' "claude-fable-5,claude-opus-4-8,claude-opus-4-7" ;;
    claude:action) printf '%s' "claude-sonnet-5,claude-opus-4-8" ;;
    claude:single) printf '%s' "claude-fable-5,claude-opus-4-8,claude-opus-4-7" ;;
    claude:duck)   printf '%s' "claude-sonnet-4-6" ;;
    # gemini-2.5-pro is withdrawn for new keys ("no longer available to new
    # users … use models/gemini-3.1-pro-preview", #1960), so the quality tier
    # uses 3.1-pro-preview and degrades to the flash model that is known to work.
    gemini:flash)  printf '%s' "gemini-3.8-flash,gemini-3.1-pro-preview" ;;
    gemini:pro)    printf '%s' "gemini-3.1-pro-preview,gemini-3.8-flash" ;;
    copilot:model) printf '%s' "openai/o4-mini" ;;
  esac
}

# _ai_models_keys <provider> — the keys AI_MODELS_<PROVIDER> accepts.
_ai_models_keys() {
  case "${1:-}" in
    claude)  printf '%s' "triage deep audit action single duck" ;;
    gemini)  printf '%s' "flash pro duck" ;;
    copilot) printf '%s' "model" ;;
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
    if [[ "$chain" == *,* ]] && { [ "$key" = duck ] || [ "$key" = model ]; }; then
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

# ai_models_gemini_flash_first — the Gemini flash tier's primary model, with the
# same precedence set_engine_config applies: GEMINI_FLASH_MODEL_CHAIN, then
# GEMINI_FLASH_MODEL, then AI_MODELS_GEMINI flash / the default. Used where one
# flash model is needed outside the chain walk (the Gemini duck, the billing probe).
ai_models_gemini_flash_first() {
  local c="${GEMINI_FLASH_MODEL_CHAIN:-${GEMINI_FLASH_MODEL:-$(ai_models_chain gemini flash)}}"
  c="${c%%,*}"
  printf '%s' "${c//[[:space:]]/}"
}

# ai_models_problems — one line per unusable AI_MODELS_* entry, all providers.
ai_models_problems() {
  local p
  for p in claude gemini copilot; do
    _ai_models_scan "$p" problems
  done
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
