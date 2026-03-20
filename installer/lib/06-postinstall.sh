#!/usr/bin/env bash
# ==============================================================================
# lib/06-postinstall.sh — Post-installation: seed config, health checks
# ==============================================================================

run_post_install() {
  log_step "Running post-installation setup..."

  # Wait for kaanbal-api to be ready
  if ! wait_for "kaanbal-api pod" \
    "kubectl -n prod get pod -l app=kaanbal-api -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" \
    180; then
    log_warn "kaanbal-api not ready after 180s — skipping post-install seed"
    log_warn "The web wizard will handle configuration instead"
    return 0
  fi

  # Get kaanbal-api pod IP for direct communication
  local api_ip
  api_ip=$(kubectl -n prod get pod -l app=kaanbal-api -o jsonpath='{.items[0].status.podIP}')
  local api_url="http://${api_ip}:8000"

  log_step "Seeding platform configuration..."

  # 1. Create admin user (bootstrap)
  local token
  token=$(curl -sf --max-time 10 -X POST "${api_url}/api/v1/auth/signup" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${KB_ADMIN_USER}\",\"email\":\"${KB_GIT_USER:-admin@localhost}\",\"password\":\"${KB_ADMIN_PASSWORD}\"}" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

  # If signup fails (user exists), try login
  if [ -z "$token" ]; then
    token=$(curl -sf --max-time 10 -X POST "${api_url}/api/v1/auth/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=${KB_ADMIN_USER}&password=${KB_ADMIN_PASSWORD}" \
      2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
  fi

  if [ -z "$token" ]; then
    log_warn "Could not authenticate with kaanbal-api. Manual setup may be needed."
    return 0
  fi

  log_info "Admin user authenticated"

  # 2. Seed system configuration
  local argocd_server="https://argocd-server.argocd.svc.cluster.local"
  local argocd_url="http://localhost:30082"
  [ "$KB_MODE" != "local" ] && argocd_url="https://cd.${KB_DOMAIN}"

  local settings_payload
  settings_payload=$(cat <<SEED
{
  "domain": "${KB_DOMAIN}",
  "argocd_server": "${argocd_server}",
  "argocd_url": "${argocd_url}",
  "argocd_username": "admin",
  "argocd_password": "${KB_ARGOCD_PASSWORD:-}",
  "git_token": "${KB_GIT_TOKEN}",
  "git_username": "${KB_GIT_USER}",
  "git_workspace": "${KB_GIT_WORKSPACE}",
  "bitbucket_email": "${KB_GIT_USER}",
  "bitbucket_workspace": "${KB_BITBUCKET_WORKSPACE:-}",
  "dockerhub_username": "${KB_DOCKER_USERNAME}",
  "dockerhub_token": "${KB_DOCKER_TOKEN}",
  "tailscale_dns_suffix": "${KB_TAILSCALE_DNS_SUFFIX:-}",
  "KB_mode": "${KB_MODE}",
  "git_provider": "${KB_GIT_PROVIDER:-bitbucket}",
  "github_org": "${KB_GITHUB_ORG:-${KB_GIT_WORKSPACE}}",
  "github_token": "${KB_GIT_TOKEN}",
  "github_is_org": false,
  "cloudflare_token": "${KB_CLOUDFLARE_TOKEN:-}",
  "cloudflare_account_id": "${KB_CLOUDFLARE_ACCOUNT_ID:-}",
  "cloudflare_tunnel_id": "${KB_CLOUDFLARE_TUNNEL_ID:-}",
  "cloudflare_zone_id": "${KB_CLOUDFLARE_ZONE_ID:-}",
  "vault_token": "${KB_VAULT_TOKEN:-}",
  "vault_addr": "${KB_VAULT_ADDR:-}",
  "templates_repo": "kaanbal-templates"
}
SEED
)

  local seed_result
  seed_result=$(curl -sf --max-time 15 -X PUT "${api_url}/api/v1/admin/settings" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$settings_payload" 2>&1)

  if echo "$seed_result" | grep -q "success\|updated\|ok" 2>/dev/null; then
    log_info "System configuration seeded in MongoDB"
  else
    log_warn "Config seed response: ${seed_result:-no response}"
    log_warn "You may need to configure settings manually from the UI"
  fi
}

wait_for_healthy() {
  log_step "Verifying all components are healthy..."

  local all_healthy=true

  # Check pods
  for app in datastore kaanbal-api kaanbal-console; do
    if kubectl -n prod get pod -l "app=$app" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
      log_info "$app: Running"
    else
      log_warn "$app: not ready yet"
      all_healthy=false
    fi
  done

  # Check ArgoCD (cloud/hybrid only — skipped in local mode)
  if [ "$KB_MODE" != "local" ]; then
    if kubectl -n argocd get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
      log_info "ArgoCD: Running"
    else
      log_warn "ArgoCD: not ready yet"
      all_healthy=false
    fi
  fi

  # Check Ingress (cloud/hybrid only — local mode uses NodePort)
  if [ "$KB_MODE" != "local" ]; then
    if kubectl -n ingress-nginx get pod -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
      log_info "Nginx Ingress: Running"
    else
      log_warn "Nginx Ingress: not ready yet"
      all_healthy=false
    fi
  fi

  if [ "$all_healthy" = true ]; then
    log_info "All components healthy"
  else
    log_warn "Some components are still starting. Run 'kb status' to check later."
  fi
}
