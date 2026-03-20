#!/usr/bin/env bash
# Step 08: Platform Console — kaanbal-console (Vue 3 frontend)
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/05-deploy.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

KB_MODE="${KB_MODE:-local}"
export KB_MODE

echo "=== Deploying Platform Console ==="
deploy_kaanbal_console
echo ""
echo "[OK] kaanbal-console deployed"
echo "=== Platform Console complete ==="
