# One install path. Pins live in versions.env, names in demo.env, secrets in .env (never read by make).
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

# The main checkout, even from a worktree (P12).
ROOT      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
MAIN_ROOT := $(patsubst %/,%,$(dir $(shell git -C $(ROOT) rev-parse --path-format=absolute --git-common-dir)))

# The caller's environment may pin the push target (tests do), as in scripts/common.sh load_env.
_CALLER_TRACKED_BRANCH := $(TRACKED_BRANCH)
_CALLER_REPO_SLUG      := $(REPO_SLUG)
include $(ROOT)/versions.env
include $(ROOT)/demo.env
ifneq ($(_CALLER_TRACKED_BRANCH),)
TRACKED_BRANCH := $(_CALLER_TRACKED_BRANCH)
endif
ifneq ($(_CALLER_REPO_SLUG),)
REPO_SLUG := $(_CALLER_REPO_SLUG)
endif

# P25: the pinned tools win on PATH. TOOLS_BIN: command line > .env > demo.env.
ENV_TOOLS_BIN := $(shell sed -n 's/^TOOLS_BIN=//p' $(MAIN_ROOT)/.env 2>/dev/null | tail -1)
ifneq ($(ENV_TOOLS_BIN),)
  ifeq ($(origin TOOLS_BIN),file)
    TOOLS_BIN := $(ENV_TOOLS_BIN)
  endif
endif
export PATH := $(TOOLS_BIN):$(PATH)

# Isolated kubeconfig (P3). Luke's default kubeconfig is never used.
export KUBECONFIG := $(MAIN_ROOT)/$(KUBECONFIG_REL)
export HELM_CONFIG_HOME := $(MAIN_ROOT)/.kube/helm/config
export HELM_CACHE_HOME  := $(MAIN_ROOT)/.kube/helm/cache
export HELM_DATA_HOME   := $(MAIN_ROOT)/.kube/helm/data
.EXPORT_ALL_VARIABLES:

# Each recipe is one shell (.ONESHELL). A guard is the first line:
#   LOCKED  takes the cluster lock and refuses any context but kind-argoconna26
#   CTX     checks the context only (read-only targets)
#   PRE     takes the lock but does not need the cluster (kind create / delete)
LOCKED = . $(ROOT)/scripts/common.sh; load_env; cluster_lock; require_context
CTX    = . $(ROOT)/scripts/common.sh; load_env; require_context
PRE    = . $(ROOT)/scripts/common.sh; load_env; cluster_lock

.PHONY: help
help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

################################################################################
# Tools and checks                                                             #
################################################################################

.PHONY: vendor
vendor: ## Check required tools are present and at the pinned versions
	@$(ROOT)/scripts/vendor-check.sh

.PHONY: brew
brew: ## Install the CLI tools from the Brewfile (macOS or Linux), then run vendor
	@command -v brew >/dev/null || { echo "brew: Homebrew not found, see https://brew.sh" >&2; exit 1; }
	brew bundle install --no-upgrade --file=$(ROOT)/Brewfile
	$(ROOT)/scripts/vendor-check.sh

