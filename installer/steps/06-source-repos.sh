#!/usr/bin/env bash
# ==============================================================================
# Step 06: Source Repositories
# Creates Git repos (GitHub or Bitbucket), pushes source code, configures
# CI/CD pipelines, triggers first build, and waits for Docker images.
# ==============================================================================
set -euo pipefail

INSTALLER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$INSTALLER_DIR/lib/00-common.sh"

# Load config
[ -f "$HOME/.software-factory/config.env" ] && source "$HOME/.software-factory/config.env"

echo "=== Setting Up Source Repositories ==="

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
GIT_PROVIDER="${KB_GIT_PROVIDER:-github}"
GIT_USER="${KB_GIT_USER:-}"
GIT_EMAIL="${KB_GIT_EMAIL:-installer@softwarefactory.dev}"
GIT_TOKEN="${KB_GIT_TOKEN:-}"
GIT_WORKSPACE="${KB_GIT_WORKSPACE:-$GIT_USER}"
DOCKER_USER="${KB_DOCKER_USER:-${KB_DOCKER_USERNAME:-}}"
DOCKER_TOKEN="${KB_DOCKER_TOKEN:-}"
DOMAIN="${KB_DOMAIN:-kaanbal.local}"
TAILSCALE_DNS="${KB_TAILSCALE_DNS_SUFFIX:-}"

if [ -z "$GIT_USER" ] || [ -z "$GIT_TOKEN" ]; then
  log_error "Git credentials not configured. Ensure KB_GIT_USER and KB_GIT_TOKEN are set."
  exit 1
fi
if [ -z "$DOCKER_USER" ] || [ -z "$DOCKER_TOKEN" ]; then
  log_error "Docker Hub credentials not configured. Ensure KB_DOCKER_USER and KB_DOCKER_TOKEN are set."
  exit 1
fi

log_info "Git provider: $GIT_PROVIDER"
log_info "Git user: $GIT_USER"
log_info "Git workspace: $GIT_WORKSPACE"
log_info "Docker Hub user: $DOCKER_USER"

# ===========================================================================
#                         GITHUB FUNCTIONS
# ===========================================================================

gh_api() {
  local method="$1" url="$2"
  shift 2
  curl -sf --max-time 30 -X "$method" \
    -H "Authorization: Bearer ${GIT_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url" "$@" 2>/dev/null
}

gh_create_repo() {
  local repo_slug="$1"
  local description="${2:-}"

  log_step "Checking repo: ${GIT_WORKSPACE}/${repo_slug} (GitHub)"

  # Check if repo exists
  if gh_api GET "https://api.github.com/repos/${GIT_WORKSPACE}/${repo_slug}" > /dev/null 2>&1; then
    log_info "Repo '${repo_slug}' already exists on GitHub"
    return 0
  fi

  log_info "Creating repo '${repo_slug}' on GitHub..."
  local payload
  payload=$(cat <<EOJSON
{
  "name": "${repo_slug}",
  "description": "${description}",
  "private": true,
  "auto_init": false,
  "has_issues": true,
  "has_projects": false,
  "has_wiki": false
}
EOJSON
  )

  if gh_api POST "https://api.github.com/user/repos" -d "$payload" > /dev/null 2>&1; then
    log_info "Repo '${repo_slug}' created successfully on GitHub"
  else
    log_error "Failed to create repo '${repo_slug}' on GitHub"
    return 1
  fi
}

