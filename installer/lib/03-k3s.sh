#!/usr/bin/env bash
# ==============================================================================
# lib/03-k3s.sh — K3s installation and configuration
# ==============================================================================

# Helper: copy kubeconfig from K3s to ~/.kube/config
setup_kubeconfig() {
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    mkdir -p "$HOME/.kube"
    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
    log_info "Kubeconfig copied to ~/.kube/config"
  else
    log_warn "K3s kubeconfig not found at /etc/rancher/k3s/k3s.yaml"
  fi
}

install_k3s() {
  # Case 1: K3s installed and API is up — nothing to do
  if command -v k3s &>/dev/null && k3s kubectl get nodes &>/dev/null 2>&1; then
    log_info "K3s already installed and running"
    local version
    version=$(k3s --version 2>/dev/null | head -1)
    log_info "Version: $version"
    return 0
  fi

  # Case 2: K3s binary exists but service is stopped (e.g. previous test install)
  if command -v k3s &>/dev/null; then
    log_info "K3s binary found but not running — attempting restart..."

    # WSL2: update config before restart (may have new cgroup workarounds)
    if [ "$SF_IS_WSL" = true ] && [ -d /etc/rancher/k3s ]; then
      cat <<WSLCONF | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
snapshotter: native
protect-kernel-defaults: false
disable:
  - traefik
kubelet-arg:
  - "eviction-hard=nodefs.available<1%,imagefs.available<1%"
  - "image-gc-high-threshold=100"
  - "image-gc-low-threshold=80"
  - "cgroups-per-qos=false"
  - "enforce-node-allocatable="
tls-san:
  - 127.0.0.1
  - localhost
WSLCONF
      log_info "Updated K3s config for WSL2 compatibility"
    fi

    sudo systemctl start k3s 2>/dev/null || true

    # Wait for K3s API to become available, then copy fresh kubeconfig
    if ! wait_for "K3s API server" "k3s kubectl get nodes" 60 2>/dev/null; then
      log_warn "K3s failed to start — performing clean reinstall..."
      sudo systemctl stop k3s 2>/dev/null || true
      /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
      rm -f "$HOME/.kube/config"
    else
      # Copy kubeconfig AFTER K3s is ready (fresh certs, avoids stale x509 errors)
      setup_kubeconfig
      log_info "K3s started"
      kubectl get nodes 2>/dev/null || k3s kubectl get nodes
      return 0
    fi
  fi

  log_step "Installing K3s..."

  # Build K3s install args based on mode
  local k3s_args=""

  # TLS SANs — add domain and local IPs so kubectl works remotely
  local tls_sans="--tls-san 127.0.0.1 --tls-san localhost"
  if [ "$SF_MODE" = "cloud" ] || [ "$SF_MODE" = "hybrid" ]; then
    [ -n "$SF_DOMAIN" ] && tls_sans="$tls_sans --tls-san $SF_DOMAIN --tls-san *.$SF_DOMAIN"
    [ -n "$SF_ELASTIC_IP" ] && tls_sans="$tls_sans --tls-san $SF_ELASTIC_IP"
  fi

  # Disable default traefik (we use nginx-ingress)
  k3s_args="--disable traefik"

  # WSL2-specific configuration
  if [ "$SF_IS_WSL" = true ]; then
    log_info "WSL2 detected — applying K3s workarounds"

    # Pre-create K3s config for WSL2:
    # - native snapshotter: fixes InvalidDiskCapacity kubelet crash on WSL2
    # - protect-kernel-defaults false: skips strict sysctl validation
    # - relaxed eviction: WSL2 disk reporting can be inaccurate
    # - cgroups-per-qos false + enforce-node-allocatable empty: avoids
    #   "wrong number of fields" cgroup parsing error on WSL2 kernels
    sudo mkdir -p /etc/rancher/k3s
    cat <<WSLCONF | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
snapshotter: native
protect-kernel-defaults: false
disable:
  - traefik
kubelet-arg:
  - "eviction-hard=nodefs.available<1%,imagefs.available<1%"
  - "image-gc-high-threshold=100"
  - "image-gc-low-threshold=80"
  - "cgroups-per-qos=false"
  - "enforce-node-allocatable="
tls-san:
  - 127.0.0.1
  - localhost
WSLCONF

    # Pin K3s version on WSL2 for cgroup compatibility (v1.31+ handles 7-field /proc/cgroups)
    export INSTALL_K3S_VERSION="v1.31.4+k3s1"
    log_info "Pinning K3s to ${INSTALL_K3S_VERSION} for WSL2 compatibility"
  fi

  # Install K3s
  log_step "Downloading and installing K3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server $k3s_args $tls_sans" sh -

  # WSL2: disable autostart to prevent VM crash loop on boot
  if [ "$SF_IS_WSL" = true ]; then
    sudo systemctl disable k3s 2>/dev/null || true
    log_info "K3s autostart disabled (WSL2) — start manually with: sudo systemctl start k3s"
  fi

  # Wait for K3s to be ready
  wait_for "K3s API server" "k3s kubectl get nodes" 60

  # Set up kubeconfig (AFTER K3s is ready so certs are valid)
  setup_kubeconfig

  # If mode allows remote access, update kubeconfig server URL
  if [ "$SF_MODE" = "cloud" ] && [ -n "$SF_ELASTIC_IP" ]; then
    sed -i "s|server: https://127.0.0.1:6443|server: https://${SF_ELASTIC_IP}:6443|" "$HOME/.kube/config"
  fi

  # Alias kubectl
  if ! command -v kubectl &>/dev/null; then
    sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
  fi

  log_info "K3s installed and running"
  kubectl get nodes 2>/dev/null || k3s kubectl get nodes
}

# Install Helm if not present
install_helm() {
  if command -v helm &>/dev/null; then
    return 0
  fi

  log_step "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log_info "Helm installed"
}
