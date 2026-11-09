#!/usr/bin/env bash
# Load .env into cluster Secrets, idempotently. Secret values never reach stdout, stderr or kubectl args.
#   scripts/secrets.sh base|late|all
# base: needs no running service (grafana-admin, litellm, bridge, argocd-notifications,
#       and the optional Argo CD admin password)
# late: needs running services (holmes, cdevents-grafana); stubbed until slice 3.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_ensure_ns() { # NS (created only when missing, so Helm-owned namespaces are left alone)
  k get namespace "$1" >/dev/null 2>&1 || k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null
}

# _have KEY... : true when every key is set and non-empty in the environment
_have() {
  local v
  for v in "$@"; do [[ -n "${!v:-}" ]] || return 1; done
}

# Entries are written one per file into a private (0700) temp dir and passed with
# --from-file=<dir>, so values never appear in process arguments and multi-line values
# (a PEM key) work. `kubectl create secret` cannot mix --from-env-file with --from-file.
SECRET_DIR=""

_new_secret_dir() {
  _cleanup_secret_dir
  SECRET_DIR="$(mktemp -d)"
  chmod 700 "$SECRET_DIR"
}

_put() { printf '%s' "$2" > "$SECRET_DIR/$1"; } # KEY VALUE (printf is a builtin: no argv exposure)

_cleanup_secret_dir() { [[ -z "${SECRET_DIR:-}" ]] || rm -rf "$SECRET_DIR"; SECRET_DIR=""; }

LAST_APPLIED=kubectl.kubernetes.io/last-applied-configuration

# _apply_secret NS NAME [--from-file=k=path ...]
# Server-side apply: unlike client-side apply it writes no last-applied-configuration
# annotation, which would hold a second copy of every value in object metadata. An
# unchanged Secret is a no-op (same UID and resourceVersion), so build-all stays idempotent.
_apply_secret() {
  local ns="$1" name="$2"; shift 2
  _ensure_ns "$ns"
  k create secret generic "$name" -n "$ns" --from-file="$SECRET_DIR" "$@" \
    --dry-run=client -o yaml \
    | k apply --server-side --field-manager=secrets-sh --force-conflicts -f - >/dev/null
  # A Secret first written by an older client-side apply still carries the annotation.
  # (Checked with jq -e, so the annotation's value is never read into the shell.)
  if k get secret "$name" -n "$ns" -o json 2>/dev/null \
       | jq -e --arg a "$LAST_APPLIED" '.metadata.annotations[$a] != null' >/dev/null; then
    k annotate secret "$name" -n "$ns" "${LAST_APPLIED}-" >/dev/null
    log_info "secret: $ns/$name (removed the old last-applied annotation)"
  fi
  log_info "secret: $ns/$name"
  _cleanup_secret_dir
}

secret_grafana_admin() {
  if ! _have GRAFANA_ADMIN_PASSWORD; then
    log_warn "skipped: grafana-admin (GRAFANA_ADMIN_PASSWORD missing in .env)"; return 0
  fi
  _new_secret_dir
  _put admin-user admin
  _put admin-password "$GRAFANA_ADMIN_PASSWORD"
  _apply_secret "$NS_MONITORING" grafana-admin
}

secret_litellm() {
  if ! _have LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_DB_PASSWORD; then
    log_warn "skipped: litellm (LITELLM_MASTER_KEY, LITELLM_SALT_KEY or LITELLM_DB_PASSWORD missing in .env)"; return 0
  fi
  _new_secret_dir; _put masterkey "$LITELLM_MASTER_KEY"
  _apply_secret "$NS_AIOPS" litellm-masterkey
  _new_secret_dir; _put username litellm; _put password "$LITELLM_DB_PASSWORD"
  _apply_secret "$NS_AIOPS" litellm-db
  if [[ "${LLM_PROVIDER:-}" != chatgpt && -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENAI_API_KEY:-}" ]]; then
    log_warn "litellm-env has no provider key (ANTHROPIC_API_KEY or OPENAI_API_KEY missing in .env); model calls will fail"
  fi
  _new_secret_dir
  _put LITELLM_SALT_KEY "$LITELLM_SALT_KEY"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] || _put ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
  [[ -z "${OPENAI_API_KEY:-}" ]] || _put OPENAI_API_KEY "$OPENAI_API_KEY"
  _apply_secret "$NS_AIOPS" litellm-env
}

