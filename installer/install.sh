#!/usr/bin/env bash
# ==============================================================================
# Software Factory — Installer
# ==============================================================================
# Installs a complete personal PaaS on any Linux machine (bare metal, VM, WSL2).
#
# Usage:
#   bash install.sh                        # Zero-config: installs + opens web wizard
#   bash install.sh --config config.env    # Non-interactive: full install from config file
#
# The web wizard at localhost:30080/setup handles ALL configuration.
# ==============================================================================

# Auto-fix Windows line endings (CRLF → LF) if running from a Windows filesystem
if head -1 "$0" | grep -q $'\r'; then
  echo "Fixing Windows line endings..."
  find "$(dirname "$0")" -name "*.sh" -exec sed -i 's/\r//' {} +
  exec bash "$0" "$@"
fi

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_VERSION="1.0.0"
SF_HOME="${SF_HOME:-$HOME/.software-factory}"
SF_CONFIG="$SF_HOME/config.env"
SF_LOG="$SF_HOME/install.log"

# Default platform image registry (public images for bootstrap)
SF_DEFAULT_REGISTRY="${SF_DEFAULT_REGISTRY:-andresbardalescalva}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# Source library functions
for lib in "$INSTALLER_DIR/lib/"*.sh; do
  [ -f "$lib" ] && source "$lib"
done

# ==============================================================================
# MAIN
# ==============================================================================

# Parse CLI arguments
SF_CONFIG_FILE=""
SF_BOOTSTRAP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      SF_CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

main() {
  mkdir -p "$SF_HOME"
  exec > >(tee -a "$SF_LOG") 2>&1

  print_banner
  log_info "Software Factory Installer v${SF_VERSION}"
  log_info "Log file: $SF_LOG"
  echo ""

  # Phase 1: Pre-flight checks
  log_section "Pre-flight Checks"
  check_os
  check_resources
  check_dependencies
  echo ""

  # Phase 2: Configuration — pick the mode
  log_section "Configuration"

  if [ -n "$SF_CONFIG_FILE" ]; then
    # ── Mode A: Full config file ──────────────────────────────────────────
    if [ ! -f "$SF_CONFIG_FILE" ]; then
      log_error "Config file not found: $SF_CONFIG_FILE"
      exit 1
    fi
    log_info "Using config file: $SF_CONFIG_FILE"
    cp "$SF_CONFIG_FILE" "$SF_CONFIG"
    chmod 600 "$SF_CONFIG"

    source "$SF_CONFIG"
    # Fill auto-generated values
    if [ -z "${SF_ADMIN_PASSWORD:-}" ]; then
      SF_ADMIN_PASSWORD="$(generate_password 12)"
      echo "SF_ADMIN_PASSWORD=\"${SF_ADMIN_PASSWORD}\"" >> "$SF_CONFIG"
    fi
    if ! grep -q "SF_ARGOCD_PASSWORD" "$SF_CONFIG" 2>/dev/null; then
      SF_ARGOCD_PASSWORD="$(generate_password 16)"
      echo "SF_ARGOCD_PASSWORD=\"${SF_ARGOCD_PASSWORD}\"" >> "$SF_CONFIG"
    fi

  elif [ -f "$SF_CONFIG" ]; then
    # ── Mode B: Existing config from previous run ─────────────────────────
    log_info "Found existing config at $SF_CONFIG"
    if prompt_yn "Use existing configuration?"; then
      source "$SF_CONFIG"
    else
      SF_BOOTSTRAP=true
    fi

  else
    # ── Mode C: Zero-config bootstrap → web wizard ────────────────────────
    SF_BOOTSTRAP=true
  fi

  if [ "$SF_BOOTSTRAP" = true ]; then
    log_info "Bootstrap mode — installing platform core"
    log_info "All configuration will be done via the web wizard after install"

    SF_MODE="local"
    SF_DOMAIN="localhost"
    SF_DOCKER_USERNAME="${SF_DEFAULT_REGISTRY}"
    SF_ENABLE_TLS=false
    SF_ADMIN_USER=""
    SF_ADMIN_PASSWORD=""
    SF_ARGOCD_PASSWORD=""
    SF_GIT_USERNAME=""
    SF_GIT_TOKEN=""
    SF_GIT_PROVIDER="bitbucket"
    SF_BITBUCKET_WORKSPACE=""
    SF_DOCKER_TOKEN=""
    SF_TAILSCALE_ENABLED=false
    SF_TUNNEL_PROVIDER=""
    SF_CLOUDFLARE_TOKEN=""
    SF_CLOUDFLARE_ACCOUNT_ID=""

    # Minimal config file
    cat > "$SF_CONFIG" << CONF
SF_MODE="local"
SF_DOMAIN="localhost"
SF_DOCKER_USERNAME="${SF_DOCKER_USERNAME}"
SF_ENABLE_TLS=false
CONF
    chmod 600 "$SF_CONFIG"
  fi

  source "$SF_CONFIG"
  echo ""

  # Phase 3: Install K3s
  log_section "Installing K3s"
  install_k3s
  echo ""

  # Phase 4: Install core infrastructure
  log_section "Installing Core Infrastructure"
  install_core_infra
  echo ""

  # Phase 5: Deploy Software Factory
  log_section "Deploying Software Factory"
  deploy_software_factory
  echo ""

  # Phase 6: Cloudflare Tunnel (only if configured)
  if [ -n "${SF_TUNNEL_PROVIDER:-}" ]; then
    setup_cloudflare_tunnel
    echo ""
  fi

  # Phase 7: Post-installation setup (only if full config)
  if [ "$SF_BOOTSTRAP" != true ]; then
    log_section "Post-Installation"
    run_post_install
    echo ""

    log_section "Health Check"
    wait_for_healthy
    echo ""
  fi

  # Done
  if [ "$SF_BOOTSTRAP" = true ]; then
    print_wizard_ready
  else
    print_complete
  fi
}