gh_push_code() {
  local repo_slug="$1"
  local archive="$2"

  if [ ! -f "$archive" ]; then
    log_error "Template archive not found: $archive"
    return 1
  fi

  log_step "Pushing code to ${GIT_WORKSPACE}/${repo_slug} (GitHub)..."

  local ENCODED_TOKEN
  ENCODED_TOKEN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GIT_TOKEN}', safe=''))")
  local AUTH_URL="https://${GIT_USER}:${ENCODED_TOKEN}@github.com/${GIT_WORKSPACE}/${repo_slug}.git"

  # Check if remote already has commits
  if git ls-remote --heads "$AUTH_URL" main 2>/dev/null | grep -q main; then
    log_info "Repo '${repo_slug}' already has code on main — skipping push"
    return 0
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  tar -xzf "$archive" -C "$tmp_dir"

  # Replace placeholders
  log_info "Substituting placeholders in ${repo_slug}..."
  find "$tmp_dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
    -o -name '*.md' -o -name '*.js' -o -name '*.vue' -o -name '*.py' \
    -o -name '*.sh' -o -name '*.ps1' -o -name '*.env' -o -name '*.toml' \) -exec sed -i \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__WORKSPACE__|${GIT_WORKSPACE}|g" \
    -e "s|__DOCKER_USER__|${DOCKER_USER}|g" \
    -e "s|__GIT_PROVIDER__|${GIT_PROVIDER}|g" \
    -e "s|__GIT_USER__|${GIT_USER}|g" \
    -e "s|__TAILSCALE_DNS__|${TAILSCALE_DNS}|g" \
    {} +

  cd "$tmp_dir"
  git init -b main
  git config user.email "$GIT_EMAIL"
  git config user.name "SF Installer"

  git remote add origin "$AUTH_URL"
  git add -A
  git commit -m "feat: initial commit from Kaanbal Engine installer"
  git push -u origin main 2>&1 || {
    log_warn "Push failed — repo may already have content"
    cd /
    rm -rf "$tmp_dir"
    return 0
  }

  log_info "Code pushed to ${GIT_WORKSPACE}/${repo_slug}"
  cd /
  rm -rf "$tmp_dir"
}

gh_set_secret() {
  local repo_slug="$1" secret_name="$2" secret_value="$3"

  # Get repo public key for secret encryption
  local key_response
  key_response=$(gh_api GET "https://api.github.com/repos/${GIT_WORKSPACE}/${repo_slug}/actions/secrets/public-key" 2>/dev/null)
  if [ -z "$key_response" ]; then
    log_warn "Could not get public key for ${repo_slug} — secret ${secret_name} not set"
    return 1
  fi

  local key_id key_value
  key_id=$(echo "$key_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['key_id'])" 2>/dev/null)
  key_value=$(echo "$key_response" | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])" 2>/dev/null)

  if [ -z "$key_id" ] || [ -z "$key_value" ]; then
    log_warn "Could not parse public key for ${repo_slug}"
    return 1
  fi

  # Encrypt secret using PyNaCl
  local encrypted_value
  encrypted_value=$(python3 << PYEOF
import base64, sys
try:
    from nacl import encoding, public
    pub_key = public.PublicKey(base64.b64decode("${key_value}"))
    sealed = public.SealedBox(pub_key)
    encrypted = sealed.encrypt("${secret_value}".encode("utf-8"))
    print(base64.b64encode(encrypted).decode("utf-8"))
except Exception as e:
    print("", file=sys.stderr)
    sys.exit(1)
PYEOF
  )

  if [ -z "$encrypted_value" ]; then
    log_warn "Could not encrypt secret ${secret_name}"
    return 1
  fi

  local payload="{\"encrypted_value\":\"${encrypted_value}\",\"key_id\":\"${key_id}\"}"

  if gh_api PUT "https://api.github.com/repos/${GIT_WORKSPACE}/${repo_slug}/actions/secrets/${secret_name}" \
    -d "$payload" > /dev/null 2>&1; then
    log_info "Secret '${secret_name}' set on ${repo_slug}"
  else
    log_warn "Failed to set secret '${secret_name}' on ${repo_slug}"
    return 1
  fi
}

