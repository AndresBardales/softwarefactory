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
  local mode_idx=$?
  case $mode_idx in
    0) SF_MODE="local" ;;
    1) SF_MODE="cloud" ;;
    2) SF_MODE="hybrid" ;;
  esac
  log_info "Mode: $SF_MODE"
  echo ""

  # --------------------------------------------------
  # Step 2: Git provider
  # --------------------------------------------------
  prompt_choice "Choose your Git provider:" \
    "Bitbucket (recommended — integrated pipelines)" \
    "GitHub" \
    "GitLab"
  local git_idx=$?
  case $git_idx in
    0) SF_GIT_PROVIDER="bitbucket" ;;
    1) SF_GIT_PROVIDER="github" ;;
    2) SF_GIT_PROVIDER="gitlab" ;;
  esac
  log_info "Git provider: $SF_GIT_PROVIDER"
  echo ""

  # Git credentials
  prompt_value "Git username" "" SF_GIT_USERNAME
  prompt_value "Git email" "" SF_GIT_EMAIL
  prompt_value "Git access token (with repo + pipeline permissions)" "" SF_GIT_TOKEN true

  if [ "$SF_GIT_PROVIDER" = "bitbucket" ]; then
    prompt_value "Bitbucket workspace slug" "" SF_BITBUCKET_WORKSPACE
  elif [ "$SF_GIT_PROVIDER" = "github" ]; then
    prompt_value "GitHub organization (or username)" "$SF_GIT_USERNAME" SF_GITHUB_ORG
  fi
  echo ""

  # --------------------------------------------------
  # Step 3: Docker registry
  # --------------------------------------------------
  prompt_value "Docker Hub username" "" SF_DOCKER_USERNAME
  prompt_value "Docker Hub token" "" SF_DOCKER_TOKEN true
  echo ""

  # --------------------------------------------------
  # Step 4: Domain & networking (cloud/hybrid only)
  # --------------------------------------------------
  SF_DOMAIN="localhost"
  SF_ELASTIC_IP=""
  SF_ENABLE_TLS=false

  if [ "$SF_MODE" = "cloud" ] || [ "$SF_MODE" = "hybrid" ]; then
    prompt_value "Your domain name (e.g., futurefarms.mx)" "" SF_DOMAIN
    SF_ENABLE_TLS=true

    if [ "$SF_MODE" = "cloud" ]; then
      prompt_value "AWS Elastic IP (leave blank to auto-create)" "" SF_ELASTIC_IP
    fi
  fi

  # Local mode: offer nip.io for LAN access
  if [ "$SF_MODE" = "local" ]; then
    echo ""
    if prompt_yn "Enable LAN access (access from other devices on your network)?"; then
      local lan_ip
      lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      SF_DOMAIN="${lan_ip}.nip.io"
      log_info "LAN domain: $SF_DOMAIN (auto-resolves to $lan_ip)"
    fi
  fi
  echo ""

  # --------------------------------------------------
  # Step 5: Tailscale (optional for local, recommended for hybrid)
  # --------------------------------------------------
  SF_TAILSCALE_ENABLED=false
  SF_TAILSCALE_CLIENT_ID=""
  SF_TAILSCALE_CLIENT_SECRET=""
  SF_TAILSCALE_DNS_SUFFIX=""

  if [ "$SF_MODE" = "hybrid" ]; then
    log_info "Tailscale is required for hybrid mode (VPN mesh between local and cloud)"
    SF_TAILSCALE_ENABLED=true
  elif prompt_yn "Enable Tailscale (secure remote access to internal apps)?"; then
    SF_TAILSCALE_ENABLED=true
  fi

  if [ "$SF_TAILSCALE_ENABLED" = true ]; then
    prompt_value "Tailscale OAuth Client ID" "" SF_TAILSCALE_CLIENT_ID true
    prompt_value "Tailscale OAuth Client Secret" "" SF_TAILSCALE_CLIENT_SECRET true
    prompt_value "Tailscale MagicDNS suffix (e.g., taildd8884.ts.net)" "" SF_TAILSCALE_DNS_SUFFIX
  fi
  echo ""

  # --------------------------------------------------
  # Step 6: AWS credentials (cloud/hybrid only)
  # --------------------------------------------------
  SF_AWS_REGION=""
  SF_AWS_ACCESS_KEY=""
  SF_AWS_SECRET_KEY=""

  if [ "$SF_MODE" = "cloud" ] || [ "$SF_MODE" = "hybrid" ]; then
    log_info "AWS credentials are needed for cloud infrastructure"
    prompt_value "AWS region" "us-east-1" SF_AWS_REGION
    prompt_value "AWS Access Key" "" SF_AWS_ACCESS_KEY true
    prompt_value "AWS Secret Key" "" SF_AWS_SECRET_KEY true
    echo ""
  fi

  # --------------------------------------------------
  # Step 7: Admin credentials
  # --------------------------------------------------
  SF_ADMIN_USER="admin"
  SF_ADMIN_PASSWORD="$(generate_password 12)"
  prompt_value "Admin username" "admin" SF_ADMIN_USER
  prompt_value "Admin password (auto-generated if blank)" "$SF_ADMIN_PASSWORD" SF_ADMIN_PASSWORD

  # ArgoCD password
  SF_ARGOCD_PASSWORD="$(generate_password 16)"
  echo ""

  # --------------------------------------------------
  # Save configuration
  # --------------------------------------------------
  log_step "Saving configuration to $SF_CONFIG"

  cat > "$SF_CONFIG" << CONF