# argo_call BEARER METHOD PATH [JSON_BODY] : Argo CD HTTP API on the host port. The bearer goes
# through a curl config file descriptor, the body through stdin: neither shows in process args.
argo_call() {
  local bearer="$1" method="$2" path="$3" body="${4:-}" args=()
  [[ -z "$body" ]] || args=(-H 'Content-Type: application/json' --data-binary @-)
  if [[ -n "$bearer" ]]; then
    printf '%s' "$body" | curl -sf --max-time 15 -X "$method" "${args[@]}" \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$bearer") "${ARGOCD_HOST_URL}${path}"
  else
    printf '%s' "$body" | curl -sf --max-time 15 -X "$method" "${args[@]}" "${ARGOCD_HOST_URL}${path}"
  fi
}

# HolmesGPT: HOLMES_API_KEY for its server (holmes-api) and an API token for the read-only
# Argo CD account holmesgpt (holmes-argocd). The token is minted through the Argo CD HTTP API
# (session with the admin password, then POST /api/v1/account/holmesgpt/token), so no argocd
# CLI login is involved (P13). A token Argo CD still accepts is kept.
secret_holmes() {
  if _have HOLMES_API_KEY; then
    _new_secret_dir; _put HOLMES_API_KEY "$HOLMES_API_KEY"
    _apply_secret "$NS_AIOPS" holmes-api
  else
    log_warn "skipped: holmes-api (HOLMES_API_KEY missing in .env)"
  fi
  local cur pw sess tok
  cur="$(k get secret holmes-argocd -n "$NS_AIOPS" -o jsonpath='{.data.ARGOCD_AUTH_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$cur" ]] && argo_call "$cur" GET /api/v1/applications >/dev/null 2>&1; then
    log_info "skip: Secret $NS_AIOPS/holmes-argocd holds a token Argo CD accepts"
    return 0
  fi
  pw="$(k get secret argocd-initial-admin-secret -n "$NS_ARGOCD" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "$pw" ]]; then
    log_warn "skipped: holmes-argocd (argocd-initial-admin-secret not readable)"; return 0
  fi
  # the password reaches jq through its environment, not its arguments
  sess="$(argo_call "" POST /api/v1/session "$(ARGO_PW="$pw" jq -nc '{username: "admin", password: env.ARGO_PW}')" 2>/dev/null | jq -r '.token // empty' || true)"
  [[ -n "$sess" ]] || { log_warn "skipped: holmes-argocd (Argo CD session failed on $ARGOCD_HOST_URL)"; return 0; }
  tok="$(argo_call "$sess" POST /api/v1/account/holmesgpt/token '{"name":"holmes"}' 2>/dev/null | jq -r '.token // empty' || true)"
  [[ -n "$tok" ]] || { log_warn "skipped: holmes-argocd (Argo CD would not mint a holmesgpt token)"; return 0; }
  _new_secret_dir; _put ARGOCD_AUTH_TOKEN "$tok"
  _apply_secret "$NS_AIOPS" holmes-argocd
}

secret_cdevents_grafana() {
  # Needs the Grafana API, so it is made by `make grafana-token` (scripts/grafana-token.sh)
  # after kps-install, not here.
  log_info "skipped: cdevents-grafana (made by make grafana-token once Grafana is up)"
}

