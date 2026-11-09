#!/usr/bin/env bash
# Pre-flight checks. Exits 1 on any FAIL.   scripts/preflight.sh [RUNG] [--armed] [--pre-promotion] [--job-run] [--quiet]
#   --armed          rung 3 is promoted: autonomy on the tracked branch must be act
#   --pre-promotion  autonomy must still be propose (rung 3, before the promotion PR merges)
#   --job-run        running inside the scheduled unit: GH_TOKEN (from job.env) is the credential,
#                    and the github-admin section (Luke's admin login) is skipped
#   --quiet          print only failures; exit status is the same
# Rung-specific sections need the rung (1, 2 or 3): fleet, github_admin (2 and 3), github_runtime, job (3).
# Without a rung only the platform sections run.
#
# L5b checks (Task 4.5): the checks that need the promotion-board team and code-owner review (the
# tracked ruleset's code-owner rule, the team's repo permission, the stage approver's membership,
# the App installation permissions) are hard checks by default (PREFLIGHT_L5B=1). On a repository
# that has not applied the full `github-ruleset.sh apply` yet (a fresh fork), PREFLIGHT_L5B=auto
# makes them WARN lines "deferred to L5b" until the code-owner rule is live on the tracked branch,
# and PREFLIGHT_L5B=0 always defers them.
#
# Test/tuning overrides: PREFLIGHT_FLEET_WAIT_S (how long to wait for the fleet gauge series, default 20),
# PREFLIGHT_MIN_FREE_GB (default 5), SYSTEMD_USER_DIR, XDG_RUNTIME_DIR. PREFLIGHT_REQUIRE_SCORE=1
# makes a missing full dry-run score a FAIL (section dryrun; stage-day morning sets it).
# Sections are functions named section_<name>. V1_SECTIONS runs first, in order; any other
# section_* function defined by a later slice runs after them (alphabetically).
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PASS=0
FAIL=0
WARN=0
RUNG=""
ARMED=0
PRE_PROMOTION=0
JOB_RUN=0
QUIET=0
check_pass() { ((QUIET)) || printf '  \033[0;32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
check_fail() { printf '  \033[0;31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check_warn() { ((QUIET)) || printf '  \033[0;33m[WARN]\033[0m %s\n' "$1"; WARN=$((WARN + 1)); }
say() { ((QUIET)) || printf '%s\n' "$*"; }

parse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --armed) ARMED=1 ;;
      --pre-promotion) PRE_PROMOTION=1 ;;
      --job-run) JOB_RUN=1 ;;
      --quiet) QUIET=1 ;;
      --*) echo "preflight: unknown option $a" >&2; exit 2 ;;
      *) RUNG="$a" ;;
    esac
  done
}

V1_SECTIONS=(tools context cluster nodes pods endpoints)

section_tools() {
  local out
  if out="$("$COMMON_SH_DIR/vendor-check.sh" 2>&1)"; then
    check_pass "tools: all present at the pinned versions"
  else
    while IFS= read -r line; do check_fail "$line"; done <<<"$out"
  fi
}

section_context() {
  local out
  if out="$(require_context 2>&1)"; then
    check_pass "kube context is $CLUSTER_CONTEXT on the isolated kubeconfig"
  else
    check_fail "kube context guard: $out"
  fi
}

section_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    check_pass "kind cluster '$CLUSTER_NAME' exists"
  else
    check_fail "kind cluster '$CLUSTER_NAME' does not exist"
  fi
}

# A stopped kind container still passes require_context (it reads only the local
# kubeconfig), so every cluster read below is guarded: a failed kubectl is a FAIL line
# with a reason, never a silent errexit before the summary.
_api_up() { k get --raw=/readyz >/dev/null 2>&1; }

section_nodes() {
  local json not_ready total
  if ! json="$(k get nodes -o json 2>/dev/null)"; then
    check_fail "API server unreachable: cannot list nodes"
    return 0
  fi
  total="$(jq '.items | length' <<<"$json")"
  not_ready="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status != "True")) | .metadata.name] | join(" ")' <<<"$json")"
  if [[ "$total" -ge 1 && -z "$not_ready" ]]; then
    check_pass "all $total nodes Ready"
  else
    check_fail "nodes not Ready: ${not_ready:-none found}"
  fi
}

# Namespaces that must hold at least one pod. Any other namespace (kube-system, local-path-storage,
# default, ...) is checked too, but may be empty.
_required_namespaces() { printf '%s\n' "$NS_ARGOCD" "$NS_ROLLOUTS" "$NS_MONITORING" "$NS_DEMO" "$NS_AIOPS"; }

section_pods() {
  local ns json bad count all_ns
  if ! _api_up; then
    check_fail "API server unreachable: pods not checked"
    return 0
  fi
  if ! all_ns="$(k get namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name')"; then
    check_fail "cannot list namespaces"
    return 0
  fi
  # shellcheck disable=SC2046
  all_ns="$(printf '%s\n' "$all_ns" $(_required_namespaces) | sort -u)"
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    if ! k get namespace "$ns" >/dev/null 2>&1; then
      check_fail "namespace $ns does not exist"; continue
    fi
    if ! json="$(k get pods -n "$ns" -o json 2>/dev/null)"; then
      check_fail "cannot list pods in $ns"; continue
    fi
    count="$(jq '[.items[] | select(.status.phase != "Succeeded")] | length' <<<"$json")"
    bad="$(jq -r '
      [.items[] | select(.status.phase != "Succeeded")
       | select(any(.status.conditions[]?; .type == "Ready" and .status == "True") | not)
       | .metadata.name] | join(" ")' <<<"$json")"
    if [[ "$count" -eq 0 ]] && ! _required_namespaces | grep -qx "$ns"; then
      continue
    elif [[ "$count" -ge 1 && -z "$bad" ]]; then
      check_pass "every pod Ready in $ns ($count)"
    elif [[ "$count" -ge 1 ]] && pods_ready "$ns" 2>/dev/null; then
      check_pass "every pod Ready in $ns ($count; a retried Job's failed attempt is ignored)"
    else
      check_fail "pods not Ready in $ns: ${bad:-none running}"
    fi
  done <<<"$all_ns"
}

