# SSH Key Selection Guide for Team Executors

## Quick Decision Tree

### ❓ What are you trying to do?

#### 🏢 **Access Production Cluster (Contabo VPS)**
- **Use**: `contabo.pem`
- **Target User**: `ubuntu`
- **Command**: 
  ```bash
  ssh -i "_private/keys/contabo.pem" ubuntu@<CONTABO_ELASTIC_IP>
  ```
- **Common Tasks**: 
  - Kubectl operations
  - ArgoCD management
  - Cluster diagnostics
  - K3s maintenance
- **Jira Comment Template**:
  ```
  [runtime] SSH to contabo.pem / ubuntu@<IP>
  Command: kubectl get nodes
  Result: [paste output]
  ```

---

#### 🧪 **Access Staging/Test Environment**
- **Use**: `customer1`
- **Target User**: `root`
- **Command**:
  ```bash
  ssh -i "_private/keys/customer1" root@<CUSTOMER_IP>
  ```
- **Common Tasks**:
  - Pre-production validation
  - Customer environment setup
  - Test deployments
  - Configuration review
- **Jira Comment Template**:
  ```
  [builder] SSH to customer1 / root@<IP>
  Command: [operation]
  Result: [paste output]
  ```

---

#### ⚙️ **Infrastructure Automation / Factory Tasks**
- **Use**: `factory.pem`
- **Target User**: `deployment` (or verify with provider)
- **Command**:
  ```bash
  ssh -i "_private/keys/factory.pem" deployment@<FACTORY_HOST>
  ```
- **Common Tasks**:
  - Automated provisioning
  - Resource setup
  - Configuration management
- **Reference**: Confirm target host and user with provider before first use

---

#### 📦 **Fabric-based Deployments (Legacy)**
- **Use**: `fabric.pem` (DEPRECATED)
- **Status**: Inactive — **do not use for new deployments**
- **Action**: Check `.agent/context/LESSONS.md` for why fabric was deprecated
- **Migration**: Use `contabo.pem` + direct kubectl instead

---

## 🎯 Key-to-Environment Mapping

| Key | Environment | Access Level | Primary Host | Status |
|-----|-------------|--------------|--------------|--------|
| **contabo.pem** | Production | Full Admin (ubuntu→root via sudo) | Contabo VPS | ✅ Active |
| **customer1** | Staging | Root (direct) | Customer provider | ✅ Active |
| **factory.pem** | Infrastructure | Deployment user | Factory host | ✅ Available |
| **fabric.pem** | Legacy | N/A | N/A | ⛔ Deprecated |

---

## 🚦 Pre-SSH Checklist

Before executing any SSH command in a team prompt:

- [ ] Confirmed correct key file exists: `_private/keys/<key_name>`
- [ ] Confirmed target IP/hostname is correct (cross-check with SETUP-CREDENTIALS.txt)
- [ ] Confirmed target username (ubuntu vs root vs deployment)
- [ ] Permission check: `stat _private/keys/<key_name>` shows 400 or 600
- [ ] Key validation: `ssh-keygen -lf _private/keys/<key_name>` returns fingerprint
- [ ] First-time host? Run: `ssh-keyscan -t rsa <target_host> >> ~/.ssh/known_hosts`

---

## 🛡️ Common SSH Patterns for Team

### Pattern 1: Simple Remote Command
```bash
ssh -i "_private/keys/contabo.pem" ubuntu@<IP> "kubectl get pods"
```

### Pattern 2: Tunnel (e.g., MongoDB)
```bash
ssh -i "_private/keys/contabo.pem" -N -L 27017:datastore.prod.svc.cluster.local:27017 ubuntu@<IP>
# In another terminal: mongo localhost:27017
```

### Pattern 3: File Transfer (SCP)
```bash
scp -i "_private/keys/contabo.pem" /local/path/file ubuntu@<IP>:/remote/path/
```

### Pattern 4: Interactive Shell (with agent forwarding if needed)
```bash
ssh -i "_private/keys/contabo.pem" -A ubuntu@<IP>
```

### Pattern 5: Batch Operations (with error handling)
```bash
#!/bin/bash
set -euo pipefail
KEY="_private/keys/contabo.pem"
IP="$(grep CONTABO_IP _private/SETUP-CREDENTIALS.txt | cut -d= -f2)"
ssh -i "$KEY" ubuntu@"$IP" "set -e; kubectl get nodes; kubectl get pods -A"
```

---

## ⚠️ Troubleshooting

### **Connection Refused**
```bash
# Likely causes:
# 1. Wrong IP → check SETUP-CREDENTIALS.txt
# 2. Wrong username → confirm with infrastructure provider
# 3. SSH daemon not running → check target system status
# 4. Firewall blocking → verify security group / network ACL
```

### **Permission Denied (publickey)**
```bash
# Likely causes:
# 1. Wrong key file → verify with ssh-keygen -lf
# 2. Key permissions too open → should be 400
# 3. Public key not installed on target → coordinate with provider
# 4. Username mismatch → ubuntu vs root vs deployment
```

### **Key File Permissions Too Open**
```bash
# Fix:
chmod 400 _private/keys/<key_name>
```

### **Host Key Verification Failed**
```bash
# First time connecting? Add to known_hosts:
ssh-keyscan -t rsa <host> >> ~/.ssh/known_hosts
# Then retry SSH command
```

---

## 📋 Team Operations Checklist

When assigning SSH-based work in Jira:

1. **Creator** (agent assigning):
   - [ ] Specify which key(s) will be needed
   - [ ] Specify target IP and username
   - [ ] Link to this guide in ticket description

2. **Executor** (team agent running the work):
   - [ ] Validate key permis before use
   - [ ] Execute ssh command
   - [ ] Capture output (stdout + stderr)
   - [ ] Post command + result to Jira comment with key ID
   - [ ] If key access failed → move ticket to BLOCKED with diagnostic

3. **Reviewer** (orchestrator validating):
   - [ ] Confirm key ID matches environment in ticket
   - [ ] Verify SSH output matches expected result
   - [ ] Approve for next phase

---

## 🔄 Incident Response

### **If a key is compromised:**

1. Immediately move affected Jira ticket to BLOCKED
2. Post comment: "SECURITY: Key [name] may be compromised. Rotating..."
3. Contact infrastructure provider to revoke old key + issue new one
4. Update `_private/keys/[name]` with new key
5. Re-run validation script
6. Update ticket back to In Progress when confirmed

### **If a key is lost/deleted:**

1. Move Jira ticket to BLOCKED
2. Post comment: "BLOCKED: Key [name] missing. Requesting replacement from [provider]"
3. Wait for provider to issue new key
4. Place new key in `_private/keys/[name]`
5. Validate with `validate-keys.sh`
6. Resume ticket execution

---

## 📞 Support

- **Key validation fails?** → Run `.agent/lab/ssh-keys/validate-keys.sh` for diagnostic
- **SSH access denied?** → Check the Troubleshooting section above
- **Need a new key?** → Contact infrastructure provider; update inventory.csv once received
- **Documentation questions?** → Refer to [copilot-instructions.md](./.github/copilot-instructions.md) SSH section

---

**Last Updated**: 2026-03-22  
**Maintained By**: Copilot Orchestrator  
