#!/usr/bin/env bash
# ==============================================================================
# lib/04-core.sh — Install core infrastructure (ArgoCD, Vault, Ingress, etc.)
# ==============================================================================

install_core_infra() {
  install_helm

  # Validate cluster access before proceeding
  if ! validate_kubectl; then
    log_error "Cannot reach Kubernetes cluster — aborting core infra install"
    return 1
  fi

  # Derive defaults
  SF_ENABLE_TLS="${SF_ENABLE_TLS:-false}"
  [ "$SF_MODE" != "local" ] && SF_ENABLE_TLS="true"

  # Create namespaces (minimal set for local, full set otherwise)
  log_step "Creating namespaces..."
  if [ "$SF_MODE" = "local" ]; then
    for ns in prod dev staging; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || \
        log_warn "Failed to create namespace $ns — continuing"
    done
  else
    for ns in prod dev staging apps monitoring vault argocd ingress-nginx cert-manager tailscale; do
      kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || \
        log_warn "Failed to create namespace $ns — continuing"
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
    kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    log_step "Installing Nginx Ingress Controller..."
    if helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null && \
       helm repo update ingress-nginx 2>/dev/null; then
      if helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        -n ingress-nginx \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=NodePort \
        --set controller.kind=DaemonSet \
        --wait --timeout 120s 2>&1; then
        log_info "Nginx Ingress Controller installed"
      else
        log_warn "Nginx Ingress Controller install failed — services may need NodePort access"
      fi
    else
      log_warn "Cannot add ingress-nginx helm repo — check internet connectivity"
    fi
  else
    log_info "Nginx Ingress: skipped (local mode — using NodePort :30080/:30081)"
  fi

  # --------------------------------------------------
  # 2. cert-manager (TLS — cloud/hybrid only)
  # --------------------------------------------------
  if [ "$SF_ENABLE_TLS" = "true" ]; then
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    log_step "Installing cert-manager..."
    if helm repo add jetstack https://charts.jetstack.io 2>/dev/null && \
       helm repo update jetstack 2>/dev/null; then
      if helm upgrade --install cert-manager jetstack/cert-manager \
        -n cert-manager \
        --set installCRDs=true \
        --wait --timeout 120s 2>&1; then

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
        log_warn "cert-manager install failed — TLS certificates will not be auto-provisioned"
      fi
    else
      log_warn "Cannot add jetstack helm repo — skipping cert-manager"
    fi
  else
    log_info "TLS disabled (local mode) — skipping cert-manager"
  fi

  # --------------------------------------------------
  # 3. ArgoCD (cloud/hybrid only — too heavy for local WSL2)
  # --------------------------------------------------
  if [ "$SF_MODE" != "local" ]; then
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    log_step "Installing ArgoCD..."
    if ! helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || \
       ! helm repo update argo 2>/dev/null; then
      log_warn "Cannot add ArgoCD helm repo — skipping ArgoCD"
    else
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

      if helm upgrade --install argocd argo/argo-cd \
        -n argocd \
        --set configs.params."server\.insecure"=true \
        --set server.extraArgs[0]="--insecure" \
        --set controller.resources.requests.memory=256Mi \
        --set controller.resources.limits.memory=512Mi \
        --set server.resources.requests.memory=64Mi \
        --set server.resources.limits.memory=256Mi \
        --wait --timeout 180s 2>&1; then

        if [ -n "$argocd_bcrypt" ]; then
          kubectl -n argocd patch secret argocd-secret -p \
            "{\"stringData\":{\"admin.password\":\"${argocd_bcrypt}\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}" \
            2>/dev/null || true
        fi
        log_info "ArgoCD installed"

        # Git credentials for ArgoCD (repo-creds type for URL-prefix matching)
        if [ -n "${SF_GIT_TOKEN:-}" ]; then
          log_step "Configuring Git credentials for ArgoCD..."
          local git_url_prefix="" git_username="" git_password=""
          case "$SF_GIT_PROVIDER" in
            bitbucket) git_url_prefix="https://bitbucket.org/${SF_GIT_WORKSPACE}"; git_username="${SF_GIT_USER}"; git_password="${SF_GIT_TOKEN}" ;;
            github)    git_url_prefix="https://github.com/${SF_GIT_WORKSPACE}"; git_username="${SF_GIT_USER}"; git_password="${SF_GIT_TOKEN}" ;;
            gitlab)    git_url_prefix="https://gitlab.com/${SF_GIT_WORKSPACE}"; git_username="oauth2"; git_password="${SF_GIT_TOKEN}" ;;
          esac
          if [ -n "$git_url_prefix" ]; then
            # Delete old-format secret if it exists (type=repository with embedded creds)
            kubectl delete secret -n argocd git-credentials --ignore-not-found 2>/dev/null || true
            kubectl create secret generic github-repo-creds \
              -n argocd \
              --from-literal=url="$git_url_prefix" \
              --from-literal=username="$git_username" \
              --from-literal=password="$git_password" \
              --from-literal=type=git \
              --dry-run=client -o yaml | kubectl apply -f -
            kubectl label secret github-repo-creds -n argocd \
              argocd.argoproj.io/secret-type=repo-creds \
              --overwrite 2>/dev/null || true
            log_info "Git credentials configured for ArgoCD (repo-creds prefix match)"
          fi

          # Bootstrap Application — watches infra-gitops and auto-syncs argocd/ folder.
          # Step 06 pushes the infra-gitops repo which contains ApplicationSets.
          # Once that repo is live, ArgoCD will discover and sync all apps automatically.
          local _infra_git_url=""
          case "$SF_GIT_PROVIDER" in
            bitbucket) _infra_git_url="https://bitbucket.org/${SF_GIT_WORKSPACE}/infra-gitops.git" ;;
            github)    _infra_git_url="https://github.com/${SF_GIT_WORKSPACE}/infra-gitops.git" ;;
            gitlab)    _infra_git_url="https://gitlab.com/${SF_GIT_WORKSPACE}/infra-gitops.git" ;;
          esac
          if [ -n "$_infra_git_url" ]; then
            cat <<ARGOAPP | kubectl apply -f - 2>/dev/null || log_warn "ArgoCD bootstrap Application failed to apply"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-bootstrap
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: ${_infra_git_url}
    targetRevision: main
    path: argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
