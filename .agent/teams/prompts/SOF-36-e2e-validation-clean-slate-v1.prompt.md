# SOF-36: E2E Validation — Install → Deploy Apps → Test Combos → Clean Slate

## Role
You are the validation team for SOF-36. Your job is to systematically fix platform issues, validate the entire app deployment lifecycle, and leave the cluster pristine for human QA. Work fast, produce deterministic evidence, and fix bugs as you find them.

## Jira Ticket
- **Issue**: SOF-36 — "E2E Validation: Install → Deploy Apps → Test Combos (SOF-2/SOF-12) → Clean Slate"
- **Project**: SOF (Cloud ID: `537b033e-4b1a-4cd4-843f-61057f49a3a9`)
- **Related**: SOF-2 (Vue+FastAPI exposure combos), SOF-12 (Database templates)
- **Jira URL**: https://futurefarms.atlassian.net/browse/SOF-36

## Critical Safety Rules
1. Execute ONLY for DEV assets explicitly listed below.
2. Do NOT touch production platform repos (kaanbal-api, kaanbal-console, infra-gitops source — only push fixes).
3. Do NOT print raw credentials in logs.
4. Store ad-hoc scripts and artifacts only under `.agent/lab/`.
5. If scope is ambiguous, stop and post a Jira comment asking for clarification.

## Mandatory Workflow (follow in order)

### Step 0: Read Context
Before writing any code, read these files in order:
1. `.agent/context/PROJECT.md` — Architecture overview
2. `.agent/context/ARCHITECTURE.md` — Technical details
3. `.agent/LESSONS.md` — Solved problems & patterns
4. `.agent/sessions/2026-03-22.md` — Today's session with installer fixes
5. `kaanbal-api/app/services/app_deployer.py` — The deployer code
6. `kaanbal-templates/catalog.json` — Template definitions
7. Read SOF-36 ticket description and last 5 comments via Jira MCP
8. Read SOF-2 and SOF-12 descriptions for original acceptance criteria

Move SOF-36 to `In Progress` (transition ID: 31).

### Step 1: Fix Platform Core (DEV namespace)

**Known issues to fix:**

1. **kaanbal-console-dev CrashLoopBackOff**: The dev overlay nginx config references upstream `kaanbal-api` but in the dev namespace the service name is `kaanbal-api-dev`. Fix the nginx config in the infra-gitops dev overlay for kaanbal-console, push to GitHub, and let ArgoCD sync.

2. **kaanbal-api-dev ImagePullBackOff**: The dev kustomization.yaml references a Docker image tag that doesn't exist on Docker Hub. Check what tags actually exist on Docker Hub for `andresbardaleswork/kaanbal-api` and `andresbardaleswork/kaanbal-console`, then update the dev overlay to use existing tags.

3. **Stale test apps (test1, testapi)**: These were launched from the console but their Docker images were never built. Delete these ArgoCD applications and any K8s resources.

**Validation gate**: ALL ArgoCD apps for platform core must be Synced/Healthy:
- `kaanbal-api-prod` ✅ (already healthy)
- `kaanbal-console-prod` ✅ (already healthy)
- `datastore-prod` ✅ (already healthy)
- `kaanbal-api-dev` → must become Healthy
- `kaanbal-console-dev` → must become Healthy

### Step 2: Validate Platform API is Functional

Using SSH to VPS, test these API endpoints:

```bash
# Health
curl -s http://localhost:30081/health

# Auth — get a token (check if there's a default admin user or create one)
curl -s -X POST http://localhost:30081/api/v1/auth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=admin&password=<find-password>"

# Templates list
curl -s http://localhost:30081/api/v1/templates \
  -H "Authorization: Bearer <token>"

# Apps list
curl -s http://localhost:30081/api/v1/apps \
  -H "Authorization: Bearer <token>"
```

If auth doesn't work, check MongoDB for existing users:
```bash
kubectl -n prod exec -it deploy/datastore -- mongosh forge --eval "db.users.find().pretty()"
```