secret_bridge() {
  local keyfile="" root real
  if ! _have BRIDGE_WEBHOOK_TOKEN; then
    log_warn "skipped: bridge (BRIDGE_WEBHOOK_TOKEN missing in .env)"; return 0
  fi
  if [[ -n "${GITHUB_APP_KEY_PATH:-}" ]]; then
    root="$(main_root)"
    real="$(realpath -m "$GITHUB_APP_KEY_PATH")"
    case "$real/" in
      "$root"/*|"$COMMON_ROOT"/*) die "GITHUB_APP_KEY_PATH must live outside the repo" ;;
    esac
    [[ -r "$real" ]] || die "GITHUB_APP_KEY_PATH is not a readable file"
    keyfile="$real"
  fi
  _new_secret_dir
  _put webhook-token "$BRIDGE_WEBHOOK_TOKEN"
  [[ -z "${HOLMES_API_KEY:-}" ]] || _put holmes-api-key "$HOLMES_API_KEY"
  [[ -z "${GITHUB_APP_ID:-}" ]] || _put github-app-id "$GITHUB_APP_ID"
  [[ -z "${GITHUB_INSTALLATION_ID:-}" ]] || _put github-installation-id "$GITHUB_INSTALLATION_ID"
  if [[ -n "$keyfile" ]]; then
    _apply_secret "$NS_AIOPS" bridge-secrets "--from-file=github-app-key=$keyfile"
  else
    log_warn "bridge: no GitHub App key yet (GITHUB_APP_KEY_PATH unset); the bridge Secret has no App credentials"
    _apply_secret "$NS_AIOPS" bridge-secrets
  fi
}

secret_argocd_notifications() {
  if ! _have BRIDGE_WEBHOOK_TOKEN; then
    log_warn "skipped: argocd-notifications-secret (BRIDGE_WEBHOOK_TOKEN missing in .env)"; return 0
  fi
  _new_secret_dir; _put bridge-token "$BRIDGE_WEBHOOK_TOKEN"
  _apply_secret "$NS_ARGOCD" argocd-notifications-secret
}

# Argo CD admin login, for a local demo only: when ARGOCD_ADMIN_PASSWORD is set in .env,
# argocd-secret gets its bcrypt hash (which skips Argo CD's own password-length rule) and
# argocd-initial-admin-secret is set to the same value, so `make argocd-password` and
# secrets-late keep reading the live password. Unset: Argo CD's generated password stays.
# `argocd account bcrypt` takes the value only as a flag, so it is briefly in that process's
# arguments on this machine; it never reaches kubectl's arguments or any output.
secret_argocd_admin() {
  if ! _have ARGOCD_ADMIN_PASSWORD; then
    log_info "skip: argocd admin password (ARGOCD_ADMIN_PASSWORD unset; the generated one stays)"; return 0
  fi
  local cur hash patch
  cur="$(k get secret argocd-initial-admin-secret -n "$NS_ARGOCD" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "$cur" && "$cur" == "$ARGOCD_ADMIN_PASSWORD" ]]; then
    log_info "skip: argocd admin password already set from .env"; return 0
  fi
  hash="$(argocd account bcrypt --password "$ARGOCD_ADMIN_PASSWORD")" || die "argocd account bcrypt failed"
  [[ "$hash" == \$2* ]] || die "argocd account bcrypt did not return a bcrypt hash"
  _new_secret_dir
  patch="$SECRET_DIR/patch.json"
  jq -n --arg h "$(printf '%s' "$hash" | base64 -w0)" --arg t "$(date -u +%FT%TZ | base64 -w0)" \
    '{data: {"admin.password": $h, "admin.passwordMtime": $t}}' >"$patch"
  k patch secret argocd-secret -n "$NS_ARGOCD" --type merge --patch-file="$patch" >/dev/null
  _cleanup_secret_dir
  log_info "secret: $NS_ARGOCD/argocd-secret (admin password from .env)"
  _new_secret_dir; _put password "$ARGOCD_ADMIN_PASSWORD"
  _apply_secret "$NS_ARGOCD" argocd-initial-admin-secret
}

secrets_base() {
  secret_grafana_admin
  secret_litellm
  secret_bridge
  secret_argocd_notifications
  secret_argocd_admin
}

secrets_late() {
  secret_holmes
  secret_cdevents_grafana
}

main() {
  local what="${1:-base}"
  load_env
  trap _cleanup_secret_dir EXIT
  cluster_lock
  require_context
  case "$what" in
    base) secrets_base ;;
    late) secrets_late ;;
    all)  secrets_base; secrets_late ;;
    *) die "usage: secrets.sh base|late|all" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
