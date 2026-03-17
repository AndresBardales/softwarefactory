#!/usr/bin/env bash
# Step 00: Clean Install — Wipe everything and start fresh.
# Optional remote cleanup is controlled by env vars:
#   SF_CLEAN_DELETE_CLOUDFLARE_TUNNEL=true|false (default true)
#   SF_CLEAN_DELETE_REMOTE_REPOS=true|false      (default false)
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

CONFIG_DIR="$HOME/.software-factory"
CONFIG_FILE="$CONFIG_DIR/config.env"
STATE_FILE="$CONFIG_DIR/installer-state.json"

DELETE_CF_TUNNEL="${SF_CLEAN_DELETE_CLOUDFLARE_TUNNEL:-true}"
DELETE_REMOTE_REPOS="${SF_CLEAN_DELETE_REMOTE_REPOS:-false}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" || true
fi

echo "=== Clean Install: Wiping Everything ==="
echo ""
log_warn "This removes local cluster, data, installer state and (optionally) remote resources."
echo ""

clean_cloudflare_tunnel() {
  [ "$DELETE_CF_TUNNEL" = "true" ] || return 0

  local token="${SF_CLOUDFLARE_TOKEN:-}"
  local account_id="${SF_CLOUDFLARE_ACCOUNT_ID:-}"
  local tunnel_id="${SF_CLOUDFLARE_TUNNEL_ID:-}"

  if [ -z "$token" ] || [ -z "$account_id" ]; then
    log_warn "Cloudflare credentials not found — skipping remote tunnel cleanup"
    return 0
  fi

  if [ -z "$tunnel_id" ]; then
    tunnel_id=$(curl -sS -X GET "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel?name=software-factory&is_deleted=false" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result',[]); print(r[0].get('id','') if r else '')" 2>/dev/null || true)
  fi

  if [ -n "$tunnel_id" ]; then
    log_info "Deleting Cloudflare tunnel: ${tunnel_id}"
    curl -sS -X DELETE "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" >/dev/null 2>&1 || true
  else
    log_info "No Cloudflare tunnel to delete"
  fi
}

clean_remote_github_repos() {
  [ "$DELETE_REMOTE_REPOS" = "true" ] || return 0

  local provider="${SF_GIT_PROVIDER:-github}"
  local user="${SF_GIT_WORKSPACE:-${SF_GIT_USER:-}}"
  local token="${SF_GIT_TOKEN:-}"

  if [ "$provider" != "github" ]; then
    log_warn "Remote repo delete currently implemented for GitHub only — skipping"
    return 0
  fi
  if [ -z "$user" ] || [ -z "$token" ]; then
    log_warn "Git credentials not found — skipping remote repo cleanup"
    return 0
  fi

  for repo in nexus-api nexus-console infra-gitops; do
    log_info "Deleting GitHub repo: ${user}/${repo}"
    curl -sS -X DELETE "https://api.github.com/repos/${user}/${repo}" \
      -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.github+json" >/dev/null 2>&1 || true
  done
}

# 1) Optional remote cleanup first while credentials still exist
clean_cloudflare_tunnel
clean_remote_github_repos

# 2) Uninstall K3s
if command -v k3s-uninstall.sh >/dev/null 2>&1; then
  log_info "Uninstalling K3s server..."
  sudo k3s-uninstall.sh || true
  echo "[OK] K3s server uninstalled"
elif command -v k3s-agent-uninstall.sh >/dev/null 2>&1; then
  log_info "Uninstalling K3s agent..."
  sudo k3s-agent-uninstall.sh || true
  echo "[OK] K3s agent uninstalled"
else
  log_info "K3s not found — skipping uninstall"
fi

# 3) Kill helper processes
sudo pkill -f cloudflared 2>/dev/null || true
sudo pkill -f tailscaled 2>/dev/null || true

# 4) Clean K3s and Kubernetes data
log_info "Cleaning Kubernetes data directories..."
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s /var/lib/kubelet /etc/cni /var/lib/cni 2>/dev/null || true
sudo rm -rf /opt/local-path-provisioner /var/lib/rancher/k3s/storage 2>/dev/null || true
echo "[OK] Kubernetes data cleaned"

# 5) Clean kubeconfig
rm -f "$HOME/.kube/config" 2>/dev/null || true
sudo rm -f /etc/rancher/k3s/k3s.yaml 2>/dev/null || true

# 6) Clean container artifacts
if command -v crictl >/dev/null 2>&1; then
  log_info "Cleaning container images..."
  sudo crictl rmi --prune 2>/dev/null || true
fi

# 7) Reset installer state (keep setup token only)
mkdir -p "$CONFIG_DIR"
TOKEN_LINE=""
if [ -f "$CONFIG_FILE" ]; then
  TOKEN_LINE=$(grep "^SF_SETUP_TOKEN=" "$CONFIG_FILE" 2>/dev/null || true)
fi

cat > "$CONFIG_FILE" <<EOF
SF_MODE="local"
SF_DOMAIN="localhost"
SF_ENABLE_TLS=false
${TOKEN_LINE}
EOF
chmod 600 "$CONFIG_FILE"

rm -f "$STATE_FILE" "$CONFIG_DIR"/vault-keys.json 2>/dev/null || true
rm -rf "$CONFIG_DIR"/logs 2>/dev/null || true

# 8) Remove temp artifacts
sudo rm -f /tmp/sf-*.sh /tmp/sf-*.log /tmp/step-log*.bin 2>/dev/null || true

echo ""
echo "[OK] Clean install complete — system is ready for a fresh installation"
echo "=== Clean install done ==="
