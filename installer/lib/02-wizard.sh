#!/usr/bin/env bash
# ==============================================================================
# lib/02-wizard.sh — Interactive configuration wizard
# ==============================================================================

run_wizard() {
  log_info "Starting configuration wizard..."
  echo ""

  # --------------------------------------------------
  # Step 1: Installation mode
  # --------------------------------------------------
  prompt_choice "Choose installation mode:" \
    "Local — apps on localhost, zero cloud cost" \
    "Cloud — deploy to AWS with public domain" \
    "Hybrid — local master + cloud gateway for public access"
  case $PROMPT_RESULT in
    0) KB_MODE="local" ;;
    1) KB_MODE="cloud" ;;
    2) KB_MODE="hybrid" ;;
  esac
  log_info "Mode: $KB_MODE"
  echo ""

  # --------------------------------------------------
  # Step 2: Git provider
  # --------------------------------------------------
  prompt_choice "Choose your Git provider:" \
    "Bitbucket (recommended — integrated pipelines)" \
    "GitHub" \
    "GitLab"
  case $PROMPT_RESULT in
    0) KB_GIT_PROVIDER="bitbucket" ;;
    1) KB_GIT_PROVIDER="github" ;;
    2) KB_GIT_PROVIDER="gitlab" ;;
  esac
  log_info "Git provider: $KB_GIT_PROVIDER"
  echo ""

  # Git credentials
  prompt_value "Git username" "" KB_GIT_USERNAME
  prompt_value "Git email" "" KB_GIT_EMAIL
  prompt_value "Git access token (with repo + pipeline permissions)" "" KB_GIT_TOKEN true

  if [ "$KB_GIT_PROVIDER" = "bitbucket" ]; then
    prompt_value "Bitbucket workspace slug" "" KB_BITBUCKET_WORKSPACE
  elif [ "$KB_GIT_PROVIDER" = "github" ]; then
    prompt_value "GitHub organization (or username)" "$KB_GIT_USERNAME" KB_GITHUB_ORG
  fi
  echo ""

  # --------------------------------------------------
  # Step 3: Docker registry
  # --------------------------------------------------
  prompt_value "Docker Hub username" "" KB_DOCKER_USERNAME
  prompt_value "Docker Hub token" "" KB_DOCKER_TOKEN true
  echo ""

  # --------------------------------------------------
  # Step 4: Domain & networking (cloud/hybrid only)
  # --------------------------------------------------
  KB_DOMAIN="localhost"
  KB_ELASTIC_IP=""
  KB_ENABLE_TLS=false
  KB_TUNNEL_PROVIDER=""
  KB_CLOUDFLARE_TOKEN=""
  KB_CLOUDFLARE_ACCOUNT_ID=""

  if [ "$KB_MODE" = "cloud" ] || [ "$KB_MODE" = "hybrid" ]; then
    prompt_value "Your domain name (e.g., yourdomain.com)" "" KB_DOMAIN
    KB_ENABLE_TLS=true

    if [ "$KB_MODE" = "hybrid" ]; then
      echo ""
      log_info "Hybrid mode needs a tunnel to expose local apps publicly."
      prompt_choice "Choose tunnel provider:" \
        "Cloudflare Tunnel (recommended — free, no VPS needed)" \
        "Tailscale Funnel (free, limited to HTTPS)" \
        "Skip for now (configure later via web wizard)"
      case $PROMPT_RESULT in
        0) KB_TUNNEL_PROVIDER="cloudflare" ;;
        1) KB_TUNNEL_PROVIDER="tailscale-funnel" ;;
        2) KB_TUNNEL_PROVIDER="" ;;
      esac

      if [ "$KB_TUNNEL_PROVIDER" = "cloudflare" ]; then
        echo ""
        log_info "Create a Cloudflare API token at: https://dash.cloudflare.com/profile/api-tokens"
        log_info "Required permissions: Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit"
        prompt_value "Cloudflare API Token" "" KB_CLOUDFLARE_TOKEN true
        prompt_value "Cloudflare Account ID (from dashboard URL)" "" KB_CLOUDFLARE_ACCOUNT_ID
      fi
    fi

    if [ "$KB_MODE" = "cloud" ]; then
      prompt_value "AWS Elastic IP (leave blank to auto-create)" "" KB_ELASTIC_IP
    fi
  fi

  # Local mode: offer nip.io for LAN access
  if [ "$KB_MODE" = "local" ]; then
    echo ""
    if prompt_yn "Enable LAN access (access from other devices on your network)?"; then
      local lan_ip
      lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      KB_DOMAIN="${lan_ip}.nip.io"
      log_info "LAN domain: $KB_DOMAIN (auto-resolves to $lan_ip)"
    fi
  fi
  echo ""

  # --------------------------------------------------
  # Step 5: Tailscale (optional for local, recommended for hybrid)
  # --------------------------------------------------
  KB_TAILSCALE_ENABLED=false
  KB_TAILSCALE_CLIENT_ID=""
  KB_TAILSCALE_CLIENT_SECRET=""
  KB_TAILSCALE_DNS_SUFFIX=""

  if [ "$KB_MODE" = "hybrid" ]; then
    log_info "Tailscale is required for hybrid mode (VPN mesh between local and cloud)"
    KB_TAILSCALE_ENABLED=true
  elif prompt_yn "Enable Tailscale (secure remote access to internal apps)?"; then
    KB_TAILSCALE_ENABLED=true
  fi

  if [ "$KB_TAILSCALE_ENABLED" = true ]; then
    prompt_value "Tailscale OAuth Client ID" "" KB_TAILSCALE_CLIENT_ID true
    prompt_value "Tailscale OAuth Client Secret" "" KB_TAILSCALE_CLIENT_SECRET true
    prompt_value "Tailscale MagicDNS suffix (e.g., taildd8884.ts.net)" "" KB_TAILSCALE_DNS_SUFFIX
  fi
  echo ""

  # --------------------------------------------------
  # Step 6: AWS credentials (cloud/hybrid only)
  # --------------------------------------------------
  KB_AWS_REGION=""
  KB_AWS_ACCESS_KEY=""
  KB_AWS_SECRET_KEY=""

  if [ "$KB_MODE" = "cloud" ] || [ "$KB_MODE" = "hybrid" ]; then
    log_info "AWS credentials are needed for cloud infrastructure"
    prompt_value "AWS region" "us-east-1" KB_AWS_REGION
    prompt_value "AWS Access Key" "" KB_AWS_ACCESS_KEY true
    prompt_value "AWS Secret Key" "" KB_AWS_SECRET_KEY true
    echo ""
  fi

  # --------------------------------------------------
  # Step 7: Admin credentials
  # --------------------------------------------------
  KB_ADMIN_USER="admin"
  KB_ADMIN_PASSWORD="$(generate_password 12)"
  prompt_value "Admin username" "admin" KB_ADMIN_USER
  prompt_value "Admin password (auto-generated if blank)" "$KB_ADMIN_PASSWORD" KB_ADMIN_PASSWORD

  # ArgoCD password
  KB_ARGOCD_PASSWORD="$(generate_password 16)"
  echo ""

  # --------------------------------------------------
  # Save configuration
  # --------------------------------------------------
  log_step "Saving configuration to $KB_CONFIG"

  cat > "$KB_CONFIG" << CONF
