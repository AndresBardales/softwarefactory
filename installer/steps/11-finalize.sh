#!/usr/bin/env bash
# Step 11: Finalize — Seed admin user, install sf CLI, print access summary
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

echo "=== Finalizing Installation ==="

CONFIG_DIR="$HOME/.software-factory"
CONFIG_FILE="$CONFIG_DIR/config.env"

# Load all config (includes SF_ADMIN_PASSWORD set by step 04)
source "$CONFIG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------
# Resolve admin credentials — ALWAYS use what the user entered.
# SF_ADMIN_PASSWORD is set by step 04.  SF_ADMIN_PASS is the old
# legacy variable; keep them in sync.  Never regenerate if already set.
# ---------------------------------------------------------------
if [ -z "${SF_ADMIN_USER:-}" ]; then
  SF_ADMIN_USER="admin"
  echo "SF_ADMIN_USER=${SF_ADMIN_USER}" >> "$CONFIG_FILE"
fi

# Prefer user-entered over old random one; if neither exists, generate once
_ADMIN_PW="${SF_ADMIN_PASSWORD:-${SF_ADMIN_PASS:-}}"
if [ -z "$_ADMIN_PW" ]; then
  _ADMIN_PW="$(generate_password 16)"
  echo "SF_ADMIN_PASSWORD=${_ADMIN_PW}" >> "$CONFIG_FILE"
  echo "SF_ADMIN_PASS=${_ADMIN_PW}"     >> "$CONFIG_FILE"
fi

_ARGOCD_PW="${SF_ARGOCD_PASSWORD:-${_ADMIN_PW}}"
_VAULT_TOKEN="${SF_VAULT_TOKEN:-${SF_VAULT_ROOT_TOKEN:-}}"
_VAULT_ADDR="${SF_VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"

chmod 600 "$CONFIG_FILE"

# ---------------------------------------------------------------
# Resolve URLs based on mode
# ---------------------------------------------------------------
SF_MODE="${SF_MODE:-standalone}"
SF_DOMAIN="${SF_DOMAIN:-}"
SERVER_IP="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

if [ "$SF_MODE" = "standalone" ] || [ -z "$SF_DOMAIN" ]; then
  CONSOLE_URL="http://${SERVER_IP}:30080"
  API_URL="http://${SERVER_IP}:30081"
  ARGOCD_URL="http://${SERVER_IP}:30082"
else
  CONSOLE_URL="https://nexus-console.${SF_DOMAIN}"
  API_URL="https://nexus-api.${SF_DOMAIN}"
  ARGOCD_URL="https://argocd.${SF_DOMAIN}"
fi

# ---------------------------------------------------------------
# Install sf CLI
# ---------------------------------------------------------------
if [ -f "$INSTALLER_DIR/sf" ]; then
  sudo cp "$INSTALLER_DIR/sf" /usr/local/bin/sf
  sudo chmod +x /usr/local/bin/sf
  log_info "sf CLI installed — use 'sf status' to check health"
fi