section_endpoints() {
  if [[ "$(curl -s --max-time 5 "$ARGOCD_HOST_URL/healthz" || true)" == "ok" ]]; then
    check_pass "Argo CD answers on $ARGOCD_HOST_URL"
  else
    check_fail "Argo CD does not answer on $ARGOCD_HOST_URL"
  fi
  if curl -sf --max-time 5 "$GRAFANA_HOST_URL/api/health" >/dev/null; then
    check_pass "Grafana answers on $GRAFANA_HOST_URL"
  else
    check_fail "Grafana does not answer on $GRAFANA_HOST_URL"
  fi
  if curl -sf --max-time 5 "$PROM_HOST_URL/-/ready" >/dev/null; then
    check_pass "Prometheus is ready on $PROM_HOST_URL"
  else
    check_fail "Prometheus is not ready on $PROM_HOST_URL"
  fi
}

# llm: the proxy answers on the rca alias, the holmes key has budget left, and the build's
# cumulative spend (exports of earlier clusters plus the live proxy) is under LLM_BUDGET_USD.
section_llm() {
  local key code info left live cum
  # shellcheck source=scripts/litellm.sh
  . "$COMMON_SH_DIR/litellm.sh"
  if ! _have LITELLM_MASTER_KEY || { [[ "${LLM_PROVIDER:-}" != chatgpt ]] && ! _have LLM_BUDGET_USD; }; then
    check_fail "llm: LITELLM_MASTER_KEY or LLM_BUDGET_USD is missing in .env"; return 0
  fi
  if ! curl -sf --max-time 5 "${LITELLM_HOST_URL}/health/readiness" >/dev/null; then
    check_fail "llm: LiteLLM does not answer on $LITELLM_HOST_URL"; return 0
  fi
  key="$(stored_key holmes-llm)"
  if [[ -z "$key" ]]; then
    check_fail "llm: Secret holmes-llm is missing (make litellm-keys)"; return 0
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$LLM_ALIAS_RCA" '{model: $m, max_tokens: 5, messages: [{role: "user", content: "Reply ok."}]}')" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$key") "${LITELLM_HOST_URL}/v1/chat/completions" || true)"
  if [[ "$code" == 200 ]]; then
    check_pass "llm: completion on alias $LLM_ALIAS_RCA returns 200"
  else
    check_fail "llm: completion on alias $LLM_ALIAS_RCA returned HTTP ${code:-none}"
  fi
  if [[ "${LLM_PROVIDER:-}" == chatgpt ]]; then
    if info="$(llm_call "$key" GET /key/info 2>/dev/null)" && jq -e '.info.rpm_limit == 10 and .info.tpm_limit == 100000' <<<"$info" >/dev/null; then
      check_pass "llm: holmes key limits 10 requests/minute, 100000 tokens/minute"
    else
      check_fail "llm: ChatGPT key request/token limits missing or unreadable"
    fi
    check_warn "llm: ChatGPT subscription usage is not metered in dollars; dollar budget check unavailable"
    return 0
  fi
  if info="$(llm_call "$key" GET /key/info 2>/dev/null)"; then
    left="$(jq -r '((.info.max_budget // 0) - (.info.spend // 0))' <<<"$info")"
    if awk -v l="$left" 'BEGIN { exit !(l > 5) }'; then
      check_pass "llm: the holmes key has \$$(printf '%.2f' "$left") left"
    else
      check_fail "llm: the holmes key has only \$$(printf '%.2f' "$left") left (need more than \$5)"
    fi
  else
    check_fail "llm: GET /key/info failed for the holmes key"
  fi
  live="$(live_spend 2>/dev/null || echo 0)"
  cum="$(spend_total "$(spend_dir)" "$live")"
  if awk -v c="$cum" -v b="$LLM_BUDGET_USD" 'BEGIN { exit !(c <= b) }'; then
    check_pass "$(awk -v l="$live" -v c="$cum" -v b="$LLM_BUDGET_USD" 'BEGIN { printf "llm: this cluster has $%.2f of $%.2f left; the build has spent $%.2f in all", b - l, b, c }')"
  else
    check_fail "llm: the build has spent \$$cum, over LLM_BUDGET_USD (\$$LLM_BUDGET_USD)"
  fi
}

