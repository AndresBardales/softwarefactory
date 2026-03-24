# SOF-36 Root-Cause Fix + Full Reinstall + E2E Validation (v2)

## Prompt ID
`SOF-36-root-cause-fix-and-reinstall-v2`
Version: 2 | Date: 2026-03-22 | Author: sf.orchestrator@kanbaal.dev

---

## Problem Statement

SOF-2 (Vue+FastAPI exposure combos) and SOF-12 (Database templates) keep breaking after every clean
VPS reinstall. The pattern is always the same:

1. Nuclear VPS wipe + fresh install → platform comes up healthy
2. App deployment → fails (npm not available / empty scaffold / ImagePullBackOff / nginx upstream wrong)
3. Multiple manual fix iterations to patch the cluster
4. Next clean reinstall → same failures reappear

**Root cause hypothesis** (from previous runs):
- `kaanbal-templates.tar.gz` inside the installer package does not contain complete scaffold content
  (Dockerfiles, actual app source, CI/CD workflows are empty/missing after `package.sh` runs)
- `infra-gitops` dev overlay for `kaanbal-console` has nginx upstream `kaanbal-api` (prod name)
  instead of `kaanbal-api-dev` (dev name) — reappears on every fresh push
- Dev namespace apps get `ImagePullBackOff` because no CI/CD images exist yet on fresh install —
  this is expected but the installer has no mechanism to defer dev-overlay health checks

**Objective**: Find ALL root causes, fix them in source (not just cluster patches), do one clean
reinstall, validate everything end-to-end with interconnected apps, then leave the cluster pristine.

---

## Jira Context

- **Primary ticket**: SOF-36
- **Related**: SOF-2 (exposure combos), SOF-12 (database templates), SOF-1 (parent epic)
- **Project**: SOF (Cloud ID: `537b033e-4b1a-4cd4-843f-61057f49a3a9`)
- **Jira site**: `futurefarms.atlassian.net`

## Jira Agent Identities (read tokens from `_private/SETUP-CREDENTIALS.txt`)

Each role writes to Jira using its own account token:
- `sf.orchestrator@kanbaal.dev` → orchestrator / lead / product-analyst
- `sf.builder@kanbaal.dev` → installer-owner / template-repo-auditor / implementation-owner
- `sf.runtime@kanbaal.dev` → deploy-runtime-owner / runtime-path-reviewer
- `sf.validation@kanbaal.dev` → e2e-validator / validation-owner
- `sf.riskqa@kanbaal.dev` → risk-reviewer / qa-skeptic

---

## Critical Safety Rules

1. Execute ONLY for DEV assets explicitly listed in the allowlists below.
2. NEVER touch: `kaanbal-api`, `kaanbal-console`, `infra-gitops`, `kaanbal-templates`,
   `softwarefactory` platform repos — only push **fixes** to them.
3. NEVER print raw credentials in logs or Jira comments.
4. Store ALL ad-hoc scripts under `.agent/lab/sof-36/`.
5. If scope is ambiguous → post Jira comment asking for clarification → stop.
6. Max 3 fix iterations per root cause. If still failing → document as blocker and continue.

---

## Infrastructure Access

| Resource | Value |
|----------|-------|
| DEV VPS IP | `161.97.112.80` |
| SSH key | `_private/keys/contabo-rescue` |
| SSH user | `root` |
| Installer API | `http://localhost:3000` (or `http://161.97.112.80:3000` from local) |
| Platform API | `http://localhost:30081` (NodePort on VPS) |
| Platform Console | `http://localhost:30080` (NodePort on VPS) |
| Domain | `automation.com.mx` |

---

## Cleanup Allowlists (DEV ONLY — NEVER exceed these)

**GitHub repos** (andresbardaleswork-cyber) that MAY be deleted:
```
e2e-vue, e2e-api, e2e-mongo, e2e-mysql, e2e-postgres, e2e-fullstack,
test1, testapi, pame, vuem, e2e-vue3, e2e-fastapi
```

**Docker Hub** (andresbardaleswork) repos/tags that MAY be deleted:
```
e2e-vue, e2e-api, e2e-mongo, e2e-mysql, e2e-postgres, e2e-fullstack,
test1, testapi, pame, vuem, e2e-vue3, e2e-fastapi
```

**Tailscale** nodes/routes matching these patterns MAY be removed:
```
kaanbal-*, automation-com-mx-*, e2e-*, software-factory-*
```
(use Tailscale ACL API, filter by hostname prefix only)

**NEVER delete**: `kaanbal-api`, `kaanbal-console`, `infra-gitops`,
`kaanbal-templates`, `softwarefactory` repos.

---

## Mandatory Workflow (follow in strict order)

