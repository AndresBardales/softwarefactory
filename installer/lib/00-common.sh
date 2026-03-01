#!/usr/bin/env bash
# ==============================================================================
# lib/common.sh — Shared utilities (logging, prompts, checks)
# ==============================================================================

# Logging
log_info()    { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "${RED}[✗]${NC} $*"; }
log_step()    { echo -e "${BLUE}[→]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}\n"; }

# Prompt yes/no (default yes)
prompt_yn() {
  local prompt="$1"
  local response
  read -r -p "$(echo -e "${YELLOW}[?]${NC} ${prompt} [Y/n]: ")" response
  [[ "$response" =~ ^[Nn] ]] && return 1 || return 0
}

# Prompt for value with default
prompt_value() {
  local prompt="$1"
  local default="$2"
  local var_name="$3"
  local is_secret="${4:-false}"
  local response

  if [ "$is_secret" = "true" ]; then
    read -r -s -p "$(echo -e "${YELLOW}[?]${NC} ${prompt} [hidden]: ")" response
    echo ""
  elif [ -n "$default" ]; then
    read -r -p "$(echo -e "${YELLOW}[?]${NC} ${prompt} [${default}]: ")" response
  else
    read -r -p "$(echo -e "${YELLOW}[?]${NC} ${prompt}: ")" response
  fi

  response="${response:-$default}"
  eval "$var_name='$response'"
}

# Prompt choice from options (sets PROMPT_RESULT to 0-based index)
PROMPT_RESULT=0
prompt_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  local choice

  echo -e "${YELLOW}[?]${NC} ${prompt}"
  for i in "${!options[@]}"; do
    echo -e "    ${BOLD}[$((i+1))]${NC} ${options[$i]}"
  done

  while true; do
    read -r -p "    > " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
      PROMPT_RESULT=$((choice - 1))
      return 0
    fi
    echo -e "    ${RED}Invalid choice. Enter 1-${#options[@]}${NC}"
  done
}

# Spinner for long operations
spin() {
  local pid=$1
  local msg="${2:-Working...}"
  local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${BLUE}[%s]${NC} %s" "${spinchars:$i:1}" "$msg"
    i=$(( (i+1) % ${#spinchars} ))
    sleep 0.1
  done
  printf "\r"
}

# Wait for a command with timeout
wait_for() {
  local description="$1"
  local cmd="$2"
  local timeout="${3:-120}"
  local interval="${4:-5}"
  local elapsed=0

  log_step "Waiting for ${description} (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    if eval "$cmd" &>/dev/null; then
      log_info "${description} — ready"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    printf "\r  ${BLUE}[⏳]${NC} %ds / %ds" "$elapsed" "$timeout"
  done

  printf "\n"
  log_error "${description} — timed out after ${timeout}s"
  return 1
}

# Generate random password
generate_password() {
  local length="${1:-16}"
  openssl rand -base64 "$length" | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Run a command with validation — logs failure but does NOT exit on error.
# Returns the command's exit code so the caller can decide what to do.
# Usage: safe_run "description" command args...
safe_run() {
  local desc="$1"
  shift
  log_step "$desc"
  if "$@" 2>&1; then
    return 0
  else
    local rc=$?
    log_warn "$desc — failed (exit code $rc)"
    return $rc
  fi
}

# Validate that kubectl can talk to the cluster
validate_kubectl() {
  if kubectl cluster-info &>/dev/null; then
    return 0
  elif k3s kubectl cluster-info &>/dev/null; then
    # kubectl has stale config but k3s kubectl works — fix kubeconfig
    log_warn "kubectl has stale config — refreshing kubeconfig..."
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
      mkdir -p "$HOME/.kube"
      sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
      sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
      chmod 600 "$HOME/.kube/config"
    fi
    # Create symlink if kubectl doesn't exist
    if ! command -v kubectl &>/dev/null; then
      sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
    fi
    return 0
  else
    log_error "Cannot reach Kubernetes API — is K3s running?"
    log_error "Try: sudo systemctl start k3s"
    return 1
  fi
}

# Retry a command N times with a delay between attempts
# Usage: retry 3 5 "description" command args...
retry() {
  local max_attempts="$1"
  local delay="$2"
  local desc="$3"
  shift 3
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if "$@" 2>/dev/null; then
      return 0
    fi
    if [ $attempt -lt $max_attempts ]; then
      log_warn "$desc — attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  log_error "$desc — all $max_attempts attempts failed"
  return 1
}
