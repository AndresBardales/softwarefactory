# Contributing to Software Factory

Thank you for your interest in improving Software Factory! This guide explains how to propose changes, report issues, and get your contributions merged.

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Development Setup](#development-setup)
3. [Branching & Commit Convention](#branching--commit-convention)
4. [Submitting a Pull Request](#submitting-a-pull-request)
5. [Issue Reporting](#issue-reporting)
6. [Code Style](#code-style)
7. [Testing Your Change](#testing-your-change)

---

## Getting Started

1. **Fork** the repository on GitHub
2. **Clone** your fork:
   ```bash
   git clone https://github.com/<your-username>/softwarefactory.git
   cd softwarefactory
   ```
3. **Add upstream** remote:
   ```bash
   git remote add upstream https://github.com/AndresBardales/softwarefactory.git
   ```
4. Keep your fork in sync before starting new work:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

---

## Development Setup

### Prerequisites

- Ubuntu 22.04+ (native, WSL2, or VM) — the installer is bash-only
- A VPS or VM with 4 GB RAM + 20 GB disk for end-to-end testing
- `git`, `curl`, `openssl` on the target machine
- A GitHub account and a Docker Hub account (free tiers work)

### Run the installer in development

```bash
# On your test VPS (not your laptop)
git clone https://github.com/<your-fork>/softwarefactory.git
cd softwarefactory
bash install.sh
```

Open `http://<vps-ip>:3000` with the token printed in the terminal.

### Backend / Frontend changes

For changes to nexus-api or nexus-console, see their respective repos:
- [nexus-api](https://github.com/AndresBardales/nexus-api)
- [nexus-console](https://github.com/AndresBardales/nexus-console)

Those repos follow the same process: fork → branch → PR.

---

## Branching & Commit Convention

### Branch names

```
<type>/<short-slug>
```

Examples:
- `feat/add-mysql-template`
- `fix/wizard-token-expiry`
- `docs/improve-install-guide`
- `chore/update-k3s-version`

### Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <summary>

[optional body]

[optional footer: BREAKING CHANGE: ...]
```

**Types:**
| Type | When to use | Version impact |
|------|-------------|----------------|
| `feat` | New feature | MINOR |
| `fix` | Bug fix | PATCH |
| `docs` | Documentation only | none |
| `chore` | Maintenance, deps, tooling | none |
| `refactor` | Code restructure (no behavior change) | none |
| `test` | Tests only | none |
| `perf` | Performance improvement | PATCH |

`BREAKING CHANGE:` in the footer triggers a MAJOR version bump.

**Examples:**
```
feat: add postgres template to catalog

fix: wizard fails when Tailscale key contains special chars

docs: add Hetzner VPS setup to INSTALL-GUIDE

feat!: change installer step numbering
BREAKING CHANGE: step 07 is now step 08 in all scripts
```

---

## Submitting a Pull Request

1. Create your branch from the latest `main`:
   ```bash
   git checkout -b feat/my-feature upstream/main
   ```

2. Make your changes. Keep each PR focused on **one thing**.

3. Test your change end-to-end (see [Testing Your Change](#testing-your-change)).

4. Push and open a PR against `AndresBardales/softwarefactory:main`:
   ```bash
   git push origin feat/my-feature
   # Then open PR on GitHub
   ```

5. Fill in the PR template — provide validation evidence (screenshots, command output, links).

6. A maintainer will review within 2-3 business days.

### What makes a good PR

- **Small scope** — one feature or bug fix per PR
- **Evidence** — show it works (terminal output, screenshot)
- **Clean commits** — squash "WIP" commits before submitting
- **Documentation** — if you add a new step or feature, update `README.md` or `INSTALL-GUIDE.md`

---

## Issue Reporting

Before opening a new issue, search existing issues to avoid duplicates.

**Bug reports** should include:
- OS version and installation mode (local/cloud/hybrid)
- Installer step where the failure occurred
- Error message or log excerpt
- Steps to reproduce

**Feature requests** should include:
- Use case (why is this needed?)
- Proposed behavior
- Any alternative solutions considered

---

## Code Style

### Bash (installer scripts)

- Use `set -euo pipefail` at the top of every script
- Use `log_info`, `log_warn`, `log_error` helper functions from `lib/00-common.sh`
- Prefer `local` variables inside functions
- Quote all variable expansions: `"$VAR"` not `$VAR`
- No hardcoded values — use `SF_*` config variables or placeholders (`__DOMAIN__`, `__WORKSPACE__`)

### Python (nexus-api)

- Follow PEP 8
- Run `ruff check .` before committing
- Keep endpoints thin — logic in service layer, not router

### Vue 3 (nexus-console)

- Composition API with `<script setup>`
- Tailwind CSS utility classes — no inline styles
- No hardcoded domains/URLs — use `src/config.js`

---

## Testing Your Change

### Installer changes

Run a clean install on a fresh VM/VPS:
```bash
# Clean state
sudo bash installer/steps/00-clean-install.sh

# Run full install
bash install.sh
```

Verify:
- [ ] All 11 steps complete without errors
- [ ] `http://<ip>:30080/setup` loads
- [ ] Admin login works
- [ ] One app deploys successfully (use a Vue or FastAPI template)

### Checking pre-flight only

```bash
bash installer/steps/01-system-check.sh
```

### Template changes

```bash
# Validate catalog JSON
python3 -c "import json; json.load(open('nexus-templates/catalog.json'))"
```

---

## Questions?

Open a [GitHub Discussion](https://github.com/AndresBardales/softwarefactory/discussions) for general questions.  
Use Issues only for confirmed bugs and feature requests.

Thank you for contributing!
