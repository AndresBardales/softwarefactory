#!/usr/bin/env bash
# ==============================================================================
# Software Factory — Installer
# ==============================================================================
# Launches a web-based installer dashboard where you can monitor each step,
# enter credentials interactively, retry failures, and launch the platform.
#
# Usage:
#   bash install.sh              # Launches installer dashboard at localhost:3000
#   bash install.sh --headless   # Legacy headless mode (runs all steps in terminal)
# ==============================================================================

# Auto-fix Windows line endings (CRLF → LF) if running from a Windows filesystem
if head -1 "$0" | grep -q $'\r'; then
  echo "Fixing Windows line endings..."
  find "$(dirname "$0")" -name "*.sh" -exec sed -i 's/\r//' {} +
  find "$(dirname "$0")" -name "*.py" -exec sed -i 's/\r//' {} +
  exec bash "$0" "$@"
fi

set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_VERSION="1.0.0"
SF_HOME="${SF_HOME:-$HOME/.software-factory}"
INSTALLER_PORT="${INSTALLER_PORT:-3000}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

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

# ==============================================================================
# HEADLESS MODE (legacy — runs everything in terminal)
# ==============================================================================

run_headless() {
  echo -e "${YELLOW}[headless]${NC} Running all steps in terminal mode..."
  echo ""
  for step_script in "$INSTALLER_DIR/steps/"*.sh; do
    [ -f "$step_script" ] || continue
    step_name="$(basename "$step_script" .sh)"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step: ${step_name}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if bash "$step_script"; then
      echo -e "${GREEN}[✓]${NC} ${step_name} completed"
    else
      echo -e "${RED}[✗]${NC} ${step_name} failed"
      echo ""
      echo "Fix the issue and re-run: bash install.sh --headless"
      exit 1
    fi
    echo ""
  done
  echo -e "${GREEN}${BOLD}Installation complete!${NC}"
  echo -e "  Dashboard: ${CYAN}http://localhost:30080${NC}"
}

# ==============================================================================
# DASHBOARD MODE (default — launches web UI)
# ==============================================================================

run_dashboard() {
  # 1. Check Python3
  if ! command -v python3 &>/dev/null; then
    echo -e "${YELLOW}[!]${NC} Python3 is required for the installer dashboard."
    echo "    Installing python3..."
    sudo apt-get update -qq && sudo apt-get install -y python3 || {
      echo -e "${RED}[✗]${NC} Failed to install Python3. Install manually: sudo apt install python3"
      exit 1
    }
  fi

  # 2. Generate setup token
  local SF_SETUP_TOKEN
  if command -v openssl &>/dev/null; then
    SF_SETUP_TOKEN="$(openssl rand -hex 12)"
  else
    SF_SETUP_TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 24)"
  fi

  # 3. Create config directory
  mkdir -p "$SF_HOME"

  # Minimal config (no hardcoded Docker user — the UI form provides it)
  cat > "$SF_HOME/config.env" << EOF
SF_MODE="local"
SF_DOMAIN="localhost"
SF_ENABLE_TLS=false
SF_SETUP_TOKEN="${SF_SETUP_TOKEN}"
EOF
  chmod 600 "$SF_HOME/config.env"

  # Installer env (for server.py)
  cat > "$SF_HOME/installer.env" << EOF
SF_SETUP_TOKEN=${SF_SETUP_TOKEN}
INSTALLER_DIR=${INSTALLER_DIR}
INSTALLER_PORT=${INSTALLER_PORT}
EOF

  # 4. Build the URL
  local PUBLIC_IP
  if command -v curl &>/dev/null; then
    PUBLIC_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "localhost")
  else
    PUBLIC_IP="localhost"
  fi
  local DASHBOARD_URL="http://${PUBLIC_IP}:${INSTALLER_PORT}?token=${SF_SETUP_TOKEN}"

  # 5. Print access info
  echo ""
  echo -e "  ${BLUE}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${BLUE}│${NC}                                                          ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}   ${BOLD}Installer Dashboard${NC}                                    ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}                                                          ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}   ${CYAN}http://${PUBLIC_IP}:${INSTALLER_PORT}${NC}"
  echo -e "  ${BLUE}│${NC}   Token: ${YELLOW}${SF_SETUP_TOKEN}${NC}"
  echo -e "  ${BLUE}│${NC}                                                          ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}   Open the URL in your browser and use the token.       ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}   Press ${BOLD}Ctrl+C${NC} to stop the installer.                    ${BLUE}│${NC}"
  echo -e "  ${BLUE}│${NC}                                                          ${BLUE}│${NC}"
  echo -e "  ${BLUE}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""

  # 6. Try to open browser
  if command -v wslview &>/dev/null; then
    wslview "$DASHBOARD_URL" 2>/dev/null &
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$DASHBOARD_URL" 2>/dev/null &
  elif command -v sensible-browser &>/dev/null; then
    sensible-browser "$DASHBOARD_URL" 2>/dev/null &
  fi

  # 7. Launch server
  export SF_SETUP_TOKEN
  export INSTALLER_PORT
  exec python3 "$INSTALLER_DIR/server.py"
}

# ==============================================================================
# Entry point
# ==============================================================================

main() {
  print_banner

  echo -e "${GREEN}[✓]${NC} Software Factory Installer v${SF_VERSION}"
  echo -e "${GREEN}[✓]${NC} Log file: $SF_HOME/install.log"
  echo ""

  # Parse args
  local mode="dashboard"
  while [ $# -gt 0 ]; do
    case "$1" in
      --headless) mode="headless"; shift ;;
      *) shift ;;
    esac
  done

  case "$mode" in
    headless)  run_headless ;;
    dashboard) run_dashboard ;;
  esac
}

main "$@"