# bridge_hooks (every rung): the test-hook Secret bridge-env must not exist, and the running
# bridge must report no test hook active. A failure-paths run that was killed leaves it behind,
# and then every live incident is refused or handed off (Task 4.6). Key names only, never values.
section_bridge_hooks() {
  local json keys status
  if ! _api_up; then
    check_fail "API server unreachable: bridge-env not checked"; return 0
  fi
  if ! json="$(k get secret bridge-env -n "$NS_AIOPS" --ignore-not-found -o json 2>/dev/null)"; then
    check_fail "cannot read Secret bridge-env in $NS_AIOPS"; return 0
  fi
  if [[ -z "$json" ]]; then
    check_pass "no bridge-env Secret (no bridge test hooks)"
  else
    keys="$(jq -r '(.data // {}) | keys | join(" ")' <<<"$json")"
    check_fail "Secret bridge-env exists (${keys:-no keys}): run make bridge-hooks-clear"
  fi
  if ! status="$(curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status")"; then
    check_warn "bridge /status does not answer on port $PORT_BRIDGE: test hooks not checked"
  elif jq -e '.test_hooks_active == false' >/dev/null <<<"$status"; then
    check_pass "bridge /status: no test hook active"
  else
    check_fail "bridge /status: test hooks active (confidence_threshold $(jq -r .confidence_threshold <<<"$status"), holmes_timeout_s $(jq -r .holmes_timeout_s <<<"$status")): run make bridge-hooks-clear"
  fi
}

