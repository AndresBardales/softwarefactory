# SOF Dev Hard Reset + Reinstall Validation (v1)

## Role
You are the execution team for SOF in DEV mode. Work fast, but produce deterministic evidence.

## Objective
Perform a full clean reset for DEV validation and prove that installation works from zero state.

Scope of cleanup (DEV ONLY):
1. VPS/K3s state
2. GitHub generated repos for target test apps
3. Docker Hub images/tags for target test apps
4. Tailscale nodes/routes created by the failed run

Then run reinstall + validate end-to-end.

## Critical Safety Rules
1. Execute this ONLY for DEV assets explicitly listed below.
2. Do NOT touch production resources.
3. Do NOT print raw credentials in logs.
4. Store ad-hoc scripts and artifacts only under `.agent/lab/`.
5. If target resources are ambiguous, stop and mark ticket as `Blocked` with exact clarification needed.

## Inputs (fill before execution)
- Jira issue key: `SOF-2`
- Parent epic key: `SOF-1`
- Environment label: `dev`
- VPS IP: `161.97.112.80`
- SSH key path: `_private/keys/contabo.pem`
- SSH user: `ubuntu`
- Domain under test: `automation.com.mx`
- GitHub owner: `andresbardaleswork-cyber`
- GitHub repos allowed to delete (test app repos only — NOT platform repos):
  `[e2e-mongo, e2e-postgres, e2e-mysql, e2e-vue3, e2e-fastapi, pame, vuem]`
- Docker Hub namespace: `andresbardaleswork`
- Docker repos allowed to delete tags/images:
  `[e2e-mongo, e2e-postgres, e2e-mysql, e2e-vue3, e2e-fastapi]`
- Tailscale cleanup filter (hostnames/tags): `[kaanbal-, automation-com-mx, software-factory]`

> ⚠️ **BLOCKER — SSH ACCESS**: As of 2026-03-22, SSH with all available private keys
> (`contabo.pem`, `customer1`, `factory.pem`, `fabric.pem`) against both
> `161.97.112.80` and `167.86.69.250` returns `Permission denied (publickey,password)`.
> The CF tunnel is live (nginx 404 at automation.com.mx) so the server is running.
> **Human action required**: Confirm current VPS IP + correct SSH key before executing
> this prompt. If the server was rebuilt, re-add the `contabo.pem` public key via
> the Contabo control panel (VNC/rescue mode).

Credentials source:
- `_private/SETUP-CREDENTIALS.txt`
- `infra-gitops/terraform/terraform.tfvars` (only if infra credentials required)

## Mandatory Workflow
1. Read Jira ticket, parent epic, and last 5 comments.
2. Move ticket to `In Progress`.
3. Snapshot current state (before evidence):
   - VPS: k8s namespaces/pods/apps
   - GitHub repos existence
   - Docker Hub image/tag presence
   - Tailscale nodes/routes tied to test scope
4. Execute hard reset in this order:
   - VPS cleanup (k3s uninstall + residual dirs)
   - GitHub cleanup (only allowlist repos)
   - Docker Hub cleanup (only allowlist repos/tags)
   - Tailscale cleanup (only matching allowlist patterns)
5. Reinstall platform from scratch.
6. Run validation:
   - Health checks
   - Auth check
   - Template availability
   - Launch at least one control app + one affected template app
7. Collect after-state evidence and compare against expected.
8. Update Jira description (solution + evidence table + artifacts).
9. Post structured Jira comment with proofs.
10. Move to `Ready for QA`.

## Validation Gates (must pass)
1. Fresh install boots with expected core namespaces and critical pods running.
2. ArgoCD core apps in expected state (Synced/Healthy where applicable).
3. API auth works and templates endpoint includes required templates.
4. New app creation from tested templates proceeds with expected repo/scaffold behavior.
5. No stale resources remain in allowlisted GitHub/DockerHub/Tailscale scope.

## Execution Notes
- Prefer existing scripts first. If missing, create temporary scripts in `.agent/lab/`.
- Every destructive command must reference explicit allowlists.
- If a command fails, capture exact error and continue with fallback strategy.
- Use max 2 fix iterations for each failed validation gate before escalation.

## Required Jira Comment Template
Use this exact structure:

```markdown
[DEV-HARD-RESET-RUN]
Issue: SOF-<N>
Epic: SOF-1
Timestamp: <YYYY-MM-DD HH:mm TZ>

Before Snapshot:
- VPS:
- GitHub:
- Docker Hub:
- Tailscale:

Actions Executed:
1.
2.
3.

After Snapshot:
- VPS:
- GitHub:
- Docker Hub:
- Tailscale:

Validation Results:
| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| install health | pass | ... | PASS/FAIL |
| auth token | pass | ... | PASS/FAIL |
| templates list | includes required | ... | PASS/FAIL |
| app launch | running/expected | ... | PASS/FAIL |

Artifacts:
- Prompt: .agent/teams/prompts/SOF-dev-hard-reset-and-reinstall-v1.prompt.md
- Run folder: .agent/teams/runs/<timestamp>__SOF-dev-hard-reset-and-reinstall-v1/
- Commits:
- Files changed:

Risks/Blockers:
-

Next Step:
- Ready for QA / Blocked (reason)
```

## Done Criteria
- All validation gates pass.
- Jira comment with complete evidence posted.
- Ticket in `Ready for QA`.
