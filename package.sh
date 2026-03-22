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
REPOS=("kaanbal-api" "kaanbal-console" "infra-gitops" "kaanbal-templates")

# Source directory overrides (when local dir name differs from repo name)
declare -A REPO_SOURCE_DIR
# All repos now use their canonical names at workspace root

# Current owner values — these get replaced with __PLACEHOLDER__ tokens in tarballs
# so the installer can substitute the new user's values
CURRENT_GIT_WORKSPACE="${KB_CURRENT_GIT_WORKSPACE:-andresbardaleswork-cyber}"
CURRENT_DOCKER_USER="${KB_CURRENT_DOCKER_USER:-andresbardaleswork}"
CURRENT_DOMAIN="${KB_CURRENT_DOMAIN:-automation.com.mx}"

# Sensitive values auto-detected from infra-gitops (replaced with __PLACEHOLDER__ tokens)
CURRENT_MONGO_PASSWORD=""
CURRENT_SECRET_KEY=""

_detect_sensitive_values() {
  local ig_path="$WORKSPACE/infra-gitops"
  if [ -d "$ig_path/apps/datastore/base" ]; then
    CURRENT_MONGO_PASSWORD=$(python3 -c "
import re
with open('${ig_path}/apps/datastore/base/secret.yaml') as f:
    m = re.search(r'root-password:\s*\"(.+?)\"', f.read())
    print(m.group(1) if m else '')
" 2>/dev/null || true)
    CURRENT_SECRET_KEY=$(python3 -c "
import re
with open('${ig_path}/apps/kaanbal-api/base/deployment.yaml') as f:
    m = re.search(r'name: SECRET_KEY\n\s+value:\s*\"(.+?)\"', f.read())
    print(m.group(1) if m else '')
" 2>/dev/null || true)
    if [ -n "$CURRENT_MONGO_PASSWORD" ]; then log_info "Auto-detected MongoDB password for templatization"; fi
    if [ -n "$CURRENT_SECRET_KEY" ]; then log_info "Auto-detected SECRET_KEY for templatization"; fi
  fi
}

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

  # Replace sensitive values (auto-detected from infra-gitops)
  # __MONGO_PASSWORD__ = MongoDB root password (generated per install)
  # __SECRET_KEY__ = kaanbal-api JWT/session key (generated per install)
  if [ -n "${CURRENT_MONGO_PASSWORD:-}" ]; then
    find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec sed -i \
      -e "s|${CURRENT_MONGO_PASSWORD}|__MONGO_PASSWORD__|g" \
      {} +
  fi
  if [ -n "${CURRENT_SECRET_KEY:-}" ]; then
    find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec sed -i \
      -e "s|${CURRENT_SECRET_KEY}|__SECRET_KEY__|g" \
      {} +
  fi
}

# ==============================================================================
# Package a single repo
# ==============================================================================
package_repo() {
  local repo_name="$1"
  local source_dir="${REPO_SOURCE_DIR[$repo_name]:-$repo_name}"
  local repo_path="$WORKSPACE/$source_dir"
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
      --exclude='.terraform' --exclude='terraform.tfstate*' \
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

# Auto-detect sensitive values for templatization
_detect_sensitive_values

# Validate all repos exist before starting
for repo in "${REPOS[@]}"; do
  source_dir="${REPO_SOURCE_DIR[$repo]:-$repo}"
  if [ ! -d "$WORKSPACE/$source_dir" ]; then
    log_error "Required repo missing: $WORKSPACE/$source_dir (for $repo)"
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

# Scaffold completeness guard: kaanbal-templates must contain required Dockerfiles
log_step "Validating kaanbal-templates scaffold completeness..."
TEMPLATES_TARBALL="$OUTPUT_DIR/kaanbal-templates.tar.gz"
if [ -f "$TEMPLATES_TARBALL" ]; then
  MISSING_SCAFFOLDS=()
  tarball_listing=$(tar -tzf "$TEMPLATES_TARBALL" 2>/dev/null || true)
  for required_file in \
    "kaanbal-templates/templates/frontend/vue3-spa/Dockerfile" \
    "kaanbal-templates/templates/backend/fastapi-api/Dockerfile"; do
    if ! grep -qF "$required_file" <<< "$tarball_listing"; then
      MISSING_SCAFFOLDS+=("$required_file")
    fi
  done
  if [ ${#MISSING_SCAFFOLDS[@]} -gt 0 ]; then
    for missing in "${MISSING_SCAFFOLDS[@]}"; do
      log_warn "Scaffold file absent from tarball: $missing"
    done
    if [ ${#MISSING_SCAFFOLDS[@]} -ge 2 ]; then
      log_error "Both code template scaffolds are missing — packaging blocked."
      log_error "Commit scaffold content to kaanbal-templates before running package.sh"
      errors=$((errors + 1))
    else
      log_warn "One code template scaffold is missing — package will have partial template support"
    fi
  else
    log_info "Scaffold completeness check passed"
  fi
else
  log_warn "kaanbal-templates.tar.gz not found — skipping scaffold check"
fi

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