# ------------------------------------------------------------------ apps
# Every Argo CD Application is Synced and Healthy (spec section 9).
section_apps() {
  local json bad total
  if ! _api_up; then
    check_fail "apps: API server unreachable; Argo CD Applications not checked"; return 0
  fi
  if ! json="$(k get applications.argoproj.io -n "$NS_ARGOCD" -o json 2>/dev/null)"; then
    check_fail "apps: cannot list Argo CD Applications"; return 0
  fi
  total="$(jq '.items | length' <<<"$json")"
  bad="$(jq -r '[.items[]
      | select((.status.sync.status // "Unknown") != "Synced" or (.status.health.status // "Unknown") != "Healthy")
      | "\(.metadata.name) (\(.status.sync.status // "Unknown")/\(.status.health.status // "Unknown"))"] | join(", ")' <<<"$json")"
  if [[ "$total" -ge 1 && -z "$bad" ]]; then
    check_pass "apps: all $total Argo CD Applications are Synced and Healthy"
  else
    check_fail "apps: not Synced and Healthy: ${bad:-no Applications found}"
  fi
}

# ------------------------------------------------------------------ bridge
# The bridge Deployment runs, and /status says it can write for real: a GitHub token, a reachable
# HolmesGPT and no dry forge. (bridge_hooks, below, covers the test hooks.)
section_bridge() {
  local dep ready want status
  if ! _api_up; then
    check_fail "bridge: API server unreachable; Deployment not checked"
  elif ! dep="$(k get deployment bridge -n "$NS_AIOPS" -o json 2>/dev/null)"; then
    check_fail "bridge: Deployment bridge not found in $NS_AIOPS"
  else
    want="$(jq -r '.spec.replicas // 0' <<<"$dep")"
    ready="$(jq -r '.status.readyReplicas // 0' <<<"$dep")"
    if [[ "$want" -ge 1 && "$ready" -ge 1 ]]; then
      check_pass "bridge: Deployment has $ready of $want replicas ready"
    else
      check_fail "bridge: Deployment has $ready of $want replicas ready (scaled to 0 or not Ready)"
    fi
  fi
  if ! status="$(curl -sf --max-time 5 "127.0.0.1:${PORT_BRIDGE}/status")"; then
    check_fail "bridge: /status does not answer on port $PORT_BRIDGE"; return 0
  fi
  if jq -e '.github_token_ok == true' >/dev/null 2>&1 <<<"$status"; then
    check_pass "bridge /status: github_token_ok"
  else
    check_fail "bridge /status: github_token_ok is not true (the App token does not mint)"
  fi
  if jq -e '.holmes_reachable == true' >/dev/null 2>&1 <<<"$status"; then
    check_pass "bridge /status: holmes_reachable"
  else
    check_fail "bridge /status: holmes_reachable is not true"
  fi
  if jq -e '.dry_forge == false' >/dev/null 2>&1 <<<"$status"; then
    check_pass "bridge /status: dry_forge is false"
  else
    check_fail "bridge /status: dry_forge is not false (writes would be simulated)"
  fi
}

# ------------------------------------------------------------------ holmes
# HolmesGPT is read-only and cannot read Secrets (Task 3.12 Step 2): the live can-i checks.
section_holmes() {
  local out line n=0
  if ! _api_up; then
    check_fail "holmes: API server unreachable; can-i checks not run"; return 0
  fi
  if out="$("$COMMON_SH_DIR/holmes-rbac.sh" live 2>&1)"; then
    check_pass "holmes: the ServiceAccount cannot read Secrets or create pods, and can read pods and rollouts"
  else
    while IFS= read -r line; do
      if [[ "$line" == *"error: "* ]]; then check_fail "holmes: ${line#*error: }"; n=$((n + 1)); fi
    done <<<"$out"
    ((n > 0)) || check_fail "holmes: holmes-rbac.sh live failed: ${out##*$'\n'}"
  fi
}

# ------------------------------------------------------------------ fleet
# Rungs 1 to 3. check_fleet_disarmed (Task 1.3) catches the armed-but-Healthy fleet a canary-less
# sync produces; its FAIL lines are passed through. Rungs 1 and 2 also need the stable image, and
# no checkout pod may have restarted since the last disarm (the disarm bump recreates the pods, so
# a restart count above 0 on a current pod happened after it).
section_fleet() {
  local out line pods
  [[ "$RUNG" =~ ^[123]$ ]] || return 0
  if ! _api_up; then
    check_fail "fleet: API server unreachable; checkout fleet not checked"; return 0
  fi
  if out="$(FLEET_WAIT_S="${PREFLIGHT_FLEET_WAIT_S:-20}" FLEET_RATE_WAIT_S="${PREFLIGHT_FLEET_RATE_WAIT_S:-75}" check_fleet_disarmed 2>&1)"; then
    check_pass "fleet: ${out##*$'\n'}"
  else
    line="$(grep -F 'FAIL:' <<<"$out" | tail -n1 || true)"
    check_fail "fleet: ${line:-check_fleet_disarmed failed: ${out##*$'\n'}}"
  fi
  if ! pods="$(k get pods -n "$NS_DEMO" -l "$CHECKOUT_POD_SELECTOR" -o json 2>/dev/null)"; then
    check_fail "fleet: cannot list checkout pods"; return 0
  fi
  if [[ "$RUNG" == 1 || "$RUNG" == 2 ]]; then
    local wrong
    wrong="$(jq -r --arg t ":${CHECKOUT_STABLE_TAG}" '[.items[] | select(.metadata.deletionTimestamp == null)
        | select(any(.spec.containers[]; (.image | endswith($t)) | not)) | .metadata.name] | join(" ")' <<<"$pods")"
    if [[ -z "$wrong" ]]; then
      check_pass "fleet: every checkout pod runs the stable image $CHECKOUT_STABLE_TAG"
    else
      check_fail "fleet: checkout pods not on the stable image $CHECKOUT_STABLE_TAG: $wrong"
    fi
  fi
  local restarted
  restarted="$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null)
      | select(([.status.containerStatuses[]?.restartCount] | add // 0) > 0) | .metadata.name] | join(" ")' <<<"$pods")"
  if [[ -z "$restarted" ]]; then
    check_pass "fleet: no checkout pod has restarted since the last disarm"
  else
    check_fail "fleet: checkout pods restarted since the last disarm: $restarted"
  fi
}

# ------------------------------------------------------------------ local
# The operator's machine: the pre-commit hook in the main repo and in the operator clone, one kube
# context in the isolated kubeconfig, and disk space.
section_local() {
  local common hook ctxs n free_kb min_gb
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  hook="${common:-$(main_root)/.git}/hooks/pre-commit"
  if [[ -x "$hook" ]]; then check_pass "local: pre-commit hook installed in the main repo"; else check_fail "local: no executable pre-commit hook at $hook"; fi
  hook="$OPERATOR_DIR/.git/hooks/pre-commit"
  if [[ -x "$hook" ]]; then
    check_pass "local: pre-commit hook installed in the operator clone"
  else
    check_fail "local: no executable pre-commit hook in the operator clone ($hook; make operator-clone)"
  fi
  if ctxs="$(kubectl config get-contexts -o name 2>/dev/null)"; then
    n="$(grep -c . <<<"$ctxs" || true)"
    if [[ "$n" == 1 && "$ctxs" == "$CLUSTER_CONTEXT" ]]; then
      check_pass "local: the isolated kubeconfig holds one context ($CLUSTER_CONTEXT)"
    else
      check_fail "local: the isolated kubeconfig holds $n contexts ($(tr '\n' ' ' <<<"$ctxs")); expected only $CLUSTER_CONTEXT"
    fi
  else
    check_fail "local: cannot list kube contexts"
  fi
  min_gb="${PREFLIGHT_MIN_FREE_GB:-5}"
  free_kb="$(df -Pk "$(main_root)" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && ((free_kb > min_gb * 1024 * 1024)); then
    check_pass "local: $((free_kb / 1024 / 1024)) GB free (need more than $min_gb GB)"
  else
    check_fail "local: ${free_kb:-unknown} KB free; need more than $min_gb GB"
  fi
}

# ------------------------------------------------------------------ GitHub helpers
# True when the L5b checks are hard. PREFLIGHT_L5B=1 (the default) / 0 forces it; under auto it is
# true when the tracked branch's rules carry code-owner review. Read with whichever credential gh holds.
# Fails closed: when the rules cannot be read (no access, rate limit, 5xx) that is a FAIL of its
# own and the L5b checks run as hard checks; only a successful read without the rule defers them.
_L5B=""
l5b_active() {
  local rules
  case "${PREFLIGHT_L5B:-1}" in 1) return 0 ;; 0) return 1 ;; auto) ;; *) die "PREFLIGHT_L5B must be 1, 0 or auto" ;; esac
  if [[ -z "$_L5B" ]]; then
    if ! rules="$(gh api "repos/${REPO_SLUG}/rules/branches/${TRACKED_BRANCH}" 2>/dev/null)" \
        || ! jq -e 'type == "array"' <<<"$rules" >/dev/null 2>&1; then
      _L5B=yes
      check_fail "github: cannot read the rules on $TRACKED_BRANCH; the L5b checks run as hard checks"
    elif jq -e 'any(.[]?; .type == "pull_request" and .parameters.require_code_owner_review == true)' \
        <<<"$rules" >/dev/null 2>&1; then _L5B=yes; else _L5B=no; fi
  fi
  [[ "$_L5B" == yes ]]
}

# l5b_check MESSAGE : a failure, or a WARN while the L5b checks are deferred (PREFLIGHT_L5B=0|auto).
l5b_check() {
  if l5b_active; then check_fail "$1"; else check_warn "$1 (deferred to L5b)"; fi
}

