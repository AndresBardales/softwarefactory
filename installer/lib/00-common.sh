#!/usr/bin/env bash
# ==============================================================================
# lib/common.sh — Shared utilities (logging, prompts, checks)
# ==============================================================================

# Colors (safe to re-source — idempotent)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# Ensure kubectl looks at the user's local config by default
export KUBECONFIG="$HOME/.kube/config"

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

# Wait for a command with timeout — shows a progress bar
wait_for() {
  local description="$1"
  local cmd="$2"
  local timeout="${3:-120}"
  local interval="${4:-5}"
  local elapsed=0
  local bar_width=30
  local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_i=0

  echo -ne "  ${BLUE}[⏳]${NC} ${description} "

  while [ $elapsed -lt $timeout ]; do
    if eval "$cmd" &>/dev/null; then
      # Fill the bar to 100% on success
      local full_bar
      full_bar=$(printf '█%.0s' $(seq 1 $bar_width))
      printf "\r  ${GREEN}[✓]${NC} ${description} [${GREEN}${full_bar}${NC}] ready\n"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))

    # Calculate progress bar
    local pct=$((elapsed * 100 / timeout))
    local filled=$((pct * bar_width / 100))
    local empty=$((bar_width - filled))
    local fill_str=""
    local empty_str=""
    [ "$filled" -gt 0 ] && fill_str=$(printf '█%.0s' $(seq 1 $filled))
    [ "$empty" -gt 0 ] && empty_str=$(printf '░%.0s' $(seq 1 $empty))
    local sc="${spinchars:$spin_i:1}"
    spin_i=$(( (spin_i + 1) % ${#spinchars} ))

    printf "\r  ${BLUE}[${sc}]${NC} ${description} [${CYAN}${fill_str}${NC}${empty_str}] %ds " "$elapsed"
  done

  printf "\r  ${RED}[✗]${NC} ${description} — timed out after ${timeout}s\n"
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