**Validation gate**: API health returns 200, auth works, templates endpoint returns templates including vue3-spa, fastapi-api, mongodb-db.

### Step 3: Test Vue 3 SPA Lifecycle (SOF-2 scope)

Create a Vue 3 app with per-environment exposure:

```bash
curl -s -X POST http://localhost:30081/api/v1/apps \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "e2e-vue",
    "template_id": "vue3-spa",
    "environment_exposure": {
      "prod": "public",
      "dev": "tailscale",
      "staging": "internal"
    }
  }'
```

Wait for deployment. Then validate:
- [ ] GitHub repo `e2e-vue` exists at `andresbardaleswork-cyber/e2e-vue`
- [ ] GitHub Actions pipeline triggered and completed
- [ ] Docker Hub image `andresbardaleswork/e2e-vue` exists with correct tag
- [ ] ArgoCD apps created: `e2e-vue-prod`, `e2e-vue-dev`, `e2e-vue-staging`
- [ ] All ArgoCD apps Synced/Healthy
- [ ] Pods Running in prod, dev, staging namespaces
- [ ] `curl https://e2e-vue.automation.com.mx` returns 200 (public prod)
- [ ] Tailscale endpoint accessible for dev
- [ ] No ingress exists for staging (internal only)

### Step 4: Test FastAPI Lifecycle (SOF-2 scope)

Create a FastAPI app:

```bash
curl -s -X POST http://localhost:30081/api/v1/apps \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "e2e-api",
    "template_id": "fastapi-api",
    "environment_exposure": {
      "prod": "public",
      "dev": "public",
      "staging": "tailscale"
    }
  }'
```

Same validation as Step 3 but with:
- [ ] `curl https://e2e-api.automation.com.mx/health` returns 200
- [ ] `curl https://dev-e2e-api.automation.com.mx/health` returns 200 (public dev — SOF-2 fix)
- [ ] Tailscale endpoint accessible for staging

### Step 5: Test MongoDB Lifecycle (SOF-12 scope)

Create a MongoDB app:

```bash
curl -s -X POST http://localhost:30081/api/v1/apps \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "e2e-mongo",
    "template_id": "mongodb-db",
    "environment_exposure": {
      "prod": "tailscale",
      "dev": "internal",
      "staging": "internal"
    }
  }'
```

Validate:
- [ ] No GitHub repo created (config-only mode)
- [ ] infra-gitops has `apps/e2e-mongo/` directory pushed
- [ ] ArgoCD apps created and Synced
- [ ] Pod Running with PVC attached
- [ ] Vault secrets written at `secret/prod/e2e-mongo`
- [ ] Tailscale TCP endpoint accessible on port 27017 for prod
- [ ] Connection info returned by `GET /api/v1/apps/e2e-mongo`

### Step 6: Test MySQL and PostgreSQL (SOF-12 scope, if templates ready)

If K8s manifests exist for mysql-db and postgres-db templates, repeat Step 5 for each. If manifests are missing, document what's needed and skip.

### Step 7: Bug Fixing

For EVERY failure found in steps 1-6:
1. Diagnose root cause (read logs, describe pods, check configs)
2. Fix the code in the appropriate repo (kaanbal-api, kaanbal-console, infra-gitops, kaanbal-templates)
3. Commit with format: `SOF-36 fix: <description>`
4. Push to main
5. Wait for CI/CD if applicable
6. Re-test the failed validation

Maximum 3 fix iterations per issue. If not resolved, document the issue and continue.

### Step 8: Delete All Test Apps (Clean Slate)

Delete every test app created, in reverse order:

```bash
# Get app IDs
curl -s http://localhost:30081/api/v1/apps -H "Authorization: Bearer <token>"

# Delete each
curl -s -X DELETE http://localhost:30081/api/v1/apps/<app_id> \
  -H "Authorization: Bearer <token>"
```

