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

# Prompt choice from options
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
      return $((choice - 1))
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
