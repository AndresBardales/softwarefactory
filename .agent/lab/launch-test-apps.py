#!/usr/bin/env python3
"""
E2E Test App Launcher — Validates app deployment pipeline
==========================================================
Run this ON THE VPS after installation to test app creation.

Launches test apps using templates that are known to work (config-only mode),
documents which templates are blocked, and validates each deployed app.

Usage:
  python3 launch-test-apps.py                   # launch + validate
  python3 launch-test-apps.py --cleanup          # delete test apps only
  python3 launch-test-apps.py --skip-cleanup     # launch without deleting after

Requirements: Network access to localhost:30081 (kaanbal-api NodePort)
"""
import json
import os
import sys
import time
import urllib.request
import urllib.parse
import urllib.error

# ─── Config ──────────────────────────────────────────────────────────────────
API_BASE = os.environ.get("API_BASE", "http://127.0.0.1:30081")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin123#")

# Test app definitions
# NOTE: Code-based templates (vue3-spa, fastapi-api) are SKIPPED because
# kaanbal-templates repo has only metadata and empty directory skeletons.
# This is a separate issue to fix — populate template content first.
TEST_APPS = [
    {
        "name": "e2e-mongo",
        "template": "mongodb",
        "environments": ["dev"],
        "exposure": {"type": "internal"},
        "expect_status": "running",
        "category": "database",
    },
    {
        "name": "e2e-postgres",
        "template": "postgres",
        "environments": ["dev"],
        "exposure": {"type": "internal"},
        "expect_status": "running",
        "category": "database",
    },
    {
        "name": "e2e-mysql",
        "template": "mysql",
        "environments": ["dev"],
        "exposure": {"type": "internal"},
        "expect_status": "running",
        "category": "database",
    },
]

# Templates that are BLOCKED (document why, don't attempt)
SKIPPED_TEMPLATES = {
    "vue3-spa": "Scaffold requires npm (not in cluster) + fallback template files are empty in kaanbal-templates repo",
    "fastapi-api": "scaffold.source 'templates/backend/fastapi-api' directory is empty in kaanbal-templates repo",
}

# ─── HTTP Helpers ────────────────────────────────────────────────────────────
def http_json(method, url, data=None, token=None, timeout=30):
    """Make HTTP request returning (status, response_dict)."""
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {"detail": str(e)}
    except Exception as e:
        return 0, {"error": str(e)}