# ---------------------------------------------------------------
# Seed admin user via nexus-api
# ---------------------------------------------------------------
if curl -sf --max-time 5 "http://localhost:30081/health" &>/dev/null; then
  log_info "Seeding admin user via API..."
  _git_provider="${SF_GIT_PROVIDER:-github}"
  _git_workspace="${SF_GIT_WORKSPACE:-${SF_GIT_USER:-}}"
  _github_org=""
  _bitbucket_workspace=""
  if [ "${_git_provider}" = "github" ]; then
    _github_org="${_git_workspace}"
  elif [ "${_git_provider}" = "bitbucket" ]; then
    _bitbucket_workspace="${_git_workspace}"
  fi

  curl -sf --max-time 15 -X POST "http://localhost:30081/api/v1/setup/install" \
    -H "Content-Type: application/json" \
    -d "{\"mode\":\"${SF_MODE:-hybrid}\",\"domain\":\"${SF_DOMAIN:-}\",\"git_provider\":\"${_git_provider}\",\"git_username\":\"${SF_GIT_USER:-}\",\"git_token\":\"${SF_GIT_TOKEN:-}\",\"git_workspace\":\"${_git_workspace}\",\"github_org\":\"${_github_org}\",\"bitbucket_workspace\":\"${_bitbucket_workspace}\",\"dockerhub_username\":\"${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}\",\"dockerhub_token\":\"${SF_DOCKER_TOKEN:-}\",\"tailscale_client_id\":\"${SF_TAILSCALE_CLIENT_ID:-}\",\"tailscale_client_secret\":\"${SF_TAILSCALE_CLIENT_SECRET:-}\",\"tailscale_dns_suffix\":\"${SF_TAILSCALE_DNS_SUFFIX:-}\",\"cloudflare_token\":\"${SF_CLOUDFLARE_TOKEN:-}\",\"cloudflare_account_id\":\"${SF_CLOUDFLARE_ACCOUNT_ID:-}\",\"cloudflare_zone_id\":\"${SF_CLOUDFLARE_ZONE_ID:-}\",\"cloudflare_tunnel_id\":\"${SF_CLOUDFLARE_TUNNEL_ID:-}\",\"admin_user\":\"${SF_ADMIN_USER}\",\"admin_password\":\"${_ADMIN_PW}\",\"argocd_password\":\"${_ARGOCD_PW}\",\"vault_addr\":\"${_VAULT_ADDR}\",\"vault_token\":\"${_VAULT_TOKEN}\",\"vault_hostname\":\"${SF_VAULT_HOSTNAME:-}\",\"cluster_ssh_host\":\"${SF_CLUSTER_SSH_HOST:-}\"}" \
    &>/dev/null && log_info "Setup state + admin user created ✓" || log_warn "Setup seed may already exist — skipping"
else
  log_warn "API not reachable yet — admin user will be created on first login"
fi

# ---------------------------------------------------------------
# SOF-14 smoke checks (non-blocking): templates + Vault write/read + local-path
# ---------------------------------------------------------------
smoke_warnings=0

_warn_smoke() {
  log_warn "$1"
  smoke_warnings=$((smoke_warnings + 1))
}

if kubectl get storageclass local-path &>/dev/null; then
  log_info "SOF-14 smoke: local-path StorageClass available ✓"
else
  _warn_smoke "SOF-14 smoke: local-path StorageClass missing"
fi

if curl -sf --max-time 5 "http://localhost:30081/health" &>/dev/null; then
  _access_token="$(curl -sf --max-time 10 -X POST "http://localhost:30081/api/v1/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${SF_ADMIN_USER}&password=${_ADMIN_PW}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)"

  if [ -n "${_access_token}" ]; then
    _templates_json="$(curl -sf --max-time 15 "http://localhost:30081/api/v1/templates" \
      -H "Authorization: Bearer ${_access_token}" 2>/dev/null || true)"

    if [ -n "${_templates_json}" ] && echo "${_templates_json}" | python3 - <<'PY' >/dev/null 2>&1
import json
import sys

raw = sys.stdin.read()
data = json.loads(raw)
items = data if isinstance(data, list) else data.get("templates", [])
template_ids = {i.get("id") for i in items if isinstance(i, dict) and i.get("id")}
expected = {
    "vue3-spa",
    "fastapi-backend",
    "mongodb",
    "mysql",
    "postgres",
    "emqx",
    "n8n",
    "react-frontend",
}
missing = expected - template_ids
if missing:
    raise SystemExit(1)
PY
    then
      log_info "SOF-14 smoke: templates endpoint returned expected catalog IDs ✓"
    else
      _warn_smoke "SOF-14 smoke: templates endpoint missing expected IDs"
    fi
  else
    _warn_smoke "SOF-14 smoke: could not authenticate against API for template validation"
  fi
else
  _warn_smoke "SOF-14 smoke: API not reachable for templates check"
fi

