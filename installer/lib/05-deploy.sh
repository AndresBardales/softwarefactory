#!/usr/bin/env bash
# ==============================================================================
# lib/05-deploy.sh — Deploy Software Factory (nexus-api, nexus-console, MongoDB)
# ==============================================================================

# Resolve the image tag to use for a given Docker Hub repo.
# Priority: SF_IMAGE_TAG env var > :latest if it exists > most recent prod-* tag
resolve_image_tag() {
  local docker_user="$1"

  # Explicit override wins
  if [ -n "${SF_IMAGE_TAG:-}" ] && [ "$SF_IMAGE_TAG" != "latest" ]; then
    echo "$SF_IMAGE_TAG"
    return
  fi

  # Check if :latest tag exists on Docker Hub for nexus-api
  local check_url="https://hub.docker.com/v2/repositories/${docker_user}/nexus-api/tags/latest/"
  if curl -sf --max-time 8 "$check_url" &>/dev/null; then
    echo "latest"
    return
  fi

  # Fetch the most recent prod-* tag from Docker Hub API
  log_warn ":latest tag not found on Docker Hub — fetching most recent prod-* tag..."
  local api_url="https://hub.docker.com/v2/repositories/${docker_user}/nexus-api/tags/?page_size=25&ordering=last_updated"
  local latest_tag
  latest_tag=$(curl -sf --max-time 10 "$api_url" 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = [r['name'] for r in data.get('results', []) if r['name'].startswith('prod-')]
print(tags[0] if tags else 'latest')
" 2>/dev/null || echo "latest")

  log_info "Auto-detected tag: $latest_tag"
  echo "$latest_tag"
}

deploy_software_factory() {
  log_step "Deploying Software Factory core services..."

  # Resolve image tag (auto-detects if :latest doesn't exist on Docker Hub)
  local image_tag
  image_tag=$(resolve_image_tag "$SF_DOCKER_USERNAME")
  log_info "Using image tag: $image_tag"

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
---
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

  wait_for "MongoDB" "kubectl -n prod get pod -l app=datastore -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true" 120
  log_info "MongoDB deployed"

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
      imagePullSecrets:
      - name: dockerhub-credentials
      serviceAccountName: default
      containers:
      - name: nexus-api
        image: ${SF_DOCKER_USERNAME}/nexus-api:${image_tag}
        ports:
        - containerPort: 8000
        env:
        - name: MONGODB_URI
          value: "${mongo_uri}"
        - name: SECRET_KEY
          value: "$(generate_password 32)"
        - name: DOMAIN
          value: "${SF_DOMAIN}"
        - name: NEXUS_ADMIN_USER
          value: "${SF_ADMIN_USER}"
        - name: NEXUS_ADMIN_PASSWORD
          value: "${SF_ADMIN_PASSWORD}"
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
      imagePullSecrets:
      - name: dockerhub-credentials
      containers:
      - name: nexus-console
        image: ${SF_DOCKER_USERNAME}/nexus-console:${image_tag}
        ports:
        - containerPort: 80
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
  echo "SF_MONGODB_URI=\"${mongo_uri}\"" >> "$SF_CONFIG"
  echo "SF_MONGO_PASSWORD=\"${mongo_password}\"" >> "$SF_CONFIG"
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
