# .agent/lab — Team Testing & Development Playground

This directory contains **non-production scripts, test utilities, validation tools, and development artifacts** used by team executors for testing, debugging, and validation tasks.

---

## 📂 Directory Structure

### `ssh-keys/` — SSH Key Management
Centralized SSH key inventory for team infrastructure access.

**Files:**
- `README.md` — Comprehensive SSH key documentation + usage rules
- `inventory.csv` — Quick reference table of all SSH keys (ID, type, use case, status)
- `SELECTION-GUIDE.md` — Decision tree for choosing the correct key per task
- `validate-keys.sh` — Bash script to validate all keys + check permissions + fingerprints

**For Team Executors:**
- Before any SSH operation, consult `SELECTION-GUIDE.md`
- Use `validate-keys.sh` to verify key integrity before executing team prompts
- Log SSH usage in Jira comments with key ID and target

**See Also:**
- [.github/copilot-instructions.md](../../../.github/copilot-instructions.md) — SSH access section
- [_private/SETUP-CREDENTIALS.txt](../../../_private/SETUP-CREDENTIALS.txt) — IPs for each VPS

---

## 🧪 Testing Scripts (Examples)

When team executors need to test APIs, validate configurations, or run diagnostics:

1. **Write the test script** in this directory (`test-*.sh`, `check-*.py`, etc.)
2. **Document assumptions** — what credentials, what environment, what output format
3. **Include error handling** — exit codes, logging, cleanup
4. **Run in isolation** — don't assume prior state; design for clean slate
5. **Log results** — post output to Jira comment with command + result

### Example Test Script Structure
```bash
#!/usr/bin/env bash
# Purpose: Validate MongoDB connection after reinstall
# Credentials: MongoDB tunnel via SSH + contabo.pem
# Expected Output: Connection string + ping result

set -euo pipefail

# ... script logic ...

# POST RESULT TO JIRA:
# Command: bash .agent/lab/check-mongodb.sh
# Result:  [paste output]
```

---

## 📊 Validation & Diagnostics

### When to Use Lab Scripts

✅ **Good Use Cases:**
- Validate infrastructure state (kubectl, ArgoCD, Tailscale)
- Test API connectivity (Jira, GitHub, Docker Hub)
- Check file existence / permissions on remote hosts
- Validate configuration correctness before deployment
- Run E2E smoke tests after reinstall

❌ **Not for Lab Scripts:**
- Destructive operations (cleanup, reset, delete)
- Production hotfixes (deploy instead via git + ArgoCD)
- Persistent state changes (use git-committed solutions instead)

---

## 🛠️ Reusable Patterns

### SSH Tunneling
```bash
# See ssh-keys/README.md for complete patterns
ssh -i "_private/keys/contabo.pem" -N -L 27017:datastore.prod.svc.cluster.local:27017 ubuntu@<IP>
```

### API Testing (curl)
```bash
# Jira MCP: tested in copilot-instructions.md
# GitHub API: Bearer token auth from SETUP-CREDENTIALS.txt
curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
```

### Kubernetes Read-Only Diagnostics
```bash
ssh -i "_private/keys/contabo.pem" ubuntu@<IP> "kubectl get nodes -o wide && kubectl top nodes"
```

---

## 🚷 Security Rules (MANDATORY)

1. **Never commit credentials** — all scripts must read from `_private/SETUP-CREDENTIALS.txt` or environment variables
2. **Never commit .pem keys** — `.gitignore` blocks `_private/`, but double-check before committing
3. **Cleanup after test runs** — remove temp files, close tunnels, flush sensitive output from terminal history
4. **Log SSH operations** — post key ID + command in Jira so audit trail exists
5. **Use non-root when possible** — scripts should run with minimum privilege (e.g., `ubuntu@` not `root@`)

---

## 📝 Team Operations

### When a Team Executor Needs Lab Scripts

1. **Orchestrator prepares** the lab script as part of the team prompt
2. **Executor runs** the script locally or via SSH
3. **Executor captures** stdout/stderr + exit code
4. **Executor posts to Jira** comment: command + result + any diagnostics
5. **Reviewer validates** result matches expected behavior

### Example Jira Comment
```markdown
[validation] E2E deployment test after reinstall

Command:
bash .agent/lab/launch-test-apps.py --env dev --max-wait 300

Result:
- e2e-mongo: PASS (running)
- e2e-postgres: PASS (running)
- e2e-vue3: PASS (running, endpoint responsive)
- e2e-fastapi: PASS (running)
- e2e-n8n: SKIP (not in TEST_APPS config)

Gate Status: PASS (all code + database templates working)
```

---

## 🔗 Related Documentation

- **Installer commands**: See `softwarefactory/README.md`
- **Infrastructure access**: See `.github/copilot-instructions.md` (SSH section)
- **Jira ticket workflow**: See `.agent/METHODOLOGY.md`
- **Configuration system**: See `kaanbal-api/app/defaults.py`
- **E2E validation**: See `.agent/lab/launch-test-apps.py` (if exists)

---

## 📬 Maintenance

Lab scripts are **self-service for team executors**:

- If a script becomes outdated → update it + commit to main with `[lab-update]` message
- If a script fails → add diagnostic output + document the blocker in Jira
- Old scripts → move to `.agent/lab/.archive/` + document why
- New patterns discovered → add to this README with examples

---

**Last Updated**: 2026-03-22  
**Created By**: Copilot Orchestrator  
**Purpose**: Support autonomous team execution with documented, validated test utilities