### PHASE 0 — Context + Diagnostic (sf.orchestrator + sf.builder + sf.runtime in parallel)

> Move SOF-36 to `In Progress` (transition ID: 31) using sf.orchestrator Jira token.

Run these 4 audits **in parallel** before touching anything:

#### Audit A — Installer Package Integrity (sf.builder)
1. Read `softwarefactory/installer/steps/06-source-repos.sh`
2. Read `softwarefactory/package.sh` (if it exists)
3. Inspect what's inside `installer/templates/kaanbal-templates.tar.gz`:
   ```bash
   tar -tzf installer/templates/kaanbal-templates.tar.gz | head -100
   ```
4. Inspect `installer/templates/infra-gitops.tar.gz` for dev overlay nginx config:
   ```bash
   tar -tzf installer/templates/infra-gitops.tar.gz | grep -i nginx
   tar -xzf installer/templates/infra-gitops.tar.gz -O \
     "*/apps/kaanbal-console/overlays/dev/nginx.conf" 2>/dev/null || \
   tar -xzf installer/templates/infra-gitops.tar.gz --wildcards \
     "*/overlays/dev/*nginx*" -O 2>/dev/null || echo "NOT FOUND"
   ```
5. Determine: Does `kaanbal-templates.tar.gz` contain scaffold source code
   (Dockerfiles, app source, `.github/workflows`) or only metadata?
6. Report: exact list of missing vs present files per template type

#### Audit B — Runtime Deployer Expectations (sf.runtime)
1. Read `kaanbal-api/app/services/app_deployer.py` (full file)
2. Read `kaanbal-api/app/services/template_spec.py` (if it exists)
3. Read `kaanbal-templates/catalog.json`
4. Read `kaanbal-templates/manifest.json` (if present)
5. Determine:
   - What exact paths does `app_deployer.py` expect in the kaanbal-templates repo at runtime?
   - Does it clone kaanbal-templates at deploy time? From which repo/branch?
   - What happens when scaffold source is empty: silent fail or error?
   - What is the infra-gitops dev overlay upstream service name for kaanbal-console?
6. Report: exact deployer contract vs what installer actually provides

#### Audit C — Previous Session Findings (sf.orchestrator)
1. Check if `.agent/sessions/2026-03-22.md` exists and read it
2. Read the last 5 Jira comments on SOF-36 via Jira MCP
3. Read SOF-2 and SOF-12 acceptance criteria from Jira
4. Identify which specific fixes were applied in previous iterations and whether they
   were cluster-only patches (not in source) or actual code commits
5. Report: what's been tried, what worked, what regressed on reinstall

#### Audit D — Current Cluster + External State Snapshot (sf.runtime)
SSH to VPS and capture before-state:
```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  echo '=== K8S PODS ==='; kubectl get pods -A --no-headers 2>/dev/null || echo 'K3s not running'
  echo '=== ARGOCD APPS ==='; kubectl -n argocd get applications --no-headers 2>/dev/null || true
  echo '=== INSTALLER STATUS ==='; curl -sf -H 'Authorization: Bearer da9289283200ebb064b66218' \
    http://localhost:3000/api/status 2>/dev/null | python3 -c 'import sys,json; [print(f\"{s[\"id\"]:30} {s[\"status\"]}\") for s in json.load(sys.stdin).get(\"steps\",[])]' 2>/dev/null || echo 'installer not running'
"
```

Also capture GitHub repos (via API) and Tailscale nodes (via API) in the allowlist scope.

**Before posting parallel audit results**: Each auditor posts their finding as a Jira comment
on SOF-36 using their respective role token. Format: `[AUDIT-<X>] <role>\n<findings>`.

---

### PHASE 1 — Root Cause Synthesis + Fix Plan (sf.orchestrator leads, sf.riskqa challenges)

After all 4 audits complete:

1. **sf.orchestrator synthesizes**:
   - List every root cause found (not symptoms — root causes)
   - For each root cause: which file/line must change, who owns it (installer/templates/deployer)
   - Priority: P1 = breaks fresh reinstall | P2 = breaks after first deploy | P3 = cosmetic
   - Propose minimal change set

2. **sf.riskqa challenges**:
   - For each proposed fix: could this break prod? Does it handle edge cases?
   - Are there circular dependencies? (e.g., fixing deployer but installer still ships wrong templates)
   - Post risk assessment as Jira comment on SOF-36

3. **Agree on fix plan** before implementing. If risks are unresolvable → mark ticket Blocked.

---

### PHASE 2 — Fix Implementation (sf.builder implements, sf.runtime verifies)

For each P1 root cause, implement the fix in order:

