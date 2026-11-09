# 07. Setup

What you need before `make build-all`: the tools, the secrets, the GitHub side, and the changes
for running the demo from your own fork. The [README](../README.md#quick-start) has the short
version.

## Tools and secrets

Tools. Versions marked pinned are checked by `make vendor` against [versions.env](../versions.env).

| Tool | Version | Notes |
|------|---------|-------|
| Docker | Recent | Builds the demo images |
| [kind](https://kind.sigs.k8s.io/) | v0.33.0 | Pinned |
| kubectl | v1.37.2 | Pinned |
| kubectl-argo-rollouts plugin | v1.10.0 | Pinned |
| argocd CLI | v3.5.6 | Pinned |
| conftest | v0.71.1 | Pinned |
| gitleaks | v8.30.1 | Pinned |
| bats | 1.14.0 | Pinned |
| shellcheck | Recent | `make lint` |
| Helm | 3.x | Not pinned |
| gh | Recent | Operator login; scopes in [docs/github-setup.md](./github-setup.md) |
| jq, yq, envsubst, flock, curl, git, uv, pv | Recent | |
| asciinema, agg | v3.2.1, v1.9.0 | Pinned; recording only |
| systemd (user units) | Any | Only for the rung-3 scheduled job (`make night`) |

**Installing them with Homebrew.** On macOS or Linux, `make brew` runs
`brew bundle install --no-upgrade` on the [Brewfile](../Brewfile), then the `make vendor` check.
It covers the tools above except Docker (bring your own engine: Docker Desktop, colima or your
distro's package), curl, git and systemd. Homebrew installs a formula's current version, not the
one in versions.env, so `make vendor` can still fail on a pinned tool after a fresh install. In
November 2026 that was argocd: Homebrew had 3.6, the pin is 3.5. For such a tool, download the
pinned release binary from the project's GitHub releases into a directory and set `TOOLS_BIN` to
it in `.env`; make puts `TOOLS_BIN` first on `PATH`. `--no-upgrade` leaves tools you already
have alone, so it won't move one off its pin.

**Secrets.** Copy [.env.example](../.env.example) to `.env`, mode 0600. It is never committed. The
keys, all blank in the example:

| Key | Used for |
|-----|----------|
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` | LiteLLM's upstream provider keys (the second is optional) |
| `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_DB_PASSWORD` | LiteLLM proxy and its Postgres |
| `LLM_BUDGET_USD` | Per-cluster LLM budget in LiteLLM. Also set a spend limit at the provider |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login |
| `ARGOCD_ADMIN_PASSWORD` | Optional Argo CD admin login for a local demo; unset keeps Argo CD's generated one |
| `BRIDGE_WEBHOOK_TOKEN` | Bearer token Argo CD Notifications send to the bridge |
| `HOLMES_API_KEY` | `X-API-Key` HolmesGPT requires from the bridge |
| `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_APP_KEY_PATH` | The bridge's GitHub App (key file must live outside the repo) |
| `STAGE_APPROVER_LOGIN` | Login that approves promotion PRs on stage |
| `EVIDENCE_DIR`, `PRECOMMIT_HOOK_SRC`, `TOOLS_BIN` | Optional local paths |

**GitHub.** The bridge writes to Git only as a GitHub App, and rulesets box that App in. Create
the App, install it on one repository (your fork), and apply the rulesets as described in
[docs/github-setup.md](./github-setup.md).

## Run it from your own fork

As published, the Applications read `argo-multiverse-labs/argoconna26`, and the operator
scripts push to it. Without push rights there, point the demo at a fork of yours:

1. Fork the repository on GitHub and clone your fork.
2. Set the three names and rewrite everything that uses them, then commit to your fork:

   ```bash
   make configure-fork REPO_SLUG=you/argoconna26 BOT_LOGIN=your-app[bot] PROMOTION_TEAM=@you/promotion-board
   make consistency          # prints "consistency: OK" when every name agrees
   git add -A && git commit -m "feat: configure the demo for my fork" && git push
   ```

   This changes `demo.env`, each Application's `repoURL` under `gitops/`, `.github/CODEOWNERS`,
   `policy/data/agent.yaml` and the two env values in `bridge/deploy/deployment.yaml`. Any name
   you leave out keeps its value, and running it twice changes nothing the second time.
   `BOT_LOGIN` is your GitHub App's login (`<app-name>[bot]`).
3. Copy [.env.example](../.env.example) to `.env` (mode 0600) and add an LLM key.
4. `make operator-clone`. It pushes with your own `gh` login, or with a fine-grained token for
   your fork in `GH_TOKEN`.
5. `make build-all` (it creates the kind cluster), then `scripts/stage-day.sh morning` (the start
   state and the checks), then `make demo-full`. With rung 1 only, `make reset-demo` then
   `make demo-rung-1`.

What each rung needs on top of the platform:

| Rung | Needs |
|------|-------|
| The platform, the incident and `make naive-revert` | Push rights to your fork |
| 1 (suggest) | Also your own GitHub App with the permissions in [docs/github-setup.md](./github-setup.md), installed on the fork |
| 2 and 3 (propose, act) | Also a promotion-board team that owns the code-owner paths, the rulesets (`scripts/github-ruleset.sh apply`), `allow_auto_merge` on the repository, and Actions enabled (the `policy-check` workflow). Until those exist, run preflight with `PREFLIGHT_L5B=auto` |

`make retarget BRANCH=<branch>` moves the branch Argo CD, the bridge and the rulesets follow (for
example from `build/demo` to `main`, which is how the demo came to track `main`). It refuses a
destination the live rulesets do not already protect. See [docs/06-operations.md](./06-operations.md).

The fork path was checked on the upstream repository and by the tests in
`tests/bats/configure_fork.bats` and `tests/bats/consistency.bats`, not from a real fork.

## This fork: ChatGPT subscription backend

The `rca` and `judge` aliases use `chatgpt/gpt-6.1-sol` with LiteLLM 1.106.4.
No Anthropic or OpenAI API key is required. Run `make chatgpt-login` and complete
the device login in your browser before `make build-all`. Enable device-code login
in your ChatGPT security settings if the login flow asks for it.

The login is separate from Codex's cached credentials. Its default path is
`~/.config/litellm/chatgpt/auth.json`, outside this repository. `make litellm-install`
loads it into a Kubernetes Secret and seeds one persistent, writable token file.
One replica and one worker use it, so refresh tokens remain consistent across restarts.
After signing in again, update the Secret with `make litellm-install`; to replace
an already seeded login, remove only `/tokens/chatgpt/auth.json` from the LiteLLM
pod and restart the deployment so its init container seeds the new login.

Subscription usage counts against the signed-in account's allowance. LiteLLM does
not report its dollar cost or remaining subscription quota, so dollar-budget
checks are explicitly unavailable. Keys enforce 10 requests/minute and 100000
tokens/minute, with additional per-model limits in the proxy config. These are
rate limits, not a total-spend cap. The original Anthropic evaluation results do
not validate this model; rerun the dry-run harness before claiming the same score.

### Fedora WSL and the conference network

Set `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` to the host's trusted CA bundle;
on this laptop it is `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`.
The kind setup copies this bundle into demo nodes when it differs, and the image
builds accept it through a BuildKit secret. Argo CD trusts it for GitHub, and
LiteLLM mounts it from a ConfigMap. TLS verification stays enabled.

This laptop uses `OPERATOR_GIT_PROTOCOL=ssh` and a dedicated `GIT_SSH_COMMAND`
in `.env`. SSH handles Git; GitHub CLI's separate login handles REST/GraphQL.
For the first scene, leave `PREFLIGHT_L5B=auto` and use `make reset-demo`, then
`make demo-rung-1`. Promotion-team setup is only needed for the later scenes.

The pinned ChatGPT adapter drops the Responses `text` field, including JSON schemas.
`platform/litellm/chatgpt_schema.py` preserves this field using a small compatibility
callback loaded by LiteLLM. Native structured output was verified against the
subscription backend before deployment; the bridge still validates every RCA.
