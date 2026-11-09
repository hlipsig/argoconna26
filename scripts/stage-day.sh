#!/usr/bin/env bash
# Stage-day runbook (Task 6.9). Prints each step, times it, stops at the first failure and at
# every human step.
#
#   scripts/stage-day.sh morning               11-09 morning: the cluster is up (else make
#                                              build-all), reset, preflight 1 (a full dry-run
#                                              score required), LLM budget,
#                                              gh auth, the job unit current + preflight 3, then
#                                              leaves the propose promotion PR open (make demo-full
#                                              needs nothing else)
#   scripts/stage-day.sh arm-rung-3 [--admin]  between rung 2 and rung 3 (or just before the
#                                              talk): reset-rung-3 (from suggest it first opens
#                                              the propose promotion: merge it, record, reset
#                                              again) -> preflight 3 --pre-promotion
#                                              -> HUMAN: approve the promotion PR -> merge
#                                              -> record-approval -> preflight 3 --armed
#
# --admin merges with `promotion-pr.sh merge PR --admin` (logged there as admin-bypass) instead of
# waiting for a board member's approving review. Either way the script stops at the human step
# and reads one line from stdin: Enter continues, anything starting with q stops (exit 3). With
# no input (EOF) it also stops, so an unattended run never merges.
#
# Run it from the main checkout: every step touches the cluster or the tracked branch (P12).
# The steps take cluster_lock themselves; this script never holds it.
#
# Exit codes: 0 done, 1 a step failed (the last line names it), 2 usage, 3 stopped at a human step.
#
# After a run, the steps and their timings are saved to <EVIDENCE_DIR>/stage-day/<sub>-<ts>.txt
# (they feed the run of show), and on stage nothing from the night before is needed or kept.
#
# Test overrides (each names an executable): STAGE_DAY_PREFLIGHT, STAGE_DAY_PROMOTION,
# STAGE_DAY_LITELLM, STAGE_DAY_GRAFANA_URL. `make` and `gh` are found on PATH.
# STAGE_LLM_MIN_REMAINING_USD (default 2.00): the least live budget left that still passes.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

readonly EXIT_STEP=1 EXIT_USAGE=2 EXIT_HUMAN=3
PREFLIGHT="${STAGE_DAY_PREFLIGHT:-$COMMON_SH_DIR/preflight.sh}"
PROMOTION="${STAGE_DAY_PROMOTION:-$COMMON_SH_DIR/promotion-pr.sh}"
LITELLM="${STAGE_DAY_LITELLM:-$COMMON_SH_DIR/litellm.sh}"
GRAFANA_URL="${STAGE_DAY_GRAFANA_URL:-$COMMON_SH_DIR/grafana-run-url.sh}"

SUB=""
SUMMARY=()
T_START=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit "$EXIT_USAGE"
}

# ------------------------------------------------------------------ steps
# save_summary : write the step list and timings under the evidence dir; best effort.
save_summary() {
  local dir out
  dir="$(evidence_dir)/stage-day"
  mkdir -p "$dir" 2>/dev/null || return 0
  out="$dir/${SUB}-$(date -u +%Y%m%dT%H%M%SZ).txt"
  printf '%s\n' "${SUMMARY[@]}" >"$out" 2>/dev/null || return 0
  printf 'saved: %s\n' "$out"
}

record() { SUMMARY+=("$1"); printf '%s\n' "$1"; }

# finish RC LAST : print the total, save, exit RC.
finish() {
  local rc="$1" last="$2"
  record "$last (total $(($(date +%s) - T_START)) s)"
  save_summary
  exit "$rc"
}

# step TITLE CMD... : run CMD, time it, stop the whole run on failure.
step() {
  local title="$1" t0 rc=0
  shift
  printf '\n== %s\n' "$title"
  t0="$(date +%s)"
  "$@" || rc=$?
  if ((rc != 0)); then
    record "FAILED  $title (exit $rc, $(($(date +%s) - t0)) s)"
    finish "$EXIT_STEP" "stopped: fix '$title', then run $SUB again"
  fi
  record "ok      $title ($(($(date +%s) - t0)) s)"
}