#### Fix Priority Order:
1. **Installer template content** (if scaffold dirs are empty in `kaanbal-templates.tar.gz`):
   - If `package.sh` is excluding template scaffold dirs → fix the exclusion rule
   - If `kaanbal-templates/` local workspace has empty scaffold dirs → populate them from
     the actual template files in `kaanbal-templates/vue3-spa/`, `kaanbal-templates/fastapi-api/`,
     `kaanbal-templates/mongodb-db/k8s/`, etc.
   - Rebuild the tar.gz: `cd installer/templates && tar -czf kaanbal-templates.tar.gz <source>`
   - Verify integrity: `tar -tzf installer/templates/kaanbal-templates.tar.gz | wc -l`

2. **infra-gitops dev overlay nginx upstream** (if wrong service name):
   - Locate the nginx config inside `installer/templates/infra-gitops.tar.gz`
   - Extract → fix `proxy_pass` from `kaanbal-api` → `kaanbal-api-dev` in dev overlay
   - Rebuild the tar.gz
   - Verify the fix survives reinstall

3. **Dev overlay image tag strategy** (if dev kustomization uses non-existent tags):
   - Fix the dev overlay to use `imagePullPolicy: Always` + `latest` tag OR
   - Add a post-install step that skips health checks for dev namespace on fresh install
   - This prevents the false-alarm CrashLoopBackOff on day-1 install

4. **Any deployer-side bug** found in Audit B:
   - Fix in `kaanbal-api/app/services/app_deployer.py`
   - Commit: `SOF-36 fix: <description>`

**Commit format for ALL changes**: `SOF-36 fix: <description>`
**Push to main** for each repo. Wait for CI/CD if applicable.

After each fix, sf.builder posts a Jira comment with: file changed, what changed, commit SHA.

---

### PHASE 3 — Hard Reset + Clean State (sf.runtime executes)

Once ALL fixes are committed and pushed:

#### 3a. External Cleanup (allowlist only)

```bash
# GitHub — delete allowlisted test repos
# Use GH token from _private/SETUP-CREDENTIALS.txt
for repo in e2e-vue e2e-api e2e-mongo e2e-mysql e2e-postgres e2e-fullstack test1 testapi; do
  curl -sf -X DELETE "https://api.github.com/repos/andresbardaleswork-cyber/${repo}" \
    -H "Authorization: Bearer <GH_TOKEN>" \
    -H "Accept: application/vnd.github+json" 2>/dev/null && \
    echo "Deleted: ${repo}" || echo "Not found: ${repo}"
done

# Docker Hub — delete allowlisted image repos
# (use Docker Hub API with hub.docker.com/v2/repositories/<user>/<repo>)
for repo in e2e-vue e2e-api e2e-mongo e2e-mysql e2e-postgres e2e-fullstack test1 testapi; do
  curl -sf -X DELETE "https://hub.docker.com/v2/repositories/andresbardaleswork/${repo}/" \
    -H "Authorization: Bearer <DOCKERHUB_TOKEN>" 2>/dev/null && \
    echo "Deleted DH: ${repo}" || echo "Not found DH: ${repo}"
done
```

For Tailscale: use Tailscale API to remove nodes matching `e2e-*`, `test1-*`, `testapi-*` patterns.
Read Tailscale ACL token from credentials file.

#### 3b. VPS Hard Reset

```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  # Uninstall K3s
  /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
  /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true

  # Clean all K3s/K8s state
  rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni/net.d /opt/cni
  rm -rf /var/lib/containerd /run/k3s /opt/local-path-provisioner
  rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service
  rm -f /etc/systemd/system/k3s.service.env /etc/systemd/system/k3s-agent.service.env
  rm -rf /root/.kube /root/.kaanbal

  # Kill lingering processes
  pkill -f cloudflared 2>/dev/null || true
  pkill -f tailscaled 2>/dev/null || true

  # Clean installer state (keep token)
  TOKEN_LINE=\$(grep '^KB_SETUP_TOKEN=' /root/.software-factory/config.env 2>/dev/null || true)
  rm -rf /root/.software-factory/logs /root/.software-factory/installer-state.json
  rm -rf /root/.software-factory/vault-keys.json

  systemctl daemon-reload
  echo 'VPS reset complete'
"
```

Verify reset:
```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  test -d /var/lib/rancher && echo 'FAIL: rancher still present' || echo 'OK: rancher absent'
  systemctl list-unit-files | grep k3s && echo 'FAIL: k3s units exist' || echo 'OK: no k3s units'
  echo 'Process check:'; pgrep k3s 2>/dev/null && echo 'FAIL: k3s running' || echo 'OK: k3s gone'
"
```

#### 3c. Also delete test repos from infra-gitops on GitHub

