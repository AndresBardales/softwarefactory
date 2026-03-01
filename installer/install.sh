#!/usr/bin/env bash
# ==============================================================================
# Software Factory — Installer
# ==============================================================================
# Installs a complete personal PaaS on any Linux machine (bare metal, VM, WSL2).
#
# Usage:
#   curl -sSL https://get.softwarefactory.dev | bash
#   OR
#   git clone ... && cd installer && bash install.sh
#   OR (non-interactive with config file):
#   bash install.sh --config config.env
#
# Modes:
#   local  — Everything runs on this machine. Apps on localhost.
#   cloud  — Provision cloud infrastructure (AWS). Apps on public domain.
#   hybrid — Local master + cloud gateway for public access.
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

  # Phase 2: Mode selection + configuration wizard
  log_section "Configuration"

  if [ -n "$SF_CONFIG_FILE" ]; then
    # Non-interactive mode: use provided config file
    if [ ! -f "$SF_CONFIG_FILE" ]; then
      log_error "Config file not found: $SF_CONFIG_FILE"
      exit 1
    fi
    log_info "Using config file: $SF_CONFIG_FILE"
    cp "$SF_CONFIG_FILE" "$SF_CONFIG"
    chmod 600 "$SF_CONFIG"

    # Source and fill in auto-generated values if missing
    source "$SF_CONFIG"
    if [ -z "$SF_ADMIN_PASSWORD" ]; then
      SF_ADMIN_PASSWORD="$(generate_password 12)"
      echo "SF_ADMIN_PASSWORD=\"${SF_ADMIN_PASSWORD}\"" >> "$SF_CONFIG"
    fi
    if ! grep -q "SF_ARGOCD_PASSWORD" "$SF_CONFIG"; then
      SF_ARGOCD_PASSWORD="$(generate_password 16)"
      echo "SF_ARGOCD_PASSWORD=\"${SF_ARGOCD_PASSWORD}\"" >> "$SF_CONFIG"
    fi
  elif [ -f "$SF_CONFIG" ]; then
    log_info "Found existing config at $SF_CONFIG"
    prompt_yn "Use existing configuration?" && source "$SF_CONFIG" || run_wizard
  else
    run_wizard
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

  # Phase 6: Post-installation setup
  log_section "Post-Installation"
  run_post_install
  echo ""

  # Phase 7: Health check
  log_section "Health Check"
  wait_for_healthy
  echo ""

  # Done
  print_complete
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

print_complete() {
  local CONSOLE_URL="http://localhost:30080"
  [ "$SF_MODE" = "cloud" ] || [ "$SF_MODE" = "hybrid" ] && CONSOLE_URL="https://nexus-console.${SF_DOMAIN}"

  echo -e "${GREEN}"
  cat << EOF

  ============================================================
   Installation complete!
  ============================================================

   Dashboard:  ${CONSOLE_URL}
   Username:   admin
   Password:   ${SF_ADMIN_PASSWORD}

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