_team_org() { local t="${PROMOTION_TEAM#@}"; printf '%s' "${t%%/*}"; }
_team_slug() { local t="${PROMOTION_TEAM#@}"; printf '%s' "${t#*/}"; }

# _rulesets_json : every ruleset of the repo, in full, as one JSON array.
_rulesets_json() {
  local ids id out="[]"
  ids="$(gh api "repos/${REPO_SLUG}/rulesets" 2>/dev/null | jq -r '.[].id')" || return 1
  while read -r id; do
    [[ -n "$id" ]] || continue
    out="$(jq -c --argjson r "$(gh api "repos/${REPO_SLUG}/rulesets/$id" 2>/dev/null)" '. + [$r]' <<<"$out")" || return 1
  done <<<"$ids"
  printf '%s' "$out"
}

_ruleset_refs() { # branch list from RULESET_BRANCHES -> JSON array of refs/heads/...
  local IFS=','
  # shellcheck disable=SC2086
  set -- $RULESET_BRANCHES
  printf '%s\n' "$@" | sed '/^$/d' | jq -R '"refs/heads/" + .' | jq -s -c .
}

# ------------------------------------------------------------------ github-admin
# Luke's admin gh login. Run by preflight 2 and 3, never by --job-run (main skips it; so does this).
section_github_admin() {
  local repo rs refs name r label org slug perm state login
  ((JOB_RUN)) && return 0
  [[ "$RUNG" == 2 || "$RUNG" == 3 ]] || return 0
  if ! repo="$(gh api "repos/${REPO_SLUG}" 2>/dev/null)"; then
    check_fail "github-admin: cannot read repos/$REPO_SLUG with the gh login"; return 0
  fi
  if jq -e '.allow_auto_merge == true' >/dev/null <<<"$repo"; then
    check_pass "github-admin: allow_auto_merge is on"
  else
    check_fail "github-admin: allow_auto_merge is not on"
  fi
  if jq -e '.security_and_analysis.secret_scanning_push_protection.status == "enabled"' >/dev/null <<<"$repo"; then
    check_pass "github-admin: secret-scanning push protection is enabled"
  else
    check_fail "github-admin: secret-scanning push protection is not enabled (or security_and_analysis is hidden: the gh login is not an admin)"
  fi
  if ! rs="$(_rulesets_json)"; then
    check_fail "github-admin: cannot read the rulesets"; return 0
  fi
  refs="$(_ruleset_refs)"
  _admin_integrity "$rs" "$refs"
  _admin_tracked "$rs" "$refs"
  _admin_promote "$rs"
  org="$(_team_org)"; slug="$(_team_slug)"
  # Without the repository media type GitHub answers 204 with no body, so nothing to read.
  if perm="$(gh api -H 'Accept: application/vnd.github.v3.repository+json' \
        "orgs/${org}/teams/${slug}/repos/${REPO_SLUG}" 2>/dev/null)" \
      && jq -e '(.role_name // "") as $r
                | (["push","write","maintain","admin"] | index($r) != null)
                  or (.permissions.push == true)' >/dev/null <<<"$perm"; then
    check_pass "github-admin: team $slug has push or higher on the repo"
  else
    l5b_check "github-admin: team $slug has no push access to the repo (or does not exist)"
  fi
  for label in demo-reset policy-negative-test; do
    if gh api "repos/${REPO_SLUG}/labels/$label" >/dev/null 2>&1; then
      check_pass "github-admin: label $label exists"
    else
      check_fail "github-admin: label $label is missing (github-ruleset.sh apply creates it)"
    fi
  done
  if [[ "$RUNG" == 2 || ( "$RUNG" == 3 && $PRE_PROMOTION -eq 1 ) ]]; then
    login="${STAGE_APPROVER_LOGIN:-}"
    if [[ -z "$login" ]]; then
      check_warn "github-admin: no stage approver set; rung 2 needs admin bypass"
    else
      state="$(gh api "orgs/${org}/teams/${slug}/memberships/${login}" 2>/dev/null | jq -r '.state // empty' 2>/dev/null || true)"
      if [[ "$state" == active ]]; then
        check_pass "github-admin: the stage approver's membership of $slug is active"
      else
        l5b_check "github-admin: the stage approver's membership of $slug is '${state:-absent}', not active"
      fi
    fi
  fi
}

_ruleset_named() { jq -c --arg n "$2" '[.[] | select(.name == $n)][0] // empty' <<<"$1"; }

