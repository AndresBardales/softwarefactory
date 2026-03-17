#!/usr/bin/env bash
# Step 06: Database — MongoDB 7 with persistent storage
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/05-deploy.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

SF_MODE="${SF_MODE:-local}"
export SF_MODE

echo "=== Installing Database (MongoDB) ==="
deploy_mongodb
echo ""
echo "[OK] MongoDB deployed"
echo "=== Database complete ==="
