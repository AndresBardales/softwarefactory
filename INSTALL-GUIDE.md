# Software Factory — Complete Install Guide

> **This guide walks you step by step from zero to a running platform.**
> You will need ~30 minutes. Most of that time is services starting up.

---

## Table of Contents

1. [Before You Start — Accounts & Credentials](#1-before-you-start--accounts--credentials)
2. [Provision Your VPS](#2-provision-your-vps)
3. [SSH Into Your Server](#3-ssh-into-your-server)
4. [Clone & Run the Installer](#4-clone--run-the-installer)
5. [Wizard Walkthrough (Steps 1–11)](#5-wizard-walkthrough-steps-111)
6. [Credentials Reference Card](#6-credentials-reference-card)
7. [After Install — Setup Wizard](#7-after-install--setup-wizard)
8. [Deploy Your First App](#8-deploy-your-first-app)
9. [Upgrade to a New Version](#9-upgrade-to-a-new-version)
10. [Contribute a Feature (Fork → PR Flow)](#10-contribute-a-feature-fork--pr-flow)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Before You Start — Accounts & Credentials

You will need accounts for these services. All have free tiers that are enough.

---

### 1.1 GitHub (Required)

Used to host your application code and run CI/CD pipelines.

1. Go to [github.com](https://github.com) → Sign up
2. Create an **Organization** (recommended) or use your personal account
   - Settings → Organizations → New organization → Free plan
   - Example org name: `my-factory`
3. Generate a **Personal Access Token (Classic)**
   - GitHub → Profile → Settings → Developer settings → Personal access tokens → Tokens (classic)
   - Click **Generate new token (classic)**
   - Note: `Software Factory installer`
   - Expiration: 90 days (or No expiration for personal use)
   - Scopes to check:
     - ✅ `repo` (full repo access)
     - ✅ `workflow` (GitHub Actions)
     - ✅ `write:packages`
     - ✅ `admin:repo_hook`
   - Click **Generate token**
   - **Copy it now** — you will not see it again
   - Format looks like: `ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

> **Save this as:** `SF_GIT_TOKEN`

---

### 1.2 Docker Hub (Required)

Used to store your application images that get built by GitHub Actions.

1. Go to [hub.docker.com](https://hub.docker.com) → Sign up
2. Note your **username** (e.g., `johndoe`)
3. Generate an **Access Token**
   - Account Settings (top-right menu) → Security → New Access Token
   - Description: `Software Factory`
   - Permissions: **Read, Write, Delete**
   - Click **Generate**
   - **Copy it now**
   - Format looks like: `dckr_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

> **Save as:** `SF_DOCKER_USERNAME` + `SF_DOCKER_TOKEN`

---

### 1.3 Cloudflare (Required for public domain)

Used to automatically create DNS records when you deploy apps.

1. Go to [cloudflare.com](https://cloudflare.com) → Sign up (free)
2. Add your domain → click **Add a site** → enter your domain → Free plan
3. Follow Cloudflare's nameserver instructions to point your domain to Cloudflare
   - (Log in to your domain registrar → change nameservers to the two Cloudflare provides)
4. Once active, generate an **API Token**
   - My Profile → API Tokens → **Create Token**
   - Use template: **Edit zone DNS**
   - Zone Resources: Include → Specific zone → `your-domain.com`
   - Click **Continue to summary** → **Create Token**
   - **Copy the token now**
   - Format: `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
5. Get your **Zone ID**
   - Cloudflare dashboard → select your domain → Overview → right sidebar
   - Copy the **Zone ID** value

> **Save as:** `SF_CLOUDFLARE_TOKEN` + `SF_CLOUDFLARE_ZONE_ID`

---

### 1.4 Tailscale (Recommended for private access)

Used to access dev/staging environments over a private VPN without exposing them publicly.

1. Go to [tailscale.com](https://tailscale.com) → Sign up (free for personal use)
2. Generate an **Auth Key**
   - Settings → Keys → **Generate auth key**
   - ✅ Reusable
   - ✅ Ephemeral (nodes auto-expire when inactive)
   - Tags: leave empty or add `tag:k8s`
   - Expiry: 90 days
   - Click **Generate key**
   - Format looks like: `tskey-auth-xxxxxxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
3. Note your **Tailnet name** (visible on the dashboard, e.g., `youremail.github`)
   - The DNS suffix will be `<something>.ts.net`

> **Save as:** `SF_TAILSCALE_AUTH_KEY` + your tailnet DNS suffix (e.g., `tail1abc2.ts.net`)

---

### Summary Table

| Credential | Variable Name | Where to Get |
|---|---|---|
| GitHub org/user | `SF_GIT_WORKSPACE` | github.com → your account username |
| GitHub token | `SF_GIT_TOKEN` | Settings → Developer settings → PAT (classic) |
| Docker Hub user | `SF_DOCKER_USERNAME` | hub.docker.com → your username |
| Docker Hub token | `SF_DOCKER_TOKEN` | Account Settings → Security → New Access Token |
| Your domain | `SF_DOMAIN` | Your domain registrar |
| Cloudflare token | `SF_CLOUDFLARE_TOKEN` | Profile → API Tokens → Edit zone DNS |
| Cloudflare zone | `SF_CLOUDFLARE_ZONE_ID` | Domain overview → right sidebar |
| Tailscale key | `SF_TAILSCALE_AUTH_KEY` | Settings → Keys → Generate auth key |

---

## 2. Provision Your VPS

### Minimum requirements

| Resource | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB | 40 GB+ |
| CPU | 2 cores | 4 cores |
| Network | 100 Mbps | 1 Gbps |
| IP | Public IPv4 | Public IPv4 |

### Provider recommendations

| Provider | Plan | Monthly Cost | Notes |
|---|---|---|---|
| [Contabo](https://contabo.com) | VPS M | ~$8 | Great value, EU/US DC |
| [Hetzner](https://hetzner.com) | CX22 | ~$5 | Fast network, EU/US |
| [DigitalOcean](https://digitalocean.com) | Basic $12 | $12 | Simple UI, good docs |
| [Vultr](https://vultr.com) | Regular 4GB | $24 | Many locations |
| AWS EC2 | t3.medium | ~$30 | Best if you use other AWS services |

### Firewall / Security group

Open these ports before starting:

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP (redirects to HTTPS) |
| 443 | TCP | HTTPS (public apps) |
| 3000 | TCP | Installer dashboard (close after install) |
| 6443 | TCP | Kubernetes API (optional, for local kubectl) |
| 30080 | TCP | Nexus Console (temporary, during setup) |

---

## 3. SSH Into Your Server

```bash
# With PEM key (AWS / Contabo):
ssh -i /path/to/your-key.pem ubuntu@<your-vps-ip>

# With password (DigitalOcean / Hetzner):
ssh root@<your-vps-ip>
```

---

## 4. Clone & Run the Installer

```bash
# Install git if not present
sudo apt-get update && sudo apt-get install -y git curl

# Clone Software Factory
git clone https://github.com/AndresBardales/softwarefactory.git
cd softwarefactory

# Start the installer
bash install.sh
```

You will see output like:
```
╔════════════════════════════════════════╗
║   Software Factory Installer v0.1.0   ║
╚════════════════════════════════════════╝

  Dashboard: http://161.97.112.80:3000
  Token:     abc123xyz789

  Open the URL above in your browser to continue.
  Press Ctrl+C to stop.
```

**Open your browser to `http://<your-vps-ip>:3000` and enter the token.**

---

## 5. Wizard Walkthrough (Steps 1–11)

The installer runs 11 automated steps. The dashboard shows live progress.

| Step | Name | What Happens |
|---|---|---|
| 01 | System Check | Verifies OS, RAM, disk, CPU, and required tools |
| 02 | Dependencies | Installs Docker, kubectl, helm, jq, etc. |
| 03 | K3s | Installs Kubernetes (K3s) on your server |
| 04 | Credentials | **You enter your credentials here** (see section 6) |
| 05 | Core Services | Deploys ArgoCD, Vault, cert-manager, Traefik |
| 06 | Source Repos | Creates your GitHub repos and sets up CI/CD |
| 07 | Database | Deploys MongoDB (your app datastore) |
| 08 | Platform API | Deploys nexus-api (the backend) |
| 09 | Platform Console | Deploys nexus-console (the web dashboard) |
| 10 | Health Check | Verifies all services are running |
| 11 | Finalize | Creates admin user, seeds config, prints login URL |

### Step 04 — Entering Credentials

This is the most important step. A form appears in the dashboard asking for:

1. **Install mode** → choose `cloud` for a VPS with a public domain
2. **Git provider** → `github`
3. **Git workspace / org** → your GitHub org or username
4. **Git token** → your `ghp_...` token
5. **Docker Hub username** → your Docker Hub username
6. **Docker Hub token** → your `dckr_pat_...` token
7. **Domain** → `yourdomain.com`
8. **Cloudflare API token** → your Cloudflare token
9. **Cloudflare Zone ID** → your zone ID
10. **Tailscale auth key** → your `tskey-auth-...` key

> Tip: Keep the [Credentials Reference Card](#6-credentials-reference-card) open in another tab.

---

## 6. Credentials Reference Card

Print or bookmark this for quick lookup during install:

```
┌─────────────────────────────────────────────────────────────────────┐
│              SOFTWARE FACTORY — CREDENTIALS CARD                    │
├─────────────────────────┬───────────────────────────────────────────┤
│ WHERE TO GET             │ FORMAT                                   │
├─────────────────────────┴───────────────────────────────────────────┤
│ GITHUB                                                              │
│  ↳ github.com → Settings → Developer settings → PAT (classic)      │
│  Token looks like: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx            │
├─────────────────────────────────────────────────────────────────────┤
│ DOCKER HUB                                                          │
│  ↳ hub.docker.com → Account Settings → Security → New Access Token  │
│  Token looks like: dckr_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx         │
├─────────────────────────────────────────────────────────────────────┤
│ CLOUDFLARE                                                          │
│  ↳ cloudflare.com → Profile → API Tokens → Edit zone DNS            │
│  Token looks like: 40-char alphanumeric string                      │
│  Zone ID: Dashboard → your domain → Overview → right sidebar        │
├─────────────────────────────────────────────────────────────────────┤
│ TAILSCALE                                                           │
│  ↳ tailscale.com → Settings → Keys → Generate auth key              │
│  Token looks like: tskey-auth-xxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. After Install — Setup Wizard

When step 11 finishes, the installer prints:

```
════════════════════════════════════════
   Software Factory is ready!
════════════════════════════════════════

   Console:   https://console.yourdomain.com
              (or http://<ip>:30080 if DNS not yet propagated)

   Setup:     https://console.yourdomain.com/setup
              (create your admin account here)

   Tailscale: https://console.<tailnet>.ts.net (VPN only)
════════════════════════════════════════
```

1. Open the setup URL
2. Create your **admin account** (username + strong password)
3. You will be redirected to the main dashboard

---

## 8. Deploy Your First App

1. Log in to the console
2. Click **"New App"** in the top right
3. Choose a template: `vue3-spa`, `fastapi-api`, `mongodb-db`, `mysql-db`
4. Fill in:
   - **App name** — lowercase, letters and numbers only (e.g., `my-frontend`)
   - **Environments** — check `dev`, `staging`, `prod` as needed
   - **Exposure** — `public` (Cloudflare DNS) or `tailscale` (VPN-only)
5. Click **Deploy**

The platform will:
- Create a GitHub repo under your org
- Push the template code
- Trigger GitHub Actions (builds Docker image)
- Deploy to Kubernetes via ArgoCD
- Create DNS records automatically

Within ~3 minutes, your app is live at:
- `https://my-frontend.yourdomain.com` (prod)
- `https://dev.my-frontend.yourdomain.com` (dev)
- `https://my-frontend.<tailnet>.ts.net` (VPN)

---

## 9. Upgrade to a New Version

```bash
# From your server, using the sf CLI
sf upgrade

# Or with a specific channel
SF_UPDATE_CHANNEL=rc sf upgrade

# Check current version
sf --version
```

The upgrade command will:
1. Fetch the versions manifest from GitHub
2. Compare your current version
3. Download and validate the new installer
4. Apply the update
5. Print rollback instructions if something goes wrong

---

## 10. Contribute a Feature (Fork → PR Flow)

This is how you propose improvements to Software Factory.

### 10.1 Fork the repo

```
github.com/AndresBardales/softwarefactory → Fork → your-username/softwarefactory
```

### 10.2 Clone your fork

```bash
git clone https://github.com/<your-username>/softwarefactory.git
cd softwarefactory
git remote add upstream https://github.com/AndresBardales/softwarefactory.git
```

### 10.3 Create a branch

```bash
git checkout -b feat/my-awesome-feature upstream/main
```

### 10.4 Make your change

Edit the installer scripts, README, templates, etc.

Commit using [Conventional Commits](https://www.conventionalcommits.org/):

```bash
git add .
git commit -m "feat: add nginx proxy template to catalog"
```

### 10.5 Push and open a PR

```bash
git push origin feat/my-awesome-feature
# Then open a Pull Request at github.com
```

Fill in the PR template — show evidence that your change works.
A maintainer will review and merge or request changes.

### 10.6 After your PR is merged

Your contribution is now in `main`. When the next version is tagged, it will be in the release and available to all users via `sf upgrade`.

---

## 11. Troubleshooting

### Installer stuck at step X

1. Check the logs in the dashboard (click the step card)
2. SSH into your server and run:
   ```bash
   kubectl get pods -A
   kubectl describe pod <pod-name> -n <namespace>
   ```

### "Setup endpoint already called" error

The installer is idempotent — safe to re-run. If you see errors, run:
```bash
bash install.sh
```
It will pick up from where it left off.

### "Template not found — skipping" for step 06

The installer cannot find the code tarballs. This means the installer was not packaged correctly.
Solution: Re-clone from the official repo:
```bash
cd ..
rm -rf softwarefactory
git clone https://github.com/AndresBardales/softwarefactory.git
cd softwarefactory
bash install.sh
```

### ArgoCD shows Degraded / Progressing

Give it 5–10 minutes after install. Then run:
```bash
sf status
```

### Can't access console after install

DNS may not have propagated yet (up to 24h, usually 5 min with Cloudflare).
Use the direct IP + port in the meantime:
```
http://<your-vps-ip>:30080
```

### Reset admin password

```bash
# From the server
kubectl -n prod exec deploy/nexus-api -- python3 -c "
import asyncio, motor.motor_asyncio, os
db = motor.motor_asyncio.AsyncIOMotorClient(os.environ['MONGODB_URI'])['forge']
asyncio.run(db.users.update_one({'username': 'admin'}, {'\$set': {'password': 'NEW_HASHED_PASSWORD'}}))"
```

Or contact the maintainer for a reset script.

---

*Guide version: aligned with Software Factory v0.1.0*  
*Last updated: 2026-03-19*
