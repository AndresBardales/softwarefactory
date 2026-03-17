#!/usr/bin/env bash
# Step 02: Dependencies — curl, git, iptables, helm, openssl
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/01-preflight.sh"

echo "=== Dependencies ==="
check_dependencies

# Install Helm if marked for install during dependency check
if [ "${SF_INSTALL_HELM:-}" = "true" ]; then
  source "$INSTALLER_DIR/lib/03-k3s.sh"
  install_helm
fi

echo ""
echo "[OK] All dependencies available"
echo "=== Dependencies complete ==="
