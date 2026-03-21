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
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8") or "{}"
        return resp.status, json.loads(body)


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

print("AUTH", post("/api/auth", {"token": TOKEN}, auth=False))
status, validate = post("/api/validate-credentials", payload, auth=True)
print("VALIDATE", status, validate.get("valid"), "errors=", len(validate.get("errors", [])), "warnings=", len(validate.get("warnings", [])))
if validate.get("errors"):
    print("FIRST_ERROR", validate["errors"][0])

print("CREDENTIALS", post("/api/credentials", payload, auth=True))

for i in range(30):
    time.sleep(10)
    _, s = get("/api/status", auth=True)
    steps = {item["id"]: item["status"] for item in s.get("steps", [])}
    print(f"T+{(i+1)*10}s", steps)

print("DONE")