# Software Factory Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Version: ${SF_VERSION}

# Mode: local | cloud | hybrid
SF_MODE="${SF_MODE}"

# Git provider: bitbucket | github | gitlab
SF_GIT_PROVIDER="${SF_GIT_PROVIDER}"
SF_GIT_USERNAME="${SF_GIT_USERNAME}"
SF_GIT_EMAIL="${SF_GIT_EMAIL}"
SF_GIT_TOKEN="${SF_GIT_TOKEN}"
SF_BITBUCKET_WORKSPACE="${SF_BITBUCKET_WORKSPACE:-}"
SF_GITHUB_ORG="${SF_GITHUB_ORG:-}"

# Docker Hub
SF_DOCKER_USERNAME="${SF_DOCKER_USERNAME}"
SF_DOCKER_TOKEN="${SF_DOCKER_TOKEN}"

# Domain & Networking
SF_DOMAIN="${SF_DOMAIN}"
SF_ELASTIC_IP="${SF_ELASTIC_IP}"
SF_ENABLE_TLS="${SF_ENABLE_TLS}"

# Tailscale
SF_TAILSCALE_ENABLED="${SF_TAILSCALE_ENABLED}"
SF_TAILSCALE_CLIENT_ID="${SF_TAILSCALE_CLIENT_ID}"
SF_TAILSCALE_CLIENT_SECRET="${SF_TAILSCALE_CLIENT_SECRET}"
SF_TAILSCALE_DNS_SUFFIX="${SF_TAILSCALE_DNS_SUFFIX}"

# AWS (cloud/hybrid only)
SF_AWS_REGION="${SF_AWS_REGION}"
SF_AWS_ACCESS_KEY="${SF_AWS_ACCESS_KEY}"
SF_AWS_SECRET_KEY="${SF_AWS_SECRET_KEY}"

# Admin
SF_ADMIN_USER="${SF_ADMIN_USER}"
SF_ADMIN_PASSWORD="${SF_ADMIN_PASSWORD}"
SF_ARGOCD_PASSWORD="${SF_ARGOCD_PASSWORD}"
CONF

  chmod 600 "$SF_CONFIG"
  log_info "Configuration saved (file permissions: 600)"
}
