#!/usr/bin/env python3
"""
Software Factory Installer — Dashboard Server
Python stdlib only (no pip). Serves the installer UI and runs installation steps.
"""

import http.server
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INSTALLER_DIR = Path(__file__).resolve().parent
STEPS_DIR = INSTALLER_DIR / "steps"
UI_DIR = INSTALLER_DIR / "ui"
CONFIG_DIR = Path.home() / ".software-factory"
CONFIG_FILE = CONFIG_DIR / "config.env"
INSTALLER_ENV = CONFIG_DIR / "installer.env"

PORT = int(os.environ.get("INSTALLER_PORT", 3000))
TOKEN = os.environ.get("SF_SETUP_TOKEN", "")

# ---------------------------------------------------------------------------
# Step definitions
# ---------------------------------------------------------------------------
STEPS_ORDER = [
    "01-system-check",
    "02-dependencies",
    "03-k3s",
    "04-credentials",
    "05-core-services",
    "06-source-repos",
    "07-database",
    "08-platform-api",
    "09-platform-console",
    "10-health-check",
    "11-finalize",
]

STEPS_META = {
    "01-system-check":     {"title": "System Check",       "desc": "OS, RAM, CPU, disk space",          "auto": True},
    "02-dependencies":     {"title": "Dependencies",       "desc": "curl, git, iptables, helm, openssl","auto": True},
    "03-k3s":              {"title": "Kubernetes (K3s)",    "desc": "Lightweight K8s cluster",           "auto": True},
    "04-credentials":      {"title": "Configuration",      "desc": "Networking, Keys & Security Setup", "auto": False},
    "05-core-services":    {"title": "Core Services",      "desc": "Ingress, cert-manager, namespaces", "auto": True},
    "06-source-repos":     {"title": "Source Repos",       "desc": "Create repos, pipelines & Docker images", "auto": True},
    "07-database":         {"title": "Database",           "desc": "MongoDB 7 with persistent storage", "auto": True},
    "08-platform-api":     {"title": "Platform API",       "desc": "nexus-api (FastAPI backend)",       "auto": True},
    "09-platform-console": {"title": "Platform Console",   "desc": "nexus-console (Vue 3 frontend)",    "auto": True},
    "10-health-check":     {"title": "Health Check",       "desc": "Verify all services are running",   "auto": True},
    "11-finalize":         {"title": "Ready!",             "desc": "Platform is ready to use",          "auto": True},
}

# ---------------------------------------------------------------------------
# Global state (thread-safe via lock)
# ---------------------------------------------------------------------------
state_lock = threading.Lock()
steps_state = {}
step_logs = {}       # step_id -> list of log lines
step_queues = {}     # step_id -> Queue for SSE streaming
step_processes = {}  # step_id -> subprocess.Popen
admin_creds = {}     # generated admin credentials

STATE_FILE = CONFIG_DIR / "installer-state.json"


def init_state():
    """Initialize step states."""
    global steps_state, step_logs, step_queues
    for sid in STEPS_ORDER:
        meta = STEPS_META[sid]
        steps_state[sid] = {
            "id": sid,
            "title": meta["title"],
            "desc": meta["desc"],
            "auto": meta["auto"],
            "status": "pending",    # pending | running | done | error | skipped
            "exit_code": None,
            "started_at": None,
            "finished_at": None,
        }
        step_logs[sid] = []
        step_queues[sid] = queue.Queue()


def save_state():
    """Persist step statuses to disk so we can resume after restart."""
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {}
        with state_lock:
            for sid in STEPS_ORDER:
                data[sid] = {
                    "status": steps_state[sid]["status"],
                    "exit_code": steps_state[sid]["exit_code"],
                }
            data["_admin"] = admin_creds.copy()
        STATE_FILE.write_text(json.dumps(data, indent=2))
    except Exception:
        pass  # best-effort persistence


def load_state():
    """Load persisted step states from disk (if any)."""
    global admin_creds
    if not STATE_FILE.exists():
        return False
    try:
        data = json.loads(STATE_FILE.read_text())
        any_progress = False
        for sid in STEPS_ORDER:
            if sid in data:
                saved = data[sid]
                status = saved.get("status", "pending")
                # A step that was running when server died → mark as error
                if status == "running":
                    status = "error"
                steps_state[sid]["status"] = status
                steps_state[sid]["exit_code"] = saved.get("exit_code")
                if status in ("done", "skipped", "error"):
                    any_progress = True
        if "_admin" in data:
            admin_creds.update(data["_admin"])
        return any_progress
    except Exception:
        return False


init_state()
_resumed = load_state()


