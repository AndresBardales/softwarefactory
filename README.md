# Software Factory

Your Personal PaaS. Deploy your own cloud platform in minutes.

Run apps, databases, and automations — locally, in the cloud, or hybrid.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  1. INSTALLER         bash install.sh                           │
│     Web dashboard at :3000 with secure token                    │
│     ↓ Installs K3s, MongoDB, API, Console, health checks       │
├─────────────────────────────────────────────────────────────────┤
│  2. SETUP WIZARD      http://<IP>:30080/setup                   │
│     Create admin account, connect Git & Docker Hub              │
│     ↓ Platform is now configured and ready                      │
├─────────────────────────────────────────────────────────────────┤
│  3. NEXUS CONSOLE     http://<IP>:30080                         │
│     Deploy apps from templates, manage databases & services     │
└─────────────────────────────────────────────────────────────────┘
```

## Requirements

- **OS**: Ubuntu 22.04+ (native Linux, WSL2, or VM)
- **RAM**: 4 GB minimum
- **Disk**: 20 GB free
- **CPU**: 2+ cores
- Tools: `curl`, `git`, `openssl` (installer checks automatically)

## Quick Start

```bash
git clone https://github.com/AndresBardales/softwarefactory.git
cd softwarefactory
bash install.sh
```

The installer launches a **web dashboard** at `http://<your-ip>:3000`.  
A **setup token** is printed in the terminal — paste it in the browser to begin.

11 automated steps run in sequence: system check → dependencies → K3s → credentials → core services → source repos → database → platform API → platform console → health check → finalize.

When complete, open `http://<your-ip>:30080/setup` to create your admin account and connect your Git and Docker credentials.

## Install Modes

| Mode | Use Case | What You Get |
|------|----------|--------------|
| **Local** | Development & testing | K3s + MongoDB + API + Dashboard on localhost |
| **Cloud** | Production on a VPS | Everything above + ArgoCD + Vault + TLS + domain |
| **Hybrid** | Local dev + public access | Local cluster exposed via Tailscale or cloud gateway |

## What Gets Deployed

| Component | Description | Modes |
|-----------|-------------|-------|
| K3s | Lightweight Kubernetes | All |
| nexus-api | Backend API (FastAPI) | All |
| nexus-console | Web Dashboard (Vue 3) | All |
| MongoDB | Database | All |
| ArgoCD | GitOps continuous delivery | Cloud, Hybrid |
| cert-manager | TLS certificates (Let's Encrypt) | Cloud, Hybrid |
| Vault | Secrets management | Cloud, Hybrid |
| Tailscale | Secure networking | Optional |

## After Install

Open the dashboard:
- **Local**: `http://localhost:30080`
- **Cloud/Hybrid**: `https://nexus-console.yourdomain.com`

The setup wizard will walk you through creating your admin account and configuring credentials.

## CLI Tool

After installation, use the `sf` command to manage your platform:

```bash
sf status    # Cluster health and resource usage
sf apps      # List deployed applications
sf logs app  # Stream application logs
sf config    # View configuration (secrets masked)
sf upgrade   # Update to latest images
```

## Project Structure

```
softwarefactory/
├── install.sh              # Root entry point
└── installer/
    ├── install.sh          # Main orchestrator
    ├── sf                  # CLI management tool
    └── lib/
        ├── 00-common.sh    # Logging, prompts, utilities
        ├── 01-preflight.sh # OS and resource validation
        ├── 02-wizard.sh    # Interactive configuration
        ├── 03-k3s.sh       # Kubernetes setup
        ├── 04-core.sh      # Infrastructure (Helm charts)
        ├── 05-deploy.sh    # App deployment
        └── 06-postinstall.sh # Admin user, health checks
```

## License

MIT

## Links

- Website: [open-source.futurefarms.mx](https://open-source.futurefarms.mx)
- Built by [FutureFarms](https://futurefarms.mx)
