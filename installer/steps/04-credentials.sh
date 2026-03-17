#!/usr/bin/env bash
# Step 04: Configuration — Save all installer credentials to config.env
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

echo "=== Saving Credentials ==="

CONFIG_DIR="$HOME/.software-factory"
CONFIG_FILE="$CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"

# Normalise Docker user: prefer SF_DOCKER_USER, fall back to SF_DOCKER_USERNAME
_DOCKER_USER="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"

# Normalise admin password: SF_ADMIN_PASSWORD is what the wizard sets.
# SF_ADMIN_PASS is the legacy variable; keep both in sync so step 11 uses
# the password the user actually chose instead of regenerating a new one.
_ADMIN_PW="${SF_ADMIN_PASSWORD:-${SF_ADMIN_PASS:-}}"
_ARGOCD_PW="${SF_ARGOCD_PASSWORD:-${_ADMIN_PW}}"
_VAULT_TOKEN="${SF_VAULT_TOKEN:-${SF_VAULT_ROOT_TOKEN:-}}"

# Create or update config file with all credentials passed via env vars.
# Values are appended so later runs overwrite via shell source order.
{
  echo ""
  echo "# -------------------------------------------------------"
  echo "# Platform Config — written by step 04 on $(date -u +%FT%TZ)"
  echo "# -------------------------------------------------------"
  echo ""
  echo "# Platform"
  [ -n "${SF_MODE:-}" ]           && echo "SF_MODE=${SF_MODE}"
  [ -n "${SF_DOMAIN:-}" ]         && echo "SF_DOMAIN=${SF_DOMAIN}"
  echo ""
  echo "# Git Provider"
  [ -n "${SF_GIT_PROVIDER:-}" ]   && echo "SF_GIT_PROVIDER=${SF_GIT_PROVIDER}"
  [ -n "${SF_GIT_USER:-}" ]       && echo "SF_GIT_USER=${SF_GIT_USER}"
  [ -n "${SF_GIT_EMAIL:-}" ]      && echo "SF_GIT_EMAIL=${SF_GIT_EMAIL}"
  [ -n "${SF_GIT_TOKEN:-}" ]      && echo "SF_GIT_TOKEN=${SF_GIT_TOKEN}"
  # Workspace: for GitHub this is the org/user; for Bitbucket it's the workspace slug
  _workspace="${SF_GIT_WORKSPACE:-${SF_GIT_USER:-}}"
  [ -n "$_workspace" ]            && echo "SF_GIT_WORKSPACE=${_workspace}"
  echo ""
  echo "# Docker Hub"
  [ -n "$_DOCKER_USER" ]          && echo "SF_DOCKER_USER=${_DOCKER_USER}"
  [ -n "$_DOCKER_USER" ]          && echo "SF_DOCKER_USERNAME=${_DOCKER_USER}"   # alias
  [ -n "${SF_DOCKER_TOKEN:-}" ]   && echo "SF_DOCKER_TOKEN=${SF_DOCKER_TOKEN}"
  echo ""
  echo "# Tailscale VPN"
  [ -n "${SF_TAILSCALE_ENABLED:-}" ]       && echo "SF_TAILSCALE_ENABLED=${SF_TAILSCALE_ENABLED}"
  [ -n "${SF_TAILSCALE_CLIENT_ID:-}" ]     && echo "SF_TAILSCALE_CLIENT_ID=${SF_TAILSCALE_CLIENT_ID}"
  [ -n "${SF_TAILSCALE_CLIENT_SECRET:-}" ] && echo "SF_TAILSCALE_CLIENT_SECRET=${SF_TAILSCALE_CLIENT_SECRET}"
  [ -n "${SF_TAILSCALE_DNS_SUFFIX:-}" ]    && echo "SF_TAILSCALE_DNS_SUFFIX=${SF_TAILSCALE_DNS_SUFFIX}"
  [ -n "${SF_TAILSCALE_ACL_TOKEN:-}" ]     && echo "SF_TAILSCALE_ACL_TOKEN=${SF_TAILSCALE_ACL_TOKEN}"
  echo ""
  echo "# Cloudflare"
  [ -n "${SF_CLOUDFLARE_TUNNEL_TOKEN:-}" ]  && echo "SF_CLOUDFLARE_TUNNEL_TOKEN=${SF_CLOUDFLARE_TUNNEL_TOKEN}"
  [ -n "${SF_CLOUDFLARE_TOKEN:-}" ]         && echo "SF_CLOUDFLARE_TOKEN=${SF_CLOUDFLARE_TOKEN}"
  [ -n "${SF_CLOUDFLARE_ACCOUNT_ID:-}" ]    && echo "SF_CLOUDFLARE_ACCOUNT_ID=${SF_CLOUDFLARE_ACCOUNT_ID}"
  echo ""
  echo "# AWS (optional)"
  [ -n "${SF_AWS_ACCESS_KEY:-}" ] && echo "SF_AWS_ACCESS_KEY=${SF_AWS_ACCESS_KEY}"
  [ -n "${SF_AWS_SECRET_KEY:-}" ] && echo "SF_AWS_SECRET_KEY=${SF_AWS_SECRET_KEY}"
  [ -n "${SF_AWS_REGION:-}" ]     && echo "SF_AWS_REGION=${SF_AWS_REGION}"
  echo ""
  echo "# Admin & ArgoCD"
  [ -n "${SF_ADMIN_USER:-}" ]     && echo "SF_ADMIN_USER=${SF_ADMIN_USER}"
  [ -n "$_ADMIN_PW" ]             && echo "SF_ADMIN_PASSWORD=${_ADMIN_PW}"
  [ -n "$_ADMIN_PW" ]             && echo "SF_ADMIN_PASS=${_ADMIN_PW}"       # step-11 compat
  [ -n "$_ARGOCD_PW" ]            && echo "SF_ARGOCD_PASSWORD=${_ARGOCD_PW}"
  [ -n "$_VAULT_TOKEN" ]          && echo "SF_VAULT_TOKEN=${_VAULT_TOKEN}"
  [ -n "$_VAULT_TOKEN" ]          && echo "SF_VAULT_ROOT_TOKEN=${_VAULT_TOKEN}" # backward compat
} >> "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

# ------ Summary -------
log_section "Configuration saved"
[ -n "${SF_GIT_PROVIDER:-}" ]  && log_info "  Git provider : ${SF_GIT_PROVIDER} (${SF_GIT_USER:-?})"
[ -n "$_DOCKER_USER" ]         && log_info "  Docker Hub   : ${_DOCKER_USER}"
[ -n "${SF_DOMAIN:-}" ]        && log_info "  Domain       : ${SF_DOMAIN}"
[ "${SF_TAILSCALE_ENABLED:-false}" = "true" ] && log_info "  Tailscale    : enabled (${SF_TAILSCALE_DNS_SUFFIX:-?})"
[ -n "${SF_CLOUDFLARE_TUNNEL_TOKEN:-}" ]      && log_info "  Cloudflare   : tunnel token set"
[ -n "${SF_ADMIN_USER:-}" ]    && log_info "  Admin user   : ${SF_ADMIN_USER}"
[ -n "$_ARGOCD_PW" ]           && log_info "  ArgoCD       : password configured"
[ -n "$_VAULT_TOKEN" ]         && log_info "  Vault        : token configured"

echo ""
echo "[OK] Credentials saved securely to ${CONFIG_FILE}"
echo "=== Credentials complete ==="
