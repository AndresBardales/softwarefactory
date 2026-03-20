#!/usr/bin/env bash
# Step 04: Configuration — Save all installer credentials to config.env
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

echo "=== Saving Credentials ==="

CONFIG_DIR="$HOME/.software-factory"
CONFIG_FILE="$CONFIG_DIR/config.env"
mkdir -p "$CONFIG_DIR"

# Normalise Docker user: prefer KB_DOCKER_USER, fall back to KB_DOCKER_USERNAME
_DOCKER_USER="${KB_DOCKER_USER:-${KB_DOCKER_USERNAME:-}}"

# Normalise admin password: KB_ADMIN_PASSWORD is what the wizard sets.
# KB_ADMIN_PASS is the legacy variable; keep both in sync so step 11 uses
# the password the user actually chose instead of regenerating a new one.
_ADMIN_PW="${KB_ADMIN_PASSWORD:-${KB_ADMIN_PASS:-}}"
_ARGOCD_PW="${KB_ARGOCD_PASSWORD:-${_ADMIN_PW}}"
_VAULT_TOKEN="${KB_VAULT_TOKEN:-${KB_VAULT_ROOT_TOKEN:-}}"

# Create or update config file with all credentials passed via env vars.
# Values are appended so later runs overwrite via shell source order.
{
  echo ""
  echo "# -------------------------------------------------------"
  echo "# Platform Config — written by step 04 on $(date -u +%FT%TZ)"
  echo "# -------------------------------------------------------"
  echo ""
  echo "# Platform"
  [ -n "${KB_MODE:-}" ]           && echo "KB_MODE=${KB_MODE}"
  [ -n "${KB_DOMAIN:-}" ]         && echo "KB_DOMAIN=${KB_DOMAIN}"
  echo ""
  echo "# Git Provider"
  [ -n "${KB_GIT_PROVIDER:-}" ]   && echo "KB_GIT_PROVIDER=${KB_GIT_PROVIDER}"
  [ -n "${KB_GIT_USER:-}" ]       && echo "KB_GIT_USER=${KB_GIT_USER}"
  [ -n "${KB_GIT_EMAIL:-}" ]      && echo "KB_GIT_EMAIL=${KB_GIT_EMAIL}"
  [ -n "${KB_GIT_TOKEN:-}" ]      && echo "KB_GIT_TOKEN=${KB_GIT_TOKEN}"
  # Workspace: for GitHub this is the org/user; for Bitbucket it's the workspace slug
  _workspace="${KB_GIT_WORKSPACE:-${KB_GIT_USER:-}}"
  [ -n "$_workspace" ]            && echo "KB_GIT_WORKSPACE=${_workspace}"
  echo ""
  echo "# Docker Hub"
  [ -n "$_DOCKER_USER" ]          && echo "KB_DOCKER_USER=${_DOCKER_USER}"
  [ -n "$_DOCKER_USER" ]          && echo "KB_DOCKER_USERNAME=${_DOCKER_USER}"   # alias
  [ -n "${KB_DOCKER_TOKEN:-}" ]   && echo "KB_DOCKER_TOKEN=${KB_DOCKER_TOKEN}"
  echo ""
  echo "# Tailscale VPN"
  [ -n "${KB_TAILSCALE_ENABLED:-}" ]       && echo "KB_TAILSCALE_ENABLED=${KB_TAILSCALE_ENABLED}"
  [ -n "${KB_TAILSCALE_CLIENT_ID:-}" ]     && echo "KB_TAILSCALE_CLIENT_ID=${KB_TAILSCALE_CLIENT_ID}"
  [ -n "${KB_TAILSCALE_CLIENT_SECRET:-}" ] && echo "KB_TAILSCALE_CLIENT_SECRET=${KB_TAILSCALE_CLIENT_SECRET}"
  [ -n "${KB_TAILSCALE_DNS_SUFFIX:-}" ]    && echo "KB_TAILSCALE_DNS_SUFFIX=${KB_TAILSCALE_DNS_SUFFIX}"
  [ -n "${KB_TAILSCALE_ACL_TOKEN:-}" ]     && echo "KB_TAILSCALE_ACL_TOKEN=${KB_TAILSCALE_ACL_TOKEN}"
  echo ""
  echo "# Cloudflare"
  [ -n "${KB_CLOUDFLARE_TUNNEL_TOKEN:-}" ]  && echo "KB_CLOUDFLARE_TUNNEL_TOKEN=${KB_CLOUDFLARE_TUNNEL_TOKEN}"
  [ -n "${KB_CLOUDFLARE_TOKEN:-}" ]         && echo "KB_CLOUDFLARE_TOKEN=${KB_CLOUDFLARE_TOKEN}"
  [ -n "${KB_CLOUDFLARE_ACCOUNT_ID:-}" ]    && echo "KB_CLOUDFLARE_ACCOUNT_ID=${KB_CLOUDFLARE_ACCOUNT_ID}"
  echo ""
  echo "# AWS (optional)"
  [ -n "${KB_AWS_ACCESS_KEY:-}" ] && echo "KB_AWS_ACCESS_KEY=${KB_AWS_ACCESS_KEY}"
  [ -n "${KB_AWS_SECRET_KEY:-}" ] && echo "KB_AWS_SECRET_KEY=${KB_AWS_SECRET_KEY}"
  [ -n "${KB_AWS_REGION:-}" ]     && echo "KB_AWS_REGION=${KB_AWS_REGION}"
  echo ""
  echo "# Admin & ArgoCD"
  [ -n "${KB_ADMIN_USER:-}" ]     && echo "KB_ADMIN_USER=${KB_ADMIN_USER}"
  [ -n "$_ADMIN_PW" ]             && echo "KB_ADMIN_PASSWORD=${_ADMIN_PW}"
  [ -n "$_ADMIN_PW" ]             && echo "KB_ADMIN_PASS=${_ADMIN_PW}"       # step-11 compat
  [ -n "$_ARGOCD_PW" ]            && echo "KB_ARGOCD_PASSWORD=${_ARGOCD_PW}"
  [ -n "$_VAULT_TOKEN" ]          && echo "KB_VAULT_TOKEN=${_VAULT_TOKEN}"
  [ -n "$_VAULT_TOKEN" ]          && echo "KB_VAULT_ROOT_TOKEN=${_VAULT_TOKEN}" # backward compat
} >> "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

# ------ Summary -------
log_section "Configuration saved"
[ -n "${KB_GIT_PROVIDER:-}" ]  && log_info "  Git provider : ${KB_GIT_PROVIDER} (${KB_GIT_USER:-?})"
[ -n "$_DOCKER_USER" ]         && log_info "  Docker Hub   : ${_DOCKER_USER}"
[ -n "${KB_DOMAIN:-}" ]        && log_info "  Domain       : ${KB_DOMAIN}"
[ "${KB_TAILSCALE_ENABLED:-false}" = "true" ] && log_info "  Tailscale    : enabled (${KB_TAILSCALE_DNS_SUFFIX:-?})"
[ -n "${KB_CLOUDFLARE_TUNNEL_TOKEN:-}" ]      && log_info "  Cloudflare   : tunnel token set"
[ -n "${KB_ADMIN_USER:-}" ]    && log_info "  Admin user   : ${KB_ADMIN_USER}"
[ -n "$_ARGOCD_PW" ]           && log_info "  ArgoCD       : password configured"
[ -n "$_VAULT_TOKEN" ]         && log_info "  Vault        : token configured"

echo ""
echo "[OK] Credentials saved securely to ${CONFIG_FILE}"
echo "=== Credentials complete ==="
