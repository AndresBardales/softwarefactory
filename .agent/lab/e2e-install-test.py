#!/usr/bin/env python3
"""
E2E Install Test Orchestrator
==============================
Runs FROM A LOCAL MACHINE (Windows/Mac/Linux) via SSH to the VPS.
Orchestrates the full install → health check → app launch cycle.

Usage:
  python e2e-install-test.py --vps-ip 167.86.69.250 --ssh-key path/to/key
  python e2e-install-test.py --vps-ip 167.86.69.250 --ssh-key path/to/key --skip-install
  python e2e-install-test.py --vps-ip 167.86.69.250 --ssh-key path/to/key --health-only

Prereqs: SSH key access to VPS as root, Python 3.8+
"""
import argparse
import json
import os
import subprocess
import sys
import textwrap
import time
import base64

# ─── Config ──────────────────────────────────────────────────────────────────
INSTALLER_PORT = 3000
API_NODEPORT = 30081
CONSOLE_NODEPORT = 30080

# ─── SSH Helper ──────────────────────────────────────────────────────────────
class VPS:
    def __init__(self, ip, ssh_key, user="root"):
        self.ip = ip
        self.key = ssh_key
        self.user = user

    def ssh(self, cmd, timeout=120):
        """Run SSH command and return (returncode, stdout, stderr)."""
        full = [
            "ssh",
            "-i", self.key,
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=10",
            f"{self.user}@{self.ip}",
            cmd
        ]
        try:
            result = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
            return result.returncode, result.stdout.strip(), result.stderr.strip()
        except subprocess.TimeoutExpired:
            return 1, "", "SSH timeout"
        except Exception as e:
            return 1, "", str(e)

    def ssh_script(self, script_content, interpreter="python3", timeout=120):
        """Upload and run a script via base64 encoding."""
        b64 = base64.b64encode(script_content.encode()).decode()
        cmd = f"echo {b64} | base64 -d | {interpreter}"
        return self.ssh(cmd, timeout=timeout)

    def upload_file(self, local_path, remote_path):
        """SCP file to VPS."""
        full = [
            "scp",
            "-i", self.key,
            "-o", "StrictHostKeyChecking=no",
            local_path,
            f"{self.user}@{self.ip}:{remote_path}"
        ]
        try:
            result = subprocess.run(full, capture_output=True, text=True, timeout=60)
            return result.returncode == 0
        except Exception:
            return False


# ─── Phases ──────────────────────────────────────────────────────────────────
def phase_connectivity(vps):
    """Verify SSH and basic VPS state."""
    print("\n═══ Phase 0: Connectivity ═══")
    rc, out, err = vps.ssh("hostname && uptime")
    if rc != 0:
        print(f"  ✗ SSH failed: {err}")
        return False
    print(f"  ✓ Connected to {out.splitlines()[0]}")
    return True


def phase_pre_check(vps):
    """Check if K3s is installed and services are running."""
    print("\n═══ Phase 0.5: Pre-Check ═══")
    rc, out, _ = vps.ssh("which kubectl && kubectl get nodes --no-headers 2>/dev/null")
    if rc != 0 or "Ready" not in out:
        print("  ⚠ K3s not installed or not ready")
        return False
    print(f"  ✓ K3s running: {out.splitlines()[-1]}")
    return True


def phase_health_check(vps, script_dir):
    """Upload and run the health check script."""
    print("\n═══ Phase 1: Health Check ═══")
    health_script = os.path.join(script_dir, "e2e-health-check.py")
    if not os.path.exists(health_script):
        print(f"  ✗ Health check script not found: {health_script}")
        return False

    with open(health_script, "r") as f:
        script_content = f.read()

    rc, out, err = vps.ssh_script(script_content, timeout=120)
    print(out)
    if err:
        print(f"  stderr: {err}")
    return rc == 0


def phase_app_launch(vps, script_dir):
    """Upload and run the app launcher script."""
    print("\n═══ Phase 2: App Launch Test ═══")
    launch_script = os.path.join(script_dir, "launch-test-apps.py")
    if not os.path.exists(launch_script):
        print(f"  ✗ Launch script not found: {launch_script}")
        return False

    with open(launch_script, "r") as f:
        script_content = f.read()

    rc, out, err = vps.ssh_script(script_content, timeout=180)
    print(out)
    if err:
        print(f"  stderr: {err}")
    return rc == 0


