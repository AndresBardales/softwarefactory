#!/usr/bin/env bash
# Step 03: K3s — Lightweight Kubernetes cluster
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/03-k3s.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

# Detect WSL2
SF_IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && SF_IS_WSL=true
export SF_IS_WSL

# Default to local mode if not set
SF_MODE="${SF_MODE:-local}"
export SF_MODE

echo "=== Installing Kubernetes (K3s) ==="
install_k3s
echo ""
echo "[OK] K3s cluster is running"
echo "=== K3s installation complete ==="
