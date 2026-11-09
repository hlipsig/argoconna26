#!/usr/bin/env bash
# Keep the provider's login separate from Codex's own refresh credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/common.sh"
load_env
umask 077
uv run --with "litellm[mcp]==${LITELLM_IMAGE_TAG#v}" python -c 'from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token(); print("ChatGPT login saved.")'