# ---------------------------------------------------------------------------
# Step execution engine
# ---------------------------------------------------------------------------
def run_step(step_id, env_extra=None):
    """Run a step script in a background thread. Returns immediately."""
    script = STEPS_DIR / f"{step_id}.sh"
    if not script.exists():
        _fail_step(step_id, f"Script not found: {script}")
        return

    with state_lock:
        steps_state[step_id]["status"] = "running"
        steps_state[step_id]["started_at"] = time.time()
        steps_state[step_id]["finished_at"] = None
        steps_state[step_id]["exit_code"] = None
        step_logs[step_id] = []
        step_queues[step_id] = queue.Queue()

    env = {**os.environ}
    env["INSTALLER_DIR"] = str(INSTALLER_DIR)
    env["SF_SETUP_TOKEN"] = TOKEN
    env["TERM"] = "dumb"           # no ANSI cursor control
    env["DEBIAN_FRONTEND"] = "noninteractive"
    if env_extra:
        env.update(env_extra)

    def _worker():
        try:
            proc = subprocess.Popen(
                ["bash", str(script)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                env=env,
                cwd=str(INSTALLER_DIR),
                bufsize=1,
                universal_newlines=True,
            )
            step_processes[step_id] = proc

            for line in proc.stdout:
                line = line.rstrip("\n")
                # Capture admin creds from finalize step
                if step_id == "11-finalize":
                    if line.startswith("=== ADMIN_USER="):
                        admin_creds["user"] = line.split("=", 2)[2].rstrip(" =")
                        continue  # don't show in logs
                    if line.startswith("=== ADMIN_PASS="):
                        admin_creds["pass"] = line.split("=", 2)[2].rstrip(" =")
                        continue
                with state_lock:
                    step_logs[step_id].append(line)
                step_queues[step_id].put({"type": "log", "data": line})

            proc.wait()
            rc = proc.returncode

            with state_lock:
                steps_state[step_id]["exit_code"] = rc
                steps_state[step_id]["finished_at"] = time.time()
                if rc == 0:
                    steps_state[step_id]["status"] = "done"
                else:
                    steps_state[step_id]["status"] = "error"

            save_state()

            step_queues[step_id].put({
                "type": "done",
                "exit_code": rc,
            })

            # Auto-advance: trigger next auto step
            if rc == 0:
                _auto_advance(step_id)

        except Exception as e:
            _fail_step(step_id, str(e))

    t = threading.Thread(target=_worker, daemon=True)
    t.start()


def _fail_step(step_id, message):
    with state_lock:
        steps_state[step_id]["status"] = "error"
        steps_state[step_id]["finished_at"] = time.time()
        step_logs[step_id].append(f"[ERROR] {message}")
    step_queues[step_id].put({"type": "log", "data": f"[ERROR] {message}"})
    step_queues[step_id].put({"type": "done", "exit_code": 1})


def _auto_advance(completed_step_id):
    """After a step completes, start the next auto step."""
    idx = STEPS_ORDER.index(completed_step_id)
    if idx + 1 < len(STEPS_ORDER):
        next_id = STEPS_ORDER[idx + 1]
        with state_lock:
            ns = steps_state[next_id]
        if ns["auto"] and ns["status"] == "pending":
            time.sleep(0.5)  # brief pause for UI to update
            run_step(next_id)


def skip_step(step_id):
    with state_lock:
        steps_state[step_id]["status"] = "skipped"
        steps_state[step_id]["finished_at"] = time.time()
    step_queues[step_id].put({"type": "done", "exit_code": 0})
    save_state()
    _auto_advance(step_id)


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------
class InstallerHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        # Suppress default access logs
        pass

    # --- Routing -----------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path == "/":
            self._serve_ui()
        elif path == "/api/status":
            self._handle_status()
        elif path == "/api/system/info":
            self._handle_system_info()
        elif re.match(r"^/api/steps/[\w-]+/logs$", path):
            step_id = path.split("/")[3]
            self._handle_logs_sse(step_id)
        else:
            self._json_response(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        body = self._read_body()

        if path == "/api/auth":
            self._handle_auth(body)
        elif re.match(r"^/api/steps/[\w-]+/run$", path):
            step_id = path.split("/")[3]
            self._handle_run_step(step_id, body)
        elif re.match(r"^/api/steps/[\w-]+/skip$", path):
            step_id = path.split("/")[3]
            self._handle_skip_step(step_id)
        elif path == "/api/credentials":
            self._handle_credentials(body)
        elif path == "/api/validate-credentials":
            self._handle_validate_credentials(body)
        elif path == "/api/upload-config":
            self._handle_upload_config(body)
        elif path == "/api/clean-install":
            self._handle_clean_install(body)
        elif path == "/api/reset-state":
            self._handle_reset_state(body)
        elif path == "/api/resume":
            self._handle_resume(body)
        elif path == "/api/steps/update-config":
            self._handle_update_config(body)
        else:
            self._json_response(404, {"error": "not found"})

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors_headers()
        self.end_headers()

    # --- Auth --------------------------------------------------------------

    def _check_token(self):
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {TOKEN}":
            return True
        self._json_response(401, {"error": "unauthorized"})
        return False

    def _handle_auth(self, body):
        token = body.get("token", "")
        if token == TOKEN:
            self._json_response(200, {"ok": True, "token": TOKEN})
        else:
            self._json_response(401, {"error": "invalid token"})

    # --- API handlers ------------------------------------------------------

    def _handle_status(self):
        if not self._check_token():
            return
        with state_lock:
            data = {
                "steps": [steps_state[sid] for sid in STEPS_ORDER],
                "admin": admin_creds,
            }
        self._json_response(200, data)

    def _handle_system_info(self):
        if not self._check_token():
            return
        info = _get_system_info()
        self._json_response(200, info)

    def _handle_run_step(self, step_id, body):
        if not self._check_token():
            return
        if step_id not in steps_state:
            self._json_response(404, {"error": f"unknown step: {step_id}"})
            return
        with state_lock:
            st = steps_state[step_id]["status"]
        if st == "running":
            self._json_response(409, {"error": "step already running"})
            return
        env_extra = body.get("env", {})
        run_step(step_id, env_extra)
        self._json_response(200, {"ok": True, "step": step_id})

    def _handle_skip_step(self, step_id):
        if not self._check_token():
            return
        if step_id not in steps_state:
            self._json_response(404, {"error": f"unknown step: {step_id}"})
            return
        skip_step(step_id)
        self._json_response(200, {"ok": True, "step": step_id, "status": "skipped"})

    def _handle_credentials(self, body):
        if not self._check_token():
            return
        argocd_password = (body.get("SF_ARGOCD_PASSWORD") or "").strip()
        vault_token = (body.get("SF_VAULT_TOKEN") or body.get("SF_VAULT_ROOT_TOKEN") or "").strip()
        if not argocd_password:
            self._json_response(400, {"error": "SF_ARGOCD_PASSWORD is required"})
            return
        if not vault_token:
            self._json_response(400, {"error": "SF_VAULT_TOKEN is required"})
            return

        # Save credentials and configuration to env_extra and run step 04
        env_extra = {}
        valid_keys = [
            "SF_MODE", "SF_GIT_PROVIDER", "SF_GIT_USER", "SF_GIT_EMAIL", "SF_GIT_TOKEN", "SF_GIT_WORKSPACE",
            "SF_DOCKER_USER", "SF_DOCKER_USERNAME", "SF_DOCKER_TOKEN",
            "SF_DOMAIN", "SF_TAILSCALE_ENABLED", "SF_TAILSCALE_CLIENT_ID", "SF_TAILSCALE_CLIENT_SECRET",
            "SF_TAILSCALE_DNS_SUFFIX", "SF_TAILSCALE_ACL_TOKEN", "SF_CLOUDFLARE_TUNNEL_TOKEN",
            "SF_CLOUDFLARE_TOKEN", "SF_CLOUDFLARE_ACCOUNT_ID",
            "SF_AWS_ACCESS_KEY", "SF_AWS_SECRET_KEY", "SF_AWS_REGION",
            "SF_ADMIN_USER", "SF_ADMIN_PASSWORD", "SF_ADMIN_PASS", "SF_ARGOCD_PASSWORD",
            "SF_VAULT_TOKEN", "SF_VAULT_ROOT_TOKEN"
        ]
        for key in valid_keys:
            if key in body:
                env_extra[key] = body[key]
        run_step("04-credentials", env_extra)
        self._json_response(200, {"ok": True})

    def _handle_upload_config(self, body):
        """Parse a .env file content and return extracted key-value pairs for the UI to prefill."""
        if not self._check_token():
            return
        content = body.get("content", "")
        if not content:
            self._json_response(400, {"error": "No content provided"})
            return

        parsed = {}
        # Map common key variants to our SF_ keys
        key_map = {
            # Direct SF_ keys
            "SF_DOMAIN": "SF_DOMAIN",
            "SF_GIT_PROVIDER": "SF_GIT_PROVIDER",
            "SF_GIT_USER": "SF_GIT_USER",
            "SF_GIT_USERNAME": "SF_GIT_USER",
            "SF_GIT_EMAIL": "SF_GIT_EMAIL",
            "SF_GIT_TOKEN": "SF_GIT_TOKEN",
            "SF_GIT_WORKSPACE": "SF_GIT_WORKSPACE",
            "SF_BITBUCKET_WORKSPACE": "SF_GIT_WORKSPACE",
            "SF_DOCKER_USER": "SF_DOCKER_USER",
            "SF_DOCKER_USERNAME": "SF_DOCKER_USER",
            "SF_DOCKER_TOKEN": "SF_DOCKER_TOKEN",
            "SF_TAILSCALE_ENABLED": "SF_TAILSCALE_ENABLED",
            "SF_TAILSCALE_CLIENT_ID": "SF_TAILSCALE_CLIENT_ID",
            "SF_TAILSCALE_CLIENT_SECRET": "SF_TAILSCALE_CLIENT_SECRET",
            "SF_TAILSCALE_DNS_SUFFIX": "SF_TAILSCALE_DNS_SUFFIX",
            "SF_TAILSCALE_ACL_TOKEN": "SF_TAILSCALE_ACL_TOKEN",
            "SF_CLOUDFLARE_TUNNEL_TOKEN": "SF_CLOUDFLARE_TUNNEL_TOKEN",
            "SF_AWS_ACCESS_KEY": "SF_AWS_ACCESS_KEY",
            "SF_AWS_SECRET_KEY": "SF_AWS_SECRET_KEY",
            "SF_AWS_REGION": "SF_AWS_REGION",
            "SF_ADMIN_USER": "SF_ADMIN_USER",
            "SF_ADMIN_PASSWORD": "SF_ADMIN_PASSWORD",
            "SF_ARGOCD_PASSWORD": "SF_ARGOCD_PASSWORD",
            "SF_VAULT_TOKEN": "SF_VAULT_TOKEN",
            "SF_VAULT_ROOT_TOKEN": "SF_VAULT_TOKEN",
            # Terraform-style keys (from terraform.tfvars format)
            "git_username": "SF_GIT_USER",
            "git_token": "SF_GIT_TOKEN",
            "bitbucket_email": "SF_GIT_EMAIL",
            "bitbucket_workspace": "SF_GIT_WORKSPACE",
            "docker_username": "SF_DOCKER_USER",
            "docker_token": "SF_DOCKER_TOKEN",
            "domain_name": "SF_DOMAIN",
            "aws_access_key": "SF_AWS_ACCESS_KEY",
            "aws_secret_key": "SF_AWS_SECRET_KEY",
            "aws_region": "SF_AWS_REGION",
            "tailscale_client_id": "SF_TAILSCALE_CLIENT_ID",
            "tailscale_client_secret": "SF_TAILSCALE_CLIENT_SECRET",
            "tailscale_dns_suffix": "SF_TAILSCALE_DNS_SUFFIX",
            "tailscale_acl_token": "SF_TAILSCALE_ACL_TOKEN",
            "argocd_admin_password": "SF_ARGOCD_PASSWORD",
            "vault_init_token": "SF_VAULT_TOKEN",
            "vault_token": "SF_VAULT_TOKEN",
            "nexus_admin_user": "SF_ADMIN_USER",
            "nexus_admin_password": "SF_ADMIN_PASSWORD",
            # Contabo-style keys
            "CONTABO_DOCKER_USERNAME": "SF_DOCKER_USER",
            "CONTABO_DOCKER_TOKEN": "SF_DOCKER_TOKEN",
            "CONTABO_BITBUCKET_WORKSPACE": "SF_GIT_WORKSPACE",
            "CONTABO_BITBUCKET_EMAIL": "SF_GIT_EMAIL",
            "CONTABO_DOMAIN": "SF_DOMAIN",
        }

        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Handle both KEY=VALUE and KEY = "VALUE" formats
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*["\']?([^"\'#]*)["\']?', line)
            if m:
                raw_key = m.group(1).strip()
                raw_val = m.group(2).strip()
                sf_key = key_map.get(raw_key)
                if sf_key and raw_val:
                    parsed[sf_key] = raw_val

        # Auto-detect: if we got Tailscale creds, enable it
        if parsed.get("SF_TAILSCALE_CLIENT_ID") and parsed.get("SF_TAILSCALE_CLIENT_SECRET"):
            parsed["SF_TAILSCALE_ENABLED"] = "true"

        # Auto-detect git provider from workspace
        if parsed.get("SF_GIT_WORKSPACE") and "SF_GIT_PROVIDER" not in parsed:
            parsed["SF_GIT_PROVIDER"] = "bitbucket"

        self._json_response(200, {"ok": True, "config": parsed, "keys_found": len(parsed)})

    def _handle_clean_install(self, body):
        """Wipe everything and reset installer state for a fresh install."""
        if not self._check_token():
            return
        confirm = body.get("confirm", False)
        delete_remote_repos = bool(body.get("delete_remote_repos", False))
        delete_cloudflare_tunnel = bool(body.get("delete_cloudflare_tunnel", True))
        if not confirm:
            self._json_response(400, {"error": "Must confirm clean install"})
            return

        # Reset all step states
        init_state()

        # Run the clean install script
        script = STEPS_DIR / "00-clean-install.sh"
        if not script.exists():
            self._json_response(500, {"error": "Clean install script not found"})
            return

        # Use a synthetic step ID for tracking
        clean_id = "00-clean-install"
        with state_lock:
            steps_state[clean_id] = {
                "id": clean_id,
                "title": "Clean Install",
                "desc": "Wiping everything for fresh install",
                "auto": False,
                "status": "running",
                "exit_code": None,
                "started_at": time.time(),
                "finished_at": None,
            }
            step_logs[clean_id] = []
            step_queues[clean_id] = queue.Queue()

        def _clean_worker():
            try:
                env = {**os.environ}
                env["INSTALLER_DIR"] = str(INSTALLER_DIR)
                env["TERM"] = "dumb"
                env["DEBIAN_FRONTEND"] = "noninteractive"
                env["SF_CLEAN_DELETE_REMOTE_REPOS"] = "true" if delete_remote_repos else "false"
                env["SF_CLEAN_DELETE_CLOUDFLARE_TUNNEL"] = "true" if delete_cloudflare_tunnel else "false"
                proc = subprocess.Popen(
                    ["bash", str(script)],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL, env=env,
                    cwd=str(INSTALLER_DIR), bufsize=1, universal_newlines=True,
                )
                for line in proc.stdout:
                    line = line.rstrip("\n")
                    with state_lock:
                        step_logs[clean_id].append(line)
                    step_queues[clean_id].put({"type": "log", "data": line})
                proc.wait()
                rc = proc.returncode
                with state_lock:
                    steps_state[clean_id]["exit_code"] = rc
                    steps_state[clean_id]["finished_at"] = time.time()
                    steps_state[clean_id]["status"] = "done" if rc == 0 else "error"
                step_queues[clean_id].put({"type": "done", "exit_code": rc})
                # After clean, re-initialize normal step states
                if rc == 0:
                    time.sleep(0.5)
                    init_state()
                    save_state()
            except Exception as e:
                with state_lock:
                    steps_state[clean_id]["status"] = "error"
                    step_logs[clean_id].append(f"[ERROR] {e}")
                step_queues[clean_id].put({"type": "done", "exit_code": 1})

        t = threading.Thread(target=_clean_worker, daemon=True)
        t.start()
        self._json_response(200, {"ok": True, "step": clean_id})

    def _handle_reset_state(self, body):
        """Reset all step states to pending (does NOT wipe K3s or data)."""
        if not self._check_token():
            return
        if not body.get("confirm"):
            self._json_response(400, {"error": "Must confirm reset"})
            return
        init_state()
        save_state()
        self._json_response(200, {"ok": True, "message": "All steps reset to pending"})

    def _handle_resume(self, body):
        """Resume installation from first error/pending step after last done step."""
        if not self._check_token():
            return

        # Find first step that isn't done/skipped
        resume_from = None
        for sid in STEPS_ORDER:
            with state_lock:
                st = steps_state[sid]["status"]
            if st in ("error", "pending"):
                resume_from = sid
                break

        if resume_from is None:
            self._json_response(200, {"ok": True, "message": "All steps completed", "step": None})
            return

        # If it's the credentials step, don't auto-run — user needs to fill the form
        if resume_from == "04-credentials":
            self._json_response(200, {"ok": True, "message": "Awaiting credentials", "step": resume_from})
            return

        # Run the step
        run_step(resume_from)
        self._json_response(200, {"ok": True, "step": resume_from, "message": f"Resuming from {resume_from}"})

    def _handle_update_config(self, body):
        """Update specific config values in config.env without re-running credentials step."""
        if not self._check_token():
            return
        updates = body.get("updates", {})
        if not updates:
            self._json_response(400, {"error": "No updates provided"})
            return

        config_file = CONFIG_DIR / "config.env"
        if not config_file.exists():
            self._json_response(400, {"error": "config.env not found — run credentials step first"})
            return

        content = config_file.read_text()
        for key, value in updates.items():
            # Only allow known config keys
            if not key.startswith("SF_"):
                continue
            # Replace existing line or append
            import re as re_mod
            pattern = rf'^{re_mod.escape(key)}=.*$'
            if re_mod.search(pattern, content, re_mod.MULTILINE):
                content = re_mod.sub(pattern, f'{key}={value}', content, flags=re_mod.MULTILINE)
            else:
                content += f'\n{key}={value}\n'

        config_file.write_text(content)
        self._json_response(200, {"ok": True, "message": f"Updated {len(updates)} config value(s)"})

    def _handle_validate_credentials(self, body):
        """Validate credentials BEFORE saving — checks Docker Hub repos and Git access."""
        if not self._check_token():
            return

        errors = []
        warnings = []

        # --- Required field checks ---
        docker_user = (body.get("SF_DOCKER_USER") or "").strip()
        docker_token = (body.get("SF_DOCKER_TOKEN") or "").strip()
        git_user = (body.get("SF_GIT_USER") or "").strip()
        git_email = (body.get("SF_GIT_EMAIL") or "").strip()
        git_token = (body.get("SF_GIT_TOKEN") or "").strip()
        git_provider = (body.get("SF_GIT_PROVIDER") or "").strip()
        git_workspace = (body.get("SF_GIT_WORKSPACE") or "").strip()
        domain = (body.get("SF_DOMAIN") or "").strip()
        ts_enabled = (body.get("SF_TAILSCALE_ENABLED") or "").strip().lower() in ("true", "1", "yes")
        ts_client_id = (body.get("SF_TAILSCALE_CLIENT_ID") or "").strip()
        ts_client_secret = (body.get("SF_TAILSCALE_CLIENT_SECRET") or "").strip()
        ts_acl_token = (body.get("SF_TAILSCALE_ACL_TOKEN") or "").strip()
        admin_password = (body.get("SF_ADMIN_PASSWORD") or body.get("SF_ADMIN_PASS") or "").strip()
        argocd_password = (body.get("SF_ARGOCD_PASSWORD") or "").strip()
        vault_token = (body.get("SF_VAULT_TOKEN") or body.get("SF_VAULT_ROOT_TOKEN") or "").strip()

        # Core control plane secrets are required so post-install does not end in partial configuration.
        if not admin_password:
            errors.append({"field": "SF_ADMIN_PASSWORD", "msg": "Admin password is required"})
        if not argocd_password:
            errors.append({"field": "SF_ARGOCD_PASSWORD", "msg": "ArgoCD admin password is required"})
        if not vault_token:
            errors.append({"field": "SF_VAULT_TOKEN", "msg": "Vault token is required"})

        if not domain:
            errors.append({"field": "SF_DOMAIN", "msg": "Domain is required"})

        # --- Tailscale is mandatory ---
        if not ts_enabled:
            errors.append({"field": "SF_TAILSCALE_ENABLED", "msg": "Tailscale VPN is required — it provides secure cluster networking and hybrid cloud connectivity"})
        if ts_enabled and not ts_client_id:
            errors.append({"field": "SF_TAILSCALE_CLIENT_ID", "msg": "Tailscale OAuth Client ID is required"})
        if ts_enabled and not ts_client_secret:
            errors.append({"field": "SF_TAILSCALE_CLIENT_SECRET", "msg": "Tailscale OAuth Client Secret is required"})
        if ts_enabled and not ts_acl_token:
            errors.append({"field": "SF_TAILSCALE_ACL_TOKEN", "msg": "Tailscale ACL Admin Token is required for automatic tag policy fixes (tagOwners)"})

        if ts_acl_token and not (ts_acl_token.startswith("tskey-api-") or ts_acl_token.startswith("tskey-auth-")):
            warnings.append({"field": "SF_TAILSCALE_ACL_TOKEN", "msg": "Tailscale ACL token format looks unusual (expected tskey-api-* or tskey-auth-*)"})

        # Validate Tailscale OAuth if provided
        if ts_client_id and ts_client_secret:
            import urllib.request
            import urllib.error
            try:
                ts_body = f"client_id={ts_client_id}&client_secret={ts_client_secret}&grant_type=client_credentials".encode()
                req = urllib.request.Request("https://api.tailscale.com/api/v2/oauth/token", data=ts_body, method="POST")
                req.add_header("Content-Type", "application/x-www-form-urlencoded")
                req.add_header("User-Agent", "SF-Installer/1.0")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    pass  # 200 = OAuth OK
            except urllib.error.HTTPError as e:
                errors.append({"field": "SF_TAILSCALE_CLIENT_ID", "msg": f"Tailscale OAuth failed (HTTP {e.code}) — verify your Client ID and Secret"})
            except Exception:
                warnings.append({"field": "SF_TAILSCALE_CLIENT_ID", "msg": "Could not reach Tailscale API to verify credentials"})

        # --- Docker Hub validation ---
        if not docker_user:
            errors.append({"field": "SF_DOCKER_USER", "msg": "Docker Hub username is required"})
        if not docker_token:
            errors.append({"field": "SF_DOCKER_TOKEN", "msg": "Docker Hub token is required"})

        if docker_user and docker_token:
            # Check if Docker Hub user exists and repos are available
            # NOTE: Repos not existing is a WARNING (installer will create them),
            #       only auth failure is a blocking ERROR.
            import urllib.request
            import urllib.error

            for repo_name in ["nexus-api", "nexus-console"]:
                url = f"https://hub.docker.com/v2/repositories/{docker_user}/{repo_name}/tags/?page_size=1"
                try:
                    req = urllib.request.Request(url, method="GET")
                    req.add_header("User-Agent", "SF-Installer/1.0")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        data = json.loads(resp.read())
                        count = data.get("count", 0)
                        if count == 0:
                            warnings.append({
                                "field": "SF_DOCKER_USER",
                                "msg": f"Repository '{docker_user}/{repo_name}' exists but has no tags — first pipeline build will create them"
                            })
                except urllib.error.HTTPError as e:
                    if e.code == 404:
                        warnings.append({
                            "field": "SF_DOCKER_USER",
                            "msg": f"Repository '{docker_user}/{repo_name}' not found on Docker Hub — it will be created by the first pipeline build"
                        })
                    else:
                        warnings.append({
                            "field": "SF_DOCKER_USER",
                            "msg": f"Could not verify '{docker_user}/{repo_name}' (HTTP {e.code})"
                        })
                except Exception as e:
                    warnings.append({
                        "field": "SF_DOCKER_USER",
                        "msg": f"Could not reach Docker Hub to verify '{repo_name}': {str(e)[:80]}"
                    })

            # Validate Docker Hub auth (login test)
            try:
                login_url = "https://hub.docker.com/v2/users/login/"
                login_body = json.dumps({"username": docker_user, "password": docker_token}).encode()
                req = urllib.request.Request(login_url, data=login_body, method="POST")
                req.add_header("Content-Type", "application/json")
                req.add_header("User-Agent", "SF-Installer/1.0")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    pass  # 200 = auth OK
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    errors.append({
                        "field": "SF_DOCKER_TOKEN",
                        "msg": "Docker Hub authentication failed — check your username and token"
                    })
                else:
                    warnings.append({
                        "field": "SF_DOCKER_TOKEN",
                        "msg": f"Could not verify Docker Hub login (HTTP {e.code})"
                    })
            except Exception:
                warnings.append({
                    "field": "SF_DOCKER_TOKEN",
                    "msg": "Could not reach Docker Hub to verify credentials"
                })

        # --- Git provider validation ---
        if not git_user:
            errors.append({"field": "SF_GIT_USER", "msg": "Git username is required"})
        if not git_token:
            errors.append({"field": "SF_GIT_TOKEN", "msg": "Git access token is required"})

        if git_provider == "bitbucket":
            if not git_workspace:
                errors.append({"field": "SF_GIT_WORKSPACE", "msg": "Bitbucket workspace is required"})
            if not git_email:
                errors.append({"field": "SF_GIT_EMAIL", "msg": "Bitbucket email is required (API uses email:app_password for auth)"})

            if git_token and git_workspace and git_email:
                # Test Bitbucket API access using email:app_password (Bitbucket requirement)
                import urllib.request
                import urllib.error
                import base64
                bb_auth_ok = False
                bb_workspace_ok = False
                bb_last_error = None

                # Bitbucket API auth = email:app_password
                try:
                    bb_url = f"https://api.bitbucket.org/2.0/repositories/{git_workspace}?page=1&pagelen=1"
                    auth_str = base64.b64encode(f"{git_email}:{git_token}".encode()).decode()
                    req = urllib.request.Request(bb_url, method="GET")
                    req.add_header("Authorization", f"Basic {auth_str}")
                    req.add_header("User-Agent", "SF-Installer/1.0")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        bb_auth_ok = True
                        bb_workspace_ok = True
                except urllib.error.HTTPError as e:
                    bb_last_error = e.code
                    if e.code == 404:
                        bb_auth_ok = True  # Auth worked but workspace not found
                except Exception:
                    pass

                if not bb_auth_ok:
                    if bb_last_error in (401, 403):
                        errors.append({
                            "field": "SF_GIT_TOKEN",
                            "msg": f"Bitbucket authentication failed — verify your email ('{git_email}') and app password are correct"
                        })
                    else:
                        warnings.append({
                            "field": "SF_GIT_TOKEN",
                            "msg": f"Could not verify Bitbucket access (HTTP {bb_last_error})"
                        })
                elif not bb_workspace_ok:
                    warnings.append({
                        "field": "SF_GIT_WORKSPACE",
                        "msg": f"Bitbucket workspace '{git_workspace}' not found — it will be created during installation"
                    })

        elif git_provider == "github" and git_user and git_token:
            import urllib.request
            import urllib.error
            try:
                gh_url = "https://api.github.com/user"
                req = urllib.request.Request(gh_url, method="GET")
                req.add_header("Authorization", f"Bearer {git_token}")
                req.add_header("User-Agent", "SF-Installer/1.0")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    pass
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    errors.append({
                        "field": "SF_GIT_TOKEN",
                        "msg": "GitHub authentication failed — check your token"
                    })
            except Exception:
                warnings.append({"field": "SF_GIT_TOKEN", "msg": "Could not reach GitHub API"})

        cf_token = (body.get("SF_CLOUDFLARE_TOKEN") or body.get("SF_CLOUDFLARE_TUNNEL_TOKEN") or "").strip()
        cf_account_id = (body.get("SF_CLOUDFLARE_ACCOUNT_ID") or "").strip()

        # --- Cloudflare validation (required if token provided) ---
        if cf_token:
            import urllib.request
            import urllib.error
            cf_valid = False
            if cf_account_id:
                # 1) Check account access (requires Account Settings: Read)
                try:
                    cf_url = f"https://api.cloudflare.com/client/v4/accounts/{cf_account_id}"
                    req = urllib.request.Request(cf_url, method="GET")
                    req.add_header("Authorization", f"Bearer {cf_token}")
                    req.add_header("Content-Type", "application/json")
                    req.add_header("User-Agent", "SF-Installer/1.0")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        data = json.loads(resp.read())
                        if data.get("success"):
                            cf_valid = True
                except urllib.error.HTTPError as e:
                    if e.code in (400, 403):
                        # Fallback: try zone list (works for scoped tokens)
                        try:
                            zone_url = "https://api.cloudflare.com/client/v4/zones?per_page=1"
                            req2 = urllib.request.Request(zone_url, method="GET")
                            req2.add_header("Authorization", f"Bearer {cf_token}")
                            req2.add_header("Content-Type", "application/json")
                            req2.add_header("User-Agent", "SF-Installer/1.0")
                            with urllib.request.urlopen(req2, timeout=10) as resp2:
                                data2 = json.loads(resp2.read())
                                if data2.get("success"):
                                    cf_valid = True
                                    warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                                     "msg": "Account-level verify blocked by scope (OK for scoped tokens)"})
                        except Exception:
                            errors.append({"field": "SF_CLOUDFLARE_TOKEN",
                                           "msg": "Cloudflare authentication failed — check your API token and Account ID"})
                    else:
                        errors.append({"field": "SF_CLOUDFLARE_TOKEN",
                                       "msg": f"Cloudflare API error (HTTP {e.code}) — check token permissions"})
                except Exception:
                    warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                     "msg": "Could not reach Cloudflare API to validate token"})

                # 2) Check tunnel permission (required for auto-tunnel creation)
                if cf_valid:
                    try:
                        tun_url = f"https://api.cloudflare.com/client/v4/accounts/{cf_account_id}/cfd_tunnel?is_deleted=false&per_page=1"
                        req_t = urllib.request.Request(tun_url, method="GET")
                        req_t.add_header("Authorization", f"Bearer {cf_token}")
                        req_t.add_header("Content-Type", "application/json")
                        req_t.add_header("User-Agent", "SF-Installer/1.0")
                        with urllib.request.urlopen(req_t, timeout=10) as resp_t:
                            data_t = json.loads(resp_t.read())
                            if data_t.get("success"):
                                tunnel_count = len(data_t.get("result", []))
                                if tunnel_count > 0:
                                    warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                                     "msg": f"Tunnel access OK — found {tunnel_count} existing tunnel(s). Stale ones will be cleaned up during install."})
                            else:
                                warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                                 "msg": "Tunnel API accessible but returned no success flag"})
                    except urllib.error.HTTPError as e:
                        if e.code in (403, 401):
                            errors.append({"field": "SF_CLOUDFLARE_TOKEN",
                                           "msg": "Token lacks Cloudflare Tunnel permission — add 'Account > Cloudflare Tunnel: Edit' to your API token"})
                            cf_valid = False
                        else:
                            warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                             "msg": f"Tunnel permission check returned HTTP {e.code}"})
                    except Exception:
                        warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                         "msg": "Could not verify tunnel permissions (non-blocking)"})

                # 3) Check DNS permission (required for DNS record creation)
                if cf_valid:
                    try:
                        dns_url = "https://api.cloudflare.com/client/v4/zones?per_page=5"
                        req_d = urllib.request.Request(dns_url, method="GET")
                        req_d.add_header("Authorization", f"Bearer {cf_token}")
                        req_d.add_header("Content-Type", "application/json")
                        req_d.add_header("User-Agent", "SF-Installer/1.0")
                        with urllib.request.urlopen(req_d, timeout=10) as resp_d:
                            data_d = json.loads(resp_d.read())
                            if data_d.get("success"):
                                zone_names = [z.get("name", "?") for z in data_d.get("result", [])]
                                if zone_names:
                                    warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                                     "msg": f"DNS access OK — zones: {', '.join(zone_names[:3])}"})
                    except urllib.error.HTTPError as e:
                        if e.code in (403, 401):
                            warnings.append({"field": "SF_CLOUDFLARE_TOKEN",
                                             "msg": "Token may lack DNS permissions — add 'Zone > DNS: Edit' to your API token"})
                    except Exception:
                        pass
            else:
                errors.append({"field": "SF_CLOUDFLARE_ACCOUNT_ID",
                               "msg": "Cloudflare Account ID is required when providing a Cloudflare token"})

        result = {
            "valid": len(errors) == 0,
            "errors": errors,
            "warnings": warnings,
        }
        self._json_response(200, result)

    def _handle_logs_sse(self, step_id):
        if step_id not in steps_state:
            self._json_response(404, {"error": f"unknown step: {step_id}"})
            return
        # Check token from query string
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        t = qs.get("token", [""])[0]
        if t != TOKEN:
            self._json_response(401, {"error": "unauthorized"})
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self._cors_headers()
        self.end_headers()

        q = step_queues.get(step_id)
        if not q:
            return

        # First, send any existing logs (history)
        with state_lock:
            history = list(step_logs.get(step_id, []))
            current_status = steps_state[step_id]["status"]
        for line in history:
            self._sse_write({"type": "log", "data": line})
        if current_status in ("done", "error", "skipped"):
            self._sse_write({"type": "done", "exit_code": steps_state[step_id].get("exit_code", 0)})
            return

        # Then stream new logs
        while True:
            try:
                msg = q.get(timeout=2)
                self._sse_write(msg)
                if msg.get("type") == "done":
                    break
            except queue.Empty:
                # Send keepalive comment
                try:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    break

    # --- UI ----------------------------------------------------------------

    def _serve_ui(self):
        index = UI_DIR / "index.html"
        if not index.exists():
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"UI not found. Check installer/ui/index.html")
            return
        content = index.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    # --- Helpers -----------------------------------------------------------

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def _json_response(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")

    def _sse_write(self, data):
        try:
            payload = json.dumps(data)
            self.wfile.write(f"data: {payload}\n\n".encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


# ---------------------------------------------------------------------------
# System info helper
# ---------------------------------------------------------------------------
def _get_system_info():
    info = {"os": "unknown", "ram_gb": 0, "cpus": 0, "disk_gb": 0, "wsl": False}
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    info["os"] = line.split("=", 1)[1].strip().strip('"')
    except FileNotFoundError:
        pass
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    info["ram_gb"] = round(kb / 1024 / 1024, 1)
    except FileNotFoundError:
        pass
    try:
        info["cpus"] = os.cpu_count() or 0
    except Exception:
        pass
    try:
        st = os.statvfs("/")
        info["disk_gb"] = round(st.f_bavail * st.f_frsize / 1024 / 1024 / 1024, 1)
    except Exception:
        pass
    try:
        with open("/proc/version") as f:
            if "microsoft" in f.read().lower():
                info["wsl"] = True
    except FileNotFoundError:
        pass
    return info


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a new thread for SSE support."""
    allow_reuse_address = True

    def process_request(self, request, client_address):
        t = threading.Thread(target=self._handle, args=(request, client_address))
        t.daemon = True
        t.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


def main():
    global TOKEN
    # Load token from env file if not set
    if not TOKEN and INSTALLER_ENV.exists():
        for line in INSTALLER_ENV.read_text().splitlines():
            if line.startswith("SF_SETUP_TOKEN="):
                TOKEN = line.split("=", 1)[1].strip()

    if not TOKEN:
        TOKEN = "dev-token"
        print(f"[WARN] No setup token found, using: {TOKEN}")

    server = ThreadedHTTPServer(("0.0.0.0", PORT), InstallerHandler)

    def shutdown_handler(sig, frame):
        print("\n[INFO] Shutting down installer dashboard...")
        # Kill any running step processes
        for proc in step_processes.values():
            try:
                proc.terminate()
            except Exception:
                pass
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    print(f"[INFO] Installer dashboard running on http://localhost:{PORT}")
    print(f"[INFO] Token: {TOKEN}")
    server.serve_forever()


if __name__ == "__main__":
    main()