Validate cleanup for EACH deleted app:
- [ ] GitHub repo deleted
- [ ] Docker Hub image/tags removed (or documented)
- [ ] ArgoCD applications deleted (all envs)
- [ ] K8s pods/services/PVCs deleted
- [ ] infra-gitops directories removed
- [ ] Cloudflare DNS records removed
- [ ] Tailscale nodes removed
- [ ] Vault secrets removed

### Step 9: Also clean stale apps from previous installs

Delete these stale ArgoCD apps if they still exist: `test1-dev`, `test1-prod`, `test1-staging`, `testapi-dev`, `testapi-prod`, `testapi-staging`. Also delete any K8s resources in all namespaces for test1 and testapi.

### Step 10: Final Validation (Pristine State)

After cleanup, the cluster should have ONLY:
```
argocd:     applicationsets, core-config, infra-bootstrap (Synced/Healthy)
prod:       datastore, kaanbal-api, kaanbal-console (all Running 1/1)
dev:        kaanbal-api-dev, kaanbal-console-dev (all Running 1/1)
staging:    (empty or minimal)
tailscale:  tailscale-operator only
vault:      vault pod
```

No test/user-created apps should remain anywhere.

Run these validation checks:
```bash
# All pods healthy
kubectl get pods -A | grep -v Running | grep -v Completed

# ArgoCD apps clean
kubectl -n argocd get applications

# No orphan resources
kubectl get all -n dev --no-headers
kubectl get all -n staging --no-headers

# API health
curl -s http://localhost:30081/health

# Console serves SPA
curl -s -o /dev/null -w '%{http_code}' http://localhost:30080
```

### Step 11: Post Evidence and Transition Ticket

1. Post a structured Jira comment on SOF-36 with ALL validation results using this template:

```markdown
[E2E-VALIDATION-RUN]
Issue: SOF-36
Related: SOF-2, SOF-12
Timestamp: <YYYY-MM-DD HH:mm TZ>

## Platform Core Fix
| Component | Issue | Fix Applied | Result |
|-----------|-------|-------------|--------|
| kaanbal-console-dev | nginx upstream wrong | <fix> | PASS/FAIL |
| kaanbal-api-dev | ImagePullBackOff | <fix> | PASS/FAIL |
| stale test apps | ImagePullBackOff | deleted | PASS/FAIL |

## App Lifecycle Tests
| App | Template | Create | Build | Deploy | Access | Delete | Cleanup |
|-----|----------|--------|-------|--------|--------|--------|---------|
| e2e-vue | vue3-spa | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| e2e-api | fastapi-api | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| e2e-mongo | mongodb-db | ✅/❌ | N/A | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |

## SOF-2 Exposure Combos
| App | Env | Exposure | Expected | Actual | Status |
|-----|-----|----------|----------|--------|--------|
| e2e-vue | prod | public | 200 | <actual> | PASS/FAIL |
| e2e-vue | dev | tailscale | accessible | <actual> | PASS/FAIL |
| e2e-vue | staging | internal | no endpoint | <actual> | PASS/FAIL |
| e2e-api | prod | public | 200 | <actual> | PASS/FAIL |
| e2e-api | dev | public | 200 | <actual> | PASS/FAIL |
| e2e-api | staging | tailscale | accessible | <actual> | PASS/FAIL |

## SOF-12 Database Tests
| DB | Pod Running | Vault Secrets | TCP Access | PVC | Delete Clean |
|----|-------------|--------------|------------|-----|--------------|
| MongoDB | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ | ✅/❌ |
| MySQL | ✅/❌/SKIP | ... | ... | ... | ... |
| PostgreSQL | ✅/❌/SKIP | ... | ... | ... | ... |

## Clean Slate Verification
| Check | Expected | Actual | Status |
|-------|----------|--------|--------|
| No test pods | 0 | <count> | PASS/FAIL |
| No test ArgoCD apps | 0 | <count> | PASS/FAIL |
| No stale GitHub repos | 0 | <count> | PASS/FAIL |
| API healthy | 200 | <code> | PASS/FAIL |
| Console serves | 200 | <code> | PASS/FAIL |
| ArgoCD all healthy | true | <status> | PASS/FAIL |

## Bugs Fixed
1. <issue> → <fix> → <commit SHA>
2. ...

## Remaining Issues (if any)
1. <issue> — <why it wasn't resolved> — <recommended next step>
```

