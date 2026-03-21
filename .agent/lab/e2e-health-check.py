#!/usr/bin/env python3
"""
E2E Health Check — Post-Installation Validator
===============================================
Run this AFTER the installer completes to verify the full stack is healthy.
Designed to run FROM THE VPS (root@vps) via: python3 e2e-health-check.py

Requirements:
  - kubectl configured (K3s install does this)
  - Network access to localhost:30081 (kaanbal-api NodePort)

Exit codes:
  0 = all checks passed
  1 = one or more checks failed
"""
import json
import os
import subprocess
import sys
import urllib.request
import urllib.parse
import urllib.error
import time

# ─── Config ──────────────────────────────────────────────────────────────────
API_NODEPORT = os.environ.get("API_NODEPORT", "30081")
CONSOLE_NODEPORT = os.environ.get("CONSOLE_NODEPORT", "30080")
API_BASE = f"http://127.0.0.1:{API_NODEPORT}"
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin123#")

# ─── Helpers ─────────────────────────────────────────────────────────────────
passed = 0
failed = 0
warnings = 0

def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  ✓ {name}" + (f" — {detail}" if detail else ""))
    else:
        failed += 1
        print(f"  ✗ {name}" + (f" — {detail}" if detail else ""))

def warn(name, detail=""):
    global warnings
    warnings += 1
    print(f"  ⚠ {name}" + (f" — {detail}" if detail else ""))

def kubectl(cmd):
    """Run kubectl and return stdout. Returns empty string on failure."""
    try:
        result = subprocess.run(
            f"kubectl {cmd}",
            shell=True, capture_output=True, text=True, timeout=15
        )
        return result.stdout.strip()
    except Exception:
        return ""

def http_get(url, headers=None, timeout=10):
    """Return (status_code, body_text). Returns (0, error_msg) on failure."""
    req = urllib.request.Request(url)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode() if e.fp else ""
    except Exception as e:
        return 0, str(e)

def http_post_form(url, data, timeout=10):
    """POST form data, return (status_code, body_dict)."""
    encoded = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=encoded, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


# ═════════════════════════════════════════════════════════════════════════════
# CHECK SECTIONS
# ═════════════════════════════════════════════════════════════════════════════

def check_k3s():
    print("\n═══ K3s Cluster ═══")
    nodes = kubectl("get nodes --no-headers")
    check("K3s node exists", bool(nodes), nodes.split()[0] if nodes else "no nodes")
    ready = "Ready" in nodes if nodes else False
    check("Node is Ready", ready)

def check_namespaces():
    print("\n═══ Namespaces ═══")
    ns_out = kubectl("get namespaces --no-headers")
    ns_list = [line.split()[0] for line in ns_out.splitlines()] if ns_out else []
    required = ["argocd", "cert-manager", "cloudflare", "dev", "ingress-nginx", "prod", "tailscale", "vault"]
    for ns in required:
        check(f"Namespace '{ns}'", ns in ns_list)

def check_pods():
    print("\n═══ Pods ═══")
    pods_raw = kubectl("get pods -A --no-headers")
    if not pods_raw:
        check("Pods exist", False, "kubectl returned nothing")
        return

    lines = pods_raw.splitlines()
    total = len(lines)
    running = sum(1 for l in lines if "Running" in l or "Completed" in l)
    check(f"Pod count ({total} total)", total >= 15, f"{running} running/completed")

    # Critical pods
    critical = {
        "argocd-server": "argocd",
        "kaanbal-api": "prod",
        "kaanbal-console": "prod",
        "datastore": "prod",
        "coredns": "kube-system",
        "ingress-nginx-controller": "ingress-nginx",
        "cloudflared": "cloudflare",
        "cert-manager": "cert-manager",
    }
    for pod_prefix, ns in critical.items():
        found = any(pod_prefix in l and ns in l and ("Running" in l or "1/1" in l) for l in lines)
        check(f"Pod '{pod_prefix}' in {ns}", found)

    # Expected non-critical issues
    dev_backoff = sum(1 for l in lines if "dev" in l and ("ImagePullBackOff" in l or "ErrImagePull" in l))
    if dev_backoff > 0:
        warn(f"Dev pods in ImagePullBackOff ({dev_backoff})", "expected until CI/CD builds images")