ARGOAPP
            log_info "ArgoCD bootstrap Application created — will sync once infra-gitops is pushed ✓"
          fi
        else
          log_info "Git credentials: skipped (configure in web wizard)"
        fi
      else
        log_warn "ArgoCD install failed — GitOps will not be available"
        log_warn "You can install ArgoCD later via: helm upgrade --install argocd argo/argo-cd -n argocd"
      fi
    fi
  else
    log_info "ArgoCD: skipped (local mode — add via 'sf install --mode cloud' for GitOps)"
  fi

  # --------------------------------------------------
  # 4. Vault (cloud/hybrid only)
  # --------------------------------------------------
  if [ "$SF_MODE" != "local" ]; then
    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    log_step "Installing Vault..."
    if helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null && \
       helm repo update hashicorp 2>/dev/null; then
      if helm upgrade --install vault hashicorp/vault \
        -n vault \
        --set server.dev.enabled=false \
        --set server.standalone.enabled=true \
        --set server.dataStorage.size=1Gi \
        --set server.resources.requests.memory=64Mi \
        --set server.resources.limits.memory=256Mi \
        --set server.resources.requests.cpu=50m \
        --timeout 120s 2>&1; then
        log_info "Vault Helm chart installed"

        # ---- Wait for Vault pod to be Running (not yet Ready — it needs init first) ----
        log_step "Waiting for Vault pod (pre-init)..."
        local vault_pod=""
        for _i in $(seq 1 30); do
          vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault \
                        --field-selector=status.phase=Running \
                        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
          [ -n "$vault_pod" ] && break
          sleep 5
        done

        if [ -z "$vault_pod" ]; then
          log_warn "Vault pod not running after 150s — skipping init (run 'sf vault-init' later)"
        else
          log_info "Vault pod: ${vault_pod}"

          # ---- Initialize Vault ----
          local vault_init_json=""
          vault_init_json=$(kubectl exec -n vault "$vault_pod" -- \
            vault operator init -format=json -key-shares=5 -key-threshold=3 2>/dev/null || true)

          if [ -z "$vault_init_json" ] || echo "$vault_init_json" | grep -q "already initialized"; then
            log_info "Vault already initialized — skipping init"
          else
            log_info "Vault initialized — extracting unseal keys..."

            # Save keys locally (600 perms)
            local keys_file="${CONFIG_DIR:-$HOME/.software-factory}/vault-keys.json"
            echo "$vault_init_json" > "$keys_file"
            chmod 600 "$keys_file"

            # Extract root token + first 3 unseal keys via python3 (always available)
            local vault_root_token
            vault_root_token=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['root_token'])" < "$keys_file")
            local key1 key2 key3
            key1=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])" < "$keys_file")
            key2=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['unseal_keys_b64'][1])" < "$keys_file")
            key3=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['unseal_keys_b64'][2])" < "$keys_file")

            # Persist root token to config.env for downstream use
            echo "SF_VAULT_ROOT_TOKEN=${vault_root_token}" >> "${CONFIG_DIR:-$HOME/.software-factory}/config.env"
            echo "SF_VAULT_TOKEN=${vault_root_token}" >> "${CONFIG_DIR:-$HOME/.software-factory}/config.env"
            echo "SF_VAULT_ADDR=http://vault.vault.svc.cluster.local:8200" >> "${CONFIG_DIR:-$HOME/.software-factory}/config.env"

            # Store in K8s Secret so pods can bootstrap themselves
            kubectl create secret generic vault-init-keys -n vault \
              --from-literal=root_token="$vault_root_token" \
              --from-literal=unseal_key_1="$key1" \
              --from-literal=unseal_key_2="$key2" \
              --from-literal=unseal_key_3="$key3" \
              --dry-run=client -o yaml | kubectl apply -f -

            log_step "Unsealing Vault (3 of 5 shards)..."
            kubectl exec -n vault "$vault_pod" -- vault operator unseal "$key1" &>/dev/null || true
            kubectl exec -n vault "$vault_pod" -- vault operator unseal "$key2" &>/dev/null || true
            kubectl exec -n vault "$vault_pod" -- vault operator unseal "$key3" &>/dev/null || true

            # Wait for Vault to become Ready
            sleep 5
            local vault_status
            vault_status=$(kubectl exec -n vault "$vault_pod" -- vault status -format=json 2>/dev/null || echo '{"sealed":true}')
            if echo "$vault_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed'))" 2>/dev/null | grep -q "False"; then
              log_info "Vault unsealed ✓"

              # ---- Configure Vault ----
              log_step "Configuring Vault secrets engine and Kubernetes auth..."
              # Enable kv-v2 at secret/
              kubectl exec -n vault "$vault_pod" -- env VAULT_TOKEN="$vault_root_token" \
                vault secrets enable -path=secret kv-v2 &>/dev/null || \
                log_warn "kv-v2 already enabled or failed — continuing"

              # Enable Kubernetes auth
              kubectl exec -n vault "$vault_pod" -- env VAULT_TOKEN="$vault_root_token" \
                vault auth enable kubernetes &>/dev/null || \
                log_warn "Kubernetes auth already enabled — continuing"

              # Configure Kubernetes auth using the cluster's own service account
              kubectl exec -n vault "$vault_pod" -- env VAULT_TOKEN="$vault_root_token" \
                vault write auth/kubernetes/config \
                  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
                  &>/dev/null || log_warn "Vault K8s auth config failed — configure manually"

              # Create a policy for nexus-api to manage app secrets per environment.
              # kv-v2 requires both data/ and metadata/ paths for full list/read/write flows.
              kubectl exec -n vault "$vault_pod" -- env VAULT_TOKEN="$vault_root_token" \
                vault policy write nexus-api-policy - <<'VPOL' &>/dev/null || true
