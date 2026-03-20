#!/usr/bin/env bash
# ==============================================================================
# Kaanbal Engine — Package Script
# ==============================================================================
# Creates distributable tarballs from the sibling repos (kaanbal-api, kaanbal-console,
# infra-gitops) and places them in installer/templates/ so that a fresh install
# on a new VPS can push the code to the user's Git repos.
#
# Usage:
#   bash package.sh              # Package from current committed state
#   bash package.sh --dirty      # Package working tree (including uncommitted)
#
# Run from the softwarefactory/ directory, or it will auto-detect the workspace.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/installer/templates"
DIRTY_MODE=false

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dirty) DIRTY_MODE=true ;;
    --help|-h)
      echo "Usage: bash package.sh [--dirty]"
      echo "  --dirty  Include uncommitted changes (default: only committed)"
      exit 0
      ;;
  esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step()  { echo -e "${CYAN}[→]${NC} ${BOLD}$*${NC}"; }

# repos to package — these are sibling directories in the workspace
REPOS=("kaanbal-api" "kaanbal-console" "infra-gitops")

# Current owner values — these get replaced with __PLACEHOLDER__ tokens in tarballs
# so the installer can substitute the new user's values
CURRENT_GIT_WORKSPACE="${KB_CURRENT_GIT_WORKSPACE:-andresbardaleswork-cyber}"
CURRENT_DOCKER_USER="${KB_CURRENT_DOCKER_USER:-andresbardaleswork}"
CURRENT_DOMAIN="${KB_CURRENT_DOMAIN:-automation.com.mx}"

# Files/dirs to exclude from tarballs (they are dev-only or regenerated)
EXCLUDE_PATTERNS=(
  ".git"
  "node_modules"
  "__pycache__"
  ".env"
  ".env.*"
  "dist"
  "venv"
  ".venv"
  "*.pyc"
  ".DS_Store"
  "Thumbs.db"
)

# ==============================================================================
# Templatize: replace current owner values with __PLACEHOLDER__ tokens
# ==============================================================================
templatize_dir() {
  local dir="$1"
  log_info "  Templatizing placeholders..."

  # Order matters: replace the more specific (longer) pattern first
  # __WORKSPACE__ = git org/user (used in repo URLs)
  # __DOCKER_USER__ = DockerHub user (used in image refs)
  # __DOMAIN__ = public domain (used in ingress/hosts)
  find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
    -o -name '*.md' -o -name '*.js' -o -name '*.vue' -o -name '*.py' \
    -o -name '*.sh' -o -name '*.ps1' -o -name '*.env' -o -name '*.toml' \
    -o -name '*.html' -o -name '*.conf' -o -name '*.cfg' \) -exec sed -i \
    -e "s|${CURRENT_GIT_WORKSPACE}|__WORKSPACE__|g" \
    -e "s|${CURRENT_DOCKER_USER}|__DOCKER_USER__|g" \
    -e "s|${CURRENT_DOMAIN}|__DOMAIN__|g" \
    {} +
}

# ==============================================================================
# Package a single repo
# ==============================================================================
package_repo() {
  local repo_name="$1"
  local repo_path="$WORKSPACE/$repo_name"
  local output_file="$OUTPUT_DIR/${repo_name}.tar.gz"

  if [ ! -d "$repo_path" ]; then
    log_error "Repo not found: $repo_path"
    return 1
  fi

  log_step "Packaging $repo_name..."

  # Always use a temp dir: extract, templatize, then tar
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local tmp_repo="$tmp_dir/$repo_name"

  if [ "$DIRTY_MODE" = true ]; then
    # Copy working tree (excluding .git and heavy dirs)
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
      --exclude='venv' --exclude='.venv' --exclude='dist' --exclude='.env' \
      "$repo_path/" "$tmp_repo/"
  else
    # Use git archive for clean committed state
    cd "$repo_path"
    if ! git rev-parse HEAD &>/dev/null; then
      log_warn "$repo_name has no commits — using working tree"
      rsync -a --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
        "$repo_path/" "$tmp_repo/"
    else
      mkdir -p "$tmp_repo"
      git archive HEAD | tar -x -C "$tmp_repo"
    fi
    cd "$WORKSPACE"
  fi

  # Replace owner-specific values with __PLACEHOLDER__ tokens
  templatize_dir "$tmp_repo"

  # Create tarball from the templatized copy
  tar -czf "$output_file" -C "$tmp_dir" "$repo_name"
  log_info "$repo_name packaged → $(du -h "$output_file" | cut -f1)"

  # Cleanup
  rm -rf "$tmp_dir"
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${BOLD}Kaanbal Engine — Packager${NC}"
echo -e "Workspace: $WORKSPACE"
echo -e "Output:    $OUTPUT_DIR"
echo -e "Mode:      $([ "$DIRTY_MODE" = true ] && echo 'working tree (--dirty)' || echo 'git committed')"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Validate all repos exist before starting
for repo in "${REPOS[@]}"; do
  if [ ! -d "$WORKSPACE/$repo" ]; then
    log_error "Required repo missing: $WORKSPACE/$repo"
    log_error "All repos must be cloned as siblings in the workspace."
    exit 1
  fi
done

# Package each repo
errors=0
for repo in "${REPOS[@]}"; do
  if ! package_repo "$repo"; then
    errors=$((errors + 1))
  fi
done

echo ""

# Summary
if [ $errors -gt 0 ]; then
  log_error "$errors repo(s) failed to package"
  exit 1
fi

log_info "All repos packaged successfully!"
echo ""
echo "  Templates ready at:"
for repo in "${REPOS[@]}"; do
  local_file="$OUTPUT_DIR/${repo}.tar.gz"
  if [ -f "$local_file" ]; then
    echo "    📦 ${repo}.tar.gz ($(du -h "$local_file" | cut -f1))"
  fi
done
echo ""
echo "  Next: run the installer on a fresh VPS:"
echo "    scp -r softwarefactory/ user@server:~/"
echo "    ssh user@server 'bash ~/softwarefactory/install.sh'"
echo ""