# Kaanbal Engine Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: ${KB_VERSION}

# Mode: local | cloud | hybrid
KB_MODE="${KB_MODE}"

# Git provider: bitbucket | github | gitlab
KB_GIT_PROVIDER="${KB_GIT_PROVIDER}"
KB_GIT_USERNAME="${KB_GIT_USERNAME}"
KB_GIT_EMAIL="${KB_GIT_EMAIL}"
KB_GIT_TOKEN="${KB_GIT_TOKEN}"
KB_BITBUCKET_WORKSPACE="${KB_BITBUCKET_WORKSPACE:-}"
KB_GITHUB_ORG="${KB_GITHUB_ORG:-}"

# Docker Hub
KB_DOCKER_USERNAME="${KB_DOCKER_USERNAME}"
KB_DOCKER_TOKEN="${KB_DOCKER_TOKEN}"

# Domain & Networking
KB_DOMAIN="${KB_DOMAIN}"
KB_ELASTIC_IP="${KB_ELASTIC_IP}"
KB_ENABLE_TLS="${KB_ENABLE_TLS}"

# Tunnel
KB_TUNNEL_PROVIDER="${KB_TUNNEL_PROVIDER:-}"
KB_CLOUDFLARE_TOKEN="${KB_CLOUDFLARE_TOKEN:-}"
KB_CLOUDFLARE_ACCOUNT_ID="${KB_CLOUDFLARE_ACCOUNT_ID:-}"

# Tailscale
KB_TAILSCALE_ENABLED="${KB_TAILSCALE_ENABLED}"
KB_TAILSCALE_CLIENT_ID="${KB_TAILSCALE_CLIENT_ID}"
KB_TAILSCALE_CLIENT_SECRET="${KB_TAILSCALE_CLIENT_SECRET}"
KB_TAILSCALE_DNS_SUFFIX="${KB_TAILSCALE_DNS_SUFFIX}"

# AWS (cloud/hybrid only)
KB_AWS_REGION="${KB_AWS_REGION}"
KB_AWS_ACCESS_KEY="${KB_AWS_ACCESS_KEY}"
KB_AWS_SECRET_KEY="${KB_AWS_SECRET_KEY}"

# Admin
KB_ADMIN_USER="${KB_ADMIN_USER}"
KB_ADMIN_PASSWORD="${KB_ADMIN_PASSWORD}"
KB_ARGOCD_PASSWORD="${KB_ARGOCD_PASSWORD}"
CONF

  chmod 600 "$KB_CONFIG"
  log_info "Configuration saved (file permissions: 600)"
}