_admin_integrity() { # RULESETS REFS
  local r
  r="$(_ruleset_named "$1" "$RULESET_INTEGRITY")"
  if [[ -z "$r" ]]; then check_fail "github-admin: ruleset $RULESET_INTEGRITY does not exist"; return 0; fi
  if jq -e --argjson want "$2" '(.conditions.ref_name.include) as $i | all($want[]; . as $w | $i | index($w) != null)
        and ([.rules[].type] | (index("deletion") != null and index("non_fast_forward") != null))
        and ((.bypass_actors // []) | length == 0)' >/dev/null <<<"$r"; then
    check_pass "github-admin: $RULESET_INTEGRITY covers $RULESET_BRANCHES with deletion and non_fast_forward and no bypass actor"
  else
    check_fail "github-admin: $RULESET_INTEGRITY must cover every RULESET_BRANCHES entry with deletion and non_fast_forward and an empty bypass list"
  fi
}

_admin_tracked() { # RULESETS REFS
  local r
  r="$(_ruleset_named "$1" "$RULESET_TRACKED")"
  if [[ -z "$r" ]]; then check_fail "github-admin: ruleset $RULESET_TRACKED does not exist"; return 0; fi
  if jq -e --argjson want "$2" '(.conditions.ref_name.include) as $i | all($want[]; . as $w | $i | index($w) != null)' >/dev/null <<<"$r"; then
    check_pass "github-admin: $RULESET_TRACKED covers every RULESET_BRANCHES entry"
  else
    check_fail "github-admin: $RULESET_TRACKED does not cover every RULESET_BRANCHES entry ($RULESET_BRANCHES)"
  fi
  if jq -e '(.bypass_actors // []) | all(.actor_type == "RepositoryRole" and .actor_id == 5)' >/dev/null <<<"$r"; then
    check_pass "github-admin: neither the App nor the team can bypass $RULESET_TRACKED"
  else
    check_fail "github-admin: $RULESET_TRACKED has a bypass actor other than the admin role (the App or the team must not)"
  fi
  if jq -e --arg c "$POLICY_CHECK_CONTEXT" --argjson i "$POLICY_CHECK_INTEGRATION_ID" \
      'any(.rules[]?; .type == "required_status_checks"
         and any(.parameters.required_status_checks[]?; .context == $c and .integration_id == $i))' >/dev/null <<<"$r"; then
    check_pass "github-admin: $RULESET_TRACKED requires $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID)"
  else
    check_fail "github-admin: $RULESET_TRACKED does not require $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID)"
  fi
  if jq -e 'any(.rules[]?; .type == "pull_request" and .parameters.require_code_owner_review == true)' >/dev/null <<<"$r"; then
    check_pass "github-admin: $RULESET_TRACKED requires code-owner review"
  else
    l5b_check "github-admin: $RULESET_TRACKED does not require code-owner review"
  fi
}

_admin_promote() { # RULESETS
  local r
  r="$(_ruleset_named "$1" "$RULESET_PROMOTE")"
  if [[ -z "$r" ]]; then check_fail "github-admin: ruleset $RULESET_PROMOTE does not exist"; return 0; fi
  if jq -e '(.conditions.ref_name.include | index("refs/heads/promote/*") != null)
        and ((.bypass_actors // []) | length == 1 and .[0].actor_type == "RepositoryRole" and .[0].actor_id == 5)' >/dev/null <<<"$r"; then
    check_pass "github-admin: $RULESET_PROMOTE covers refs/heads/promote/* with only the admin role as bypass"
  else
    check_fail "github-admin: $RULESET_PROMOTE must cover refs/heads/promote/* with only the admin role as bypass"
  fi
}

# ------------------------------------------------------------------ github-runtime
# The App token and the operator credential only, so it also runs inside the job unit (--job-run).
# Autonomy level and promotion state for the rung and mode; CODEOWNERS; the required policy-check on
# the tracked branch (armed); the App's installation permissions (gated, see the header).
section_github_runtime() {
  local want="" lvl code
  [[ "$RUNG" =~ ^[123]$ ]] || return 0
  if ((JOB_RUN)) && [[ -z "${GH_TOKEN:-}" ]]; then
    check_fail "github-runtime: GH_TOKEN is not set (job.env missing from the unit environment)"; return 0
  fi
  if gh api user --jq .login >/dev/null 2>&1; then
    check_pass "github-runtime: the operator credential authenticates with gh$( ((JOB_RUN)) && printf " (GH_TOKEN)")"
  else
    check_fail "github-runtime: gh api user failed (credential rejected or GitHub unreachable)"; return 0
  fi
  case "$RUNG" in
    1 | 2) want=suggest ;;
    3) if ((ARMED)); then want=act; elif ((PRE_PROMOTION)); then want=propose; fi ;;
  esac
  if [[ -n "$want" ]]; then
    lvl="$(tracked_autonomy_level || true)"
    if [[ "$lvl" == "$want" ]]; then
      check_pass "github-runtime: autonomy on $TRACKED_BRANCH is $want"
    else
      check_fail "github-runtime: autonomy on $TRACKED_BRANCH is '${lvl:-unreadable}', expected $want"
    fi
  else
    check_warn "github-runtime: rung 3 without --pre-promotion or --armed: autonomy level not checked"
  fi
  _runtime_promotion_state
  if ((ARMED)); then
    local rules
    rules="$(gh api "repos/${REPO_SLUG}/rules/branches/${TRACKED_BRANCH}" 2>/dev/null || true)"
    if jq -e --arg c "$POLICY_CHECK_CONTEXT" --argjson i "$POLICY_CHECK_INTEGRATION_ID" \
        'any(.[]?; .type == "required_status_checks"
             and any(.parameters.required_status_checks[]?; .context == $c and .integration_id == $i))' \
        <<<"${rules:-[]}" >/dev/null 2>&1; then
      check_pass "github-runtime: $TRACKED_BRANCH requires $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID)"
    else
      check_fail "github-runtime: $TRACKED_BRANCH does not require $POLICY_CHECK_CONTEXT (integration $POLICY_CHECK_INTEGRATION_ID); act would merge on the bridge's fallback alone"
    fi
  fi
  code="$(gh api -X GET "repos/${REPO_SLUG}/contents/.github/CODEOWNERS?ref=${TRACKED_BRANCH}" --jq .name 2>/dev/null || true)"
  if [[ "$code" == CODEOWNERS ]]; then
    check_pass "github-runtime: CODEOWNERS exists on $TRACKED_BRANCH"
  else
    check_fail "github-runtime: .github/CODEOWNERS not found on $TRACKED_BRANCH"
  fi
  _runtime_app
}