def authenticate():
    """Get JWT token."""
    encoded = urllib.parse.urlencode({
        "username": ADMIN_USER,
        "password": ADMIN_PASS,
    }).encode()
    req = urllib.request.Request(
        f"{API_BASE}/api/v1/auth/token",
        data=encoded,
        method="POST"
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        data = json.loads(resp.read())
        return data.get("access_token")
    except Exception as e:
        print(f"  ✗ Auth failed: {e}")
        return None


# ─── Core Logic ──────────────────────────────────────────────────────────────
def launch_app(app_def, token):
    """Create a single test app. Returns (success, result_dict)."""
    payload = {
        "name": app_def["name"],
        "template": app_def["template"],
        "environments": app_def["environments"],
        "exposure": app_def["exposure"],
    }
    if app_def.get("category"):
        payload["category"] = app_def["category"]

    status, resp = http_json("POST", f"{API_BASE}/api/v1/apps", data=payload, token=token)

    if status in (200, 201, 202):
        return True, resp
    elif status == 409:
        print(f"    (already exists, fetching status)")
        s2, r2 = http_json("GET", f"{API_BASE}/api/v1/apps/{app_def['name']}", token=token)
        return s2 == 200, r2
    else:
        return False, resp


def wait_for_app(app_name, expect_status, token, timeout=60):
    """Poll app status until it matches or timeout."""
    deadline = time.time() + timeout
    last_status = ""
    while time.time() < deadline:
        status, resp = http_json("GET", f"{API_BASE}/api/v1/apps/{app_name}", token=token)
        if status == 200:
            last_status = resp.get("status", "unknown")
            if last_status == expect_status:
                return True, resp
            if last_status == "error":
                return False, resp
        time.sleep(5)
    return False, {"status": last_status, "detail": "timeout"}


def delete_app(app_name, token):
    """Delete a test app. Must look up ObjectId first, then DELETE by ID."""
    # GET app by name to find its _id
    status, resp = http_json("GET", f"{API_BASE}/api/v1/apps/{app_name}", token=token)
    if status == 404:
        return True, {"detail": "not found (already deleted)"}
    if status != 200:
        return False, resp
    app_id = resp.get("_id", resp.get("id", ""))
    if not app_id:
        return False, {"detail": "no id in response"}
    # DELETE by ObjectId
    status2, resp2 = http_json("DELETE", f"{API_BASE}/api/v1/apps/{app_id}", token=token)
    return status2 in (200, 204, 404), resp2


def run_cleanup(token):
    """Delete all test apps."""
    print("\n═══ Cleanup ═══")
    for app_def in TEST_APPS:
        name = app_def["name"]
        ok, resp = delete_app(name, token)
        if ok:
            print(f"  ✓ Deleted '{name}'")
        else:
            print(f"  ✗ Failed to delete '{name}': {resp}")


def run_launch(token, skip_cleanup=False):
    """Launch all test apps and validate."""
    passed = 0
    failed = 0

    print("\n═══ Skipped Templates (known blocked) ═══")
    for tmpl, reason in SKIPPED_TEMPLATES.items():
        print(f"  ⊘ {tmpl}: {reason}")

    print("\n═══ Launching Test Apps ═══")
    for app_def in TEST_APPS:
        name = app_def["name"]
        template = app_def["template"]
        print(f"\n  → {name} ({template})")

        ok, resp = launch_app(app_def, token)
        if not ok:
            print(f"    ✗ Launch failed: {resp.get('detail', resp)}")
            failed += 1
            continue

        app_id = resp.get("id", resp.get("_id", ""))
        print(f"    Launched (id={app_id}), waiting for status='{app_def['expect_status']}'...")

        ok, result = wait_for_app(name, app_def["expect_status"], token, timeout=90)
        final_status = result.get("status", "unknown")
        if ok:
            print(f"    ✓ Status: {final_status}")
            # Extra validation for databases
            conn = result.get("connection_info", {})
            if conn:
                print(f"    ✓ Connection info: host={conn.get('host', 'N/A')}, port={conn.get('port', 'N/A')}")
            passed += 1
        else:
            error = result.get("error", result.get("detail", ""))
            print(f"    ✗ Status: {final_status}" + (f" — {error}" if error else ""))
            failed += 1

    # Summary
    total = passed + failed
    print(f"\n{'═' * 50}")
    print(f"  RESULTS: {passed}/{total} apps deployed successfully")
    print(f"  SKIPPED: {len(SKIPPED_TEMPLATES)} templates (known blocked)")
    if failed == 0:
        print("  STATUS:  ✓ ALL DEPLOYABLE APPS PASSED")
    else:
        print(f"  STATUS:  ✗ {failed} APP(S) FAILED")
    print(f"{'═' * 50}")

    # Cleanup
    if not skip_cleanup:
        run_cleanup(token)

    return 0 if failed == 0 else 1


# ─── Main ────────────────────────────────────────────────────────────────────
def main():
    print("╔══════════════════════════════════════════════════════╗")
    print("║   Kaanbal Engine — E2E Test App Launcher            ║")
    print("╚══════════════════════════════════════════════════════╝")

    token = authenticate()
    if not token:
        print("FATAL: Cannot authenticate. Exiting.")
        return 1

    print(f"  ✓ Authenticated as '{ADMIN_USER}'")

    if "--cleanup" in sys.argv:
        run_cleanup(token)
        return 0

    skip_cleanup = "--skip-cleanup" in sys.argv
    return run_launch(token, skip_cleanup)


if __name__ == "__main__":
    sys.exit(main())