# human_step PROMPT : stop and wait for one line. Enter continues; q, or no input, stops.
human_step() {
  local prompt="$1" reply=""
  printf '\n== HUMAN STEP\n%s\n[Enter to continue, q to stop] ' "$prompt"
  if ! IFS= read -r reply || [[ "$reply" == [qQ]* ]]; then
    printf '\n'
    record "STOPPED human step: $prompt"
    finish "$EXIT_HUMAN" "stopped at a human step; run $SUB again when ready"
  fi
  record "ok      human step done: $prompt"
}

# ---------------------------------------------------------- the checks
# shellcheck disable=SC2329  # reached through step()
make_target() { make -C "$(main_root)" --no-print-directory "$@"; }

# llm_budget_ok : the live budget left is at least STAGE_LLM_MIN_REMAINING_USD and the build's
# cumulative spend is under the budget. Reads the one line `litellm.sh spend` prints:
#   live L remaining R cumulative C budget B
# shellcheck disable=SC2329
llm_budget_ok() {
  if [[ "${LLM_PROVIDER:-}" == chatgpt ]]; then
    "$LITELLM" spend
    log_warn "Dollar budget check unavailable for ChatGPT; preflight checks key rate limits instead"
    return
  fi
  local line min="${STAGE_LLM_MIN_REMAINING_USD:-2.00}"
  line="$("$LITELLM" spend)" || { log_error "litellm.sh spend failed"; return 1; }
  printf '%s\n' "$line"
  awk -v l="$line" -v min="$min" 'BEGIN {
      n = split(l, f, " ")
      for (i = 1; i < n; i += 2) v[f[i]] = f[i + 1]
      if (v["remaining"] == "" || v["cumulative"] == "" || v["budget"] == "") { print "unreadable spend line"; exit 2 }
      if (v["remaining"] + 0 < min + 0) { printf "only $%s left, need at least $%s\n", v["remaining"], min; exit 1 }
      if (v["cumulative"] + 0 >= v["budget"] + 0) { printf "cumulative $%s is at the budget $%s\n", v["cumulative"], v["budget"]; exit 1 }
    }' >&2
}

# cluster_ok : the kind cluster exists (from scratch, `make build-all` creates it first).
# shellcheck disable=SC2329
cluster_ok() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
    || { log_error "no kind cluster '$CLUSTER_NAME' (run: make build-all, about 5 minutes)"; return 1; }
}
# shellcheck disable=SC2329
gh_auth_ok() { gh auth status >/dev/null 2>&1 || { log_error "gh auth status failed (run: gh auth login)"; return 1; }; }

# promotion_pr LEVEL : the PR number promotion-pr.sh ensure recorded for the LEVEL promotion.
promotion_pr() {
  local level="$1" file pr
  file="$(main_root)/.operator/promotion-$level"
  [[ -r "$file" ]] || { log_error "no recorded $level promotion at .operator/promotion-$level (did reset-rung-3 open it?)"; return 1; }
  pr="$(sed -n 's/^pr=//p' "$file" | head -n1)"
  [[ "$pr" =~ ^[0-9]+$ ]] || { log_error "the recorded $level promotion has no PR number"; return 1; }
  printf '%s\n' "$pr"
}

# merge_promotion PR ADMIN : the human step, then merge (with --admin when ADMIN is 1) and record.
merge_promotion() {
  local pr="$1" admin="$2" what="$3"
  if ((admin)); then
    human_step "Merge $what promotion PR $pr with admin bypass (it will be logged as admin-bypass). Open it: gh pr view $pr --web"
    step "promotion-pr.sh merge $pr --admin" "$PROMOTION" merge "$pr" --admin
  else
    human_step "Approve $what promotion PR $pr as a promotion-board member (the On-call SRE). Open it: gh pr view $pr --web"
    step "promotion-pr.sh merge $pr" "$PROMOTION" merge "$pr"
  fi
  step "promotion-pr.sh record-approval $pr" "$PROMOTION" record-approval "$pr"
}