# _open_promotion_branches : branch names of the open promote/* PRs, one per line.
_open_promotion_branches() {
  gh pr list --repo "$REPO_SLUG" --state open --limit 100 --json number,headRefName 2>/dev/null \
    | jq -r '.[] | select(.headRefName | startswith("promote/")) | .headRefName'
}

# Rung 2: exactly one open propose promotion PR. Rung 3 pre-promotion: exactly one open act
# promotion PR. Rung 3 armed: the promotion merged and approved_by recorded (admin-bypass warns, so
# the slide can say so).
_runtime_promotion_state() {
  local level="" branches n raw by
  if [[ "$RUNG" == 2 ]]; then level=propose
  elif [[ "$RUNG" == 3 ]] && ((PRE_PROMOTION)); then level=act; fi
  if [[ -n "$level" ]]; then
    if ! branches="$(_open_promotion_branches)"; then
      check_fail "github-runtime: cannot list the open promotion PRs"; return 0
    fi
    n="$(grep -c . <<<"$branches" || true)"
    if [[ "$n" == 1 && "$branches" == "promote/${level}-"* ]]; then
      check_pass "github-runtime: exactly one open promotion PR, to $level"
    else
      check_fail "github-runtime: expected exactly one open $level promotion PR, found $n (${branches//$'\n'/, })"
    fi
  fi
  if [[ "$RUNG" == 3 ]] && ((ARMED)); then
    raw="$(gh api -H 'Accept: application/vnd.github.raw' \
      "repos/${REPO_SLUG}/contents/${AUTONOMY_FILE}?ref=${TRACKED_BRANCH}" 2>/dev/null || true)"
    by="$(yq -r '.promotion.approved_by // ""' <<<"$raw" 2>/dev/null || true)"
    if [[ -z "$by" || "$by" == null ]]; then
      check_fail "github-runtime: the promotion has no approved_by on $TRACKED_BRANCH (merge the promotion PR, then promotion-pr.sh record-approval)"
    elif [[ "$by" == admin-bypass ]]; then
      check_warn "github-runtime: the promotion was approved by admin-bypass, not the board (say so on the slide)"
    else
      check_pass "github-runtime: the promotion is approved ($by)"
    fi
  fi
}

# The App installation token mints, and the installation holds no workflows, administration or
# actions permission and nothing but contents and pull_requests at write (P21). Deferred to L5b.
_runtime_app() {
  local out bad
  if ! l5b_active; then
    check_warn "github-runtime: App installation token and permissions not checked (deferred to L5b)"; return 0
  fi
  if ! out="$(cd "$COMMON_ROOT/bridge" && uv run --quiet python -m bridge.cli app-check --repo "$REPO_SLUG" 2>/dev/null)"; then
    check_fail "github-runtime: the App check failed (GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_APP_KEY_PATH in .env, or GitHub unreachable)"
    return 0
  fi
  if jq -e '.token_minted == true' >/dev/null 2>&1 <<<"$out"; then
    check_pass "github-runtime: the App installation token mints"
  else
    check_fail "github-runtime: the App installation token does not mint"
  fi
  bad="$(jq -r '.permissions | to_entries
      | map(select((.key | IN("workflows", "administration", "actions"))
                   or ((.key | IN("contents", "pull_requests") | not) and (.value == "write" or .value == "admin"))
                   or ((.key | IN("contents", "pull_requests")) and .value == "admin")))
      | map("\(.key)=\(.value)") | join(", ")' <<<"$out" 2>/dev/null || echo unreadable)"
  if [[ -z "$bad" ]]; then
    check_pass "github-runtime: the App holds no workflows, administration or actions permission, and writes only contents and pull_requests"
  else
    check_fail "github-runtime: the App installation holds permissions it must not: $bad"
  fi
}