.PHONY: lint
lint: ## shellcheck the scripts
	@cd $(ROOT)
	shopt -s nullglob
	files=(scripts/*.sh tests/e2e/*.sh)
	shellcheck -x "$${files[@]}"
	echo "lint: OK"

.PHONY: test-bats
test-bats: ## Run the bats suite
	@cd $(ROOT) && bats tests/bats

.PHONY: consistency
consistency: ## Hardcoded versions or names that differ from versions.env / demo.env
	@$(ROOT)/scripts/check-consistency.sh $(ROOT)

# Run it from your own fork (Task 6.7a): rewrites demo.env, the Applications' repoURL, CODEOWNERS,
# the policy's agent login and the bridge Deployment. Give any of the three on the command line.
.PHONY: configure-fork
configure-fork: ## Point the demo at your fork: make configure-fork REPO_SLUG=you/repo BOT_LOGIN=app[bot] PROMOTION_TEAM=@you/team
	@args=()
	[[ "$(origin REPO_SLUG)" != "command line" ]] || args+=(--repo-slug "$(REPO_SLUG)")
	[[ "$(origin BOT_LOGIN)" != "command line" ]] || args+=(--bot-login "$(BOT_LOGIN)")
	[[ "$(origin PROMOTION_TEAM)" != "command line" ]] || args+=(--promotion-team "$(PROMOTION_TEAM)")
	$(ROOT)/scripts/configure-fork.sh --root $(ROOT) "$${args[@]}"

################################################################################
# Cluster lifecycle                                                            #
################################################################################

KIND_CONFIG_VARS := $${CLUSTER_NAME} $${KIND_NODE_IMAGE} $${HOST_BIND} $${PORT_ARGOCD} $${PORT_GRAFANA} $${PORT_PROMETHEUS} $${PORT_BRIDGE} $${PORT_SIM} $${PORT_LITELLM}

.PHONY: kind-cluster
kind-cluster: ## Create the kind cluster (skips when it exists)
	@$(PRE)
	mkdir -p "$$(dirname "$$KUBECONFIG")"
	if kind get clusters 2>/dev/null | grep -qx "$$CLUSTER_NAME"; then
	  log_info "skip: cluster $$CLUSTER_NAME exists"
	  [[ -s "$$KUBECONFIG" ]] || kind export kubeconfig --name "$$CLUSTER_NAME" --kubeconfig "$$KUBECONFIG"
	else
	  envsubst '$(KIND_CONFIG_VARS)' < $(ROOT)/cluster/kind-config.yaml \
	    | kind create cluster --config - --kubeconfig "$$KUBECONFIG" --wait 120s
	fi
	chmod 600 "$$KUBECONFIG"
	require_context
	k wait --for=condition=Ready nodes --all --timeout=120s
	$(ROOT)/scripts/host-trust.sh

.PHONY: rm-kind
rm-kind: ## Delete the kind cluster and its isolated kubeconfig
	@$(PRE)
	[[ "$$CLUSTER_NAME" == "argoconna26" ]] || die "refusing to delete cluster '$$CLUSTER_NAME'"
	# the Postgres PVC dies with the cluster, so keep LiteLLM's spend first (Task 3.11 Step 5)
	if k get --raw=/readyz >/dev/null 2>&1; then
	  $(ROOT)/scripts/litellm.sh spend-export || log_warn "llm-spend-export failed; LiteLLM spend of this cluster is not kept"
	fi
	kind delete cluster --name "$$CLUSTER_NAME" --kubeconfig "$$KUBECONFIG"
	rm -f "$$KUBECONFIG"

################################################################################
# Platform                                                                     #
################################################################################

.PHONY: helm-repos
helm-repos: ## Add the Helm repos to the isolated Helm config
	@$(CTX)
	helm repo add argo "$$ARGO_HELM_REPO" --force-update >/dev/null
	helm repo add prometheus-community "$$PROM_HELM_REPO" --force-update >/dev/null
	helm repo add robusta "$$ROBUSTA_HELM_REPO" --force-update >/dev/null
	helm repo update >/dev/null

.PHONY: argocd-install
argocd-install: helm-repos ## Install Argo CD (skips when unchanged)
	@$(LOCKED)
	extra=()
	if [[ -s "$${SSL_CERT_FILE:-}" ]]; then
	  cert_values="$$(mktemp --suffix=.yaml)"
	  trap 'rm -f "$$cert_values"' EXIT
	  CA_BUNDLE="$$SSL_CERT_FILE" yq -n '.configs.tls.certificates."github.com" = load_str(strenv(CA_BUNDLE))' > "$$cert_values"
	  extra=("$$cert_values")
	fi
	helm_ensure "$$ARGOCD_RELEASE" argo/argo-cd "$$ARGOCD_CHART_VERSION" "$$NS_ARGOCD" \
	  $(ROOT)/platform/argocd/values.yaml $(ROOT)/platform/argocd/notifications-cdevents.yaml \
	  $(ROOT)/platform/argocd/notifications-bridge.yaml "$${extra[@]}"
	k rollout status statefulset/argocd-application-controller -n "$$NS_ARGOCD" --timeout=300s

.PHONY: argocd-password
argocd-password: ## Print the Argo CD admin password
	@$(CTX) 2>/dev/null
	k -n "$$NS_ARGOCD" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: rollouts-install
rollouts-install: helm-repos ## Install Argo Rollouts (skips when unchanged)
	@$(LOCKED)
	helm_ensure "$$ROLLOUTS_RELEASE" argo/argo-rollouts "$$ROLLOUTS_CHART_VERSION" "$$NS_ROLLOUTS" $(ROOT)/platform/rollouts/values.yaml

.PHONY: secrets-base secrets-late secrets
secrets-base: ## Load .env into Secrets that need no running service
	@$(ROOT)/scripts/secrets.sh base
secrets-late: ## Load Secrets that need running services (slice 3)
	@$(ROOT)/scripts/secrets.sh late
secrets: secrets-base secrets-late ## Load all Secrets

.PHONY: grafana-token
grafana-token: ## Service account + token for cdevents-sim's Grafana annotations (needs Grafana up)
	@$(ROOT)/scripts/grafana-token.sh

.PHONY: kps-install
kps-install: helm-repos ## Install kube-prometheus-stack (needs the grafana-admin Secret)
	@$(LOCKED)
	k get secret grafana-admin -n "$$NS_MONITORING" >/dev/null 2>&1 || die "grafana-admin Secret missing: run 'make secrets-base' first"
	[[ -s "$${SSL_CERT_FILE:-}" ]] || die "SSL_CERT_FILE must name the host trusted CA bundle"
	k create configmap demo-ca-bundle -n "$$NS_MONITORING" --from-file=ca-bundle.pem="$$SSL_CERT_FILE" \
	  --dry-run=client -o yaml | k apply --server-side --field-manager=host-trust -f - >/dev/null
	helm_ensure "$$KPS_RELEASE" prometheus-community/kube-prometheus-stack "$$KPS_CHART_VERSION" "$$NS_MONITORING" $(ROOT)/platform/kps/values.yaml
	# helm --wait covers only chart-owned workloads. The Prometheus StatefulSet comes from the
	# operator afterwards, so wait for it too (verify-idempotent snapshots right after this).
	sts="prometheus-$${KPS_RELEASE}-prometheus"
	wait_for "statefulset $$sts to exist" 300 k get statefulset "$$sts" -n "$$NS_MONITORING"
	k rollout status statefulset/"$$sts" -n "$$NS_MONITORING" --timeout=300s

.PHONY: litellm-install
litellm-install: ## Install LiteLLM and its Postgres (needs the litellm Secrets from secrets-base)
	@$(LOCKED)
	for s in litellm-masterkey litellm-db litellm-env; do
	  k get secret "$$s" -n "$$NS_AIOPS" >/dev/null 2>&1 || die "Secret $$s missing: run 'make secrets-base' first"
	done
	# ChatGPT uses subscription quotas rather than a metered API budget.
	[[ -s "$${SSL_CERT_FILE:-}" ]] || die "SSL_CERT_FILE must name the host trusted CA bundle"
	k create configmap demo-ca-bundle -n "$$NS_AIOPS" --from-file=ca-bundle.pem="$$SSL_CERT_FILE" \
	  --dry-run=client -o yaml | k apply --server-side --field-manager=host-trust -f - >/dev/null
	k create configmap litellm-schema-compat -n "$$NS_AIOPS" --from-file=chatgpt_schema.py=$(ROOT)/platform/litellm/chatgpt_schema.py \
	  --dry-run=client -o yaml | k apply --server-side --field-manager=chatgpt-schema -f - >/dev/null
	chatgpt_auth="$${CHATGPT_AUTH_PATH:-$$HOME/.config/litellm/chatgpt/auth.json}"
	[[ -s "$$chatgpt_auth" ]] || die "ChatGPT login missing: run make chatgpt-login first"
	k create secret generic litellm-chatgpt-auth -n "$$NS_AIOPS" --from-file=auth.json="$$chatgpt_auth" \
	  --dry-run=client -o yaml | k apply --server-side --field-manager=chatgpt-login -f - >/dev/null
	k apply -f $(ROOT)/platform/litellm/postgres.yaml
	k rollout status statefulset/litellm-postgres -n "$$NS_AIOPS" --timeout=900s
	cfg="$$(mktemp)"
	envsubst '$${LLM_BUDGET_USD}' < $(ROOT)/platform/litellm/config.yaml > "$$cfg"
	rc=0
	helm_ensure litellm oci://ghcr.io/berriai/litellm-helm "$$LITELLM_CHART_VERSION" "$$NS_AIOPS" \
	  $(ROOT)/platform/litellm/values.yaml "$$cfg" || rc=$$?
	rm -f "$$cfg"
	(( rc == 0 )) || exit "$$rc"
	k rollout status deployment/litellm -n "$$NS_AIOPS" --timeout=300s
	# The proxy reports ready before the chart's migration Job has created its tables, and
	# /key/generate fails until then. So installed means the migrations are complete too.
	if k get job litellm-migrations -n "$$NS_AIOPS" >/dev/null 2>&1; then
	  k wait --for=condition=complete job/litellm-migrations -n "$$NS_AIOPS" --timeout=300s
	fi

.PHONY: holmes-install
holmes-install: helm-repos ## Install HolmesGPT (read-only; needs make litellm-keys and make secrets-late first). HOLMES_SET=a.b=v,... overrides values (the dry-run ablation)
	@$(LOCKED)
	for s in holmes-llm holmes-argocd holmes-api; do
	  k get secret "$$s" -n "$$NS_AIOPS" >/dev/null 2>&1 || die "Secret $$s missing: run 'make litellm-keys secrets-late' first"
	done
	$(ROOT)/scripts/holmes-rbac.sh check
	# HOLMES_SET (Task 6.2's ablation) becomes one more values file, so helm_ensure still sees
	# exactly what is installed. Keys are dotted paths; values are read as YAML (false, 3, text).
	extra=()
	if [[ -n "$(HOLMES_SET)" ]]; then
	  setf="$$(mktemp --suffix=.yaml)"
	  trap 'rm -f "$$setf"' EXIT
	  printf '{}\n' >"$$setf"
	  IFS=, read -ra sets <<<"$(HOLMES_SET)"
	  for kv in "$${sets[@]}"; do
	    path="$${kv%%=*}"
	    [[ "$$kv" == *=* && "$$path" =~ ^[A-Za-z0-9_/-]+(\.[A-Za-z0-9_/-]+)*$$ ]] || die "HOLMES_SET: bad entry '$$kv'"
	    yqpath="$$(awk -F. '{for (i = 1; i <= NF; i++) printf "[\"%s\"]", $$i}' <<<"$$path")"
	    V="$${kv#*=}" yq -i ".$$yqpath = env(V)" "$$setf"
	  done
	  log_info "holmes-install: values overridden by HOLMES_SET ($(HOLMES_SET))"
	  extra=("$$setf")
	fi
	helm_ensure "$$HOLMES_RELEASE" robusta/holmes "$$HOLMES_CHART_VERSION" "$$NS_AIOPS" $(ROOT)/platform/holmes/values.yaml "$${extra[@]}"
	k rollout status deployment/"$$HOLMES_RELEASE"-holmes -n "$$NS_AIOPS" --timeout=300s
	$(ROOT)/scripts/holmes-rbac.sh live

.PHONY: holmes-rbac-check
holmes-rbac-check: helm-repos ## Offline proof that the rendered HolmesGPT role is read-only, and the allow-list test
	@$(ROOT)/scripts/holmes-rbac.sh check
	$(ROOT)/scripts/holmes-rbac.sh allowlist

.PHONY: litellm-keys
litellm-keys: ## Virtual keys holmes and judge -> Secrets holmes-llm and judge-llm
	@$(ROOT)/scripts/litellm.sh keys

.PHONY: llm-spend-export
llm-spend-export: ## Write LiteLLM spend to .dryruns/llm-spend/ (rm-kind runs it; by hand it double counts until rebuilt)
	@$(ROOT)/scripts/litellm.sh spend-export

.PHONY: llm-spend
llm-spend: ## Live and cumulative LLM spend against the budget
	@$(ROOT)/scripts/litellm.sh spend

################################################################################
# Images                                                                       #
################################################################################

# build_image NAME DIR: docker build NAME:latest-build with the pinned base images.
IMG_BUILD = build_image() { \
	  local -a cert_args=(); \
	  [[ -z "$${SSL_CERT_FILE:-}" ]] || cert_args=(--secret "id=host_ca,src=$$SSL_CERT_FILE"); \
	  docker build "$${cert_args[@]}" -q -t "$$1:latest-build" --build-arg PYTHON_IMAGE="$$PYTHON_IMAGE" --build-arg UV_IMAGE="$$UV_IMAGE" "$$2" >/dev/null; \
	  log_info "built $$1:latest-build"; }

.PHONY: images
images: ## Build the demo images and load them into the kind nodes (skips what is present)
	@$(LOCKED)
	$(IMG_BUILD)
	cd $(ROOT)
	build_image checkout apps/checkout
	build_image pricing apps/pricing
	build_image loadgen apps/loadgen
	# bridge and cdevents-sim join once their directories hold a Dockerfile
	have_bridge=0; have_sim=0
	[[ -f bridge/Dockerfile ]] && { build_image bridge bridge; have_bridge=1; }
	[[ -f cdevents-sim/Dockerfile ]] && { build_image cdevents-sim cdevents-sim; have_sim=1; }
	IFS=, read -ra tags <<<"$$CHECKOUT_PRELOAD_TAGS"
	for t in "$${tags[@]}"; do $(ROOT)/scripts/ensure-image.sh checkout "$$t"; done
	$(ROOT)/scripts/ensure-image.sh pricing "$$PRICING_TAG"
	$(ROOT)/scripts/ensure-image.sh loadgen "$$LOADGEN_TAG"
	(( have_bridge )) && $(ROOT)/scripts/ensure-image.sh bridge "$$BRIDGE_TAG"
	(( have_sim )) && $(ROOT)/scripts/ensure-image.sh cdevents-sim "$$SIM_TAG"
	true

.PHONY: image-load
image-load: images ## Alias of images

.PHONY: bridge-log
bridge-log: ## Follow the bridge's stage lines (the short lines for the projector)
	@$(CTX)
	k logs -n "$$NS_AIOPS" deploy/bridge -f | grep --line-buffered '▸'

.PHONY: bridge-hooks-check bridge-hooks-clear
bridge-hooks-check: ## Fail while the bridge's test-hook Secret bridge-env exists (names keys, never values)
	@$(ROOT)/scripts/bridge-hooks.sh check
bridge-hooks-clear: ## Delete the test-hook Secret bridge-env and restart the bridge (resets call this)
	@$(ROOT)/scripts/bridge-hooks.sh clear

.PHONY: redeploy-bridge redeploy-sim
redeploy-bridge: images ## Rebuild the bridge image and restart its pods when they run a stale one
	@$(LOCKED)
	$(ROOT)/scripts/ensure-image.sh --redeploy bridge
redeploy-sim: images ## Rebuild the cdevents-sim image and restart its pods when they run a stale one
	@$(LOCKED)
	$(ROOT)/scripts/ensure-image.sh --redeploy cdevents-sim

################################################################################
# Policy                                                                       #
################################################################################

.PHONY: policy-verify
policy-verify: ## Run the Rego unit tests
	@cd $(ROOT) && conftest verify --policy policy

.PHONY: policy-check
policy-check: ## Golden-path labels on every app; with BASE= and HEAD= also the auto-fix rules (no cluster needed)
	@$(ROOT)/scripts/policy-check.sh $(if $(BASE),--base $(BASE) --head $(HEAD)) $(if $(BODY_FILE),--body-file $(BODY_FILE)) $(if $(AUTHOR_LOGIN),--author-login $(AUTHOR_LOGIN)) $(if $(TRACKED_REF),--tracked-ref $(TRACKED_REF))

################################################################################
# GitOps                                                                       #
################################################################################

.PHONY: gitops-bootstrap
gitops-bootstrap: ## Apply the root app-of-apps (Argo CD then creates checkout, pricing, loadgen)
	@$(LOCKED)
	# the images must be on the nodes first: imagePullPolicy is Never
	k create namespace "$$NS_DEMO" --dry-run=client -o yaml | k apply -f -
	k apply -f $(ROOT)/gitops/root.yaml

################################################################################
# Build, rebuild, info, verification                                           #
################################################################################

# The build order (Task 3.16; docs/06-operations.md repeats it):
#   vendor -> kind-cluster -> namespaces -> argocd-install (values, notifications-cdevents,
#   notifications-bridge) -> rollouts-install -> secrets-base -> kps-install -> images
#   -> litellm-install -> litellm-keys -> grafana-token -> secrets-late (the holmesgpt Argo
#   token, minted through the Argo CD HTTP API) -> holmes-install -> dryrun-summary-restore
#   -> disarm-git-only -> gitops-bootstrap -> wait-platform
# disarm-git-only comes before gitops-bootstrap, so an armed branch never meets a fresh
# cluster (Review Focus 1): Argo's first sync already reads the disarmed config.
# Seeding is not part of build-all (reset-demo does it). rm-kind, and so rebuild, first runs
# llm-spend-export when the cluster is up, so LiteLLM's spend outlives the cluster.
BUILD_STEPS := vendor kind-cluster namespaces argocd-install rollouts-install secrets-base kps-install \
	images litellm-install litellm-keys grafana-token secrets-late holmes-install \
	dryrun-summary-restore disarm-git-only gitops-bootstrap wait-platform
SNAP_DIR    := $(MAIN_ROOT)/.kube/idempotency

.PHONY: namespaces
namespaces: ## Create the demo namespaces (only those missing)
	@$(LOCKED)
	for ns in "$$NS_ARGOCD" "$$NS_ROLLOUTS" "$$NS_MONITORING" "$$NS_DEMO" "$$NS_AIOPS"; do
	  k get namespace "$$ns" >/dev/null 2>&1 || k create namespace "$$ns"
	done

.PHONY: dryrun-summary-restore
dryrun-summary-restore: ## ConfigMap dryrun-summary from .dryruns/summary.json, when that file exists
	@$(LOCKED)
	f="$(MAIN_ROOT)/.dryruns/summary.json"
	if [[ ! -s "$$f" ]]; then
	  log_info "skip: no .dryruns/summary.json yet (the accuracy panel shows pending)"
	  exit 0
	fi
	k create configmap dryrun-summary -n "$$NS_AIOPS" --from-file=summary.json="$$f" \
	  --dry-run=client -o yaml | k apply -f - >/dev/null
	log_info "dryrun-summary restored from .dryruns/summary.json"

WAIT_PLATFORM_S ?= 600

.PHONY: wait-platform
wait-platform: ## Wait until every Argo CD Application is Synced and Healthy, every pod is Ready (pods_ready) and Prometheus scrapes checkout
	@$(CTX)
	apps_ok() {
	  k get applications -n "$$NS_ARGOCD" -o json | jq -e '(.items | length) > 0 and
	    all(.items[]; .status.sync.status == "Synced" and .status.health.status == "Healthy")' >/dev/null
	}
	pods_ok() {
	  local ns
	  for ns in "$$NS_ARGOCD" "$$NS_ROLLOUTS" "$$NS_MONITORING" "$$NS_DEMO" "$$NS_AIOPS"; do
	    pods_ready "$$ns" || return 1
	  done
	}
	if ! wait_for "every Application Synced and Healthy" "$(WAIT_PLATFORM_S)" apps_ok; then
	  k get applications -n "$$NS_ARGOCD" >&2; exit 4
	fi
	wait_for "every pod Ready" "$(WAIT_PLATFORM_S)" pods_ok || { k get pods -A | grep -v Running >&2; exit 4; }
	# A new cluster: Prometheus picks up checkout's ServiceMonitor about a minute after the apps are
	# Healthy. A canary started before that (the first reset) finds no data, goes Inconclusive and
	# pauses, so wait until every Ready checkout pod is scraped and the success rate computes.
	scraped_ok() { _fleet_gauge_complete && [[ -n "$$(_fleet_success_rate)" ]]; }
	wait_for "Prometheus scraping checkout" "$(WAIT_PLATFORM_S)" scraped_ok || exit 4
	log_info "wait-platform: all Applications Synced and Healthy, all pods Ready, checkout scraped"

.PHONY: build-all
build-all: ## Create the whole stack (safe to run twice)
	@$(PRE)
	$(MAKE) --no-print-directory $(BUILD_STEPS)
	log_info "build-all: done"

.PHONY: rebuild
rebuild: ## Delete the cluster and build it again
	@$(PRE)
	$(MAKE) --no-print-directory rm-kind build-all

# The dry-run harness (Task 6.2): N runs in N/BATCH batches of re-armed incidents. Needs autonomy
# suggest; takes the cluster lock. ABLATE_TIMELINE=1 runs with the timeline toolset off (no summary).
N ?= 20
BATCH ?= 5
.PHONY: dry-runs
dry-runs: ## Score the agent: N=20 BATCH=5 dry runs on re-armed incidents (fewer = smoke run, not published; ABLATE_TIMELINE=1 for the ablation)
	@ABLATE_TIMELINE="$(ABLATE_TIMELINE)" $(ROOT)/scripts/dry-runs.sh "$(N)" "$(BATCH)"

.PHONY: preflight
preflight: ## Pre-flight checks (exit 1 on any FAIL); RUNG=3 PREFLIGHT_ARGS="--armed"
	@$(ROOT)/scripts/preflight.sh $(RUNG) $(PREFLIGHT_ARGS)

.PHONY: preflight-rung3-quiet
preflight-rung3-quiet: ## The check the scheduled unit runs before rearm (rung-3 armed checks, failures only)
	@$(ROOT)/scripts/preflight.sh 3 --armed --job-run --quiet

# The rung-3 job (Task 5.5). Not under the cluster lock: the unit can't inherit it (P12).
.PHONY: job-install night timer-arm timer-disarm timer-status
job-install: ## Install the user unit argoconna26-rearm.service (re-run when the repo path or PATH changes)
	@$(ROOT)/scripts/night.sh job-install
night: ## Run the nightly job now: the same unit the timer starts (needs autonomy act; failures exit 2, see scripts/night.sh)
	@$(ROOT)/scripts/night.sh night
timer-arm: ## Optional timer for the same unit: make timer-arm AT="YYYY-MM-DD HH:MM"
	@$(ROOT)/scripts/night.sh timer-arm "$(AT)"
timer-disarm: ## Remove the timer and the job env file
	@$(ROOT)/scripts/night.sh timer-disarm
timer-status: ## Show the timer's next trigger
	@$(ROOT)/scripts/night.sh timer-status

.PHONY: info
info: ## Print URLs and how to get credentials (never the passwords)
	@. $(ROOT)/scripts/common.sh; load_env
	cat <<INFO
	Argo CD     $$ARGOCD_HOST_URL      user admin, password: make -s argocd-password
	Grafana     $$GRAFANA_HOST_URL     user admin, password: GRAFANA_ADMIN_PASSWORD in .env
	Prometheus  $$PROM_HOST_URL
	Context     $$CLUSTER_CONTEXT (isolated kubeconfig: $$KUBECONFIG)
	INFO

################################################################################
# Operator scripts (Git pushes that drive the incident; see scripts/git-ops.sh) #
################################################################################

.PHONY: operator-clone
operator-clone: ## Clone the repo for the operator scripts and install the pre-commit hook
	@$(ROOT)/scripts/git-ops.sh operator-clone

.PHONY: seed-history
seed-history: ## Disarm, then commit PR-242 and one harmless docs change
	@$(ROOT)/scripts/seed-history.sh

.PHONY: bump
bump: ## Bump the checkout image tag by one patch version
	@$(ROOT)/scripts/git-ops.sh bump

.PHONY: rearm
rearm: ## Re-apply the PR-242 timeout, then bump the image (refuses when armed)
	@$(ROOT)/scripts/rearm.sh

.PHONY: fix
fix: ## Restore the timeout and bump config-version in one commit
	@$(ROOT)/scripts/fix.sh

.PHONY: naive-revert
naive-revert: ## Revert the last image bump: green but wrong
	@$(ROOT)/scripts/naive-revert.sh

.PHONY: disarm
disarm: ## Timeout back to 2000 (IMAGE=vX.Y.Z also pins the tag; GIT_ONLY=1 skips the wait)
	@$(ROOT)/scripts/git-ops.sh disarm $(if $(IMAGE),--image $(IMAGE)) $(if $(GIT_ONLY),--git-only)

################################################################################
# Resets between rehearsals (scripts/reset.sh; forward commits only)           #
################################################################################

.PHONY: reset-rung-1 reset-rung-2 reset-rung-3 reset-demo reset-to-scene-0 reset-to-scene-1 reset-to-scene-2 reset-to-scene-3
reset-rung-1: ## Back to the rung-1 start: disarmed, suggest, history seeded, timeline kept
	@$(ROOT)/scripts/reset.sh 1
reset-rung-2: ## Back to the rung-2 start: disarmed, suggest, a fresh propose promotion PR
	@$(ROOT)/scripts/reset.sh 2
reset-rung-3: ## Back to the rung-3 start: disarmed, propose, a fresh act promotion PR (exit 6 from suggest)
	@$(ROOT)/scripts/reset.sh 3
reset-demo: ## Rung-1 reset plus a re-seeded timeline (every full rehearsal starts the same)
	@$(ROOT)/scripts/reset.sh demo

# Jumping in at a scene (demo-full runs them in order with no reset between). reset-rung-3 also
# opens the fresh act promotion PR scene 3 needs, and exits 6 from suggest (see stage-day.sh).
reset-to-scene-0: reset-demo ## Back to before the cold open (reset-demo)
reset-to-scene-1: reset-rung-1 ## Back to the start of scene 1 (reset-rung-1)
reset-to-scene-2: reset-rung-2 ## Back to the start of scene 2 (reset-rung-2)
reset-to-scene-3: reset-rung-3 ## Back to the start of scene 3 (reset-rung-3: propose, a fresh act promotion PR)

################################################################################
# Autonomy: promotion PRs and demotion (scripts/promotion-pr.sh)               #
################################################################################

.PHONY: promotion-pr-ensure
promotion-pr-ensure: ## Close any open promotion PR and open a fresh one (LEVEL=propose|act)
	@$(ROOT)/scripts/promotion-pr.sh ensure $(or $(LEVEL),$(error LEVEL=propose|act is required))

.PHONY: promotion-record-approval
promotion-record-approval: ## After the merge, record who approved in autonomy.yaml (PR=<number>)
	@$(ROOT)/scripts/promotion-pr.sh record-approval $(or $(PR),$(error PR=<number> is required))

.PHONY: demote
demote: ## Lower the autonomy level by one step (a forward commit, direct push)
	@$(ROOT)/scripts/promotion-pr.sh demote

.PHONY: retarget
retarget: ## Move the tracked branch (BRANCH=main): commit, root app, bridge, rulesets, promotion PRs (scripts/retarget.sh)
	@$(ROOT)/scripts/retarget.sh $(or $(BRANCH),$(error BRANCH=<branch> is required))

.PHONY: disarm-git-only
disarm-git-only: ## (build-all) Push the disarm before Argo's first sync; skips without an operator clone
	@$(ROOT)/scripts/git-ops.sh disarm --git-only

################################################################################
# The rung scripts, as shown on stage (scripts/demo-rung-N.sh; TYPE_SPEED, NO_WAIT) #
################################################################################

.PHONY: demo-rung-1 demo-rung-2 demo-rung-3
demo-rung-1: ## Rung 1 (suggest) with demo-magic; start from make reset-rung-1
	@$(ROOT)/scripts/demo-rung-1.sh
demo-rung-2: ## Rung 2 (propose) with demo-magic; start from make reset-rung-2
	@$(ROOT)/scripts/demo-rung-2.sh
demo-rung-3: ## Rung 3 (act), live through make night; start from make reset-rung-3 and the act promotion
	@$(ROOT)/scripts/demo-rung-3.sh

# The scenes (O31): scripts/demo-<scene>.sh. DEMO_PACE=talk|auto, TYPE_SPEED, NO_WAIT; narration
# comes from narration/<scene>.txt when it exists (local only).
.PHONY: demo-cold-open demo-prologue demo-scene-1 demo-scene-2 demo-scene-3 demo-epilogue demo-close demo-full
demo-cold-open: ## Cold open: the 5:00 p.m. mandate, the 2:15 a.m. page
	@$(ROOT)/scripts/demo-cold-open.sh
demo-prologue: ## Prologue: Synced. Healthy. On fire.
	@$(ROOT)/scripts/demo-prologue.sh
demo-scene-1: ## Scene 1 (rung 1, suggest): look, don't touch
	@$(ROOT)/scripts/demo-scene-1.sh
demo-scene-2: ## Scene 2 (rung 2, propose): hands made of version control
	@$(ROOT)/scripts/demo-scene-2.sh
demo-scene-3: ## Scene 3 (rung 3, act): back in bed?
	@$(ROOT)/scripts/demo-scene-3.sh
demo-epilogue: ## Epilogue: what's real, then make demote
	@$(ROOT)/scripts/demo-epilogue.sh
demo-close: ## Close: the timeline, "it's in Slack", the repo
	@$(ROOT)/scripts/demo-close.sh
demo-full: ## The whole talk in order, no resets (start from stage-day.sh morning; DEMO_PACE=auto runs unattended)
	@$(ROOT)/scripts/demo-full.sh

.PHONY: snapshot
snapshot: ## (internal) record object UIDs and restart counts
	@mkdir -p $(SNAP_DIR)
	$(ROOT)/scripts/idempotency.sh snapshot $(SNAP_DIR)/before.txt

.PHONY: compare
compare: ## (internal) compare against the last snapshot
	@$(ROOT)/scripts/idempotency.sh snapshot $(SNAP_DIR)/after.txt
	$(ROOT)/scripts/idempotency.sh compare $(SNAP_DIR)/before.txt $(SNAP_DIR)/after.txt

.PHONY: verify-idempotent
verify-idempotent: ## rm-kind, build-all, build-all, compare, preflight
	@$(PRE)
	mkdir -p $(SNAP_DIR)
	$(MAKE) --no-print-directory rm-kind build-all
	$(MAKE) --no-print-directory snapshot
	$(MAKE) --no-print-directory build-all 2>&1 | tee $(SNAP_DIR)/second-build.log
	grep -q "skip: cluster $$CLUSTER_NAME exists" $(SNAP_DIR)/second-build.log \
	  || die "the second build-all did not log 'skip: cluster $$CLUSTER_NAME exists'"
	$(MAKE) --no-print-directory compare
	$(MAKE) --no-print-directory preflight
	log_info "verify-idempotent: OK"

################################################################################
# Recordings (backup clips; recordings/ is git-ignored)                        #
################################################################################

# The cast is sized to the stage terminal (DEMO_COLS, default 78; .env is not read here). asciinema 3 takes
# --window-size COLSxROWS where asciinema 2 had --cols/--rows. RECORD_CMD replaces the
# recorded command (used by the smoke test, which needs no cluster).
STAGE_ROWS    ?= 40
RECORDINGS_DIR ?= $(MAIN_ROOT)/recordings
GIF_IDLE      ?= 2

# record_cast NAME TARGET : recordings/NAME-<ts>.cast of `make TARGET`.
define record_cast
command -v asciinema >/dev/null || { echo "asciinema is not installed" >&2; exit 1; }
mkdir -p "$(RECORDINGS_DIR)"
cast="$(RECORDINGS_DIR)/$(1)-$$(date -u +%Y%m%dT%H%M%SZ).cast"
asciinema rec --return --window-size "$(or $(DEMO_COLS),78)x$(STAGE_ROWS)" \
  --command "$${RECORD_CMD:-NO_WAIT=false $(MAKE) --no-print-directory -C $(ROOT) $(2)}" \
  "$$cast"
echo "recorded: $$cast"
endef
record_rung = $(call record_cast,rung-$(1),demo-rung-$(1))

.PHONY: record-rung-1
record-rung-1: ## Record rung 1 on the stage pane size (recordings/rung-1-<ts>.cast)
	@$(call record_rung,1)

.PHONY: record-rung-2
record-rung-2: ## Record rung 2 on the stage pane size (recordings/rung-2-<ts>.cast)
	@$(call record_rung,2)

.PHONY: record-rung-3
record-rung-3: ## Record rung 3 on the stage pane size (recordings/rung-3-<ts>.cast)
	@$(call record_rung,3)

.PHONY: record-scene-1
record-scene-1: ## Record scene 1 on the stage pane size (recordings/scene-1-<ts>.cast)
	@$(call record_cast,scene-1,demo-scene-1)

.PHONY: record-scene-2
record-scene-2: ## Record scene 2 on the stage pane size (recordings/scene-2-<ts>.cast)
	@$(call record_cast,scene-2,demo-scene-2)

.PHONY: record-scene-3
record-scene-3: ## Record scene 3 on the stage pane size (recordings/scene-3-<ts>.cast)
	@$(call record_cast,scene-3,demo-scene-3)

.PHONY: record-full
record-full: ## Record the whole talk on the stage pane size (recordings/full-<ts>.cast)
	@$(call record_cast,full,demo-full)

.PHONY: gif
gif: ## Convert a cast to a GIF with agg (CAST=<file>, default the newest cast)
	@command -v agg >/dev/null || { echo "agg is not installed" >&2; exit 1; }
	cast="$(or $(CAST),$(shell ls -t $(RECORDINGS_DIR)/*.cast 2>/dev/null | head -n 1))"
	[[ -n "$$cast" && -f "$$cast" ]] || { echo "no cast: pass CAST=<file>" >&2; exit 1; }
	gif="$(or $(GIF),$${cast%.cast}.gif)"
	agg --idle-time-limit "$(GIF_IDLE)" --last-frame-duration 3 "$$cast" "$$gif"
	[[ -s "$$gif" ]] || { echo "empty gif: $$gif" >&2; exit 1; }
	echo "gif: $$gif"

.PHONY: chatgpt-login
chatgpt-login: ## Sign in to ChatGPT for LiteLLM (opens a device-code flow; no API key)
	@$(ROOT)/scripts/chatgpt-login.sh
