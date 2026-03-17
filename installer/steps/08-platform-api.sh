#!/usr/bin/env bash
# Step 07: Platform API — nexus-api (FastAPI backend)
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/05-deploy.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

SF_MODE="${SF_MODE:-local}"
export SF_MODE

echo "=== Deploying Platform API ==="
deploy_nexus_api
echo ""
echo "[OK] nexus-api deployed"
echo "=== Platform API complete ==="