# ------------------------------------------------------------------ dry-run score
# The published dry-run score (panel 4, promotion PR bodies) must come from a full run:
# .dryruns/summary.json with n >= PROMOTION_SCORE_BAR's denominator, more than one incident and
# incidents x runs_per_incident == n (Δ27), and ConfigMap dryrun-summary equal to it. No summary
# and no ConfigMap is "pending": a WARN, or a FAIL with PREFLIGHT_REQUIRE_SCORE=1 (stage-day).
section_dryrun() {
  local f cm bn
  [[ -n "$RUNG" ]] || return 0
  f="$(main_root)/.dryruns/summary.json"
  bn="${PROMOTION_SCORE_BAR#*/}"
  cm="$(k get configmap dryrun-summary -n "$NS_AIOPS" -o json 2>/dev/null | jq -r '.data["summary.json"] // empty' 2>/dev/null || true)"
  if [[ ! -s "$f" ]]; then
    if [[ -n "$cm" ]]; then
      check_fail "dryrun: ConfigMap dryrun-summary is set but .dryruns/summary.json is missing (kubectl -n $NS_AIOPS delete configmap dryrun-summary, or restore the file)"
    elif [[ "${PREFLIGHT_REQUIRE_SCORE:-0}" == 1 ]]; then
      check_fail "dryrun: no full dry-run score yet (make dry-runs N=$bn BATCH=5)"
    else
      check_warn "dryrun: score pending (no .dryruns/summary.json; panel 4 and promotion PRs say pending)"
    fi
    return 0
  fi
  if jq -e --argjson bn "$bn" '(.n | type) == "number" and .n >= $bn
      and (.incidents | type) == "number" and .incidents > 1
      and (.runs_per_incident | type) == "number" and .incidents * .runs_per_incident == .n
      and (.root_cause_matched | type) == "number"' "$f" >/dev/null 2>&1; then
    check_pass "dryrun: summary.json is a full run ($(jq -r '"\(.root_cause_matched)/\(.n) across \(.incidents) incidents"' "$f"))"
  else
    check_fail "dryrun: summary.json is not a full run ($(jq -c '{n, incidents, runs_per_incident}' "$f" 2>/dev/null || echo unreadable)); move it aside and run make dry-runs N=$bn BATCH=5"
  fi
  if [[ -z "$cm" ]]; then
    check_fail "dryrun: ConfigMap dryrun-summary is missing (make dryrun-summary-restore)"
  elif [[ "$(jq -S -c . <<<"$cm" 2>/dev/null)" == "$(jq -S -c . "$f" 2>/dev/null)" ]]; then
    check_pass "dryrun: ConfigMap dryrun-summary matches summary.json"
  else
    check_fail "dryrun: ConfigMap dryrun-summary differs from summary.json (make dryrun-summary-restore)"
  fi
}

# ------------------------------------------------------------------ job
# Rung 3, from the operator's shell (not inside the unit): the scheduled job's unit is installed
# and current, its rendered PATH resolves the pinned tools, no job.env is left from an earlier run,
# and (armed) the cluster lock is free.
section_job() {
  local dir unit path tool resolved wd rt
  [[ "$RUNG" == 3 ]] || return 0
  ((JOB_RUN)) && return 0
  dir="${SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
  unit="$dir/argoconna26-rearm.service"
  if [[ ! -r "$unit" ]]; then
    check_fail "job: argoconna26-rearm.service is not installed ($unit; run make job-install)"
  else
    check_pass "job: argoconna26-rearm.service is installed"
    wd="$(sed -n 's/^WorkingDirectory=//p' "$unit" | head -n1)"
    if [[ "$wd" == "$(main_root)" ]]; then
      check_pass "job: the unit points at this checkout"
    else
      check_fail "job: the unit's WorkingDirectory is '$wd', not $(main_root); re-run make job-install"
    fi
    path="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit" | head -n1)"
    if [[ -z "$path" ]]; then
      check_fail "job: the unit has no PATH line; re-run make job-install"
    else
      local missing="" wrong=""
      for tool in kind kubectl yq uv docker; do
        # shellcheck disable=SC2016  # the single quotes are for the inner sh
        resolved="$(env -i PATH="$path" /bin/sh -c 'command -v "$1"' _ "$tool" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then missing+=" $tool"
        elif [[ ( "$tool" == kind || "$tool" == kubectl ) && "$(dirname "$resolved")" != "$TOOLS_BIN" ]]; then wrong+=" $tool=$resolved"; fi
      done
      if [[ -z "$missing$wrong" ]]; then
        check_pass "job: the unit's PATH resolves kind, kubectl, yq, uv and docker (kind and kubectl from $TOOLS_BIN)"
      else
        check_fail "job: the unit's PATH does not resolve the pinned tools; missing:${missing:- none}; wrong place:${wrong:- none}; re-run make job-install"
      fi
    fi
  fi
  rt="${XDG_RUNTIME_DIR:-}"
  if [[ -z "$rt" ]]; then
    check_warn "job: XDG_RUNTIME_DIR is not set; job.env not checked"
  elif [[ -e "$rt/argoconna26/job.env" ]]; then
    check_fail "job: $rt/argoconna26/job.env is left over from an earlier run (make timer-disarm removes it)"
  else
    check_pass "job: no job.env left over"
  fi
  if ((ARMED)); then
    local lockfile
    lockfile="$(_lock_file)"
    if [[ -e "$lockfile" ]] && _lock_is_held "$lockfile"; then
      check_fail "job: cluster_lock is held by: $(head -n1 "$lockfile" 2>/dev/null || echo unknown); the unit cannot inherit it"
    else
      check_pass "job: cluster_lock is free"
    fi
  fi
}

main() {
  local s extra
  parse_args "$@"
  load_env
  say "============================================"
  say " ArgoCon NA 2026 demo: pre-flight${RUNG:+ (rung $RUNG)}"
  say "============================================"
  # Without the isolated context nothing else may touch the cluster.
  if ! require_context 2>/dev/null; then
    section_context
    section_cluster
    say; say "Result: $PASS passed, $FAIL failed, $WARN warnings"
    exit 1
  fi
  for s in "${V1_SECTIONS[@]}"; do
    say "--- $s ---"
    "section_$s"
  done
  while read -r extra; do
    [[ " ${V1_SECTIONS[*]} " == *" ${extra#section_} "* ]] && continue
    # The scheduled job runs with GH_TOKEN only: Luke's admin checks are the caller's job.
    if ((JOB_RUN)) && [[ "$extra" == section_github_admin ]]; then continue; fi
    say "--- ${extra#section_} ---"
    "$extra"
  done < <(compgen -A function section_ | sort)
  say
  say "Result: $PASS passed, $FAIL failed, $WARN warnings"
  (( FAIL == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
