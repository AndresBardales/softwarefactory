#!/usr/bin/env bash
# Root wrapper — runs the installer from any location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/installer/install.sh" "$@"