2. Update SOF-36 ticket description with final results.
3. Move SOF-36 to `Ready for QA` (transition ID: 2).

## Infrastructure Access

| Resource | Value |
|----------|-------|
| VPS IP | `161.97.112.80` |
| SSH key path | `_private/keys/contabo-rescue` |
| SSH user | `root` |
| Installer API | `http://localhost:3000` (token: `da9289283200ebb064b66218`) |
| Platform API | `http://localhost:30081` (kaanbal-api NodePort) |
| Platform Console | `http://localhost:30080` (kaanbal-console NodePort) |
| Domain | `automation.com.mx` |

## Credentials (read from `_private/SETUP-CREDENTIALS.txt`)

Load these before starting:
- **GitHub**: owner=`andresbardaleswork-cyber`, token from credentials file
- **Docker Hub**: user=`andresbardaleswork`, token from credentials file
- **Tailscale**: OAuth client + ACL token from credentials file, DNS suffix=`tail11dd4e.ts.net`
- **Jira**: site=`futurefarms.atlassian.net`, project=SOF

## GitHub Repos — Cleanup Allowlist (ONLY these may be deleted)
Test app repos created during validation:
- `e2e-vue`
- `e2e-api`
- `e2e-mongo`
- `e2e-mysql`
- `e2e-postgres`
- `test1`
- `testapi`

**NEVER delete**: `kaanbal-api`, `kaanbal-console`, `infra-gitops`, `kaanbal-templates`, `softwarefactory`

## Docker Hub — Cleanup Allowlist
Image repos that may be deleted/cleaned:
- `e2e-vue`, `e2e-api`, `e2e-mongo`, `e2e-mysql`, `e2e-postgres`, `test1`, `testapi`

## Key Code Paths

### App Creation Flow (kaanbal-api)
1. `POST /api/v1/apps` → `app/routers/apps.py` → `AppDeployer.deploy()`
2. Deployer checks template in `catalog.json` via `TemplateSpec`
3. For code apps (vue3-spa, fastapi-api): creates GitHub repo, pushes template code, configures CI/CD
4. For config-only apps (databases): copies K8s manifests to infra-gitops directly
5. Pushes to infra-gitops → ArgoCD syncs → pods start

### App Deletion Flow
1. `DELETE /api/v1/apps/<id>` → `app/routers/apps.py` → `AppDeployer.delete()`
2. Removes: GitHub repo, infra-gitops dirs, ArgoCD apps, K8s resources, DNS, Tailscale nodes, Vault secrets

### Deployer Source
- `kaanbal-api/app/services/app_deployer.py` — Main deployer
- `kaanbal-api/app/services/template_spec.py` — Template catalog loader

### Templates
- `kaanbal-templates/catalog.json` — Template definitions
- `kaanbal-templates/vue3-spa/` — Vue 3 SPA template
- `kaanbal-templates/fastapi-api/` — FastAPI template
- `kaanbal-templates/mongodb-db/k8s/` — MongoDB K8s manifests

### Infrastructure
- `infra-gitops/apps/` — Generated app manifests consumed by ArgoCD
- `infra-gitops/argocd/applicationsets/` — ArgoCD ApplicationSet generators

## Execution Notes
- Use SSH from local machine to VPS for all cluster operations
- All API calls go through SSH tunnel or NodePort (30081/30080)
- ArgoCD syncs automatically from infra-gitops GitHub repo
- GitHub Actions builds Docker images on push to main
- If a CI/CD build fails, check `.github/workflows/` in the generated repo
- Prefer `kubectl` over ArgoCD API for quick operations
- Save all ad-hoc scripts to `.agent/lab/sof-36/`
- Post progress updates as Jira comments periodically (not just at the end)
