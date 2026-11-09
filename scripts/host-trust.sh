#!/usr/bin/env bash
# kind nodes need the host trust roots when WSL sits behind a TLS proxy.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_env
cluster_lock
require_context
bundle="${SSL_CERT_FILE:-}"
[[ -n "$bundle" && -s "$bundle" ]] || { log_info "skip: no host CA bundle configured"; exit 0; }
want="$(sha256sum "$bundle" | cut -d' ' -f1)"
while read -r node; do
  [[ "$node" == "$CLUSTER_NAME"-* ]] || die "unexpected kind node: $node"
  have="$(docker exec "$node" sha256sum /etc/ssl/certs/ca-certificates.crt | cut -d' ' -f1)"
  if [[ "$have" != "$want" ]]; then
    docker cp "$bundle" "$node:/etc/ssl/certs/ca-certificates.crt" >/dev/null
    docker exec "$node" systemctl restart containerd
    log_info "installed host CA bundle: $node"
  else
    log_info "skip: host CA bundle unchanged: $node"
  fi
done < <(kind get nodes --name "$CLUSTER_NAME")