If `infra-gitops` GitHub repo has `apps/test1/`, `apps/testapi/`, `apps/e2e-*/` directories
from previous test runs, remove them:

```bash
# Clone infra-gitops, remove stale app dirs, push
git clone https://<GIT_USER>:<GIT_TOKEN>@github.com/andresbardaleswork-cyber/infra-gitops.git /tmp/infra-clean
cd /tmp/infra-clean
for dir in test1 testapi e2e-vue e2e-api e2e-mongo e2e-mysql e2e-postgres e2e-fullstack; do
  rm -rf "apps/$dir"
done
git add -A && git commit -m "SOF-36 chore: remove stale test app dirs" --allow-empty && git push
rm -rf /tmp/infra-clean
```

---

### PHASE 4 — Fresh Reinstall (sf.builder drives, sf.runtime monitors)

#### 4a. Verify installer is running on VPS

```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  ss -ltnp | grep ':3000' || echo 'installer not listening'
  if ! ss -ltnp | grep -q ':3000'; then
    # Pull latest softwarefactory code (with our fixes)
    cd /root
    if [ -d softwarefactory ]; then
      cd softwarefactory && git pull
    else
      git clone https://<GIT_USER>:<GIT_TOKEN>@github.com/andresbardaleswork-cyber/softwarefactory.git
    fi
    nohup bash /root/softwarefactory/install.sh > /var/log/kaanbal-installer.log 2>&1 < /dev/null &
    sleep 10
    ss -ltnp | grep ':3000' && echo 'installer started' || echo 'FAIL: installer not starting'
  fi
  # Get setup token
  grep KB_SETUP_TOKEN /root/.software-factory/installer.env 2>/dev/null || \
  grep KB_SETUP_TOKEN /root/.software-factory/config.env 2>/dev/null || echo 'token not found'
"
```

#### 4b. Validate Credentials BEFORE Submitting

Read credentials from `_private/SETUP-CREDENTIALS.txt`.
Use the installer's `/api/validate-credentials` endpoint to pre-check all tokens:

```bash
# Build payload from _private/SETUP-CREDENTIALS.txt
# Then call validate endpoint
curl -sf -X POST http://161.97.112.80:3000/api/validate-credentials \
  -H "Authorization: Bearer <INSTALLER_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '<payload_from_credentials_file>'
```

**Gate**: `valid=true` AND zero errors before proceeding.
If any error → diagnose which credential is invalid → do NOT proceed with install.
Post validation result as Jira comment (sf.validation).

#### 4c. Run Full Installer via run_installer_wizard.py

Update `.agent/lab/run_installer_wizard.py` to use:
- `INSTALLER_URL=http://161.97.112.80:3000`
- `INSTALLER_TOKEN=<token from VPS>`
- All `KB_*` values from `_private/SETUP-CREDENTIALS.txt`

Then execute:
```bash
cd softwarefactory
python .agent/lab/run_installer_wizard.py
```

This runs steps 01-11 in sequence. Monitor progress.

**If any step fails**:
1. Capture the exact error: `ssh ... "tail -50 /var/log/kaanbal-installer.log"`
2. Check step-specific logs: `kubectl logs`, `kubectl describe`, pod events
3. Fix the underlying issue (not a retry loop)
4. Re-run the failed step only

#### 4d. Post-Install Health Check

Copy and run health check:
```bash
scp -i "_private/keys/contabo-rescue" softwarefactory/.agent/lab/e2e-health-check.py \
  root@161.97.112.80:/tmp/

ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 \
  "python3 /tmp/e2e-health-check.py"
```

**Gate**: ≥50/54 checks passing (dev namespace ImagePullBackOff is expected/non-blocking on day-1).

---

### PHASE 5 — Platform API Validation (sf.runtime)

```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  # Health
  curl -sf http://localhost:30081/health | python3 -m json.tool

  # Get admin credentials from config
  source /root/.software-factory/config.env
  echo \"Admin user: \${KB_ADMIN_USER:-admin}\"

  # Auth token
  TOKEN=\$(curl -sf -X POST http://localhost:30081/api/v1/auth/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d \"username=\${KB_ADMIN_USER:-admin}&password=\${KB_ADMIN_PASSWORD}\" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"access_token\"])' 2>/dev/null)
  echo \"Token obtained: \${#TOKEN} chars\"

  # Templates
  curl -sf -H \"Authorization: Bearer \$TOKEN\" http://localhost:30081/api/v1/templates \
    | python3 -c 'import sys,json; [print(t[\"id\"]) for t in json.load(sys.stdin)]' 2>/dev/null
"
```

**Gate**: Health=200, auth works, templates include `vue3-spa`, `fastapi-api`, `mongodb-db`,
`mysql-db`, `postgres-db`.

---

