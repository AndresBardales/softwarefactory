#!/usr/bin/env bash
# Step 10: Health Check — Verify all services are running
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

CONFIG_FILE="$HOME/.software-factory/config.env"
source "$CONFIG_FILE" 2>/dev/null || true

echo "=== Health Check ==="

errors=0
warnings=0

check_ok()   { log_info  "  ✓ $*"; }
check_warn() { log_warn  "  ⚠ $*"; warnings=$((warnings + 1)); }
check_fail() { log_error "  ✗ $*"; errors=$((errors + 1)); }

pod_ready() {
  local ns="$1" label="$2"
  # Use awk to avoid grep exit-code quirks that can produce "0\n0" values.
  kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null \
    | awk '/Running/{c++} END{print c+0}'
}

# ---------------------------------------------------------------
# 1. K3s node
# ---------------------------------------------------------------
echo ""
log_step "Kubernetes cluster"
if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
  check_ok "K3s node: Ready"
else
  check_fail "K3s node: NotReady"
fi

# ---------------------------------------------------------------
# 2. Core platform pods (prod namespace)
# ---------------------------------------------------------------
echo ""
log_step "Platform services (prod)"
for deploy in datastore kaanbal-api kaanbal-console; do
  if kubectl get deployment "$deploy" -n prod &>/dev/null; then
    ready=$(kubectl get deployment "$deploy" -n prod \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${ready:-0}" -ge 1 ]; then
      check_ok "$deploy: ${ready} replica(s) running"
    else
      check_warn "$deploy: 0 replicas ready — checking for 60s..."
      if wait_for "$deploy" \
        "kubectl get deploy $deploy -n prod -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'" \
        60 5; then
        check_ok "$deploy: running"
      else
        check_fail "$deploy: not ready after 60s"
      fi
    fi
  else
    check_warn "$deploy: deployment not found"
  fi
done

# ---------------------------------------------------------------
# 3. HTTP endpoints
# ---------------------------------------------------------------
echo ""
log_step "HTTP endpoints"
if curl -sf --max-time 5 -o /dev/null "http://localhost:30080" 2>/dev/null; then
  check_ok "kaanbal-console  http://localhost:30080"
else
  check_warn "kaanbal-console  not reachable on :30080"
fi
if curl -sf --max-time 5 -o /dev/null "http://localhost:30081/health" 2>/dev/null; then
  check_ok "kaanbal-api      http://localhost:30081/health"
else
  check_warn "kaanbal-api      not reachable on :30081/health"
fi

# ---------------------------------------------------------------
# 3b. Required control-plane secrets (from step 04)
# ---------------------------------------------------------------
echo ""
log_step "Control plane secrets"
if [ -n "${KB_ADMIN_PASSWORD:-${KB_ADMIN_PASS:-}}" ]; then
  check_ok "Admin password: configured"
else
  check_fail "Admin password: missing in config.env"
fi

if [ -n "${KB_ARGOCD_PASSWORD:-}" ]; then
  check_ok "ArgoCD password: configured"
else
  check_fail "ArgoCD password: missing in config.env"
fi

if [ -n "${KB_VAULT_TOKEN:-${KB_VAULT_ROOT_TOKEN:-}}" ]; then
  check_ok "Vault token: configured"
else
  check_fail "Vault token: missing in config.env"
fi

# ---------------------------------------------------------------
# 4. ArgoCD (cloud/hybrid only)
# ---------------------------------------------------------------
if [ "${KB_MODE:-standalone}" != "standalone" ] && [ "${KB_MODE:-local}" != "local" ]; then
  echo ""
  log_step "ArgoCD (GitOps)"
  argocd_running=$(pod_ready "argocd" "app.kubernetes.io/name=argocd-server")
  if [ "$argocd_running" -ge 1 ]; then
    check_ok "argocd-server: running"
    # Check if bootstrap application is synced
    if kubectl get application infra-bootstrap -n argocd &>/dev/null; then
      sync_status=$(kubectl get application infra-bootstrap -n argocd \
                    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
      if [ "$sync_status" = "Synced" ]; then
        check_ok "infra-bootstrap application: Synced ✓"
      elif [ "$sync_status" = "OutOfSync" ]; then
        check_warn "infra-bootstrap: OutOfSync (syncing...)"
      else
        check_warn "infra-bootstrap: ${sync_status} (may still be initializing)"
      fi
    else
      check_warn "infra-bootstrap application not found — will appear after infra-gitops is pushed"
    fi
  else
    check_warn "ArgoCD not running yet"
  fi

  # ---------------------------------------------------------------
  # 5. Vault
  # ---------------------------------------------------------------
  echo ""
  log_step "Vault (Secret Management)"
  vault_running=$(pod_ready "vault" "app.kubernetes.io/name=vault")
  if [ "$vault_running" -ge 1 ]; then
    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$vault_pod" ]; then
      sealed=$(kubectl exec -n vault "$vault_pod" -- vault status -format=json 2>/dev/null \
               | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','?'))" 2>/dev/null || echo "unknown")
      if [ "$sealed" = "False" ] || [ "$sealed" = "false" ]; then
        check_ok "Vault: running and unsealed ✓"
      elif [ "$sealed" = "True" ] || [ "$sealed" = "true" ]; then
        check_fail "Vault: SEALED — run: sf vault-unseal"
      else
        check_warn "Vault: could not determine seal status"
      fi
    fi
  else
    check_warn "Vault pod not running yet"
  fi

  # ---------------------------------------------------------------
  # 6. Tailscale Operator
  # ---------------------------------------------------------------
  if [ "${KB_TAILSCALE_ENABLED:-false}" = "true" ]; then
    echo ""
    log_step "Tailscale VPN"
    if ! kubectl get secret operator-oauth -n tailscale >/dev/null 2>&1; then
      check_fail "Tailscale Operator: secret operator-oauth is missing"
    elif kubectl rollout status deployment/operator -n tailscale --timeout=120s >/dev/null 2>&1; then
      check_ok "Tailscale Operator: running"
    else
      ts_status=$(kubectl get pods -n tailscale -l app.kubernetes.io/name=tailscale-operator --no-headers 2>/dev/null | awk 'NR==1 {print $3}')
      ts_status=${ts_status:-unknown}
      check_fail "Tailscale Operator: not ready (${ts_status})"
    fi
  fi

  # ---------------------------------------------------------------
  # 7. Ingress Controller
  # ---------------------------------------------------------------
  echo ""
  log_step "Ingress Controller"
  ingress_running=$(pod_ready "ingress-nginx" "app.kubernetes.io/name=ingress-nginx")
  if [ "$ingress_running" -ge 1 ]; then
    check_ok "Nginx Ingress Controller: running"
  else
    check_warn "Nginx Ingress Controller: not running"
  fi

  # ---------------------------------------------------------------
  # 8. Cloud domain reachability (hybrid mode)
  # ---------------------------------------------------------------
  if [ -n "${KB_DOMAIN:-}" ]; then
    echo ""
    log_step "Domain reachability (${KB_DOMAIN})"
    if curl -sf --max-time 10 -o /dev/null "https://kaanbal-console.${KB_DOMAIN}" 2>/dev/null; then
      check_ok "https://kaanbal-console.${KB_DOMAIN}: reachable"
    else
      check_warn "https://kaanbal-console.${KB_DOMAIN}: not yet reachable (DNS/TLS may still be propagating)"
    fi
  fi
fi

# ---------------------------------------------------------------
# 9. StorageClass validation (required for DB templates)
# ---------------------------------------------------------------
echo ""
log_step "StorageClass"
if kubectl get storageclass local-path &>/dev/null; then
  check_ok "StorageClass local-path: available"
else
  check_fail "StorageClass local-path: missing (DB templates may fail to bind PVCs)"
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "──────────────────────────────────────────"
if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
  echo "[OK] All health checks passed ✓"
elif [ $errors -eq 0 ]; then
  echo "[WARN] $warnings warning(s) — installation succeeded with minor issues"
else
  echo "[FAIL] $errors error(s), $warnings warning(s) — some services need attention"
  echo "       Review the output above and retry the failed steps"
fi
echo "=== Health check complete ==="
