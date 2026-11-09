#!/usr/bin/env bash
# LiteLLM helpers that need the running proxy.
#   scripts/litellm.sh keys           virtual keys holmes and judge -> Secrets holmes-llm, judge-llm
#   scripts/litellm.sh spend-export   write the current spend to .dryruns/llm-spend/<ts>.json
#   scripts/litellm.sh spend          print the live spend, the cumulative spend and the budget
#   scripts/litellm.sh budget-check   one-off: a temporary key with a tiny budget is refused (Task 3.11 Step 4)
# The master key and the minted keys never appear in process arguments or output: curl reads
# its credentials from a config file descriptor.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=scripts/secrets.sh
. "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"

# llm_call BEARER METHOD PATH [JSON_BODY] -> response body on stdout; non-2xx fails
llm_call() {
  local bearer="$1" method="$2" path="$3" body="${4:-}" args=()
  [[ -z "$body" ]] || args=(-H 'Content-Type: application/json' -d "$body")
  curl -sf --max-time 30 -X "$method" "${args[@]}" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$bearer") "${LITELLM_HOST_URL}${path}"
}

llm_master() { llm_call "$LITELLM_MASTER_KEY" "$@"; }

# stored_key SECRET : the key held in the Secret, or nothing
stored_key() {
  k get secret "$1" -n "$NS_AIOPS" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true
}

# ensure_key ALIAS SECRET MODEL BUDGET : reuse the stored key while the proxy accepts it,
# otherwise drop any key with that alias and mint a new one.
ensure_key() {
  local alias="$1" secret="$2" model="$3" budget="$4" cur new
  cur="$(stored_key "$secret")"
  if [[ -n "$cur" ]] && llm_call "$cur" GET /key/info >/dev/null 2>&1; then
    log_info "skip: Secret $NS_AIOPS/$secret holds a key the proxy accepts ($alias)"
    return 0
  fi
  if llm_master GET "/key/list?key_alias=${alias}" | jq -e '.keys | length > 0' >/dev/null; then
    llm_master POST /key/delete "$(jq -nc --arg a "$alias" '{key_aliases: [$a]}')" >/dev/null
    log_info "removed the old key with alias $alias"
  fi
  new="$(llm_master POST /key/generate "$(jq -nc --arg a "$alias" --arg m "$model" --argjson b "$budget" \
    '{key_alias: $a, models: [$m], max_budget: $b} + (if $b == null then {rpm_limit: 10, tpm_limit: 100000} else {} end)')" | jq -r '.key // empty')"
  [[ -n "$new" ]] || die "LiteLLM returned no key for $alias"
  _new_secret_dir
  _put OPENAI_API_KEY "$new"
  _apply_secret "$NS_AIOPS" "$secret"
}

cmd_keys() {
  if [[ "${LLM_PROVIDER:-}" == chatgpt ]]; then
    _have LITELLM_MASTER_KEY || die "LITELLM_MASTER_KEY is missing in .env"
    wait_for "LiteLLM at $LITELLM_HOST_URL" 180 curl -sf --max-time 5 "${LITELLM_HOST_URL}/health/readiness"
    ensure_key holmes holmes-llm "$LLM_ALIAS_RCA" null
    ensure_key judge judge-llm "$LLM_ALIAS_JUDGE" null
    return
  fi
  _have LITELLM_MASTER_KEY LLM_BUDGET_USD || die "LITELLM_MASTER_KEY or LLM_BUDGET_USD is missing in .env"
  wait_for "LiteLLM at $LITELLM_HOST_URL" 180 curl -sf --max-time 5 "${LITELLM_HOST_URL}/health/readiness"
  local holmes_budget
  holmes_budget="$(awk -v b="$LLM_BUDGET_USD" 'BEGIN { printf "%.4f", b * 0.6 }')"
  ensure_key holmes holmes-llm "$LLM_ALIAS_RCA" "$holmes_budget"
  ensure_key judge judge-llm "$LLM_ALIAS_JUDGE" "$LLM_BUDGET_USD"
}

# spend_total DIR LIVE : the sum of "total" in DIR/*.json plus LIVE, 4 decimals
spend_total() {
  local dir="$1" live="$2" f sum=0
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.json; do
      [[ -e "$f" ]] || continue
      sum="$(awk -v s="$sum" -v t="$(jq -r '.total // 0' "$f")" 'BEGIN { printf "%.6f", s + t }')"
    done
  fi
  awk -v s="$sum" -v l="$live" 'BEGIN { printf "%.4f\n", s + l }'
}

