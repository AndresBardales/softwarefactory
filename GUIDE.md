# Kaanbal Engine — Step-by-Step Install Guide

This guide walks you through every screen, every credential, and every decision — from a blank server to your first deployed app.

**Time**: ~20 minutes  
**Difficulty**: Beginner-friendly (no Kubernetes experience needed)

---

## Table of Contents

1. [Get a Server](#1-get-a-server)
2. [Connect to Your Server](#2-connect-to-your-server)
3. [Download & Run the Installer](#3-download--run-the-installer)
4. [The Install Dashboard](#4-the-install-dashboard)
5. [Prepare Your Credentials](#5-prepare-your-credentials)
6. [Watch the Install](#6-watch-the-install)
7. [Create Your Admin Account](#7-create-your-admin-account)
8. [Explore the Dashboard](#8-explore-the-dashboard)
9. [Deploy Your First App](#9-deploy-your-first-app)
10. [Managing Your Platform](#10-managing-your-platform)
11. [Upgrading](#11-upgrading)
12. [Troubleshooting](#12-troubleshooting)
13. [Contributing Back](#13-contributing-back)

---

## 1. Get a Server

You need a Linux server with **Ubuntu 22.04+**, at least **4 GB RAM** and **2 CPU cores**.

### Recommended Providers (cheapest options)

| Provider | Plan | RAM | Price | Notes |
|----------|------|-----|-------|-------|
| [Contabo](https://contabo.com) | VPS S | 8 GB | ~$7/mo | Best value |
| [Hetzner](https://hetzner.com/cloud) | CX22 | 4 GB | ~$4/mo | European |
| [DigitalOcean](https://digitalocean.com) | Basic | 4 GB | $24/mo | Easy UI |
| **Local (WSL2)** | — | 4 GB+ | Free | For testing only |

### What to choose when creating the server:
- **OS**: Ubuntu 22.04 LTS (or 24.04)
- **Type**: Cheapest VPS with 4+ GB RAM
- **Location**: Closest to you
- **SSH Key**: Upload your public key (or use password — the installer works either way)

> **Save your server's IP address** — you'll need it in the next step.

---

## 2. Connect to Your Server

### From Windows (PowerShell)
```powershell
ssh root@YOUR_SERVER_IP
```

### From Mac/Linux
```bash
ssh root@YOUR_SERVER_IP
```

### With SSH Key
```bash
ssh -i ~/.ssh/your_key root@YOUR_SERVER_IP
```

You should see a terminal prompt like `root@ubuntu:~#`. You're in.

---

## 3. Download & Run the Installer

```bash
git clone https://github.com/AndresBardales/softwarefactory.git
cd softwarefactory
bash install.sh
```

You'll see output like:
```
╔══════════════════════════════════════════════════════════════╗
║                   Kaanbal Engine Installer                  ║
║                                                              ║
║  Dashboard: http://YOUR_IP:3000                              ║
║  Token:     a1b2c3d4e5f6                                     ║
╚══════════════════════════════════════════════════════════════╝
```

> **Copy the token** shown in the terminal — you'll paste it in the browser.

---

## 4. The Install Dashboard

Open your browser and go to:
```
http://YOUR_SERVER_IP:3000
```

You'll see the Kaanbal Engine install dashboard. Paste the **setup token** from the terminal.

The dashboard shows 12 steps. Each step runs automatically, showing real-time logs. Here's what each one does:

| Step | Name | What It Does | Time |
|------|------|-------------|------|
| 00 | Clean Install | Removes any previous install | 10s |
| 01 | System Check | Validates OS, RAM, CPU, disk | 5s |
| 02 | Dependencies | Installs curl, git, helm, etc. | 30s |
| 03 | Kubernetes | Deploys K3s lightweight cluster | 60s |
| 04 | Configuration | Collects your credentials | Interactive |
| 05 | Core Services | Deploys ingress, cert-manager, namespaces | 90s |
| 06 | Source Repos | Creates your Git repos, triggers CI/CD | 120s |
| 07 | Database | Deploys MongoDB with persistent storage | 60s |
| 08 | Platform API | Deploys kaanbal-api backend | 60s |
| 09 | Platform Console | Deploys kaanbal-console dashboard | 60s |
| 10 | Health Check | Verifies all services are running | 30s |
| 11 | Finalize | Seeds admin user, installs CLI, smoke tests | 30s |

---

## 5. Prepare Your Credentials

**Step 04 (Configuration)** will ask for credentials. Here's what you need and where to get each one:

### Required for ALL modes

#### Git Provider (GitHub)

1. Go to [github.com](https://github.com) → Sign up (free)
2. Go to **Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens**
3. Click **Generate new token**:
   - **Name**: `software-factory`
   - **Expiration**: 90 days (or custom)
   - **Repository access**: All repositories
   - **Permissions**:
     - Repository: `Contents` (Read and Write)
     - Repository: `Actions` (Read and Write)
     - Repository: `Secrets` (Read and Write)
     - Repository: `Metadata` (Read)
4. Click **Generate token** and **copy it immediately** (you won't see it again)

> **You'll enter**: your GitHub username + the token

#### Docker Hub

1. Go to [hub.docker.com](https://hub.docker.com) → Sign up (free)
2. Go to **Account Settings → Security → Access Tokens**
3. Click **New Access Token**:
   - **Description**: `software-factory`
   - **Permissions**: Read, Write, Delete
4. **Copy the token**

> **You'll enter**: your Docker Hub username + the token

### Required for CLOUD / HYBRID mode

#### Domain + Cloudflare (for HTTPS and DNS)

1. **Buy a domain** at any registrar (Namecheap, GoDaddy, Cloudflare...)
   - Cheap TLDs: `.xyz` (~$2/yr), `.site` (~$1/yr), `.dev` (~$12/yr)
2. **Add it to Cloudflare** (free plan):
   - Go to [cloudflare.com](https://cloudflare.com) → Add Site → enter your domain
   - Change your domain's nameservers to Cloudflare's (registrar settings)
3. **Get your API token**:
   - Cloudflare dashboard → My Profile → API Tokens → Create Token
   - Use template: **Edit zone DNS**
   - Zone: your domain
   - Click **Create Token** and copy it

> **You'll enter**: your domain (e.g., `myplatform.dev`) + Cloudflare API token

#### Tailscale (optional — for private VPN access)

1. Go to [tailscale.com](https://tailscale.com) → Sign up (free for personal use)
2. Install Tailscale on your local machine (laptop/desktop)
3. Get an **auth key**:
   - Tailscale admin console → Settings → Keys → Generate auth key
   - Check **Reusable** and **Ephemeral**
4. Get your **tailnet name**:
   - Tailscale admin → DNS page → look for `*.ts.net` suffix (e.g., `tail1234.ts.net`)

> **You'll enter**: Tailscale auth key + tailnet DNS suffix

### Summary Checklist

```
□ GitHub username
□ GitHub personal access token
□ Docker Hub username
□ Docker Hub access token
□ Domain name (cloud/hybrid only)
□ Cloudflare API token (cloud/hybrid only)
□ Tailscale auth key (optional)
□ Tailscale DNS suffix (optional)
```

---

## 6. Watch the Install

After entering credentials, the installer runs all remaining steps automatically. You can watch the real-time logs in the dashboard.

**Common things you'll see:**
- `[✓] K3s installed` — Kubernetes is ready
- `[✓] kaanbal-api repo created` — your Git repo was set up
- `[→] Waiting for CI/CD pipeline...` — GitHub Actions is building your Docker images
- `[✓] All services healthy` — everything is running

> **Step 06 takes the longest** (~2 min) because it waits for GitHub Actions to build and push Docker images.

If a step fails, the dashboard shows the error. You can retry from the failed step — no need to start over.

---

## 7. Create Your Admin Account

When the install finishes, open:
```
http://YOUR_SERVER_IP:30080/setup
```

You'll see the **Setup Wizard**:

1. **Admin Account**: Enter your name, email, and password
   - This is YOUR platform admin account (not Git or Docker credentials)
   - Save this password — it's how you log into the dashboard
2. **Git Connection**: Verify your GitHub credentials work
3. **Docker Connection**: Verify Docker Hub credentials work
4. **Done!** → You're redirected to the main dashboard

---

## 8. Explore the Dashboard

The Kaanbal Console (`http://YOUR_SERVER_IP:30080`) is your platform control panel:

- **Apps** — See all deployed applications
- **Templates** — Browse available app templates (FastAPI, Vue, MongoDB, PostgreSQL, etc.)
- **Environments** — Manage dev/staging/prod
- **Settings** — Update platform configuration
- **Logs** — View application logs

---

## 9. Deploy Your First App

Let's deploy a FastAPI backend from a template:

1. Click **"New App"** in the dashboard
2. Choose template: **FastAPI API**
3. Enter a name: `my-first-api`
4. Select environment: `prod`
5. Click **Deploy**

What happens behind the scenes:
1. A new GitHub repo is created: `your-username/my-first-api`
2. Template code is pushed to it
3. GitHub Actions builds a Docker image
4. ArgoCD detects the new image and deploys it to Kubernetes
5. Your app is running!

Access your app:
- **Local mode**: `http://localhost:30081` (check the port in the dashboard)
- **Cloud mode**: `https://my-first-api.yourdomain.com`

---

## 10. Managing Your Platform

### CLI Commands

The `kb` command is installed globally on your server:

```bash
# Check everything is running
kb status

# See your apps
kb apps

# View logs for an app
kb logs my-first-api --follow

# View your configuration (secrets masked)
kb config
```

### Pushing Code Changes

Your apps use GitOps. To update an app:

```bash
# On your local machine
git clone https://github.com/YOUR-USERNAME/my-first-api.git
cd my-first-api

# Make changes...
git add .
git commit -m "feat: add new endpoint"
git push origin main
```

GitHub Actions automatically rebuilds → ArgoCD automatically redeploys. You see the new version in ~2 minutes.

### SSH into your server

```bash
ssh root@YOUR_SERVER_IP

# Check Kubernetes directly
kubectl get pods -n prod
kubectl logs -n prod deployment/my-first-api

# Check ArgoCD
kubectl get applications -n argocd
```

---

## 11. Upgrading

### Automatic (recommended)
```bash
kb upgrade
```

This checks for new versions, downloads, verifies the checksum, and updates.

### Manual
```bash
cd ~/softwarefactory
git pull origin main
bash install.sh  # Re-runs only what changed
```

---

## 12. Troubleshooting

### "Step 06 failed — repo not created"
- **Check**: Is your GitHub token valid? Does it have repo + actions permissions?
- **Fix**: Re-run step 06 from the dashboard (click Retry)

### "Step 08 failed — kaanbal-api not starting"
- **Check**: `kubectl logs -n prod deployment/kaanbal-api`
- **Common cause**: Docker image hasn't been built yet. Wait for GitHub Actions to finish, then retry.

### "Can't access :30080 after install"
- **Check**: `kubectl get pods -n prod` — is `kaanbal-console` running?
- **Check**: Is port 30080 open in your VPS firewall?
- **Fix** (Contabo/Hetzner): `ufw allow 30080/tcp`

### "DNS not working (cloud mode)"
- **Check**: Are your Cloudflare nameservers active? (can take 24h on first setup)
- **Check**: `dig kaanbal-console.yourdomain.com` — does it point to your server IP?

### "kb command not found"
```bash
# Re-install the CLI
sudo cp ~/softwarefactory/installer/kb /usr/local/bin/kb
sudo chmod +x /usr/local/bin/kb
```

### General debug
```bash
# Show all pods
kubectl get pods -A

# Describe a problematic pod
kubectl describe pod -n prod POD_NAME

# Check events
kubectl get events -n prod --sort-by='.lastTimestamp'

# Full system status
sf status
```

---

## 13. Contributing Back

Found a bug? Have an idea? Here's how to contribute:

### Report a Bug
→ [Open a bug report](https://github.com/AndresBardales/softwarefactory/issues/new?template=bug_report.yml)

### Suggest a Feature
→ [Open a feature request](https://github.com/AndresBardales/softwarefactory/issues/new?template=feature_request.yml)

### Submit Code

```bash
# 1. Fork the repo on GitHub (click the Fork button)
# 2. Clone YOUR fork
git clone https://github.com/YOUR-USERNAME/softwarefactory.git
cd softwarefactory

# 3. Create a branch for your change
git checkout -b feat/my-improvement

# 4. Make changes, commit with conventional format
git add .
git commit -m "feat: add Redis template to catalog"

# 5. Push to YOUR fork
git push origin feat/my-improvement

# 6. Open a Pull Request
#    Go to your fork on GitHub → "Compare & pull request"
#    Fill in the PR template: what changed, how to test
```

The maintainer reviews your PR, and if it's good — it gets merged into the next release.

### What's a good first contribution?
- Fix a typo in documentation
- Add a troubleshooting tip
- Create a new app template
- Improve error messages in the installer
- Translate the guide to another language

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide.

---

## Credential Quick Reference

| Service | What you need | Where to get it | Free? |
|---------|--------------|-----------------|-------|
| GitHub | Username + Token | Settings → Developer Settings → Tokens | Yes |
| Docker Hub | Username + Token | Account Settings → Security → Tokens | Yes |
| Cloudflare | API Token | My Profile → API Tokens | Yes (free plan) |
| Tailscale | Auth Key + DNS suffix | Admin Console → Settings → Keys | Yes (personal) |
| Domain | Domain name | Any registrar | ~$2-12/yr |
| VPS | IP + SSH access | Contabo, Hetzner, DO, etc. | ~$4-7/mo |

---

**That's it!** You now have your own cloud platform. Deploy apps, invite collaborators, and build whatever you want.

Questions? [Open a discussion](https://github.com/AndresBardales/softwarefactory/discussions).
