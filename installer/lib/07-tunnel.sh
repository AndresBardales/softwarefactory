#!/usr/bin/env bash
# ==============================================================================
# lib/07-tunnel.sh — Cloudflare Tunnel setup (hybrid mode)
# ==============================================================================
# Creates (or reuses) a Cloudflare Tunnel that routes traffic from *.domain.com
# to the local K3s cluster — no open inbound ports, free TLS, global CDN.
#
# Flow:
#   0. Clean up stale tunnels from previous installs
#   1. Create tunnel via Cloudflare API (or reuse existing)
#   2. Configure ingress rules (which hostname → which K8s service)
#   3. Create DNS CNAME records pointing to the tunnel
#   4. Deploy cloudflared as a K8s Deployment inside K3s
# ==============================================================================

setup_cloudflare_tunnel() {
  # Only run in hybrid mode with Cloudflare as tunnel provider
  if [ "$SF_MODE" != "hybrid" ] || [ "${SF_TUNNEL_PROVIDER:-cloudflare}" != "cloudflare" ]; then
    log_info "Skipping Cloudflare Tunnel setup (mode=$SF_MODE, provider=${SF_TUNNEL_PROVIDER:-cloudflare})"
    return 0
  fi

  if [ -z "${SF_CLOUDFLARE_TOKEN:-}" ] || [ -z "${SF_CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    log_error "SF_CLOUDFLARE_TOKEN and SF_CLOUDFLARE_ACCOUNT_ID are required for hybrid mode"
    exit 1
  fi

  if [ -z "${SF_DOMAIN:-}" ]; then
    log_error "SF_DOMAIN is required for Cloudflare Tunnel setup"
    exit 1
  fi

  log_section "Cloudflare Tunnel"

  local cf_api="https://api.cloudflare.com/client/v4"
  local tunnel_name="software-factory"

  # ── Step 0: Cleanup stale tunnels from previous installs ──────────────────
  log_step "Checking for existing tunnels..."

  local list_resp
  list_resp=$(curl -sf \
    "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name_prefix=software-factory&is_deleted=false&per_page=50" \
    -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"result":[]}')

  # Parse existing tunnels and decide: reuse healthy one or cleanup stale ones
  local reuse_tunnel_id=""
  local reuse_tunnel_token=""
  local stale_ids
  stale_ids=$(echo "$list_resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    tunnels = d.get('result', [])
    healthy = []
    stale = []
    for t in tunnels:
        tid = t['id']
        name = t.get('name', '')
        status = t.get('status', 'unknown')
        # A tunnel with active connections is healthy
        conns = t.get('connections', [])
        active_conns = [c for c in conns if c.get('is_pending_reconnect', True) is False]
        if status in ('healthy', 'active') or len(active_conns) > 0:
            healthy.append(tid)
        else:
            stale.append(tid)
    # Print: first line = healthy tunnel (if any), rest = stale to delete
    if healthy:
        print('REUSE:' + healthy[0])
    for s in stale:
        print('DELETE:' + s)
except Exception:
    pass
" 2>/dev/null)

  # Process the results
  while IFS= read -r line; do
    case "$line" in
      REUSE:*)
        reuse_tunnel_id="${line#REUSE:}"
        log_info "Found healthy existing tunnel: $reuse_tunnel_id"
        ;;
      DELETE:*)
        local del_id="${line#DELETE:}"
        log_info "Cleaning up stale tunnel: $del_id"
        # Must clean connections first, then delete
        curl -sf -X DELETE \
          "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${del_id}/connections" \
          -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" > /dev/null 2>&1 || true
        curl -sf -X DELETE \
          "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${del_id}" \
          -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
          -H "Content-Type: application/json" > /dev/null 2>&1 || true
        ;;
    esac
  done <<< "$stale_ids"

  # ── Step 1: Create or reuse tunnel ────────────────────────────────────────
  local tunnel_id tunnel_token

  if [ -n "$reuse_tunnel_id" ]; then
    tunnel_id="$reuse_tunnel_id"
    log_step "Reusing existing tunnel: $tunnel_id"
    # Get token for existing tunnel via Cloudflare API
    local token_resp
    token_resp=$(curl -sf \
      "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" \
      -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" 2>/dev/null || echo '')
    tunnel_token=$(echo "$token_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null || echo '')
    if [ -z "$tunnel_token" ] || [ "$tunnel_token" = "None" ]; then
      log_warn "Could not retrieve token for existing tunnel — will create a new one"
      reuse_tunnel_id=""
    fi
  fi

  if [ -z "$reuse_tunnel_id" ]; then
    log_step "Creating new tunnel: $tunnel_name"

    local create_resp
    create_resp=$(curl -sf -X POST \
      "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
      -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${tunnel_name}\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")

    tunnel_id=$(echo "$create_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['id'])" 2>/dev/null)
    tunnel_token=$(echo "$create_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['token'])" 2>/dev/null)

    if [ -z "$tunnel_id" ] || [ "$tunnel_id" = "None" ]; then
      log_error "Failed to create Cloudflare tunnel"
      echo "$create_resp" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(e['message']) for e in d.get('errors',[])]" 2>/dev/null || echo "$create_resp"
      exit 1
    fi
    log_info "Tunnel created — ID: $tunnel_id"
  fi

  # Persist tunnel ID and token for future re-runs
  sed -i '/^SF_CLOUDFLARE_TUNNEL_ID=/d' "$SF_CONFIG" 2>/dev/null || true
  sed -i '/^SF_CLOUDFLARE_TUNNEL_TOKEN=/d' "$SF_CONFIG" 2>/dev/null || true
  echo "SF_CLOUDFLARE_TUNNEL_ID=\"${tunnel_id}\"" >> "$SF_CONFIG"
  echo "SF_CLOUDFLARE_TUNNEL_TOKEN=\"${tunnel_token}\"" >> "$SF_CONFIG"
  export SF_CLOUDFLARE_TUNNEL_TOKEN="${tunnel_token}"
  export SF_CLOUDFLARE_TUNNEL_ID="${tunnel_id}"

  # ── Step 2: Configure ingress rules (which hostname → which K8s service) ──
  log_step "Configuring ingress rules..."

  curl -sf -X PUT \
    "${cf_api}/accounts/${SF_CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" \
    -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"config\": {
        \"ingress\": [
          {
            \"hostname\": \"nexus-console.${SF_DOMAIN}\",
            \"service\": \"http://nexus-console.prod.svc.cluster.local:80\"
          },
          {
            \"hostname\": \"api.${SF_DOMAIN}\",
            \"service\": \"http://nexus-api.prod.svc.cluster.local:80\"
          },
          {
            \"hostname\": \"nexus-api.${SF_DOMAIN}\",
            \"service\": \"http://nexus-api.prod.svc.cluster.local:80\"
          },
          {
            \"hostname\": \"*.${SF_DOMAIN}\",
            \"service\": \"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80\"
          },
          {
            \"service\": \"http_status:404\"
          }
        ]
      }
    }" > /dev/null

  log_info "Ingress rules configured"

  # ── Step 3: Get Zone ID for the domain ───────────────────────────────────
  log_step "Looking up Cloudflare Zone for ${SF_DOMAIN}..."

  local zone_resp zone_id
  zone_resp=$(curl -sf \
    "${cf_api}/zones?name=${SF_DOMAIN}&status=active" \
    -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}")

  zone_id=$(echo "$zone_resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
results = d.get('result',[])
print(results[0]['id'] if results else '')
" 2>/dev/null)

  if [ -z "$zone_id" ]; then
    log_warn "Zone '${SF_DOMAIN}' not found in Cloudflare — skipping automatic DNS"
    log_warn "Add the domain to Cloudflare, then re-run this step."
  else
    log_info "Zone ID: $zone_id"

    # ── Step 4: Create DNS CNAME records ─────────────────────────────────────
    log_step "Creating DNS records..."

    local cname_target="${tunnel_id}.cfargotunnel.com"
    local subdomains=("nexus-console" "nexus-api" "api")

    for sub in "${subdomains[@]}"; do
      local fqdn="${sub}.${SF_DOMAIN}"

      local existing
      existing=$(curl -sf \
        "${cf_api}/zones/${zone_id}/dns_records?type=CNAME&name=${fqdn}" \
        -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)

      if [ -n "$existing" ]; then
        curl -sf -X PUT \
          "${cf_api}/zones/${zone_id}/dns_records/${existing}" \
          -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"CNAME\",\"name\":\"${fqdn}\",\"content\":\"${cname_target}\",\"proxied\":true}" > /dev/null
        log_info "DNS updated: ${fqdn}"
      else
        curl -sf -X POST \
          "${cf_api}/zones/${zone_id}/dns_records" \
          -H "Authorization: Bearer ${SF_CLOUDFLARE_TOKEN}" \
          -H "Content-Type: application/json" \
          -d "{\"type\":\"CNAME\",\"name\":\"${fqdn}\",\"content\":\"${cname_target}\",\"proxied\":true}" > /dev/null
        log_info "DNS created: ${fqdn} → tunnel"
      fi
    done
  fi

  # ── Step 5: Deploy cloudflared inside K3s ────────────────────────────────
  log_step "Deploying cloudflared to K3s..."

  kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  # Store the tunnel token as a K8s secret
  kubectl create secret generic cloudflare-tunnel-token \
    -n cloudflare \
    --from-literal=token="${tunnel_token}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
  labels:
    app: cloudflared
spec:
  replicas: 2
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
        - --metrics
        - 0.0.0.0:2000
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
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          initialDelaySeconds: 15
          periodSeconds: 10
          failureThreshold: 3
EOF

  # Wait for cloudflared pods to be ready
  log_step "Waiting for cloudflared pods..."
  local waited=0
  while [ $waited -lt 90 ]; do
    local ready
    ready=$(kubectl -n cloudflare get pods -l app=cloudflared --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || true)
    ready=${ready:-0}
    if [ "$ready" -ge 1 ] 2>/dev/null; then
      log_info "cloudflared pod(s) running ($ready replica(s))"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ $waited -ge 90 ]; then
    log_warn "cloudflared pods not ready after 90s — check with: kubectl -n cloudflare get pods"
  fi

  echo ""
  log_info "Cloudflare Tunnel active — your apps will be live at:"
  log_info "  Console  → https://nexus-console.${SF_DOMAIN}"
  log_info "  API      → https://api.${SF_DOMAIN}"
  log_info "  Wildcard → https://*.${SF_DOMAIN} (for future apps)"
  echo ""
  log_info "Manage tunnel at: https://one.dash.cloudflare.com → Networks → Tunnels"
}
