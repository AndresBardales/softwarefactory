#!/usr/bin/env bash
# ==============================================================================
# lib/03-k3s.sh — K3s installation and configuration
# ==============================================================================

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
    log_info "K3s binary found but not running — starting service..."
    sudo systemctl start k3s 2>/dev/null || true
    wait_for "K3s API server" "k3s kubectl get nodes" 60
    # Set up kubeconfig if missing
    if [ ! -f "$HOME/.kube/config" ]; then
      mkdir -p "$HOME/.kube"
      sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
      sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
      chmod 600 "$HOME/.kube/config"
    fi
    log_info "K3s started"
    kubectl get nodes
    return 0
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
    # - relaxed eviction: WSL2 disk reporting can be inaccurate
    sudo mkdir -p /etc/rancher/k3s
    cat <<WSLCONF | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
snapshotter: native
disable:
  - traefik
kubelet-arg:
  - "eviction-hard=nodefs.available<1%,imagefs.available<1%"
  - "image-gc-high-threshold=100"
  - "image-gc-low-threshold=80"
tls-san:
  - 127.0.0.1
  - localhost
WSLCONF
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

  # Set up kubeconfig
  mkdir -p "$HOME/.kube"
  sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"

  # If mode allows remote access, update kubeconfig server URL
  if [ "$SF_MODE" = "cloud" ] && [ -n "$SF_ELASTIC_IP" ]; then
    sed -i "s|server: https://127.0.0.1:6443|server: https://${SF_ELASTIC_IP}:6443|" "$HOME/.kube/config"
  fi

  # Alias kubectl
  if ! command -v kubectl &>/dev/null; then
    sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
  fi

  log_info "K3s installed and running"
  kubectl get nodes
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
