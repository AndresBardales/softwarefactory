#!/usr/bin/env bash
# Step 07: Platform API — kaanbal-api (FastAPI backend)
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/05-deploy.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

KB_MODE="${KB_MODE:-local}"
export KB_MODE

echo "=== Deploying Platform API ==="
deploy_kaanbal_api
echo ""
echo "[OK] kaanbal-api deployed"
echo "=== Platform API complete ==="