path "secret/data/dev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/dev/*" {
  capabilities = ["list", "read", "delete"]
}
path "secret/data/staging/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/staging/*" {
  capabilities = ["list", "read", "delete"]
}
path "secret/data/prod/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/prod/*" {
  capabilities = ["list", "read", "delete"]
}
path "secret/data/apps/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
path "secret/data/nexus-api/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/nexus-api/*" {
  capabilities = ["read", "list"]
}
VPOL

              # Create auth role for nexus-api service account
              kubectl exec -n vault "$vault_pod" -- env VAULT_TOKEN="$vault_root_token" \
                vault write auth/kubernetes/role/nexus-api \
                  bound_service_account_names=default,nexus-api \
                  bound_service_account_namespaces=prod \
                  policies=nexus-api-policy \
                  ttl=24h \
                  &>/dev/null || log_warn "Vault role creation failed — configure manually"

              log_info "Vault: kv-v2 secrets engine + Kubernetes auth configured ✓"
            else
              log_warn "Vault is still sealed after unseal attempt — check vault-keys.json manually"
            fi
          fi
        fi
      else
        log_warn "Vault install failed — secrets will be stored in Kubernetes"
      fi
    else
      log_warn "Cannot add hashicorp helm repo — skipping Vault"
    fi
  else
    log_info "Vault: skipped (local mode — secrets stored in Kubernetes)"
  fi

  # --------------------------------------------------
  # 5. Tailscale Operator (if enabled)
  # --------------------------------------------------
  if [ "${SF_TAILSCALE_ENABLED:-false}" = "true" ]; then
    kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    log_step "Installing Tailscale Operator..."
    if [ -z "${SF_TAILSCALE_CLIENT_ID:-}" ] || [ -z "${SF_TAILSCALE_CLIENT_SECRET:-}" ]; then
      log_warn "Tailscale credentials missing — skipping Tailscale Operator"
    elif helm repo add tailscale https://pkgs.tailscale.com/helmcharts 2>/dev/null && \
         helm repo update tailscale 2>/dev/null; then

      # ---- Pre-flight: Configure ACL tagOwners BEFORE installing operator ----
      # Without tag:k8s-operator in tagOwners, the operator will CrashLoopBackOff.
      if [ -n "${SF_TAILSCALE_ACL_TOKEN:-}" ]; then
        log_step "Configuring Tailscale ACL tagOwners..."
        local acl_response
        acl_response=$(curl -sf -u "${SF_TAILSCALE_ACL_TOKEN}:" \
          https://api.tailscale.com/api/v2/tailnet/-/acl 2>/dev/null || echo "")
        if [ -n "$acl_response" ]; then
          # Build new ACL with required tagOwners (preserving existing grants/ssh)
          local new_acl
          new_acl=$(python3 -c "
import json, sys, re
try:
    raw = '''${acl_response}'''
    # Strip JSONC comments for parsing
    cleaned = re.sub(r'//.*', '', raw)
    cleaned = re.sub(r'/\\*.*?\\*/', '', cleaned, flags=re.DOTALL)
    acl = json.loads(cleaned)
except:
    acl = {}
required_tags = {
    'tag:k8s-operator': ['autogroup:admin'],
    'tag:k8s': ['tag:k8s-operator', 'autogroup:admin'],
    'tag:database': ['tag:k8s-operator', 'autogroup:admin'],
    'tag:iot': ['tag:k8s-operator', 'autogroup:admin']
}
existing = acl.get('tagOwners', {})
existing.update(required_tags)
acl['tagOwners'] = existing
if 'grants' not in acl:
    acl['grants'] = [{'src': ['*'], 'dst': ['*'], 'ip': ['*']}]
if 'ssh' not in acl:
    acl['ssh'] = [{'action': 'check', 'src': ['autogroup:member'], 'dst': ['autogroup:self'], 'users': ['autogroup:nonroot', 'root']}]
print(json.dumps(acl))
" 2>/dev/null || echo "")
          if [ -n "$new_acl" ]; then
            local acl_status
            acl_status=$(curl -sf -o /dev/null -w '%{http_code}' \
              -X POST -u "${SF_TAILSCALE_ACL_TOKEN}:" \
              -H 'Content-Type: application/json' \
              -d "$new_acl" \
              https://api.tailscale.com/api/v2/tailnet/-/acl 2>/dev/null || echo "000")
            if [ "$acl_status" = "200" ]; then
              log_info "Tailscale ACL tagOwners configured ✓"
            else
              log_warn "Tailscale ACL update returned HTTP ${acl_status} — operator may fail to start"
            fi
          else
            log_warn "Failed to build ACL JSON — operator may fail to start"
          fi
        else
          log_warn "Cannot read Tailscale ACL (API error) — operator may fail to start"
        fi
      else
        log_warn "No SF_TAILSCALE_ACL_TOKEN — skipping ACL tagOwners setup (operator may fail)"
      fi

      # Remove any pre-existing operator-oauth secret that lacks Helm labels
      # (prevents "invalid ownership metadata" error on helm install)
      kubectl delete secret operator-oauth -n tailscale --ignore-not-found 2>/dev/null || true
      if helm upgrade --install tailscale-operator tailscale/tailscale-operator \
        -n tailscale \
        --set oauth.clientId="$SF_TAILSCALE_CLIENT_ID" \
        --set oauth.clientSecret="$SF_TAILSCALE_CLIENT_SECRET" \
        --set operatorConfig.hostname="sf-operator" \
        --wait --timeout 300s 2>&1; then
        log_info "Tailscale Operator installed"
      else
        log_warn "Tailscale Operator install failed — mesh VPN will not be available"
      fi
    else
      log_warn "Cannot add tailscale helm repo — skipping Tailscale"
    fi
  fi

  # --------------------------------------------------
  
  # --------------------------------------------------
  # 6. Cloudflare Tunnel (manual token fallback)
  # --------------------------------------------------
  # NOTE: Tunnel is primarily handled by lib/07-tunnel.sh (auto-creates from API token).
  # This section is only a fallback for manual tunnel tokens provided directly.
  # Skip if we're in hybrid mode (07-tunnel.sh will handle it after install_core_infra).
  if [ "${SF_MODE:-local}" = "hybrid" ] && [ -n "${SF_CLOUDFLARE_TOKEN:-}" ]; then
    log_info "Cloudflare Tunnel will be auto-created after core services (lib/07-tunnel.sh)"
  elif [ -n "${SF_CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    log_step "Installing Cloudflare Tunnel (cloudflared) from manual token..."
    kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

    # Store token in a K8s Secret — never expose it as a plaintext env var in the Deployment spec
    kubectl create secret generic cloudflare-tunnel-token \
      -n cloudflare \
      --from-literal=token="${SF_CLOUDFLARE_TUNNEL_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -

    cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:2024.10.0
        args:
        - tunnel
        - --no-autoupdate
        - run
        imagePullPolicy: IfNotPresent
        env:
        - name: TUNNEL_TOKEN
          valueFrom:
            secretKeyRef:
              name: cloudflare-tunnel-token
              key: token
        resources:
          requests:
            memory: 32Mi
            cpu: 20m
          limits:
            memory: 128Mi
YAML
    log_info "Cloudflare tunnel deployed (token stored in K8s Secret) ✓"
  fi

  # --------------------------------------------------
  # 7. Docker Hub credentials (only if provided)
  # --------------------------------------------------
  local _docker_user="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"
  if [ -n "${SF_DOCKER_TOKEN:-}" ] && [ -n "$_docker_user" ]; then
    log_step "Configuring Docker Hub credentials..."
    for ns in prod dev staging; do
      kubectl create secret docker-registry dockerhub-credentials \
        -n "$ns" \
        --docker-server=https://index.docker.io/v1/ \
        --docker-username="$_docker_user" \
        --docker-password="$SF_DOCKER_TOKEN" \
        --docker-email="${SF_GIT_EMAIL:-noreply@softwarefactory.dev}" \
        --dry-run=client -o yaml | kubectl apply -f -
    done
    log_info "Docker Hub credentials configured"
  else
    log_info "Docker Hub credentials: skipped (configure in web wizard)"
  fi
}
