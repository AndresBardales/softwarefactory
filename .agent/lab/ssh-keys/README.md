# SSH Keys Inventory for Team Execution

## Overview
Centralized SSH key management for Kaanbal Engine team executors. All keys are organized by **use case** and **key ID** for clarity.

---

## 🔐 Key Inventory (Validated)

### 1. **contabo.pem** 
- **Type**: OpenSSH RSA (2048-bit)
- **Format**: OpenSSH Private Key v1
- **Use Case**: Contabo standard key (currently not accepted by active VPS hosts)
- **Access**: `ssh -i contabo.pem ubuntu@<elastic_ip>`
- **Role**: Legacy/standard user access
- **Status**: ⚠️ Key valid; login currently denied on active hosts

### 2. **customer1**
- **Type**: OpenSSH Ed25519
- **Format**: OpenSSH Private Key v1
- **Use Case**: Active access key for Contabo PROD VPS
- **Access**: `ssh -i customer1 root@167.86.69.250`
- **Role**: Production VPS access (higher-capacity host)
- **Status**: ✅ Valid

### 2.1 **contabo-rescue**
- **Type**: OpenSSH Ed25519
- **Format**: OpenSSH Private Key
- **Use Case**: Active access key for Contabo DEV VPS and recovery operations
- **Access**: `ssh -i contabo-rescue root@161.97.112.80`
- **Role**: Development VPS access (lower-capacity host)
- **Status**: ✅ Valid

### 3. **fabric.pem**
- **Type**: RSA Private Key (PKCS#1)
- **Format**: Traditional RSA (BEGIN RSA PRIVATE KEY)
- **Use Case**: Fabric deployment automation (legacy)
- **Access**: Not in active use; retained for reference
- **Role**: Deprecated (kept for archive)
- **Status**: ✅ Valid (inactive)

### 4. **factory.pem**
- **Type**: RSA Private Key (PKCS#1)
- **Format**: Traditional RSA (BEGIN RSA PRIVATE KEY)
- **Use Case**: Factory automation / general infra
- **Access**: `ssh -i factory.pem <user>@<factory_host>`
- **Role**: Infrastructure automation tasks
- **Status**: ✅ Valid

---

## 📋 Public Key Companions

Each private key has a corresponding `.pub` file in `_private/keys/`:

| Private | Public | Fingerprint Verification |
|---------|--------|--------------------------|
| contabo.pem | contabo.pem.pub | `ssh-keygen -lf contabo.pem` |
| customer1 | customer1.pub | `ssh-keygen -lf customer1` |
| fabric.pem | — | (legacy, no .pub attached) |
| factory.pem | — | (check with provider) |

---

## 🛠️ Team Usage Rules

### For Team Prompts / Scripts
1. **Read from canonical location**: `_private/keys/`
2. **Never commit** any .pem to git (managed by `.gitignore`)
3. **Use customer1** for Contabo PROD (`167.86.69.250`)
4. **Use contabo-rescue** for Contabo DEV (`161.97.112.80`)
5. **Log key usage** in Jira comments (which key, which host, which operation)

### SSH Command Templates
```bash
# Production cluster access (higher-capacity host)
ssh -i "_private/keys/customer1" root@167.86.69.250

# Development cluster access (lower-capacity host)
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80

# MongoDB tunnel (prod)
ssh -i "_private/keys/customer1" -N -L 27017:datastore.prod.svc.cluster.local:27017 root@167.86.69.250

# Remote kubectl (prod)
ssh -i "_private/keys/customer1" root@167.86.69.250 "kubectl get nodes"
```

---

## 🔄 Key Rotation Policy

| Key | Last Updated | Expiry Check | Rotation | Notes |
|-----|--------------|--------------|----------|-------|
| contabo.pem | Unknown | Check VPS provider | If rotated, update .gitignore entry | Production |
| customer1 | Unknown | Check customer account | If lost, request from provider | Staging |
| fabric.pem | Legacy | N/A | Deprecate + archive | Not in use |
| factory.pem | Unknown | Check provider | If rotated, update scripts | Infra |

---

## 🚷 Security Checklist

- [ ] Never print key contents to logs or terminal history
- [ ] Never paste keys into Jira comments (post only key ID + use case)
- [ ] Never copy keys to `/tmp` unless absolutely necessary
- [ ] Always use `ssh-agent` if available, or `-i <path>` for explicit key selection
- [ ] Verify host fingerprint before first use: `ssh-keyscan -t rsa <host>`
- [ ] Audit SSH session logs after each remote operation

---

## 📝 Usage Examples (for team scripts)

### Contabo VPS Health Check
```bash
#!/bin/bash
KEY="_private/keys/contabo.pem"
IP="$(grep -oP 'CONTABO_IP=\K.*' _private/SETUP-CREDENTIALS.txt)"
ssh -i "$KEY" ubuntu@"$IP" "kubectl get nodes && kubelet status"
```

### Customer1 Test Deploy
```bash
#!/bin/bash
KEY="_private/keys/customer1"
IP="<customer_ip>"
ssh -i "$KEY" root@"$IP" "cd /opt && ./deploy.sh"
```

### Key Validation Script
```bash
#!/bin/bash
for key in _private/keys/*.pem _private/keys/{customer1,fabric.pem,factory.pem}; do
  if [ -f "$key" ]; then
    echo "Key: $key"
    ssh-keygen -lf "$key" 2>/dev/null || echo "  ERROR: Invalid format"
  fi
done
```

---

## 🔗 Related Documentation

- **[copilot-instructions.md](./../../../.github/copilot-instructions.md)** — SSH access section
- **[CLAUDE.md](./../../../CLAUDE.md)** — Infrastructure access guidelines
- **[SETUP-CREDENTIALS.txt](./_private/SETUP-CREDENTIALS.txt)** — IPs and token storage
- **[METHODOLOGY.md](./.agent/METHODOLOGY.md)** — Jira workflow + credential handling rules

---

## 🎯 Team Next Steps

1. **Before any remote operation**, read this README and confirm key ID matches target
2. **Log SSH usage** in Jira ticket comment (key name, host, command executed, outcome)
3. **If key access fails**, move ticket to BLOCKED and post: "SSH key [name] not responsive to [host]. Need credential update."
4. **Archive obsolete keys** after rotation (move to `_private/keys/.archive/`)

---

**Last Updated**: 2026-03-22  
**Maintained By**: Copilot Orchestrator  
**Review Frequency**: Quarterly (or on key rotation)