gh_configure_secrets() {
  local repo_slug="$1"
  log_step "Configuring GitHub Actions secrets for '${repo_slug}'..."

  # Install PyNaCl for secret encryption (required by GitHub API)
  if ! python3 -c 'import nacl' &>/dev/null 2>&1; then
    pip3 install pynacl -q 2>/dev/null || \
      log_warn "Could not install PyNaCl — GitHub Actions secrets may not be configured"
  fi

  gh_set_secret "$repo_slug" "DOCKERHUB_USERNAME" "$DOCKER_USER"
  gh_set_secret "$repo_slug" "DOCKERHUB_TOKEN"    "$DOCKER_TOKEN"
  gh_set_secret "$repo_slug" "INFRA_GIT_USER"     "$GIT_USER"
  gh_set_secret "$repo_slug" "INFRA_GIT_TOKEN"    "$GIT_TOKEN"

  log_info "GitHub Actions secrets configured for '${repo_slug}'"
}

gh_configure_infra_secrets() {
  # Extra secrets needed specifically by the infra-gitops repo (ArgoCD, Vault, Cloudflare)
  local repo_slug="infra-gitops"
  log_step "Configuring GitHub Actions secrets for '${repo_slug}'..."

  if ! python3 -c 'import nacl' &>/dev/null 2>&1; then
    pip3 install pynacl -q 2>/dev/null || true
  fi

  # Base CI credentials (same as other repos — needed if infra has workflows)
  gh_set_secret "$repo_slug" "DOCKERHUB_USERNAME"    "$DOCKER_USER"
  gh_set_secret "$repo_slug" "DOCKERHUB_TOKEN"       "$DOCKER_TOKEN"
  gh_set_secret "$repo_slug" "INFRA_GIT_USER"        "$GIT_USER"
  gh_set_secret "$repo_slug" "INFRA_GIT_TOKEN"       "$GIT_TOKEN"

  # Infrastructure-specific secrets
  [ -n "${KB_CLOUDFLARE_TOKEN:-}" ]      && gh_set_secret "$repo_slug" "CLOUDFLARE_API_TOKEN"    "${KB_CLOUDFLARE_TOKEN}"
  [ -n "${KB_CLOUDFLARE_ACCOUNT_ID:-}" ] && gh_set_secret "$repo_slug" "CLOUDFLARE_ACCOUNT_ID"   "${KB_CLOUDFLARE_ACCOUNT_ID}"
  [ -n "${KB_TAILSCALE_CLIENT_ID:-}" ]   && gh_set_secret "$repo_slug" "TAILSCALE_CLIENT_ID"     "${KB_TAILSCALE_CLIENT_ID}"
  [ -n "${KB_TAILSCALE_CLIENT_SECRET:-}" ] && gh_set_secret "$repo_slug" "TAILSCALE_CLIENT_SECRET" "${KB_TAILSCALE_CLIENT_SECRET}"
  [ -n "${KB_ARGOCD_PASSWORD:-}" ]       && gh_set_secret "$repo_slug" "ARGOCD_PASSWORD"         "${KB_ARGOCD_PASSWORD}"
  [ -n "${KB_DOMAIN:-}" ]                && gh_set_secret "$repo_slug" "DOMAIN"                  "${KB_DOMAIN}"

  log_info "Infrastructure secrets configured for '${repo_slug}'"
}

# ===========================================================================
#                         BITBUCKET FUNCTIONS
# ===========================================================================

BB_AUTH=""
if [ "$GIT_PROVIDER" = "bitbucket" ]; then
  BB_AUTH="$(printf '%s:%s' "$GIT_EMAIL" "$GIT_TOKEN" | base64 -w 0)"
fi

bb_api() {
  local method="$1" url="$2"
  shift 2
  curl -sf --max-time 30 -X "$method" \
    -H "Authorization: Basic ${BB_AUTH}" \
    -H "Content-Type: application/json" \
    "$url" "$@" 2>/dev/null
}