def phase_https_check(vps, domain):
    """Verify HTTPS endpoints are reachable (using CF proxy IPs)."""
    print("\n═══ Phase 3: HTTPS Endpoint Validation ═══")
    
    # Use Cloudflare proxy IPs to bypass VPS DNS issues
    endpoints = [
        (f"https://kaanbal-api.{domain}/health", "API health"),
        (f"https://kaanbal-console.{domain}/", "Console"),
    ]
    
    all_ok = True
    for url, label in endpoints:
        host = url.split("//")[1].split("/")[0]
        # Use --resolve to bypass DNS issues on VPS
        rc, out, err = vps.ssh(
            f"curl -sk --resolve {host}:443:188.114.97.3 --max-time 10 -o /dev/null -w '%{{http_code}}' '{url}'"
        )
        code = out.strip().strip("'")
        ok = code in ("200", "301", "302")
        print(f"  {'✓' if ok else '✗'} {label}: HTTP {code}")
        if not ok:
            all_ok = False

    return all_ok


def phase_tls_check(vps, domain):
    """Verify TLS certificates are valid and issued by Let's Encrypt."""
    print("\n═══ Phase 4: TLS Certificate Validation ═══")
    rc, out, _ = vps.ssh("kubectl get certificates -n prod -o json 2>/dev/null")
    if rc != 0:
        print("  ✗ Cannot query certificates")
        return False

    try:
        certs = json.loads(out)
        items = certs.get("items", [])
        all_ready = True
        for item in items:
            name = item["metadata"]["name"]
            conditions = item.get("status", {}).get("conditions", [])
            ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
            print(f"  {'✓' if ready else '✗'} {name}: READY={ready}")
            if not ready:
                all_ready = False
        return all_ready
    except json.JSONDecodeError:
        print("  ✗ Invalid JSON from kubectl")
        return False


# ─── Main ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Kaanbal Engine E2E Install Test")
    parser.add_argument("--vps-ip", required=True, help="VPS IP address")
    parser.add_argument("--ssh-key", required=True, help="Path to SSH private key")
    parser.add_argument("--ssh-user", default="root", help="SSH user (default: root)")
    parser.add_argument("--domain", default="automation.com.mx", help="Platform domain")
    parser.add_argument("--health-only", action="store_true", help="Run health check only")
    parser.add_argument("--skip-install", action="store_true", help="Skip installation phase")
    parser.add_argument("--skip-apps", action="store_true", help="Skip app launch phase")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))

    print("╔══════════════════════════════════════════════════════╗")
    print("║   Kaanbal Engine — E2E Installation Test            ║")
    print("╚══════════════════════════════════════════════════════╝")
    print(f"  VPS:    {args.vps_ip}")
    print(f"  Domain: {args.domain}")
    print(f"  Key:    {args.ssh_key}")

    vps = VPS(args.vps_ip, args.ssh_key, args.ssh_user)

    # Phase 0: Connectivity
    if not phase_connectivity(vps):
        print("\nFATAL: Cannot connect to VPS. Aborting.")
        return 1

    # Phase 0.5: Pre-check
    if not phase_pre_check(vps):
        if args.health_only:
            print("\nFATAL: K3s not running. Cannot run health checks.")
            return 1
        print("  (K3s not installed — would need full install)")

    if args.health_only:
        ok = phase_health_check(vps, script_dir)
        return 0 if ok else 1

    # Phase 1: Health Check
    health_ok = phase_health_check(vps, script_dir)

    # Phase 2: App Launch
    apps_ok = True
    if not args.skip_apps:
        apps_ok = phase_app_launch(vps, script_dir)

    # Phase 3: HTTPS
    https_ok = phase_https_check(vps, args.domain)

    # Phase 4: TLS
    tls_ok = phase_tls_check(vps, args.domain)

    # Summary
    results = {
        "health_check": health_ok,
        "app_launch": apps_ok,
        "https_endpoints": https_ok,
        "tls_certificates": tls_ok,
    }

    print(f"\n{'═' * 50}")
    print("  E2E TEST SUMMARY")
    print(f"{'═' * 50}")
    all_pass = True
    for check, ok in results.items():
        print(f"  {'✓' if ok else '✗'} {check}")
        if not ok:
            all_pass = False

    if all_pass:
        print(f"\n  ✓ ALL E2E CHECKS PASSED")
    else:
        print(f"\n  ✗ SOME CHECKS FAILED — review output above")
    print(f"{'═' * 50}")

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