### PHASE 6 — E2E App Lifecycle Tests — Interconnected Apps (sf.validation leads)

> This is the core validation. Create apps that actually TALK to each other.

#### Architecture of test apps:
```
e2e-vue (Vue3 SPA)
  ↓ calls
e2e-api (FastAPI)
  ↓ connects to
e2e-mongo (MongoDB)  — shared DB
e2e-mysql (MySQL)    — separate DB
e2e-postgres (PostgreSQL) — separate DB
```

The FastAPI template should be configured to use MongoDB as its primary DB.
Create apps in this order: databases first, then API, then frontend.

#### Step 6a: Create MongoDB (SOF-12)

```json
POST /api/v1/apps
{
  "name": "e2e-mongo",
  "template_id": "mongodb-db",
  "environment_exposure": {
    "prod": "tailscale",
    "dev": "internal",
    "staging": "internal"
  }
}
```

Validate:
- [ ] No GitHub repo created (config-only mode)
- [ ] `infra-gitops/apps/e2e-mongo/` pushed
- [ ] ArgoCD apps: `e2e-mongo-prod` Synced/Healthy
- [ ] Pod Running with PVC attached in `prod` namespace
- [ ] Vault secrets at `secret/prod/e2e-mongo`
- [ ] Tailscale TCP endpoint accessible on port 27017 for prod
- [ ] `GET /api/v1/apps/e2e-mongo` returns connection info (host, port, credentials ref)

#### Step 6b: Create MySQL (SOF-12)

```json
POST /api/v1/apps
{
  "name": "e2e-mysql",
  "template_id": "mysql-db",
  "environment_exposure": {
    "prod": "tailscale",
    "dev": "internal",
    "staging": "internal"
  }
}
```

Same validation as MongoDB. If `mysql-db` template manifests are missing, document exactly
what's needed and skip (do NOT block on this — create a follow-up sub-task).

#### Step 6c: Create PostgreSQL (SOF-12)

Same as MySQL with `template_id: "postgres-db"` and `name: "e2e-postgres"`.

#### Step 6d: Create FastAPI (SOF-2) — connects to e2e-mongo

```json
POST /api/v1/apps
{
  "name": "e2e-api",
  "template_id": "fastapi-api",
  "environment_exposure": {
    "prod": "public",
    "dev": "public",
    "staging": "tailscale"
  },
  "config": {
    "MONGODB_URL": "<connection_info_from_e2e-mongo_app>"
  }
}
```

Wait for GitHub Actions pipeline to complete (poll Docker Hub for `andresbardaleswork/e2e-api`).

Validate:
- [ ] GitHub repo `andresbardaleswork-cyber/e2e-api` exists
- [ ] GitHub Actions pipeline completed (not just triggered)
- [ ] Docker Hub image `andresbardaleswork/e2e-api` exists with at least 1 tag
- [ ] ArgoCD apps: `e2e-api-prod`, `e2e-api-dev`, `e2e-api-staging` Synced/Healthy
- [ ] Pods Running in prod, dev, staging namespaces
- [ ] `curl https://e2e-api.automation.com.mx/health` → 200 (public prod)
- [ ] `curl https://dev-e2e-api.automation.com.mx/health` → 200 (public dev — SOF-2)
- [ ] Tailscale endpoint accessible for staging — SOF-2 combo
- [ ] API can connect to MongoDB: `curl https://e2e-api.automation.com.mx/health` shows DB status

#### Step 6e: Create Vue 3 SPA (SOF-2) — points to e2e-api

```json
POST /api/v1/apps
{
  "name": "e2e-vue",
  "template_id": "vue3-spa",
  "environment_exposure": {
    "prod": "public",
    "dev": "tailscale",
    "staging": "internal"
  },
  "config": {
    "VITE_API_URL": "https://e2e-api.automation.com.mx"
  }
}
```

Wait for pipeline + Docker image.

Validate:
- [ ] GitHub repo exists, pipeline completed
- [ ] Docker Hub image `andresbardaleswork/e2e-vue` exists
- [ ] ArgoCD apps: `e2e-vue-prod`, `e2e-vue-dev`, `e2e-vue-staging` Synced/Healthy
- [ ] `curl https://e2e-vue.automation.com.mx` → 200 (public prod — SOF-2)
- [ ] Tailscale endpoint accessible for dev — SOF-2 combo
- [ ] No public ingress for staging (internal only) — SOF-2 combo
- [ ] SPA loads and VITE_API_URL is baked into the bundle correctly

#### Exposure Combo Matrix (SOF-2 complete)

