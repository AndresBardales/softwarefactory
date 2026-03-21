# E2E Installation Test Playbook

## Purpose
Repeatable, agent-executable spec for validating a full Kaanbal Engine installation.
Any agent can follow this playbook to verify a fresh install is healthy.

---

## Prerequisites

| Item | Details |
|------|---------|
| VPS | Ubuntu 22.04+, 4+ CPU, 8GB+ RAM, public IPv4 |
| SSH Key | `_private/keys/customer1` (or equivalent) |
| Domain | DNS zone managed in Cloudflare, CNAME `*.domain` → tunnel |
| Credentials | `_private/SETUP-CREDENTIALS.txt` with all KB_* values |
| Scripts | `softwarefactory/.agent/lab/` — all e2e-*.py scripts |

---

## Phase 1: Connectivity & Pre-Check

```bash
# Verify SSH access
ssh -i <key> root@<VPS_IP> "hostname && uptime"

# Check if K3s is running (skip if fresh install needed)
ssh -i <key> root@<VPS_IP> "kubectl get nodes --no-headers"
```

**Expected**: SSH connects, shows hostname. K3s shows node in Ready state.

---

## Phase 2: Run Health Check

Upload and execute the health check script:

```bash
scp -i <key> softwarefactory/.agent/lab/e2e-health-check.py root@<VPS_IP>:/tmp/
ssh -i <key> root@<VPS_IP> "python3 /tmp/e2e-health-check.py"
```

### Pass Criteria (54 checks):

| Section | Key Checks |
|---------|-----------|
| K3s Cluster | Node exists, Ready |
| Namespaces | 8 required: argocd, cert-manager, cloudflare, dev, ingress-nginx, prod, tailscale, vault |
| Pods | ≥15 total, all critical pods Running |
| ArgoCD | ≥5 apps, prod apps Synced/Healthy |
| TLS | Both `kaanbal-api-tls` and `kaanbal-console-tls` READY=True |
| API | Root 200, /health 200, /docs 200, settings-public returns keys |
| Auth | Admin login succeeds, /apps accessible, ≥3 ready templates |
| Console | HTTP 200, serves HTML |
| MongoDB | Pod Running, secret exists |
| Services | kaanbal-api, kaanbal-console, datastore, argocd-server, ingress-nginx |
| Tailscale | Operator Running |
| CoreDNS | External forwarders (1.1.1.1/8.8.8.8) |
| App Launch | Can create/validate/delete a mongodb test app |

### Expected Warnings (non-blocking):
- Dev pods in ImagePullBackOff (no CI/CD images built yet)
- Dev ArgoCD apps Degraded (same reason)
- Vault app Degraded (HA replica needs anti-affinity on multi-node)

---

## Phase 3: Run App Launch Test

```bash
scp -i <key> softwarefactory/.agent/lab/launch-test-apps.py root@<VPS_IP>:/tmp/
ssh -i <key> root@<VPS_IP> "python3 /tmp/launch-test-apps.py"
```

### Pass Criteria:

| Template | Expected Status | Notes |
|----------|----------------|-------|
| mongodb | running | Config-only mode, DevOps auto-deploy |
| postgres | running | Config-only mode |
| mysql | running | Config-only mode |

### Known Blocked Templates:
| Template | Issue |
|----------|-------|
| vue3-spa | npm not available + kaanbal-templates repo has empty scaffold dirs |
| fastapi-api | scaffold.source directory empty in kaanbal-templates repo |

**Resolution**: Populate kaanbal-templates repo with actual template content (Dockerfiles, k8s manifests, app source, CI pipelines).

---

## Phase 4: HTTPS Endpoint Validation

```bash
# From VPS (use --resolve to bypass local DNS cache issues):
curl -sk --resolve kaanbal-api.<domain>:443:188.114.97.3 https://kaanbal-api.<domain>/health
# Expected: {"status":"healthy"}

curl -sk --resolve kaanbal-console.<domain>:443:188.114.97.3 https://kaanbal-console.<domain>/
# Expected: HTTP 200, HTML content
```

---

## Phase 5: TLS Certificate Validation

```bash
kubectl get certificates -n prod
# Both should show READY=True
```

---

## Full E2E Orchestrator (Local Machine)

Run all phases from your local machine:

```bash
cd softwarefactory/.agent/lab/
python e2e-install-test.py --vps-ip <IP> --ssh-key <path/to/key>
```

Options:
- `--health-only` — Run health check only
- `--skip-apps` — Skip app launch phase
- `--domain <domain>` — Override domain (default: automation.com.mx)

---

## Error Decision Tree

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| SSH timeout | VPS down or IP wrong | Check VPS console, verify IP |
| K3s not Ready | Install incomplete | Re-run installer steps 1-3 |
| Pods CrashLoopBackOff | Config error | Check pod logs: `kubectl logs <pod> -n <ns>` |
| TLS READY=False | ACME challenges failing | Check CF tunnel routes ALL through ingress-nginx |
| API 502 | MongoDB auth mismatch | Verify datastore-credentials secret matches API MONGODB_URI |
| Console 502 | Pod not running | Check console pod: `kubectl get pods -n prod` |
| ArgoCD Degraded (prod) | Manifest error | Check ArgoCD UI or `kubectl get app <name> -n argocd -o yaml` |
| App launch 409 | App already exists | Delete existing app first |
| App status=error | Template/scaffold issue | Check API logs: `kubectl logs -n prod -l app=kaanbal-api` |

---

## Rollback

If a fresh install goes wrong:
```bash
# Full cleanup
ssh -i <key> root@<VPS_IP> "/usr/local/bin/k3s-uninstall.sh"
ssh -i <key> root@<VPS_IP> "rm -rf /etc/rancher /var/lib/rancher /opt/k3s"

# Then re-run installer from step 1
```

---

## Known Issues (Current State)

1. **VPS DNS**: Contabo DNS (`213.136.95.10`) caches stale NXDOMAIN for `*.automation.com.mx`. Workaround: CoreDNS patched to use `1.1.1.1`/`8.8.8.8`.
2. **Code Templates Empty**: `kaanbal-templates` repo has only metadata files. Template scaffold directories are empty. Blocks vue3-spa and fastapi-api deployment.
3. **Vault HA**: Single-node cluster can't satisfy pod anti-affinity for Vault HA replicas. Non-blocking.
4. **Dev Namespace Images**: Dev apps need CI/CD pipeline to build Docker images. ImagePullBackOff is expected until first build.

---

## Verification Evidence Format

After running E2E, capture:
```
Health Check: XX/XX passed, X failed, X warnings
App Launch: X/X apps deployed
HTTPS API: HTTP <code>
HTTPS Console: HTTP <code>
TLS Certs: <count> READY=True
ArgoCD: X Synced/Healthy, X Degraded (expected)
Pods: XX/XX Running
```

Post to Jira ticket as validation evidence.