bb_create_repo() {
  local repo_slug="$1"
  local description="${2:-}"

  log_step "Checking repo: ${GIT_WORKSPACE}/${repo_slug} (Bitbucket)"

  if bb_api GET "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}" > /dev/null 2>&1; then
    log_info "Repo '${repo_slug}' already exists"
    return 0
  fi

  log_info "Creating repo '${repo_slug}'..."
  local payload
  payload=$(cat <<EOJSON
{
  "scm": "git",
  "is_private": true,
  "name": "${repo_slug}",
  "description": "${description}",
  "has_issues": false,
  "has_wiki": false
}
EOJSON
  )

  if bb_api POST "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}" -d "$payload" > /dev/null 2>&1; then
    log_info "Repo '${repo_slug}' created successfully"
  else
    log_error "Failed to create repo '${repo_slug}'"
    return 1
  fi
}

bb_push_code() {
  local repo_slug="$1"
  local archive="$2"

  if [ ! -f "$archive" ]; then
    log_error "Template archive not found: $archive"
    return 1
  fi

  log_step "Pushing code to ${GIT_WORKSPACE}/${repo_slug} (Bitbucket)..."

  local ENCODED_TOKEN
  ENCODED_TOKEN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GIT_TOKEN}', safe=''))")
  local AUTH_URL="https://${GIT_USER}:${ENCODED_TOKEN}@bitbucket.org/${GIT_WORKSPACE}/${repo_slug}.git"

  if git ls-remote --heads "$AUTH_URL" main 2>/dev/null | grep -q main; then
    log_info "Repo '${repo_slug}' already has code on main — skipping push"
    return 0
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  tar -xzf "$archive" -C "$tmp_dir"

  log_info "Substituting placeholders in ${repo_slug}..."
  find "$tmp_dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
    -o -name '*.md' -o -name '*.js' -o -name '*.vue' -o -name '*.py' \
    -o -name '*.sh' -o -name '*.ps1' -o -name '*.env' -o -name '*.toml' \) -exec sed -i \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__WORKSPACE__|${GIT_WORKSPACE}|g" \
    -e "s|__DOCKER_USER__|${DOCKER_USER}|g" \
    -e "s|__GIT_PROVIDER__|${GIT_PROVIDER}|g" \
    -e "s|__GIT_USER__|${GIT_USER}|g" \
    -e "s|__TAILSCALE_DNS__|${TAILSCALE_DNS}|g" \
    {} +

  cd "$tmp_dir"
  git init -b main
  git config user.email "$GIT_EMAIL"
  git config user.name "SF Installer"
  git remote add origin "$AUTH_URL"
  git add -A
  git commit -m "feat: initial commit from Kaanbal Engine installer"
  git push -u origin main 2>&1 || {
    log_warn "Push failed — repo may already have content"
    cd /
    rm -rf "$tmp_dir"
    return 0
  }

  log_info "Code pushed to ${GIT_WORKSPACE}/${repo_slug}"
  cd /
  rm -rf "$tmp_dir"
}

bb_enable_pipelines() {
  local repo_slug="$1"
  bb_api PUT "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}/pipelines_config" \
    -d '{"enabled": true}' > /dev/null 2>&1 || true
}