def check_argocd():
    print("\n═══ ArgoCD Applications ═══")
    apps_raw = kubectl("get applications -n argocd --no-headers")
    if not apps_raw:
        check("ArgoCD apps exist", False)
        return

    lines = apps_raw.splitlines()
    check(f"ArgoCD app count", len(lines) >= 5, f"{len(lines)} apps")

    for line in lines:
        parts = line.split()
        if len(parts) >= 3:
            name, sync, health = parts[0], parts[1], parts[2]
            if health == "Healthy":
                check(f"App '{name}'", True, f"{sync}/{health}")
            elif health == "Degraded" and ("dev" in name or name == "vault"):
                warn(f"App '{name}' Degraded", "expected (dev images / vault HA)")
            else:
                check(f"App '{name}'", False, f"{sync}/{health}")

def check_tls():
    print("\n═══ TLS Certificates ═══")
    certs_raw = kubectl("get certificates -n prod --no-headers")
    if not certs_raw:
        warn("No certificates found in prod namespace")
        return

    for line in certs_raw.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            name, ready = parts[0], parts[1]
            check(f"Certificate '{name}'", ready == "True", f"READY={ready}")

def check_api_health():
    print("\n═══ API Health ═══")

    # Root endpoint
    status, body = http_get(f"{API_BASE}/")
    check("API root", status == 200, body[:80] if body else "")

    # Health
    status, body = http_get(f"{API_BASE}/health")
    check("API /health", status == 200 and "healthy" in body, body[:80] if body else "")

    # Docs
    status, body = http_get(f"{API_BASE}/docs")
    check("API /docs (Swagger)", status == 200 and "swagger" in body.lower())

    # Settings public
    status, body = http_get(f"{API_BASE}/api/v1/admin/settings-public")
    if status == 200:
        try:
            settings = json.loads(body)
            check("Settings public", True, f"{len(settings)} keys")
            # Verify critical settings
            domain = settings.get("domain", "")
            check("Domain configured", bool(domain), domain)
        except json.JSONDecodeError:
            check("Settings public (valid JSON)", False)
    else:
        check("Settings public", False, f"HTTP {status}")

def check_api_auth():
    print("\n═══ API Authentication ═══")

    # Login
    status, resp = http_post_form(
        f"{API_BASE}/api/v1/auth/token",
        {"username": ADMIN_USER, "password": ADMIN_PASS}
    )
    token = resp.get("access_token", "")
    check("Admin login", status == 200 and bool(token))

    if not token:
        warn("Skipping authenticated checks (no token)")
        return token

    # Protected endpoint
    status, body = http_get(
        f"{API_BASE}/api/v1/apps",
        headers={"Authorization": f"Bearer {token}"}
    )
    check("Authenticated /apps", status == 200)

    # Templates
    status, body = http_get(
        f"{API_BASE}/api/v1/templates",
        headers={"Authorization": f"Bearer {token}"}
    )
    if status == 200:
        try:
            templates = json.loads(body)
            ready = [t for t in templates if t.get("status") == "ready"]
            check("Templates loaded", len(ready) >= 3, f"{len(ready)} ready templates")
        except json.JSONDecodeError:
            check("Templates (valid JSON)", False)
    else:
        check("Templates endpoint", False, f"HTTP {status}")

    return token

def check_console():
    print("\n═══ Console (Frontend) ═══")
    status, body = http_get(f"http://127.0.0.1:{CONSOLE_NODEPORT}")
    check("Console HTTP", status == 200)
    if body:
        check("Console serves HTML", "<html" in body.lower() or "<!doctype" in body.lower())

def check_mongodb():
    print("\n═══ MongoDB ═══")
    # Check pod
    mongo_pod = kubectl("get pods -n prod -l app=datastore --no-headers")
    check("MongoDB pod", bool(mongo_pod) and "Running" in mongo_pod)

    # Check secret
    secret = kubectl("get secret datastore-credentials -n prod --no-headers")
    check("MongoDB secret exists", bool(secret))

def check_services():
    print("\n═══ Kubernetes Services ═══")
    svcs = kubectl("get svc -A --no-headers")
    if not svcs:
        check("Services exist", False)
        return

    critical_svcs = [
        ("kaanbal-api", "prod"),
        ("kaanbal-console", "prod"),
        ("datastore", "prod"),
        ("argocd-server", "argocd"),
        ("ingress-nginx-controller", "ingress-nginx"),
    ]
    for svc_name, ns in critical_svcs:
        found = any(svc_name in l and ns in l for l in svcs.splitlines())
        check(f"Service '{svc_name}' in {ns}", found)

