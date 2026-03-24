import json
import os
import time
import urllib.request

# Read credentials from env file (never hardcode secrets)
# Usage: Create .agent/lab/test-credentials.env with KEY=VALUE pairs
# or set environment variables directly
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CREDS_FILE = os.path.join(SCRIPT_DIR, "test-credentials.env")

def load_env_file(path):
    """Load KEY=VALUE pairs from an env file into a dict."""
    env = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    env[key.strip()] = val.strip().strip('"').strip("'")
    return env

creds = load_env_file(CREDS_FILE)

BASE = os.environ.get("INSTALLER_URL", creds.get("INSTALLER_URL", "http://167.86.69.250:3000"))
TOKEN = os.environ.get("INSTALLER_TOKEN", creds.get("INSTALLER_TOKEN", ""))


def post(path, payload, auth=False):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8") or "{}"
            return resp.status, json.loads(body)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8") or "{}"
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {"error": body}


def get(path, auth=False):
    headers = {}
    if auth:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(BASE + path, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8") or "{}"
        return resp.status, json.loads(body)


# Build payload from env file / environment variables
# Keys map directly to installer API fields
PAYLOAD_KEYS = [
    "KB_MODE", "KB_DOMAIN", "KB_GIT_PROVIDER", "KB_GIT_USER", "KB_GIT_EMAIL",
    "KB_GIT_TOKEN", "KB_GIT_WORKSPACE", "KB_DOCKER_USER", "KB_DOCKER_TOKEN",
    "KB_TAILSCALE_ENABLED", "KB_TAILSCALE_CLIENT_ID", "KB_TAILSCALE_CLIENT_SECRET",
    "KB_TAILSCALE_DNS_SUFFIX", "KB_TAILSCALE_ACL_TOKEN",
    "KB_CLOUDFLARE_TOKEN", "KB_CLOUDFLARE_ACCOUNT_ID",
    "KB_ADMIN_USER", "KB_ADMIN_PASSWORD", "KB_ARGOCD_PASSWORD", "KB_VAULT_TOKEN",
]
payload = {}
for key in PAYLOAD_KEYS:
    val = os.environ.get(key, creds.get(key, ""))
    if val:
        payload[key] = val

if not TOKEN:
    print("ERROR: INSTALLER_TOKEN not set. Set it in test-credentials.env or environment.")
    exit(1)

def wait_step(step_id, timeout=600):
    """Poll until a step finishes (done/failed/skipped), return final status."""
    for _ in range(timeout // 5):
        time.sleep(5)
        _, s = get("/api/status", auth=True)
        for item in s.get("steps", []):
            if item["id"] == step_id:
                if item["status"] in ("done", "failed", "skipped"):
                    return item["status"]
                break
    return "timeout"


def run_and_wait(step_id, env_extra=None):
    """Trigger a step and wait for it to finish."""
    # Check current status first
    _, s = get("/api/status", auth=True)
    for item in s.get("steps", []):
        if item["id"] == step_id:
            if item["status"] == "done":
                print(f"  [{step_id}] already done")
                return "done"
            if item["status"] == "running":
                print(f"  [{step_id}] already running, waiting...")
                return wait_step(step_id)
            break
    print(f"  [{step_id}] starting...")
    code, resp = post(f"/api/steps/{step_id}/run", env_extra or {}, auth=True)
    if code == 409:
        print(f"  [{step_id}] already running (409), waiting...")
    elif code != 200:
        print(f"  [{step_id}] trigger returned {code}: {resp}")
    status = wait_step(step_id)
    print(f"  [{step_id}] -> {status}")
    if status == "failed":
        _, s = get("/api/status", auth=True)
        for item in s.get("steps", []):
            if item["id"] == step_id:
                print(f"  EXIT_CODE={item.get('exit_code')}")
                break
    return status


# ── Phase 1: Auth ──
print("=== AUTH ===")
print(post("/api/auth", {"token": TOKEN}, auth=False))

# ── Phase 2: Auto steps 01-03 ──
print("\n=== INFRA STEPS ===")
for sid in ["01-system-check", "02-dependencies", "03-k3s"]:
    st = run_and_wait(sid)
    if st == "failed":
        print(f"ABORT: {sid} failed")
        exit(1)

# ── Phase 3: Validate & submit credentials ──
print("\n=== CREDENTIALS ===")
status, validate = post("/api/validate-credentials", payload, auth=True)
print(f"  Validate: valid={validate.get('valid')} errors={len(validate.get('errors', []))} warnings={len(validate.get('warnings', []))}")
for err in validate.get("errors", []):
    print(f"  ERROR: {err}")
for warn in validate.get("warnings", []):
    print(f"  WARN: {warn}")

print("  Submitting credentials...")
print(post("/api/credentials", payload, auth=True))
cred_status = wait_step("04-credentials")
print(f"  [04-credentials] -> {cred_status}")
if cred_status == "failed":
    print("ABORT: credentials step failed")
    exit(1)

# ── Phase 4: Auto steps 05-11 ──
print("\n=== DEPLOY STEPS ===")
for sid in ["05-core-services", "06-source-repos", "07-database",
            "08-platform-api", "09-platform-console", "10-health-check", "11-finalize"]:
    st = run_and_wait(sid, env_extra={"timeout": "600"})
    if st == "failed":
        print(f"WARN: {sid} failed — continuing to see remaining state")

# ── Summary ──
print("\n=== FINAL STATUS ===")
_, s = get("/api/status", auth=True)
for item in s.get("steps", []):
    print(f"  {item['id']:25s} {item['status']:10s} exit={item.get('exit_code', '-')}")

all_done = all(item["status"] == "done" for item in s.get("steps", []))
print(f"\nRESULT: {'SUCCESS' if all_done else 'PARTIAL FAILURE'}")