bb_set_pipeline_var() {
  local repo_slug="$1" key="$2" value="$3" secured="${4:-true}"
  local existing
  existing=$(bb_api GET "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}/pipelines_config/variables/?pagelen=100" 2>/dev/null || echo '{}')
  local existing_uuid
  existing_uuid=$(echo "$existing" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  for v in data.get('values', []):
    if v.get('key') == '${key}':
      print(v['uuid'].strip('{}'))
      break
except: pass
" 2>/dev/null || true)

  local payload="{\"key\":\"${key}\",\"value\":\"${value}\",\"secured\":${secured}}"

  if [ -n "$existing_uuid" ]; then
    bb_api PUT "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}/pipelines_config/variables/%7B${existing_uuid}%7D" \
      -d "$payload" > /dev/null 2>&1 || true
  else
    bb_api POST "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}/pipelines_config/variables/" \
      -d "$payload" > /dev/null 2>&1 || true
  fi
}

bb_configure_pipeline_vars() {
  local repo_slug="$1"
  log_step "Configuring pipeline variables for '${repo_slug}'..."
  bb_set_pipeline_var "$repo_slug" "DOCKERHUB_USERNAME" "$DOCKER_USER" "false"
  bb_set_pipeline_var "$repo_slug" "DOCKERHUB_PASSWORD" "$DOCKER_TOKEN" "true"
  bb_set_pipeline_var "$repo_slug" "INFRA_GIT_USER" "$GIT_USER" "false"
  bb_set_pipeline_var "$repo_slug" "INFRA_GIT_TOKEN" "$GIT_TOKEN" "true"
  bb_set_pipeline_var "$repo_slug" "BITBUCKET_WORKSPACE" "$GIT_WORKSPACE" "false"
  bb_set_pipeline_var "$repo_slug" "DOMAIN" "$DOMAIN" "false"
  log_info "Pipeline variables configured for '${repo_slug}'"
}

bb_trigger_pipeline() {
  local repo_slug="$1"
  local branch="${2:-main}"
  log_step "Triggering pipeline for '${repo_slug}' on branch '${branch}'..."
  local payload='{"target":{"ref_type":"branch","type":"pipeline_ref_target","ref_name":"'"${branch}"'"}}'
  bb_api POST "https://api.bitbucket.org/2.0/repositories/${GIT_WORKSPACE}/${repo_slug}/pipelines/" \
    -d "$payload" > /dev/null 2>&1 || {
    log_warn "Could not trigger pipeline for '${repo_slug}'"
    return 1
  }
  log_info "Pipeline triggered for ${repo_slug}"
}

# ===========================================================================
#                         COMMON FUNCTIONS
# ===========================================================================

wait_for_docker_image() {
  local docker_user="$1" repo_name="$2"
  local max_wait=600
  local interval=15
  local elapsed=0

  log_step "Waiting for Docker image: ${docker_user}/${repo_name}..."

  while [ $elapsed -lt $max_wait ]; do
    local url="https://hub.docker.com/v2/repositories/${docker_user}/${repo_name}/tags/?page_size=1"
    local count
    count=$(curl -sf --max-time 10 "$url" 2>/dev/null | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  print(data.get('count', 0))
except: print(0)
" 2>/dev/null || echo "0")

    if [ "$count" -gt 0 ] 2>/dev/null; then
      log_info "Image found: ${docker_user}/${repo_name} (${count} tags)"
      return 0
    fi

    log_info "Waiting for image... (${elapsed}s / ${max_wait}s)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  log_warn "Timeout waiting for ${docker_user}/${repo_name} — CI/CD pipeline may still be running"
  return 1
}


# ===========================================================================
#                           MAIN EXECUTION
# ===========================================================================

TEMPLATE_DIR="$INSTALLER_DIR/templates"

# --- Dispatch by provider ---
if [ "$GIT_PROVIDER" = "github" ]; then

  # ===== GITHUB FLOW =====
  log_step "Phase 1: Creating GitHub repositories..."
  gh_create_repo "kaanbal-api" "Backend API (FastAPI + Python)"
  gh_create_repo "kaanbal-console" "Frontend UI (Vue 3 + Tailwind)"
  gh_create_repo "infra-gitops" "Infrastructure manifests & GitOps"

  log_step "Phase 2: Pushing source code..."
  for repo in kaanbal-api kaanbal-console infra-gitops; do
    if [ -f "$TEMPLATE_DIR/${repo}.tar.gz" ]; then
      gh_push_code "$repo" "$TEMPLATE_DIR/${repo}.tar.gz"
    else
      log_warn "Template not found: $TEMPLATE_DIR/${repo}.tar.gz — skipping push"
    fi
  done

  log_step "Phase 3: Configuring GitHub Actions secrets..."
  gh_configure_secrets "kaanbal-api" || log_warn "Some secrets not set for kaanbal-api — check GitHub Actions settings"
  gh_configure_secrets "kaanbal-console" || log_warn "Some secrets not set for kaanbal-console — check GitHub Actions settings"
  gh_configure_infra_secrets || log_warn "Some infra secrets not set — check GitHub Actions settings"

  log_step "Phase 4: CI/CD will trigger automatically on push..."
  log_info "GitHub Actions workflows are included in the source code"
  log_info "They will trigger automatically when code is pushed"

  log_step "Phase 5: Waiting for Docker images to be built..."

  # Only wait if code was actually pushed (repos have commits on main)
  ENCODED_TOKEN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${GIT_TOKEN}', safe=''))")

  api_ok=false
  console_ok=false

  if git ls-remote --heads "https://${GIT_USER}:${ENCODED_TOKEN}@github.com/${GIT_WORKSPACE}/kaanbal-api.git" main 2>/dev/null | grep -q main; then
    log_info "Code found in kaanbal-api — waiting for Docker image..."
    wait_for_docker_image "$DOCKER_USER" "kaanbal-api" && api_ok=true
  else
    log_warn "No code in kaanbal-api — skipping image wait (templates may be missing)"
  fi

  if git ls-remote --heads "https://${GIT_USER}:${ENCODED_TOKEN}@github.com/${GIT_WORKSPACE}/kaanbal-console.git" main 2>/dev/null | grep -q main; then
    log_info "Code found in kaanbal-console — waiting for Docker image..."
    wait_for_docker_image "$DOCKER_USER" "kaanbal-console" && console_ok=true
  else
    log_warn "No code in kaanbal-console — skipping image wait (templates may be missing)"
  fi

elif [ "$GIT_PROVIDER" = "bitbucket" ]; then

  # ===== BITBUCKET FLOW =====
  log_step "Phase 1: Creating Bitbucket repositories..."
  bb_create_repo "kaanbal-api" "Backend API (FastAPI + Python)"
  bb_create_repo "kaanbal-console" "Frontend UI (Vue 3 + Tailwind)"
  bb_create_repo "infra-gitops" "Infrastructure manifests & GitOps"

  log_step "Phase 2: Pushing source code..."
  for repo in kaanbal-api kaanbal-console infra-gitops; do
    if [ -f "$TEMPLATE_DIR/${repo}.tar.gz" ]; then
      bb_push_code "$repo" "$TEMPLATE_DIR/${repo}.tar.gz"
    else
      log_warn "Template not found: $TEMPLATE_DIR/${repo}.tar.gz — skipping push"
    fi
  done

  log_step "Phase 3: Configuring Bitbucket Pipelines..."
  bb_enable_pipelines "kaanbal-api"
  bb_enable_pipelines "kaanbal-console"
  bb_configure_pipeline_vars "kaanbal-api"
  bb_configure_pipeline_vars "kaanbal-console"

  log_step "Phase 4: Triggering first pipeline builds..."
  bb_trigger_pipeline "kaanbal-api" "main" || true
  bb_trigger_pipeline "kaanbal-console" "main" || true

  log_step "Phase 5: Waiting for Docker images to be built..."
  log_info "Bitbucket Pipelines are building Docker images. This takes 2-5 minutes..."

  api_ok=false
  console_ok=false
  wait_for_docker_image "$DOCKER_USER" "kaanbal-api" && api_ok=true
  wait_for_docker_image "$DOCKER_USER" "kaanbal-console" && console_ok=true

else
  log_error "Unsupported git provider: $GIT_PROVIDER (expected 'github' or 'bitbucket')"
  exit 1
fi

# --- Result summary ---
if [ "$api_ok" = true ] && [ "$console_ok" = true ]; then
  log_info "Both Docker images are available!"
elif [ "$api_ok" = true ] || [ "$console_ok" = true ]; then
  log_warn "Only one image is ready — the other may need more time"
  log_warn "Deploy steps will proceed but some pods may need retries"
else
  log_warn "Neither image is ready yet — CI/CD may still be running"
  log_warn "Deploy steps will proceed with imagePullPolicy: Always"
  log_warn "Pods will pull images once CI/CD completes"
fi

echo ""
echo "[OK] Source repositories configured"
echo "=== Source Repos complete ==="