# reset_rung_3 ADMIN : make reset-rung-3. Its exit 6 means autonomy is below propose (for example
# after rung 2's reject + demote): it has opened the propose promotion PR, which must be merged
# before rung 3 can be armed. That costs a second promotion on stage.
reset_rung_3() {
  local admin="$1" t0 rc=0 pr
  printf '\n== %s\n' "make reset-rung-3 (pre-promotion)"
  t0="$(date +%s)"
  make_target reset-rung-3 || rc=$?
  if ((rc == 6)); then
    record "below   make reset-rung-3: autonomy is below propose ($(($(date +%s) - t0)) s)"
    pr="$(promotion_pr propose)" || finish "$EXIT_STEP" "stopped: no propose promotion PR to merge"
    printf 'Rung 3 needs propose first (rung 2 ended at suggest): the propose promotion PR %s comes first.\n' "$pr"
    merge_promotion "$pr" "$admin" propose
    step "make reset-rung-3 (pre-promotion)" make_target reset-rung-3
  elif ((rc != 0)); then
    record "FAILED  make reset-rung-3 (pre-promotion) (exit $rc, $(($(date +%s) - t0)) s)"
    finish "$EXIT_STEP" "stopped: fix 'make reset-rung-3 (pre-promotion)', then run $SUB again"
  else
    record "ok      make reset-rung-3 (pre-promotion) ($(($(date +%s) - t0)) s)"
  fi
}

# --------------------------------------------------------- subcommands
cmd_morning() {
  record "stage-day morning, $(date -u +%Y-%m-%dT%H:%MZ)"
  step "kind cluster up" cluster_ok
  step "make reset-demo" make_target reset-demo
  step "preflight 1" env PREFLIGHT_REQUIRE_SCORE=1 "$PREFLIGHT" 1
  step "LLM budget" llm_budget_ok
  step "gh auth status" gh_auth_ok
  step "make job-install (the unit is current)" make_target job-install
  step "preflight 3 (section job)" "$PREFLIGHT" 3
  # Last, so the checks above see the plain rung-1 start. Scene 2 of demo-full needs this PR open.
  step "open the propose promotion PR" "$PROMOTION" ensure propose
  printf '\nNext, by hand:\n  kiosk URL for the Grafana tab: %s\n  tabs: Argo CD, GitHub PR, Grafana; terminal 28 pt light theme, Do Not Disturb on\n  the talk: make demo-full (the propose promotion PR is open; scene 3 opens the act one)\n  rung 3 alone later: %s arm-rung-3\n' \
    "$("$GRAFANA_URL" --kiosk 2>/dev/null || echo '(grafana-run-url.sh failed)')" "scripts/stage-day.sh"
  finish 0 "morning done"
}

cmd_arm_rung_3() {
  local admin=0 pr
  while (($#)); do
    case "$1" in
      --admin) admin=1 ;;
      *) usage ;;
    esac
    shift
  done
  record "stage-day arm-rung-3, $(date -u +%Y-%m-%dT%H:%MZ)"
  reset_rung_3 "$admin"
  step "preflight 3 --pre-promotion" "$PREFLIGHT" 3 --pre-promotion
  pr="$(promotion_pr act)" || finish "$EXIT_STEP" "stopped: no promotion PR to approve"
  merge_promotion "$pr" "$admin" act
  step "preflight 3 --armed" "$PREFLIGHT" 3 --armed
  printf '\nRung 3 is armed. On stage: make demo-rung-3 (say: "running the nightly job now").\nBackup: the rung-3 clip, same 120 s rule as the other rungs.\n'
  finish 0 "arm-rung-3 done"
}

main() {
  SUB="${1:-}"
  [[ -n "$SUB" ]] || usage
  shift
  load_env
  T_START="$(date +%s)"
  case "$SUB" in
    morning) (($# == 0)) || usage; cmd_morning ;;
    arm-rung-3) cmd_arm_rung_3 "$@" ;;
    -h | --help | help) usage ;;
    *) usage ;;
  esac
}

main "$@"