spend_dir() { printf '%s/.dryruns/llm-spend' "$(main_root)"; }

# live_spend : the proxy's total spend in USD, deleted keys included (GET /global/spend)
live_spend() {
  llm_master GET /global/spend | jq -r '.spend // 0' | awk '{ printf "%.6f\n", $1 }'
}

cmd_spend_export() {
  _have LITELLM_MASTER_KEY || die "LITELLM_MASTER_KEY is missing in .env"
  local dir ts total out
  dir="$(spend_dir)"; mkdir -p "$dir"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$dir/$ts.json"
  total="$(live_spend)"
  # per key, from /global/spend/keys (a deleted key keeps its row, with a null alias)
  llm_master GET '/global/spend/keys?limit=100' \
    | jq --arg ts "$ts" --argjson total "$total" \
        '{ts: $ts, total: $total, keys: [.[]? | {alias: .key_alias, spend: (.total_spend // 0)}]}' > "$out"
  log_info "llm-spend-export: $out (total \$$total)"
}

cmd_spend() {
  if [[ "${LLM_PROVIDER:-}" == chatgpt ]]; then
    printf 'ChatGPT subscription: dollar spend and remaining quota are unavailable from LiteLLM. Key limits: 10 requests/minute, 100000 tokens/minute.\n'
    return
  fi
  _have LITELLM_MASTER_KEY LLM_BUDGET_USD || die "LITELLM_MASTER_KEY or LLM_BUDGET_USD is missing in .env"
  local live cum
  live="$(live_spend)"
  cum="$(spend_total "$(spend_dir)" "$live")"
  awk -v l="$live" -v c="$cum" -v b="$LLM_BUDGET_USD" \
    'BEGIN { printf "live %.4f remaining %.4f cumulative %.4f budget %.2f\n", l, b - l, c, b }'
}

cmd_budget_check() {
  [[ "${LLM_PROVIDER:-}" != chatgpt ]] || die "Dollar budget enforcement is unavailable for ChatGPT subscriptions; use the configured request/token limits"
  _have LITELLM_MASTER_KEY || die "LITELLM_MASTER_KEY is missing in .env"
  local key code n body resp
  key="$(llm_master POST /key/generate "$(jq -nc --arg m "$LLM_ALIAS_RCA" \
    '{key_alias: "budget-check", models: [$m], max_budget: 0.0001}')" | jq -r '.key // empty')"
  [[ -n "$key" ]] || die "no temporary key"
  resp="$(mktemp)"
  _budget_cleanup() {
    rm -f "$resp"
    llm_master POST /key/delete "$(jq -nc '{key_aliases: ["budget-check"]}')" >/dev/null || true
  }
  body="$(jq -nc --arg m "$LLM_ALIAS_RCA" \
    '{model: $m, max_tokens: 20, messages: [{role: "user", content: "Count from one to ten in words, then reply with the single word done."}]}')"
  # Call 1 must succeed: a 4xx there means a bad key or model alias, not a budget, and would
  # prove nothing. After that, only a 4xx whose body names the budget counts.
  for n in 1 2 3 4; do
    : > "$resp"
    code="$(curl -s -o "$resp" -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' -d "$body" \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") "${LITELLM_HOST_URL}/v1/chat/completions" || true)"
    log_info "budget-check call $n: HTTP $code"
    [[ "$code" == 200 ]] && continue
    if ((n > 1)) && [[ "$code" =~ ^4 ]] && grep -qiE 'budget_exceeded|budget has been exceeded' "$resp"; then
      _budget_cleanup
      log_info "budget-check: refused on call $n (max_budget 0.0001)"
      return 0
    fi
    _budget_cleanup
    if ((n == 1)); then
      die "budget-check: call 1 returned HTTP $code, not 200 (check the key and the $LLM_ALIAS_RCA alias)"
    fi
    die "budget-check: call $n returned HTTP $code without a budget error"
  done
  _budget_cleanup
  die "budget-check: no budget refusal in 4 calls; the budget is not enforced"
}

main() {
  local cmd="${1:-}"
  load_env
  trap _cleanup_secret_dir EXIT
  case "$cmd" in
    keys)         cluster_lock; require_context; cmd_keys ;;
    spend-export) require_context; cmd_spend_export ;;
    spend)        require_context; cmd_spend ;;
    budget-check) cluster_lock; require_context; cmd_budget_check ;;
    *) die "usage: litellm.sh keys|spend-export|spend|budget-check" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
