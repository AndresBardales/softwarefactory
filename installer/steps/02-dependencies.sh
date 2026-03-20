#!/usr/bin/env bash
# Step 02: Dependencies — curl, git, iptables, helm, openssl
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/01-preflight.sh"

echo "=== Dependencies ==="
check_dependencies

# Install Helm if marked for install during dependency check
if [ "${KB_INSTALL_HELM:-}" = "true" ]; then
  source "$INSTALLER_DIR/lib/03-k3s.sh"
  install_helm
fi

# Install Python packages needed by installer (PyNaCl for GitHub secrets encryption)
log_step "Installing Python packages..."
if ! python3 -c 'import nacl' &>/dev/null 2>&1; then
  apt-get install -y -qq python3-pip libffi-dev python3-dev 2>/dev/null || true
  pip3 install pynacl --break-system-packages -q 2>/dev/null || \
    pip3 install pynacl -q 2>/dev/null || \
    log_warn "Could not install PyNaCl — GitHub Actions secrets may need manual setup"
fi
python3 -c 'import nacl' &>/dev/null 2>&1 && log_info "PyNaCl: installed" || log_warn "PyNaCl: not available"

echo ""
echo "[OK] All dependencies available"
echo "=== Dependencies complete ==="
