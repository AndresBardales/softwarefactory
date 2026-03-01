#!/usr/bin/env bash
# ==============================================================================
# lib/04-core.sh — Install core infrastructure (ArgoCD, Vault, Ingress, etc.)
# ==============================================================================

install_core_infra() {
  install_helm

  # Derive defaults
  SF_ENABLE_TLS="${SF_ENABLE_TLS:-false}"
  [ "$SF_MODE" != "local" ] && SF_ENABLE_TLS="true"

  # Create namespaces (minimal set for local, full set otherwise)
  log_step "Creating namespaces..."
  if [ "$SF_MODE" = "local" ]; then
    for ns in prod dev staging; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    done
  else
    for ns in prod dev staging apps monitoring vault argocd ingress-nginx cert-manager tailscale; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    done
  fi
  log_info "Namespaces created"

  # --------------------------------------------------
  # 1. Nginx Ingress Controller (cloud/hybrid + local with domain)
  # --------------------------------------------------
  # Local mode with pure localhost: skip Ingress (NodePort is enough)
  # Local mode with nip.io domain: install Ingress for domain routing
  local install_ingress=true
  [ "$SF_MODE" = "local" ] && [ "${SF_DOMAIN:-localhost}" = "localhost" ] && install_ingress=false

  if [ "$install_ingress" = true ]; then
    kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
    log_step "Installing Nginx Ingress Controller..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null
    helm repo update ingress-nginx 2>/dev/null
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx \
      --set controller.hostPort.enabled=true \
      --set controller.service.type=NodePort \
      --set controller.kind=DaemonSet \
      --wait --timeout 120s
    log_info "Nginx Ingress Controller installed"
  else
    log_info "Nginx Ingress: skipped (local mode — using NodePort :30080/:30081)"
  fi

  # --------------------------------------------------
  # 2. cert-manager (TLS — cloud/hybrid only)
  # --------------------------------------------------
  if [ "$SF_ENABLE_TLS" = "true" ]; then
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    log_step "Installing cert-manager..."
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null
    helm repo update jetstack 2>/dev/null
    helm upgrade --install cert-manager jetstack/cert-manager \
      -n cert-manager \
      --set installCRDs=true \
      --wait --timeout 120s

    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${SF_GIT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
    log_info "cert-manager installed with Let's Encrypt issuer"
  else
    log_info "TLS disabled (local mode) — skipping cert-manager"
  fi

  # --------------------------------------------------
  # 3. ArgoCD (cloud/hybrid only — too heavy for local WSL2)
  # --------------------------------------------------
  if [ "$SF_MODE" != "local" ]; then
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    log_step "Installing ArgoCD..."
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null
    helm repo update argo 2>/dev/null

    local argocd_bcrypt=""
    if command -v htpasswd &>/dev/null; then
      argocd_bcrypt=$(htpasswd -nbBC 10 "" "$SF_ARGOCD_PASSWORD" 2>/dev/null | tr -d ':\n' | sed 's/$2y/$2a/' || echo "")
    elif command -v python3 &>/dev/null; then
      argocd_bcrypt=$(python3 -c "
import bcrypt
hashed = bcrypt.hashpw(b'${SF_ARGOCD_PASSWORD}', bcrypt.gensalt(rounds=10))
print(hashed.decode())
" 2>/dev/null || echo "")
      if [ -z "$argocd_bcrypt" ]; then
        pip3 install bcrypt -q 2>/dev/null
        argocd_bcrypt=$(python3 -c "
import bcrypt
hashed = bcrypt.hashpw(b'${SF_ARGOCD_PASSWORD}', bcrypt.gensalt(rounds=10))
print(hashed.decode())
" 2>/dev/null || echo "")
      fi
    fi

    helm upgrade --install argocd argo/argo-cd \
      -n argocd \
      --set configs.params."server\.insecure"=true \
      --set server.extraArgs[0]="--insecure" \
      --set controller.resources.requests.memory=256Mi \
      --set controller.resources.limits.memory=512Mi \
      --set server.resources.requests.memory=64Mi \
      --set server.resources.limits.memory=256Mi \
      --wait --timeout 180s

    if [ -n "$argocd_bcrypt" ]; then
      kubectl -n argocd patch secret argocd-secret -p \
        "{\"stringData\":{\"admin.password\":\"${argocd_bcrypt}\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}" \
        2>/dev/null || true
    fi
    log_info "ArgoCD installed"

    # Git credentials for ArgoCD
    log_step "Configuring Git credentials for ArgoCD..."
    local git_auth_url=""
    case "$SF_GIT_PROVIDER" in
      bitbucket) git_auth_url="https://${SF_GIT_EMAIL}:${SF_GIT_TOKEN}@bitbucket.org" ;;
      github)    git_auth_url="https://${SF_GIT_USERNAME}:${SF_GIT_TOKEN}@github.com" ;;
      gitlab)    git_auth_url="https://oauth2:${SF_GIT_TOKEN}@gitlab.com" ;;
    esac
    kubectl create secret generic git-credentials \
      -n argocd \
      --from-literal=url="$git_auth_url" \
      --from-literal=type=git \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl label secret git-credentials -n argocd \
      argocd.argoproj.io/secret-type=repository \
      --overwrite 2>/dev/null || true
    log_info "Git credentials configured for ArgoCD"
  else
    log_info "ArgoCD: skipped (local mode — add via 'sf install --mode cloud' for GitOps)"
  fi

  # --------------------------------------------------
  # 4. Vault (cloud/hybrid only)
  # --------------------------------------------------
  if [ "$SF_MODE" != "local" ]; then
    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
    log_step "Installing Vault..."
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null
    helm repo update hashicorp 2>/dev/null
    helm upgrade --install vault hashicorp/vault \
      -n vault \
      --set server.dev.enabled=false \
      --set server.standalone.enabled=true \
      --set server.dataStorage.size=1Gi \
      --set server.resources.requests.memory=64Mi \
      --set server.resources.limits.memory=256Mi \
      --set server.resources.requests.cpu=50m \
      --timeout 120s
    log_info "Vault installed (standalone — needs init on first run)"
  else
    log_info "Vault: skipped (local mode — secrets stored in Kubernetes)"
  fi

  # --------------------------------------------------
  # 5. Tailscale Operator (if enabled)
  # --------------------------------------------------
  if [ "$SF_TAILSCALE_ENABLED" = "true" ]; then
    kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
    log_step "Installing Tailscale Operator..."
    helm repo add tailscale https://pkgs.tailscale.com/helmcharts 2>/dev/null
    helm repo update tailscale 2>/dev/null
    kubectl create secret generic operator-oauth \
      -n tailscale \
      --from-literal=client_id="$SF_TAILSCALE_CLIENT_ID" \
      --from-literal=client_secret="$SF_TAILSCALE_CLIENT_SECRET" \
      --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install tailscale-operator tailscale/tailscale-operator \
      -n tailscale \
      --set oauth.clientId="$SF_TAILSCALE_CLIENT_ID" \
      --set oauth.clientSecret="$SF_TAILSCALE_CLIENT_SECRET" \
      --wait --timeout 120s
    log_info "Tailscale Operator installed"
  fi

  # --------------------------------------------------
  # 6. Docker Hub credentials (only if provided)
  # --------------------------------------------------
  if [ -n "${SF_DOCKER_TOKEN:-}" ] && [ -n "${SF_DOCKER_USERNAME:-}" ]; then
    log_step "Configuring Docker Hub credentials..."
    for ns in prod dev staging; do
      kubectl create secret docker-registry dockerhub-credentials \
        -n "$ns" \
        --docker-server=https://index.docker.io/v1/ \
        --docker-username="$SF_DOCKER_USERNAME" \
        --docker-password="$SF_DOCKER_TOKEN" \
        --docker-email="${SF_GIT_EMAIL:-noreply@softwarefactory.dev}" \
        --dry-run=client -o yaml | kubectl apply -f -
    done
    log_info "Docker Hub credentials configured"
  else
    log_info "Docker Hub credentials: skipped (configure in web wizard)"
  fi
}
