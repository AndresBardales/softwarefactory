#!/usr/bin/env bash
# ==============================================================================
# lib/01-preflight.sh — OS detection, resource checks, dependency validation
# ==============================================================================

# Minimum requirements
MIN_RAM_MB=4096
REC_RAM_MB=8192
MIN_DISK_GB=20
MIN_CPUS=2

check_os() {
  log_step "Detecting operating system..."

  SF_OS="unknown"
  SF_ARCH="$(uname -m)"
  SF_IS_WSL=false

  # Detect WSL
  if grep -qi microsoft /proc/version 2>/dev/null; then
    SF_IS_WSL=true
    SF_OS="wsl2"
    log_info "Platform: WSL2 (Windows Subsystem for Linux)"
  elif [ "$(uname -s)" = "Linux" ]; then
    SF_OS="linux"
    log_info "Platform: Linux native"
  elif [ "$(uname -s)" = "Darwin" ]; then
    SF_OS="macos"
    log_info "Platform: macOS"
  else
    log_error "Unsupported OS: $(uname -s)"
    log_error "Software Factory requires Linux, WSL2, or macOS"
    exit 1
  fi

  # Detect distro
  if [ -f /etc/os-release ]; then
    source /etc/os-release
    SF_DISTRO="${ID:-unknown}"
    SF_DISTRO_VERSION="${VERSION_ID:-unknown}"
    log_info "Distro: ${PRETTY_NAME:-$SF_DISTRO $SF_DISTRO_VERSION}"
  fi

  # Architecture check
  case "$SF_ARCH" in
    x86_64|amd64) SF_ARCH="amd64" ;;
    aarch64|arm64) SF_ARCH="arm64" ;;
    *)
      log_error "Unsupported architecture: $SF_ARCH"
      exit 1
      ;;
  esac
  log_info "Architecture: $SF_ARCH"

  # WSL-specific checks
  if [ "$SF_IS_WSL" = true ]; then
    # Verify systemd is available (required for K3s)
    if ! pidof systemd &>/dev/null; then
      log_warn "systemd not detected in WSL2"
      log_warn "K3s requires systemd. Enable it in /etc/wsl.conf:"
      echo ""
      echo "    [boot]"
      echo "    systemd=true"
      echo ""
      log_warn "Then restart WSL: wsl --shutdown"

      if ! prompt_yn "Continue anyway (may fail)?"; then
        exit 1
      fi
    else
      log_info "systemd: active"
    fi

    # Check for broken K3s installation (stale state, cgroup issues)
    if command -v k3s &>/dev/null; then
      if k3s kubectl get nodes &>/dev/null 2>&1; then
        log_info "K3s: running"
      else
        log_warn "K3s is installed but not responding"
        log_warn "The installer will attempt a clean reinstall automatically"
      fi
    fi
  fi
}

check_resources() {
  log_step "Checking system resources..."

  # RAM
  local total_ram_kb
  total_ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
  if [ -z "$total_ram_kb" ] && [ "$SF_OS" = "macos" ]; then
    total_ram_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
  fi
  local total_ram_mb=$((total_ram_kb / 1024))

  if [ "$total_ram_mb" -lt "$MIN_RAM_MB" ]; then
    log_error "Insufficient RAM: ${total_ram_mb} MB (minimum: ${MIN_RAM_MB} MB)"
    exit 1
  elif [ "$total_ram_mb" -lt "$REC_RAM_MB" ]; then
    log_warn "RAM: ${total_ram_mb} MB (recommended: ${REC_RAM_MB} MB)"
    log_warn "You may experience performance issues with many apps"
  else
    log_info "RAM: ${total_ram_mb} MB"
  fi

  # CPU cores
  local cpus
  cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  if [ "$cpus" -lt "$MIN_CPUS" ]; then
    log_error "Insufficient CPUs: ${cpus} (minimum: ${MIN_CPUS})"
    exit 1
  fi
  log_info "CPUs: ${cpus}"

  # Disk space
  local free_disk_gb
  free_disk_gb=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
  if [ -n "$free_disk_gb" ] && [ "$free_disk_gb" -lt "$MIN_DISK_GB" ]; then
    log_error "Insufficient disk: ${free_disk_gb} GB free (minimum: ${MIN_DISK_GB} GB)"
    exit 1
  fi
  [ -n "$free_disk_gb" ] && log_info "Disk: ${free_disk_gb} GB free"
}

check_dependencies() {
  log_step "Checking dependencies..."

  local missing=()

  # curl
  command -v curl &>/dev/null && log_info "curl: installed" || missing+=("curl")

  # git
  command -v git &>/dev/null && log_info "git: installed" || missing+=("git")

  # kubectl (will be installed with K3s if missing)
  if command -v kubectl &>/dev/null; then
    log_info "kubectl: installed ($(kubectl version --client --short 2>/dev/null || echo 'unknown'))"
  else
    log_info "kubectl: will be installed with K3s"
  fi

  # helm
  if command -v helm &>/dev/null; then
    log_info "helm: installed ($(helm version --short 2>/dev/null || echo 'unknown'))"
  else
    log_info "helm: will be installed automatically"
    SF_INSTALL_HELM=true
  fi

  # openssl (for password generation)
  command -v openssl &>/dev/null && log_info "openssl: installed" || missing+=("openssl")

  # iptables — required by K3s Flannel CNI for pod networking
  if command -v iptables &>/dev/null; then
    log_info "iptables: installed"
  else
    log_warn "iptables not found — required by K3s for pod networking"
    log_step "Installing iptables..."
    if sudo apt-get update -qq && sudo apt-get install -y iptables &>/dev/null; then
      log_info "iptables: installed"
    else
      missing+=("iptables")
    fi
  fi

  # libsodium-dev + pip3 (needed for PyNaCl in step 06 — GitHub Actions secrets)
  if ! python3 -c 'import nacl' &>/dev/null 2>&1; then
    log_step "Installing libsodium-dev + PyNaCl (GitHub secrets encryption)..."
    sudo apt-get install -y -qq libsodium-dev python3-pip &>/dev/null 2>&1 || true
    pip3 install pynacl --break-system-packages -q 2>/dev/null || \
      pip3 install pynacl -q 2>/dev/null || \
      log_warn "Could not install PyNaCl — GitHub Actions secrets setup may fail"
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install them with: sudo apt install ${missing[*]}"
    exit 1
  fi
}
