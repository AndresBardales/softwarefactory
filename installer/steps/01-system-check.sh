#!/usr/bin/env bash
# Step 01: System Check — OS, RAM, CPU, disk
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"
source "$INSTALLER_DIR/lib/01-preflight.sh"

echo "=== System Check ==="
check_os
check_resources
echo ""
echo "[OK] System check passed"
echo "=== System check complete ==="
