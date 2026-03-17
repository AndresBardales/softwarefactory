#!/usr/bin/env bash
# Step 05: Core Services — Ingress, cert-manager, namespaces
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/03-k3s.sh"
source "$INSTALLER_DIR/lib/04-core.sh"
source "$INSTALLER_DIR/lib/07-tunnel.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

SF_CONFIG="$HOME/.software-factory/config.env"
export SF_CONFIG

SF_MODE="${SF_MODE:-local}"
export SF_MODE

echo "=== Installing Core Services ==="
install_core_infra

# --- Cloudflare Tunnel (auto-create if hybrid mode) ---
setup_cloudflare_tunnel

echo ""
echo "[OK] Core services installed"
echo "=== Core services complete ==="