| App | Env | Mode | Expected | Validate |
|-----|-----|------|----------|---------|
| e2e-vue | prod | public | HTTPS 200 at `e2e-vue.automation.com.mx` | `curl https://e2e-vue.automation.com.mx` |
| e2e-vue | dev | tailscale | Accessible via Tailscale IP | `curl http://<ts-ip>:<port>` |
| e2e-vue | staging | internal | NO ingress created | `kubectl -n staging get ingress` shows nothing |
| e2e-api | prod | public | HTTPS 200 at `e2e-api.automation.com.mx/health` | `curl https://e2e-api.automation.com.mx/health` |
| e2e-api | dev | public | HTTPS 200 at `dev-e2e-api.automation.com.mx/health` | `curl https://dev-e2e-api.automation.com.mx/health` |
| e2e-api | staging | tailscale | Accessible via Tailscale | Tailscale reachability test |

#### Database Integration Validation (SOF-12 complete)

For each DB app that deployed:
```bash
ssh ... "
  # MongoDB — test connection from e2e-api pod
  kubectl -n prod exec deploy/e2e-api -- \
    python3 -c \"import pymongo; c=pymongo.MongoClient('mongodb://...'); print(c.list_database_names())\" \
    2>/dev/null || echo 'SKIP: no e2e-api pod or no pymongo'

  # MySQL — test if pod is running
  kubectl -n prod get pod -l app=e2e-mysql --no-headers | head -1

  # PostgreSQL — test if pod is running
  kubectl -n prod get pod -l app=e2e-postgres --no-headers | head -1
"
```

---

### PHASE 7 — Bug Fixing During Validation

For EVERY failure found in Phase 6:
1. Diagnose root cause (do NOT just retry — understand WHY it failed)
2. Is this a fresh-install regression (same bug that reappears after clean wipe)?
   - YES → fix in installer template tar.gz OR deployer source code → commit → push
   - NO → fix in the cluster only if it's a test-specific issue
3. Commit: `SOF-36 fix: <specific description of what broke and why>`
4. Re-test the specific gate

**Maximum 3 fix iterations per issue.** After 3 failures:
- Create a new Jira sub-task linked to SOF-36 with full diagnosis
- Mark that specific check as BLOCKED in evidence
- Continue with remaining checks

---

### PHASE 8 — Clean Slate (sf.runtime + sf.validation)

Delete all test apps via API in REVERSE order (frontend first, DBs last):

```bash
# Get all app IDs
TOKEN=<platform_api_token>
APPS=$(curl -sf -H "Authorization: Bearer $TOKEN" http://161.97.112.80:30081/api/v1/apps \
  | python3 -c 'import sys,json; [print(a["id"],a["name"]) for a in json.load(sys.stdin)]')
echo "$APPS"

# Delete in order: e2e-vue, e2e-api, e2e-mongo, e2e-mysql, e2e-postgres
for name in e2e-vue e2e-api e2e-mongo e2e-mysql e2e-postgres; do
  APP_ID=$(echo "$APPS" | grep "$name" | awk '{print $1}')
  if [ -n "$APP_ID" ]; then
    curl -sf -X DELETE "http://161.97.112.80:30081/api/v1/apps/$APP_ID" \
      -H "Authorization: Bearer $TOKEN" && echo "Deleted: $name ($APP_ID)"
    sleep 5  # Give ArgoCD time to cascade delete
  fi
done
```

For EACH deleted app, validate cleanup within 60 seconds:
- [ ] GitHub repo deleted (or was never created for DBs)
- [ ] ArgoCD applications gone: `kubectl -n argocd get application | grep <name>`
- [ ] K8s resources gone: `kubectl get all,pvc -n prod,dev,staging | grep <name>`
- [ ] infra-gitops directory gone: check via GitHub API
- [ ] Cloudflare DNS record removed
- [ ] Vault secrets removed: `kubectl -n vault exec vault-0 -- vault kv list secret/prod/`

Also clean stale apps from previous installs:
```bash
for name in test1 testapi; do
  for env in dev prod staging; do
    kubectl -n argocd delete application "${name}-${env}" --ignore-not-found
  done
  kubectl delete all -l app=$name -A 2>/dev/null || true
done
```

---

### PHASE 9 — Pristine State Verification (sf.validation)

```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80 "
  echo '=== PODS (non-running) ==='
  kubectl get pods -A | grep -v Running | grep -v Completed | grep -v 'NAME'

  echo '=== ARGOCD APPS ==='
  kubectl -n argocd get applications --no-headers

  echo '=== DEV NAMESPACE ==='
  kubectl get all -n dev --no-headers

  echo '=== STAGING NAMESPACE ==='
  kubectl get all -n staging --no-headers

  echo '=== PVCs ==='
  kubectl get pvc -A --no-headers

  echo '=== API HEALTH ==='
  curl -sf http://localhost:30081/health

  echo '=== CONSOLE ==='
  curl -sf -o /dev/null -w '%{http_code}' http://localhost:30080
"
```