def check_tailscale():
    print("\n═══ Tailscale ═══")
    ts_pods = kubectl("get pods -n tailscale --no-headers")
    if ts_pods:
        operator = any("operator" in l and "Running" in l for l in ts_pods.splitlines())
        check("Tailscale operator", operator)
    else:
        warn("No Tailscale pods found")

def check_dns_resolution():
    print("\n═══ DNS Resolution (CoreDNS) ═══")
    # Verify CoreDNS can resolve external domains
    coredns_cm = kubectl("get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'")
    uses_external = "1.1.1.1" in coredns_cm or "8.8.8.8" in coredns_cm
    check("CoreDNS uses external forwarders", uses_external,
          "1.1.1.1/8.8.8.8" if uses_external else "may use local resolver")

def check_app_launch_capability(token):
    print("\n═══ App Launch Capability ═══")
    if not token:
        warn("Skipping (no auth token)")
        return

    headers = {"Authorization": f"Bearer {token}"}

    # Check templates
    status, body = http_get(f"{API_BASE}/api/v1/templates?status=ready", headers=headers)
    if status != 200:
        check("Templates available", False)
        return

    templates = json.loads(body)
    template_ids = [t["id"] for t in templates]

    # Check which categories have ready templates
    categories = set(t.get("category", "") for t in templates)
    for cat in ["database", "backend", "frontend"]:
        has = cat in categories
        check(f"Template category '{cat}'", has)

    # Try launching a database app (most reliable — config-only mode)
    launch_payload = json.dumps({
        "name": "e2e-health-db",
        "template": "mongodb",
        "environments": ["dev"],
        "exposure": {"type": "internal"}
    }).encode()

    req = urllib.request.Request(
        f"{API_BASE}/api/v1/apps",
        data=launch_payload,
        method="POST"
    )
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        result = json.loads(resp.read())
        app_id = result.get("id", "")
        check("Database app launch", bool(app_id), f"id={app_id}")

        # Wait for completion
        if app_id:
            time.sleep(10)
            status2, body2 = http_get(
                f"{API_BASE}/api/v1/apps/e2e-health-db",
                headers=headers
            )
            if status2 == 200:
                app = json.loads(body2)
                app_status = app.get("status", "unknown")
                check("Database app status", app_status == "running", app_status)
            else:
                warn(f"Could not check app status: HTTP {status2}")

            # Cleanup: delete the test app
            del_req = urllib.request.Request(
                f"{API_BASE}/api/v1/apps/{app_id}",
                method="DELETE"
            )
            del_req.add_header("Authorization", f"Bearer {token}")
            try:
                urllib.request.urlopen(del_req, timeout=15)
                check("Test app cleanup", True, "deleted")
            except Exception:
                warn("Could not delete test app e2e-health-db")

    except urllib.error.HTTPError as e:
        if e.code == 409:
            warn("Test app 'e2e-health-db' already exists (delete manually)")
        else:
            check("Database app launch", False, f"HTTP {e.code}")
    except Exception as e:
        check("Database app launch", False, str(e))


# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

def main():
    print("╔══════════════════════════════════════════════════════════╗")
    print("║     Kaanbal Engine — E2E Post-Installation Health Check ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print(f"  API:     {API_BASE}")
    print(f"  Console: http://127.0.0.1:{CONSOLE_NODEPORT}")

    check_k3s()
    check_namespaces()
    check_pods()
    check_argocd()
    check_tls()
    check_api_health()
    token = check_api_auth()
    check_console()
    check_mongodb()
    check_services()
    check_tailscale()
    check_dns_resolution()
    check_app_launch_capability(token)

    # Summary
    total = passed + failed
    print(f"\n{'═' * 60}")
    print(f"  RESULTS: {passed}/{total} passed, {failed} failed, {warnings} warnings")
    if failed == 0:
        print("  STATUS:  ✓ ALL CHECKS PASSED")
    else:
        print(f"  STATUS:  ✗ {failed} CHECK(S) FAILED")
    print(f"{'═' * 60}")

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
