#!/usr/bin/env bash
# ==============================================================================
# lib/05-deploy.sh — Deploy Software Factory (nexus-api, nexus-console, MongoDB)
# ==============================================================================

# Resolve the image tag to use for a given Docker Hub repo.
# Priority: SF_IMAGE_TAG env var > :latest if it exists > most recent prod-* tag
resolve_image_tag() {
  local docker_user="$1"
  local repo_name="${2:-nexus-api}"

  # Explicit override wins
  if [ -n "${SF_IMAGE_TAG:-}" ] && [ "$SF_IMAGE_TAG" != "latest" ]; then
    echo "$SF_IMAGE_TAG"
    return
  fi

  # Check if :latest tag exists on Docker Hub
  local check_url="https://hub.docker.com/v2/repositories/${docker_user}/${repo_name}/tags/latest/"
  if curl -sf --max-time 8 "$check_url" &>/dev/null; then
    echo "latest"
    return
  fi

  # Fetch the most recent prod-* tag from Docker Hub API
  # NOTE: log to stderr (>&2) so logs don't leak into $(resolve_image_tag) capture
  log_warn ":latest tag not found on Docker Hub for ${repo_name} — fetching most recent prod-* tag..." >&2
  local api_url="https://hub.docker.com/v2/repositories/${docker_user}/${repo_name}/tags/?page_size=25&ordering=last_updated"
  local latest_tag
  latest_tag=$(curl -sf --max-time 10 "$api_url" 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = [r['name'] for r in data.get('results', []) if r['name'].startswith('prod-')]
print(tags[0] if tags else 'latest')
" 2>/dev/null || echo "latest")

  log_info "Auto-detected tag: $latest_tag" >&2
  echo "$latest_tag"
}

# ---------------------------------------------------------------------------
# Granular deploy functions (used by installer dashboard steps 06/07/08)
# ---------------------------------------------------------------------------

# Helper: ensure Docker Hub pull secret exists in prod namespace
_ensure_pull_secret() {
  local docker_user="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"
  local docker_token="${SF_DOCKER_TOKEN:-}"
  if [ -n "$docker_token" ] && [ -n "$docker_user" ]; then
    kubectl create secret docker-registry dockerhub-credentials \
      -n prod \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$docker_user" \
      --docker-password="$docker_token" \
      --dry-run=client -o yaml | kubectl apply -f - >&2
    echo 'imagePullSecrets:
      - name: dockerhub-credentials'
  else
    echo ""
  fi
}

deploy_mongodb() {
  if ! validate_kubectl; then
    log_error "Cannot reach Kubernetes cluster"
    return 1
  fi

  kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  log_step "Deploying MongoDB..."

  # Reuse existing password if already stored
  local config_file="$HOME/.software-factory/config.env"
  local mongo_password=""
  if [ -f "$config_file" ]; then
    mongo_password=$(grep '^SF_MONGO_PASSWORD=' "$config_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  fi
  if [ -z "$mongo_password" ]; then
    mongo_password="$(generate_password 20)"
  fi

  local mongo_uri="mongodb://admin:${mongo_password}@datastore.prod.svc.cluster.local:27017/forge?authSource=admin"

  kubectl create secret generic mongodb-secret \
    -n prod \
    --from-literal=MONGO_INITDB_ROOT_USERNAME=admin \
    --from-literal=MONGO_INITDB_ROOT_PASSWORD="$mongo_password" \
    --dry-run=client -o yaml | kubectl apply -f -

  if ! kubectl -n prod get pvc datastore-data &>/dev/null; then
    kubectl apply -f - <<'EOFPVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datastore-data
  namespace: prod
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOFPVC
    log_info "PVC datastore-data created"
  else
    log_info "PVC datastore-data already exists — skipping"
  fi

  kubectl apply -f - <<'EOFMONGO'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: datastore
  namespace: prod
  labels:
    app: datastore
spec:
  replicas: 1
  selector:
    matchLabels:
      app: datastore
  template:
    metadata:
      labels:
        app: datastore
    spec:
      containers:
      - name: mongodb
        image: mongo:7
        ports:
        - containerPort: 27017
        envFrom:
        - secretRef:
            name: mongodb-secret
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /data/db
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: datastore-data
---
apiVersion: v1
kind: Service
metadata:
  name: datastore
  namespace: prod
spec:
  selector:
    app: datastore
  ports:
  - port: 27017
    targetPort: 27017
EOFMONGO

  # Persist mongo credentials to config.env for nexus-api step
  if [ -f "$config_file" ]; then
    grep -q "^SF_MONGO_PASSWORD=" "$config_file" 2>/dev/null || echo "SF_MONGO_PASSWORD=\"${mongo_password}\"" >> "$config_file"
    grep -q "^SF_MONGODB_URI=" "$config_file" 2>/dev/null || echo "SF_MONGODB_URI=\"${mongo_uri}\"" >> "$config_file"
  fi

  if ! wait_for "MongoDB" "kubectl -n prod get pod -l app=datastore -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" 120; then
    log_warn "MongoDB is not ready yet — it may still be pulling the image"
  else
    log_info "MongoDB deployed and ready"
  fi
}

deploy_nexus_api() {
  if ! validate_kubectl; then
    log_error "Cannot reach Kubernetes cluster"
    return 1
  fi

  kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  # Read mongo URI from config
  local config_file="$HOME/.software-factory/config.env"
  local mongo_uri=""
  if [ -f "$config_file" ]; then
    source "$config_file" 2>/dev/null || true
    mongo_uri="${SF_MONGODB_URI:-}"
  fi
  if [ -z "$mongo_uri" ]; then
    log_error "MongoDB URI not found in config — run database step first"
    return 1
  fi

  local docker_user="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"
  if [ -z "$docker_user" ]; then
    log_error "No Docker Hub username configured. Set SF_DOCKER_USER in config."
    return 1
  fi
  local image_tag
  image_tag=$(resolve_image_tag "$docker_user" "nexus-api")
  log_info "Using Docker Hub user: $docker_user"
  log_info "Using image tag: $image_tag"

  # Validate image exists before deploying
  local check_url="https://hub.docker.com/v2/repositories/${docker_user}/nexus-api/tags/${image_tag}/"
  if ! curl -sf --max-time 10 "$check_url" &>/dev/null; then
    log_error "Image not found: ${docker_user}/nexus-api:${image_tag}"
    log_error "Please verify your Docker Hub username and that the image has been pushed."
    log_error "Check: https://hub.docker.com/r/${docker_user}/nexus-api/tags"
    return 1
  fi
  log_info "Image verified on Docker Hub: ${docker_user}/nexus-api:${image_tag}"

  local pull_secret_block
  pull_secret_block=$(_ensure_pull_secret)

  # Generate SECRET_KEY once and persist it
  local config_file="$HOME/.software-factory/config.env"
  local secret_key=""
  if [ -f "$config_file" ]; then
    secret_key=$(grep '^SF_SECRET_KEY=' "$config_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  fi
  if [ -z "$secret_key" ]; then
    secret_key="$(generate_password 32)"
    echo "SF_SECRET_KEY=\"${secret_key}\"" >> "$config_file"
  fi

  log_step "Deploying nexus-api..."

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus-api
  namespace: prod
  labels:
    app: nexus-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus-api
  template:
    metadata:
      labels:
        app: nexus-api
    spec:
      ${pull_secret_block}
      serviceAccountName: default
      containers:
      - name: nexus-api
        image: ${docker_user}/nexus-api:${image_tag}
        ports:
        - containerPort: 8000
        env:
        - name: MONGODB_URI
          value: "${mongo_uri}"
        - name: SECRET_KEY
          value: "${secret_key}"
        - name: DOMAIN
          value: "${SF_DOMAIN:-localhost}"
        - name: NEXUS_ADMIN_USER
          value: "${SF_ADMIN_USER:-admin}"
        - name: NEXUS_ADMIN_PASSWORD
          value: "${SF_ADMIN_PASSWORD:-}"
        - name: SF_MODE
          value: "${SF_MODE:-local}"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 15
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-api
  namespace: prod
spec:
  selector:
    app: nexus-api
  ports:
  - port: 80
    targetPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-api-nodeport
  namespace: prod
spec:
  type: NodePort
  selector:
    app: nexus-api
  ports:
  - port: 80
    targetPort: 8000
    nodePort: 30081
EOF

  log_info "nexus-api deployed (NodePort :30081)"
}

deploy_nexus_console() {
  if ! validate_kubectl; then
    log_error "Cannot reach Kubernetes cluster"
    return 1
  fi

  kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  local config_file="$HOME/.software-factory/config.env"
  [ -f "$config_file" ] && source "$config_file" 2>/dev/null || true

  local docker_user="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"
  if [ -z "$docker_user" ]; then
    log_error "No Docker Hub username configured. Set SF_DOCKER_USER in config."
    return 1
  fi
  local image_tag
  image_tag=$(resolve_image_tag "$docker_user" "nexus-console")
  log_info "Using Docker Hub user: $docker_user"
  log_info "Using image tag: $image_tag"

  # Validate image exists before deploying
  local check_url="https://hub.docker.com/v2/repositories/${docker_user}/nexus-console/tags/${image_tag}/"
  if ! curl -sf --max-time 10 "$check_url" &>/dev/null; then
    log_error "Image not found: ${docker_user}/nexus-console:${image_tag}"
    log_error "Please verify your Docker Hub username and that the image has been pushed."
    log_error "Check: https://hub.docker.com/r/${docker_user}/nexus-console/tags"
    return 1
  fi
  log_info "Image verified on Docker Hub: ${docker_user}/nexus-console:${image_tag}"

  local pull_secret_block
  pull_secret_block=$(_ensure_pull_secret)

  log_step "Deploying nexus-console..."

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus-console
  namespace: prod
  labels:
    app: nexus-console
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus-console
  template:
    metadata:
      labels:
        app: nexus-console
    spec:
      ${pull_secret_block}
      containers:
      - name: nexus-console
        image: ${docker_user}/nexus-console:${image_tag}
        ports:
        - containerPort: 80
        env:
        - name: SETUP_TOKEN
          value: "${SF_SETUP_TOKEN:-}"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-console
  namespace: prod
spec:
  selector:
    app: nexus-console
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-console-nodeport
  namespace: prod
spec:
  type: NodePort
  selector:
    app: nexus-console
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
EOF

  log_info "nexus-console deployed (NodePort :30080)"

  # Ingress for non-localhost domains
  if [ "${SF_DOMAIN:-localhost}" != "localhost" ]; then
    log_step "Configuring Ingress routes..."
    create_ingress "nexus-console" "nexus-console.${SF_DOMAIN}" "nexus-console" 80
    create_ingress "nexus-api" "nexus-api.${SF_DOMAIN}" "nexus-api" 80
    log_info "Ingress routes configured"
  fi
}

# ---------------------------------------------------------------------------
# Monolithic deploy (used by headless mode / legacy)
# ---------------------------------------------------------------------------
deploy_software_factory() {
  log_step "Deploying Software Factory core services..."

  # Resolve Docker username: SF_DOCKER_USER (from UI) > SF_DOCKER_USERNAME (legacy) > default
  local docker_user="${SF_DOCKER_USER:-${SF_DOCKER_USERNAME:-}}"
  if [ -z "$docker_user" ]; then
    log_error "No Docker Hub username configured. Set SF_DOCKER_USER in the installer UI or config.env"
    return 1
  fi

  # Validate cluster access
  if ! validate_kubectl; then
    log_error "Cannot reach Kubernetes cluster — aborting deployment"
    return 1
  fi

  # Resolve image tags per-repo (auto-detects if :latest doesn't exist on Docker Hub)
  local api_image_tag console_image_tag
  api_image_tag=$(resolve_image_tag "$docker_user" "nexus-api")
  console_image_tag=$(resolve_image_tag "$docker_user" "nexus-console")
  log_info "Using image tags: nexus-api:$api_image_tag, nexus-console:$console_image_tag (Docker user: $docker_user)"

  # Verify images exist on Docker Hub before deploying
  log_step "Checking image availability..."
  local images_ok=true
  for img_spec in "nexus-api:${api_image_tag}" "nexus-console:${console_image_tag}"; do
    local img="${img_spec%%:*}"
    local tag="${img_spec#*:}"
    local check_url="https://hub.docker.com/v2/repositories/${docker_user}/${img}/tags/${tag}/"
    if curl -sf --max-time 8 "$check_url" &>/dev/null; then
      log_info "Image found: ${docker_user}/${img}:${tag}"
    else
      log_warn "Image not found: ${docker_user}/${img}:${tag}"
      images_ok=false
    fi
  done
  if [ "$images_ok" = false ]; then
    log_warn "Some images not found on Docker Hub — pods may fail to start (ImagePullBackOff)"
    log_warn "Ensure images are pushed or set SF_DOCKER_USER and SF_IMAGE_TAG correctly"
  fi

  # Create prod namespace if it doesn't exist
  kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  # Docker Hub pull secret (only if credentials are provided)
  local pull_secret_block=""
  if [ -n "${SF_DOCKER_TOKEN:-}" ] && [ -n "$docker_user" ]; then
    kubectl create secret docker-registry dockerhub-credentials \
      -n prod \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$docker_user" \
      --docker-password="$SF_DOCKER_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f -
    pull_secret_block='imagePullSecrets:
      - name: dockerhub-credentials'
    log_info "Docker Hub credentials configured"
  else
    log_info "No Docker Hub credentials — pulling public images"
  fi

  # Generate SECRET_KEY once and persist it
  local config_file="$HOME/.software-factory/config.env"
  local secret_key=""
  if [ -f "$config_file" ]; then
    secret_key=$(grep '^SF_SECRET_KEY=' "$config_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
  fi
  if [ -z "$secret_key" ]; then
    secret_key="$(generate_password 32)"
    echo "SF_SECRET_KEY=\"${secret_key}\"" >> "$config_file"
  fi

  # --------------------------------------------------
  # 1. MongoDB (platform database)
  # --------------------------------------------------
  log_step "Deploying MongoDB..."

  local mongo_password
  mongo_password="$(generate_password 20)"

  kubectl create secret generic mongodb-secret \
    -n prod \
    --from-literal=MONGO_INITDB_ROOT_USERNAME=admin \
    --from-literal=MONGO_INITDB_ROOT_PASSWORD="$mongo_password" \
    --dry-run=client -o yaml | kubectl apply -f -

  local mongo_uri="mongodb://admin:${mongo_password}@datastore.prod.svc.cluster.local:27017/forge?authSource=admin"

  # PVC: create only if it doesn't exist (PVCs are immutable once bound)
  if ! kubectl -n prod get pvc datastore-data &>/dev/null; then
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: datastore-data
  namespace: prod
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
EOF
    log_info "PVC datastore-data created"
  else
    log_info "PVC datastore-data already exists — skipping"
  fi

  # Deployment + Service (idempotent via kubectl apply)
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: datastore
  namespace: prod
  labels:
    app: datastore
spec:
  replicas: 1
  selector:
    matchLabels:
      app: datastore
  template:
    metadata:
      labels:
        app: datastore
    spec:
      containers:
      - name: mongodb
        image: mongo:7
        ports:
        - containerPort: 27017
        envFrom:
        - secretRef:
            name: mongodb-secret
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: data
          mountPath: /data/db
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: datastore-data
---
apiVersion: v1
kind: Service
metadata:
  name: datastore
  namespace: prod
spec:
  selector:
    app: datastore
  ports:
  - port: 27017
    targetPort: 27017
EOF

  if ! wait_for "MongoDB" "kubectl -n prod get pod -l app=datastore -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" 120; then
    log_warn "MongoDB is not ready yet — it may still be pulling the image"
    log_warn "Check status: kubectl -n prod get pods -l app=datastore"
  else
    log_info "MongoDB deployed"
  fi

  # --------------------------------------------------
  # 2. nexus-api (backend)
  # --------------------------------------------------
  log_step "Deploying nexus-api..."

  # Determine API URL based on mode
  local api_host="nexus-api.prod.svc.cluster.local"
  local console_url="http://localhost:9000"
  if [ "$SF_MODE" = "cloud" ] || [ "$SF_MODE" = "hybrid" ]; then
    api_host="nexus-api.${SF_DOMAIN}"
    console_url="https://nexus-console.${SF_DOMAIN}"
  fi

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus-api
  namespace: prod
  labels:
    app: nexus-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus-api
  template:
    metadata:
      labels:
        app: nexus-api
    spec:
      ${pull_secret_block}
      serviceAccountName: default
      containers:
      - name: nexus-api
        image: ${docker_user}/nexus-api:${api_image_tag}
        ports:
        - containerPort: 8000
        env:
        - name: MONGODB_URI
          value: "${mongo_uri}"
        - name: SECRET_KEY
          value: "${secret_key}"
        - name: DOMAIN
          value: "${SF_DOMAIN}"
        - name: NEXUS_ADMIN_USER
          value: "${SF_ADMIN_USER:-admin}"
        - name: NEXUS_ADMIN_PASSWORD
          value: "${SF_ADMIN_PASSWORD:-}"
        - name: SF_MODE
          value: "${SF_MODE}"
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 15
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-api
  namespace: prod
spec:
  selector:
    app: nexus-api
  ports:
  - port: 80
    targetPort: 8000
EOF

  log_info "nexus-api deployment created"

  # --------------------------------------------------
  # 3. nexus-console (frontend)
  # --------------------------------------------------
  log_step "Deploying nexus-console..."

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nexus-console
  namespace: prod
  labels:
    app: nexus-console
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nexus-console
  template:
    metadata:
      labels:
        app: nexus-console
    spec:
      ${pull_secret_block}
      containers:
      - name: nexus-console
        image: ${docker_user}/nexus-console:${console_image_tag}
        ports:
        - containerPort: 80
        env:
        - name: SETUP_TOKEN
          value: "${SF_SETUP_TOKEN:-}"
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-console
  namespace: prod
spec:
  selector:
    app: nexus-console
  ports:
  - port: 80
    targetPort: 80
EOF

  log_info "nexus-console deployment created"

  # --------------------------------------------------
  # 4. Ingress routes
  # --------------------------------------------------
  log_step "Configuring Ingress routes..."

  if [ "$SF_MODE" = "local" ]; then
    # Local mode: NodePort access on localhost:9000 (console) and localhost:9001 (api)
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nexus-console-nodeport
  namespace: prod
spec:
  type: NodePort
  selector:
    app: nexus-console
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
---
apiVersion: v1
kind: Service
metadata:
  name: nexus-api-nodeport
  namespace: prod
spec:
  type: NodePort
  selector:
    app: nexus-api
  ports:
  - port: 80
    targetPort: 8000
    nodePort: 30081
EOF
    log_info "Local access: console → localhost:30080, API → localhost:30081"

    # Also create Ingress for nip.io domain access
    if [ "$SF_DOMAIN" != "localhost" ]; then
      create_ingress "nexus-console" "nexus-console.${SF_DOMAIN}" "nexus-console" 80
      create_ingress "nexus-api" "nexus-api.${SF_DOMAIN}" "nexus-api" 80
    fi
  else
    # Cloud/hybrid: standard Ingress with TLS
    create_ingress "nexus-console" "nexus-console.${SF_DOMAIN}" "nexus-console" 80
    create_ingress "nexus-api" "nexus-api.${SF_DOMAIN}" "nexus-api" 80
  fi

  log_info "Ingress routes configured"

  # Save mongo URI for post-install
  if [ -n "${SF_CONFIG:-}" ] && [ -d "$(dirname "$SF_CONFIG")" ]; then
    grep -q "SF_MONGODB_URI" "$SF_CONFIG" 2>/dev/null || echo "SF_MONGODB_URI=\"${mongo_uri}\"" >> "$SF_CONFIG"
    grep -q "SF_MONGO_PASSWORD" "$SF_CONFIG" 2>/dev/null || echo "SF_MONGO_PASSWORD=\"${mongo_password}\"" >> "$SF_CONFIG"
  fi

  # Print deployment summary
  echo ""
  log_info "Deployment summary:"
  log_info "  MongoDB:        datastore.prod.svc.cluster.local:27017"
  log_info "  nexus-api:      ${docker_user}/nexus-api:${image_tag}"
  log_info "  nexus-console:  ${docker_user}/nexus-console:${image_tag}"
  kubectl -n prod get pods 2>/dev/null || true
}

# Helper: create an Ingress resource
create_ingress() {
  local name="$1"
  local host="$2"
  local service="$3"
  local port="$4"

  local tls_block=""
  local annotations="nginx.ingress.kubernetes.io/ssl-redirect: \"false\""

  if [ "$SF_ENABLE_TLS" = "true" ]; then
    annotations="cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: \"true\""
    tls_block="
  tls:
  - hosts:
    - ${host}
    secretName: ${name}-tls"
  fi

  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: prod
  labels:
    app: ${name}
  annotations:
    ${annotations}
spec:
  ingressClassName: nginx
  rules:
  - host: ${host}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${service}
            port:
              number: ${port}
  ${tls_block}
EOF
}