if [ "${SF_MODE}" != "local" ] && [ -n "${_VAULT_TOKEN}" ]; then
  _vault_pod="$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${_vault_pod}" ]; then
    _smoke_path="installer-smoke/$(date +%s)"
    if kubectl exec -n vault "${_vault_pod}" -- sh -c "export VAULT_ADDR=http://127.0.0.1:8200; export VAULT_TOKEN='${_VAULT_TOKEN}'; vault kv put secret/${_smoke_path} probe=ok >/dev/null 2>&1; vault kv get -field=probe secret/${_smoke_path}" 2>/dev/null | grep -q '^ok$'; then
      log_info "SOF-14 smoke: Vault write/read test passed ✓"
    else
      _warn_smoke "SOF-14 smoke: Vault write/read test failed"
    fi
  else
    _warn_smoke "SOF-14 smoke: Vault pod not found"
  fi
fi

if [ "${smoke_warnings}" -eq 0 ]; then
  log_info "SOF-14 smoke checks passed"
else
  log_warn "SOF-14 smoke checks completed with ${smoke_warnings} warning(s)"
fi

# ---------------------------------------------------------------
# Write completion marker
# ---------------------------------------------------------------
echo "SF_INSTALLED=true"            >> "$CONFIG_FILE"
echo "SF_INSTALLED_AT=$(date -Iseconds)" >> "$CONFIG_FILE"

# ---------------------------------------------------------------
# Git repo URLs
# ---------------------------------------------------------------
GIT_PROVIDER="${SF_GIT_PROVIDER:-github}"
GIT_WORKSPACE="${SF_GIT_WORKSPACE:-}"
if [ "$GIT_PROVIDER" = "github" ] && [ -n "$GIT_WORKSPACE" ]; then
  REPO_BASE="https://github.com/${GIT_WORKSPACE}"
elif [ "$GIT_PROVIDER" = "bitbucket" ] && [ -n "$GIT_WORKSPACE" ]; then
  REPO_BASE="https://bitbucket.org/${GIT_WORKSPACE}"
else
  REPO_BASE=""
fi

# ---------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║          SOFTWARE FACTORY — Installation Complete          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "  🖥  Platform"
echo "     Console  : ${CONSOLE_URL}"
echo "     API      : ${API_URL}/docs"
echo "     Admin    : ${SF_ADMIN_USER} / ${_ADMIN_PW}"
echo ""
echo "  🔄  GitOps (ArgoCD)"
echo "     URL      : ${ARGOCD_URL}"
echo "     User     : admin"
echo "     Password : ${_ARGOCD_PW}"
echo ""
if [ -n "${_VAULT_TOKEN}" ]; then
  echo "  🔐  Vault"
  echo "     URL      : http://${SERVER_IP}:30083  (or vault.${SF_DOMAIN:-local})"
  echo "     Token    : ${_VAULT_TOKEN}"
  echo "     Keys     : ${CONFIG_DIR}/vault-keys.json  (keep this safe!)"
  echo ""
fi
if [ "${SF_TAILSCALE_ENABLED:-false}" = "true" ]; then
  echo "  🌐  Tailscale VPN"
  echo "     Tailnet  : ${SF_TAILSCALE_DNS_SUFFIX:-check tailscale.com/admin}"
  echo "     Status   : $(kubectl get pods -n tailscale -l app=tailscale-operator --no-headers 2>/dev/null | head -1 | awk '{print $3}' || echo 'check: kubectl get pods -n tailscale')"
  echo ""
fi
if [ -n "$REPO_BASE" ]; then
  echo "  📦  Source Repositories"
  echo "     nexus-api     : ${REPO_BASE}/nexus-api"
  echo "     nexus-console : ${REPO_BASE}/nexus-console"
  echo "     infra-gitops  : ${REPO_BASE}/infra-gitops"
  echo ""
fi
echo "  📋  Quick commands"
echo "     sf status                  — check platform health"
echo "     sf logs nexus-api          — view API logs"
echo "     kubectl get pods -n prod   — view running pods"
echo "     cat ${CONFIG_DIR}/vault-keys.json   — Vault unseal keys"
echo ""
echo "=== ADMIN_USER=${SF_ADMIN_USER} ==="
echo "=== ADMIN_PASS=${_ADMIN_PW} ==="
echo "=== CONSOLE_URL=${CONSOLE_URL} ==="
echo "=== Installation complete ==="