Expected clean state:
```
argocd:   applicationsets, core-config, infra-bootstrap (Synced/Healthy)
prod:     datastore, kaanbal-api, kaanbal-console (Running 1/1)
dev:      kaanbal-api-dev, kaanbal-console-dev (Running 1/1 OR ImagePullBackOff if day-1)
staging:  empty
vault:    vault pod
tailscale: tailscale-operator only
```

Dev namespace pods in `ImagePullBackOff` are **acceptable on day-1** of a fresh install.
They become healthy after the first `kaanbal-api`/`kaanbal-console` CI/CD builds Docker images
(which happens automatically after step 06 pushes code to GitHub).

---

### PHASE 10 — Evidence + LESSONS.md Update + Jira Transition

#### 10a. Update LESSONS.md

Add or update the "SOF-2/SOF-12 Post-Reinstall Regression" section:

```markdown
## SOF-2/SOF-12 Post-Reinstall Regression (resolved 2026-03-22)

### Root Causes Found
1. <root cause 1> — Fixed in: <file> — Commit: <SHA>
2. <root cause 2> — Fixed in: <file> — Commit: <SHA>
...

### How to Prevent
- <prevention rule 1>
- <prevention rule 2>

### Known Expected Behaviors (NOT bugs)
- Dev namespace ImagePullBackOff on day-1: expected until first CI/CD build
- Vault Degraded on single-node: expected (HA anti-affinity)

### Validation Standard (after any reinstall)
Run: `python .agent/lab/e2e-health-check.py`
Minimum passing: 50/54 checks
Acceptable warnings: dev ImagePullBackOff, vault HA
```

#### 10b. Post Final Jira Comment on SOF-36 (sf.validation)

```markdown
[E2E-VALIDATION-RUN]
Issue: SOF-36 | Related: SOF-2, SOF-12
Timestamp: <YYYY-MM-DD HH:mm TZ>
Run: .agent/teams/runs/<timestamp>__SOF-36-root-cause-fix-and-reinstall-v2/

## Root Causes Fixed
| # | Root Cause | File Changed | Commit SHA | Status |
|---|-----------|-------------|------------|--------|
| 1 | <cause> | <file> | <sha> | FIXED/OPEN |
| 2 | <cause> | <file> | <sha> | FIXED/OPEN |

## Platform Core (post-reinstall)
| Component | Expected | Actual | Status |
|-----------|---------|--------|--------|
| kaanbal-api-prod | Running 1/1 | <actual> | PASS/FAIL |
| kaanbal-console-prod | Running 1/1 | <actual> | PASS/FAIL |
| datastore-prod | Running 1/1 | <actual> | PASS/FAIL |
| kaanbal-api-dev | Running/Expected-IPBO | <actual> | PASS/WARN |
| kaanbal-console-dev | Running/Expected-IPBO | <actual> | PASS/WARN |
| API health | 200 | <code> | PASS/FAIL |
| API auth | token issued | <actual> | PASS/FAIL |
| Templates | ≥5 ready | <count> | PASS/FAIL |

## App Lifecycle (SOF-2 + SOF-12)
| App | Template | Create | Build | Deploy | Access | Delete | Cleanup |
|-----|----------|--------|-------|--------|--------|--------|---------|
| e2e-mongo | mongodb-db | ✅/❌ | N/A | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| e2e-mysql | mysql-db | ✅/❌/SKIP | N/A | ... | ... | ... | ... |
| e2e-postgres | postgres-db | ✅/❌/SKIP | N/A | ... | ... | ... | ... |
| e2e-api | fastapi-api | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| e2e-vue | vue3-spa | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |

## SOF-2 Exposure Combos
| App | Env | Mode | Expected | Actual | Status |
|-----|-----|------|---------|--------|--------|
| e2e-vue | prod | public | 200 | <code> | PASS/FAIL |
| e2e-vue | dev | tailscale | accessible | <result> | PASS/FAIL |
| e2e-vue | staging | internal | no ingress | <result> | PASS/FAIL |
| e2e-api | prod | public | 200 | <code> | PASS/FAIL |
| e2e-api | dev | public | 200 | <code> | PASS/FAIL |
| e2e-api | staging | tailscale | accessible | <result> | PASS/FAIL |

## SOF-12 Database Tests
| DB | Pod Running | PVC | Vault Secrets | TCP Access | Delete Clean |
|----|-------------|-----|--------------|------------|--------------|
| MongoDB | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| MySQL | ✅/❌/SKIP | ... | ... | ... | ... |
| PostgreSQL | ✅/❌/SKIP | ... | ... | ... | ... |

## App Interaction Validation
| Check | Expected | Actual | Status |
|-------|---------|--------|--------|
| e2e-vue calls e2e-api | 200 response | <actual> | PASS/FAIL |
| e2e-api connects to e2e-mongo | DB reachable | <actual> | PASS/FAIL |

## Clean Slate Verification
| Check | Expected | Actual | Status |
|-------|---------|--------|--------|
| No test pods remaining | 0 | <count> | PASS/FAIL |
| No test ArgoCD apps | 0 | <count> | PASS/FAIL |
| No stale GitHub repos | 0 in allowlist | <count> | PASS/FAIL |
| No stale infra-gitops dirs | 0 | <count> | PASS/FAIL |
| API healthy | 200 | <code> | PASS/FAIL |
| Console serves | 200 | <code> | PASS/FAIL |
| ArgoCD prod apps | Healthy | <status> | PASS/FAIL |

## Remaining Issues (if any)
| Issue | Root Cause | Why Not Resolved | Recommended Action | Jira Sub-Task |
|-------|-----------|-----------------|-------------------|---------------|

## Artifacts
- Prompt: .agent/teams/prompts/SOF-36-root-cause-fix-and-reinstall-v2.prompt.md
- Run folder: .agent/teams/runs/<timestamp>__SOF-36-root-cause-fix-and-reinstall-v2/
- LESSONS.md: updated
- Commits: <list all SHAs>
```