# ==============================================================================
# BANNER
# ==============================================================================

print_banner() {
  echo -e "${CYAN}"
  cat << 'BANNER'

  ███████╗ ██████╗ ███████╗████████╗██╗    ██╗ █████╗ ██████╗ ███████╗
  ██╔════╝██╔═══██╗██╔════╝╚══██╔══╝██║    ██║██╔══██╗██╔══██╗██╔════╝
  ███████╗██║   ██║█████╗     ██║   ██║ █╗ ██║███████║██████╔╝█████╗
  ╚════██║██║   ██║██╔══╝     ██║   ██║███╗██║██╔══██║██╔══██╗██╔══╝
  ███████║╚██████╔╝██║        ██║   ╚███╔███╔╝██║  ██║██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝        ╚═╝    ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝

  ███████╗ █████╗  ██████╗████████╗ ██████╗ ██████╗ ██╗   ██╗
  ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝
  █████╗  ███████║██║        ██║   ██║   ██║██████╔╝ ╚████╔╝
  ██╔══╝  ██╔══██║██║        ██║   ██║   ██║██╔══██╗  ╚██╔╝
  ██║     ██║  ██║╚██████╗   ██║   ╚██████╔╝██║  ██║   ██║
  ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝

BANNER
  echo -e "${NC}"
  echo -e "  ${BOLD}Your Personal PaaS — v${SF_VERSION}${NC}"
  echo -e "  Deploy apps, databases, and automations from a UI."
  echo ""
}

print_wizard_ready() {
  local url="http://localhost:30080"

  echo -e "${GREEN}"
  cat << EOF

  ============================================================
   Platform is ready! Open the setup wizard to configure:
  ============================================================

   Setup Wizard:  ${url}/setup

   Open this URL in your browser to:
    1. Create your admin account
    2. Choose mode (local / hybrid)
    3. Connect Git, Docker Hub
    4. Configure public access (Cloudflare Tunnel)

  ============================================================
EOF
  echo -e "${NC}"

  # Try to open browser automatically
  if command -v xdg-open &>/dev/null; then
    xdg-open "${url}/setup" 2>/dev/null &
  elif command -v wslview &>/dev/null; then
    wslview "${url}/setup" 2>/dev/null &
  elif command -v sensible-browser &>/dev/null; then
    sensible-browser "${url}/setup" 2>/dev/null &
  fi
}

print_complete() {
  local CONSOLE_URL="http://localhost:30080"
  [ "${SF_MODE:-local}" = "cloud" ] || [ "${SF_MODE:-local}" = "hybrid" ] && CONSOLE_URL="https://nexus-console.${SF_DOMAIN}"

  echo -e "${GREEN}"
  cat << EOF

  ============================================================
   Installation complete!
  ============================================================

   Dashboard:  ${CONSOLE_URL}
   Username:   ${SF_ADMIN_USER:-admin}
   Password:   ${SF_ADMIN_PASSWORD:-<set in web wizard>}

   Quick commands:
     sf status      — Check cluster health
     sf apps        — List deployed apps
     sf logs <app>  — View app logs
     sf upgrade     — Upgrade Software Factory
     sf help        — All available commands

  ============================================================
EOF
  echo -e "${NC}"
}

# ==============================================================================
# Entry point
# ==============================================================================

main "$@"
