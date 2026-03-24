#!/usr/bin/env bash
# SSH Key Validation Script for Team Executors
# Purpose: Validate all SSH keys, check permissions, verify fingerprints
# Usage: bash .agent/lab/ssh-keys/validate-keys.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="${SCRIPT_DIR}"
PRIVATE_KEYS_DIR="${SCRIPT_DIR}/../../../_private/keys"

echo "=== SSH Key Validation Report ==="
echo "Report Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TOTAL=0
VALID=0
INVALID=0
WARNINGS=0

# Function to validate a single key
validate_key() {
  local key_path="$1"
  local key_name=$(basename "$key_path")
  
  TOTAL=$((TOTAL + 1))
  
  if [ ! -f "$key_path" ]; then
    echo -e "${RED}✗ MISSING${NC}: $key_name"
    INVALID=$((INVALID + 1))
    return 1
  fi
  
  # Check permissions (should be 600 or 400 for security)
  local perms=$(stat -c "%a" "$key_path" 2>/dev/null || stat -f "%OLp" "$key_path" 2>/dev/null || echo "?")
  if [[ ! "$perms" =~ ^(400|600)$ ]]; then
    echo -e "${YELLOW}⚠ PERMISSION WARNING${NC}: $key_name has permissions $perms (should be 400 or 600)"
    WARNINGS=$((WARNINGS + 1))
  fi
  
  # Validate key format
  if ssh-keygen -lf "$key_path" >/dev/null 2>&1; then
    local fingerprint=$(ssh-keygen -lf "$key_path" 2>/dev/null | awk '{print $2}')
    local key_type=$(ssh-keygen -lf "$key_path" 2>/dev/null | awk '{print $NF}')
    echo -e "${GREEN}✓ VALID${NC}: $key_name"
    echo "  Type: $key_type"
    echo "  Fingerprint: $fingerprint"
    VALID=$((VALID + 1))
  else
    echo -e "${RED}✗ INVALID${NC}: $key_name (corrupt or wrong format)"
    INVALID=$((INVALID + 1))
    return 1
  fi
  
  # Check if public key exists
  local pub_key="${key_path}.pub"
  if [ -f "$pub_key" ]; then
    echo "  Public key: FOUND"
  else
    echo "  Public key: MISSING (optional)"
  fi
  
  echo ""
}

echo "Validating keys from: $PRIVATE_KEYS_DIR"
echo ""

# Validate each known key
for key in "contabo.pem" "customer1" "fabric.pem" "factory.pem"; do
  validate_key "$PRIVATE_KEYS_DIR/$key" || true
done

# Summary
echo ""
echo "=== Summary ==="
echo "Total keys checked: $TOTAL"
echo -e "Valid keys: ${GREEN}$VALID${NC}"
echo -e "Invalid keys: ${RED}$INVALID${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

# Exit code: 0 if all valid, 1 if any invalid
if [ $INVALID -eq 0 ]; then
  echo -e "${GREEN}All keys are valid ✓${NC}"
  exit 0
else
  echo -e "${RED}Some keys have issues. Please investigate.${NC}"
  exit 1
fi
