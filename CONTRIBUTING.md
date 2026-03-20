# Contributing to Kaanbal Engine

Thanks for your interest in improving Kaanbal Engine! This guide will help you get started.

## Quick Start for Contributors

```bash
# 1. Fork the repo on GitHub
# 2. Clone your fork
git clone https://github.com/YOUR-USERNAME/softwarefactory.git
cd softwarefactory

# 3. Create a feature branch
git checkout -b feat/my-improvement

# 4. Make your changes, then commit
git add .
git commit -m "feat: add cool new feature"

# 5. Push and open a Pull Request
git push origin feat/my-improvement
```

Then open a PR at [github.com/AndresBardales/softwarefactory](https://github.com/AndresBardales/softwarefactory/pulls).

## Commit Convention

We use [Conventional Commits](https://www.conventionalcommits.org/) to automate changelogs and versioning:

| Prefix | When to use | Version bump |
|--------|-------------|-------------|
| `feat:` | New feature or capability | MINOR |
| `fix:` | Bug fix | PATCH |
| `docs:` | Documentation only | PATCH |
| `refactor:` | Code change that doesn't fix or add | — |
| `chore:` | Build, CI, tooling | — |
| `BREAKING CHANGE:` | Incompatible change (in body) | MAJOR |

**Examples:**
```
feat: add PostgreSQL template to catalog
fix: installer hangs on step 06 when Git token has special chars
docs: add troubleshooting section for Tailscale DNS
chore: update K3s version to v1.30
```

## What You Can Contribute

### Templates (Easiest)
Add new app/database templates to `installer/` or the template catalog. See [kaanbal-templates](https://github.com/AndresBardales/kaanbal-templates) for the schema.

### Installer Improvements
- New install step or mode
- Better error handling
- Support for more Linux distros
- Localization (i18n)

### Dashboard (kaanbal-console)
- UI/UX improvements
- New views or widgets
- Accessibility fixes

### API (kaanbal-api)
- New endpoints
- Performance improvements
- Additional provider integrations

### Documentation
- Fix typos, improve clarity
- Add guides for specific use cases
- Translate to other languages

## Development Setup

### Testing the installer locally

You can test in a VM or WSL2 (Ubuntu 22.04+):

```bash
# Option A: Full install (needs 4GB RAM VM)
bash install.sh

# Option B: Just test the wizard (no K8s changes)
bash install.sh --dry-run   # (planned)
```

### Testing individual steps

Each step can be sourced and tested independently:

```bash
source installer/lib/00-common.sh
source installer/lib/01-preflight.sh
check_system_requirements
```

## Pull Request Guidelines

1. **One PR = one logical change.** Don't mix features with refactors.
2. **Test on a clean Ubuntu VM** if your change touches the install flow.
3. **Update documentation** if you add or change behavior.
4. **Keep PR description clear**: what changed, why, how to test.
5. **Screenshots welcome** for UI changes.

## Code Style

- **Shell scripts**: Follow existing patterns. Use `set -euo pipefail`. Functions prefixed by purpose (`log_`, `check_`, `deploy_`).
- **Python (kaanbal-api)**: Black formatter, type hints where practical.
- **Vue/JS (kaanbal-console)**: Composition API, Tailwind CSS.

## Reporting Issues

Use [GitHub Issues](https://github.com/AndresBardales/softwarefactory/issues). Include:

- **OS and version** (e.g., Ubuntu 22.04 on Contabo VPS)
- **Install mode** (local / cloud / hybrid)
- **Step that failed** (e.g., "Step 06 — Source Repos")
- **Logs**: paste relevant lines from the dashboard or terminal
- **Expected vs actual behavior**

## Code of Conduct

Be respectful. We're building tools to help developers — everyone is welcome regardless of experience level. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Questions?

Open a [Discussion](https://github.com/AndresBardales/softwarefactory/discussions) or file an issue with the `question` label.