#### 10c. Transition SOF-36

- If ALL P1 issues resolved → transition to `Ready for QA` (transition ID: 2) using sf.validation token
- If any P1 issue remains → transition to `Blocked` using sf.riskqa token with blocker comment
- Update SOF-36 ticket description with final results summary

---

## Agent Team Structure

Spawn these 5 sub-agents. Run Phase 0 audits in parallel, then synthesize:

| Agent | Role Token | Primary Phase | Model |
|-------|-----------|--------------|-------|
| orchestrator | sf.orchestrator@kanbaal.dev | Phase 0C, 1, 10 | Sonnet |
| builder | sf.builder@kanbaal.dev | Phase 0A, 2, 4 | Sonnet |
| runtime | sf.runtime@kanbaal.dev | Phase 0B+D, 3, 5 | Sonnet |
| validator | sf.validation@kanbaal.dev | Phase 6, 9, 10b | Sonnet |
| riskqa | sf.riskqa@kanbaal.dev | Phase 1 challenge, blockers | Haiku |

**Sequencing**:
1. Phases 0A, 0B, 0C, 0D → **run in parallel**
2. Phase 1 synthesis → **wait for all Phase 0 results**
3. Phase 2 fixes → **only after Phase 1 agreement**
4. Phases 3+4 → **only after Phase 2 commits pushed**
5. Phase 5+6 → **only after Phase 4 health check passes**
6. Phase 7 → **inline with Phase 6** (fix as you find)
7. Phase 8+9 → **only after all Phase 6 tests attempted**
8. Phase 10 → **always runs last**

---

## Key Code Paths

| What | Where |
|------|-------|
| Installer templates | `softwarefactory/installer/templates/*.tar.gz` |
| Source repos step | `softwarefactory/installer/steps/06-source-repos.sh` |
| Clean install step | `softwarefactory/installer/steps/00-clean-install.sh` |
| App deployer | `kaanbal-api/app/services/app_deployer.py` |
| Template catalog | `kaanbal-templates/catalog.json` |
| Template scaffolds | `kaanbal-templates/vue3-spa/`, `kaanbal-templates/fastapi-api/`, `kaanbal-templates/mongodb-db/` |
| Infra dev overlay | `infra-gitops/apps/kaanbal-console/overlays/dev/` |
| ArgoCD app sets | `infra-gitops/argocd/applicationsets/` |
| Health check script | `softwarefactory/.agent/lab/e2e-health-check.py` |
| Installer wizard | `softwarefactory/.agent/lab/run_installer_wizard.py` |

---

## Done Criteria

This prompt is complete when ALL of the following are true:
1. [ ] Every P1 root cause has a code commit (not a cluster patch)
2. [ ] Fresh reinstall completed without manual intervention
3. [ ] Health check ≥50/54 passing
4. [ ] At least `e2e-vue` and `e2e-api` passed full lifecycle (create → build → deploy → access → delete)
5. [ ] At least `e2e-mongo` passed full lifecycle
6. [ ] All created apps have been deleted and cluster is pristine
7. [ ] `LESSONS.md` updated with root causes and prevention rules
8. [ ] Jira SOF-36 has structured evidence comment
9. [ ] SOF-36 transitioned to `Ready for QA` or `Blocked` with full rationale
