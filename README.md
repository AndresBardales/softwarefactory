<div align="center">

# ⚡ Kaanbal Engine

**Your Personal PaaS — Deploy your own cloud platform in minutes.**

*Created by Kaanbal BioTech*

Run apps, databases, and automations on any Linux server.

[![Release](https://img.shields.io/github/v/release/AndresBardales/softwarefactory?style=flat-square)](https://github.com/AndresBardales/softwarefactory/releases)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg?style=flat-square)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](CONTRIBUTING.md)

</div>

---

## What is Kaanbal Engine?

Kaanbal Engine turns **any Ubuntu server** into a complete development platform with:

- **Kubernetes (K3s)** — lightweight container orchestration
- **Web Dashboard** — deploy apps from templates with a few clicks
- **GitOps** — push code → auto-build → auto-deploy (ArgoCD)
- **Built-in databases** — MongoDB, PostgreSQL, MySQL templates
- **TLS & DNS** — automatic HTTPS via Let's Encrypt + Cloudflare
- **Private networking** — optional Tailscale VPN integration
- **Secrets management** — HashiCorp Vault, pre-configured

All of this is set up automatically by a **single command**.

## Quick Start

```bash
# On a fresh Ubuntu 22.04+ server (VPS, VM, or WSL2):
git clone https://github.com/AndresBardales/softwarefactory.git
cd softwarefactory
bash install.sh
```

A **web dashboard** opens at `http://<your-ip>:3000` with a secure setup token.  
Follow the 11 automated steps. When done, open `http://<your-ip>:30080/setup` to create your admin account.

> 📖 **First time?** Read the **[Step-by-Step Guide](GUIDE.md)** — it walks you through every screen, every credential, and every decision.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  1. INSTALLER         bash install.sh                           │
│     Web dashboard at :3000 with secure token                    │
│     → Installs K3s, MongoDB, API, Console, health checks       │
├─────────────────────────────────────────────────────────────────┤
│  2. SETUP WIZARD      http://<IP>:30080/setup                   │
│     Create admin account, connect Git & Docker Hub              │
│     → Platform is configured and ready                          │
├─────────────────────────────────────────────────────────────────┤
│  3. KAANBAL CONSOLE   http://<IP>:30080                         │
│     Deploy apps from templates, manage databases & services     │
└─────────────────────────────────────────────────────────────────┘
```

## Requirements

| Requirement | Minimum |
|-------------|---------|
| **OS** | Ubuntu 22.04+ (native, WSL2, or VM) |
| **RAM** | 4 GB |
| **Disk** | 20 GB free |
| **CPU** | 2 cores |
| **Network** | Public IP (for cloud mode) or localhost |

The installer automatically checks and installs dependencies (`curl`, `git`, `openssl`, etc.).

## Install Modes

| Mode | Use Case | What You Get |
|------|----------|--------------|
| **Local** | Development & testing | K3s + MongoDB + API + Dashboard on localhost |
| **Cloud** | Production on a VPS | Everything above + ArgoCD + Vault + TLS + domain |
| **Hybrid** | Local dev + public access | Local cluster exposed via Tailscale or Cloudflare |

## What Gets Deployed

| Component | Description | Modes |
|-----------|-------------|-------|
| K3s | Lightweight Kubernetes | All |
| kaanbal-api | Backend API (FastAPI) | All |
| kaanbal-console | Web Dashboard (Vue 3) | All |
| MongoDB | Database | All |
| ArgoCD | GitOps continuous delivery | Cloud, Hybrid |
| cert-manager | TLS certificates (Let's Encrypt) | Cloud, Hybrid |
| Vault | Secrets management | Cloud, Hybrid |
| Tailscale | Secure networking | Optional |

## After Install

Open the dashboard:
- **Local**: `http://localhost:30080`
- **Cloud/Hybrid**: `https://kaanbal-console.yourdomain.com`

The setup wizard walks you through creating your admin account and configuring credentials.

## CLI Tool

After installation, use the `kb` command:

```bash
kb status    # Cluster health and resource usage
kb apps      # List deployed applications
kb logs app  # Stream application logs
kb config    # View configuration (secrets masked)
kb upgrade   # Update to latest version
```

## Upgrade

```bash
kb upgrade
```

The CLI checks for new releases, downloads the update, verifies the checksum, and applies it. You can also upgrade manually:

```bash
# Download a specific version
curl -LO https://github.com/AndresBardales/softwarefactory/releases/download/v0.2.0/softwarefactory-v0.2.0.tar.gz
# Verify
sha256sum -c softwarefactory-v0.2.0.sha256
# Extract over existing install
tar -xzf softwarefactory-v0.2.0.tar.gz
```

## Project Structure

```
softwarefactory/
├── install.sh              # Entry point — just run this
├── package.sh              # Build distributable bundles
├── GUIDE.md                # Step-by-step install guide
├── CONTRIBUTING.md         # How to contribute
├── installer/
│   ├── install.sh          # Main orchestrator + dashboard
│   ├── kb                  # CLI management tool
│   ├── server.py           # Dashboard backend (Python)
│   ├── ui/index.html       # Dashboard frontend (Alpine.js)
│   ├── config.example.env  # Configuration template
│   ├── lib/                # Core libraries (preflight, wizard, deploy...)
│   └── steps/              # 12 install steps (00-11)
└── .github/
    └── workflows/
        └── release.yml     # Automated release pipeline
```

## Contributing

We welcome contributions! Whether it's a bug fix, new template, UI improvement, or documentation — all PRs are appreciated.

```bash
# Fork → Clone → Branch → Commit → PR
git checkout -b feat/my-improvement
git commit -m "feat: add Redis template"
git push origin feat/my-improvement
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide.

## Versioning

This project follows [Semantic Versioning](https://semver.org/):
- **PATCH** (0.1.x): Bug fixes, docs
- **MINOR** (0.x.0): New features, templates
- **MAJOR** (x.0.0): Breaking changes

Releases are published on [GitHub Releases](https://github.com/AndresBardales/softwarefactory/releases) with checksums and changelogs.

## License

[Apache 2.0](LICENSE) — use it, modify it, share it, including commercial use.

## Links

- 📦 [Releases](https://github.com/AndresBardales/softwarefactory/releases)
- 📖 [Install Guide](GUIDE.md)
- 🐛 [Report a Bug](https://github.com/AndresBardales/softwarefactory/issues/new?template=bug_report.yml)
- 💡 [Request a Feature](https://github.com/AndresBardales/softwarefactory/issues/new?template=feature_request.yml)
- 💬 [Discussions](https://github.com/AndresBardales/softwarefactory/discussions)
