# SSH Keys for Team — Quick Start

## 📍 Location
All SSH keys are stored in: **`_private/keys/`**

They are organized in **`.agent/lab/ssh-keys/`** with documentation.

Contabo VPS role assignment is documented in **`.agent/lab/vps/VPS-ROLE-ASSIGNMENT.md`**.

---

## ✅ Available Keys (Validated 2026-03-22)

| Key | Format | Use | Target | Status |
|-----|--------|-----|--------|--------|
| `contabo.pem` | OpenSSH RSA | Production cluster (Contabo VPS) | ubuntu@<ELASTIC_IP> | ✅ Active |
| `customer1` | OpenSSH Ed25519 | Staging/test environments | root@<CUSTOMER_IP> | ✅ Active |
| `factory.pem` | PKCS#1 RSA | Infrastructure automation | deployment@<FACTORY> | ✅ Available |
| `fabric.pem` | PKCS#1 RSA | Fabric deployments (legacy) | — | ⛔ Deprecated |

---

## 🚀 Quick Commands

### Connect to PROD (higher capacity VPS)
```bash
ssh -i "_private/keys/customer1" root@167.86.69.250
```

### Connect to DEV (lower capacity VPS)
```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80
```

### MongoDB Tunnel (Local Dev)
```bash
ssh -i "_private/keys/customer1" -N -L 27017:datastore.prod.svc.cluster.local:27017 root@167.86.69.250
```

---

## 📚 Documentation

- **Full README**: `.agent/lab/ssh-keys/README.md` — Rules, security, examples
- **Selection Guide**: `.agent/lab/ssh-keys/SELECTION-GUIDE.md` — Decision tree for choosing the right key
- **Inventory**: `.agent/lab/ssh-keys/inventory.csv` — Machine-readable key reference
- **Validation Script**: `.agent/lab/ssh-keys/validate-keys.sh` — Check key integrity
- **VPS Role Assignment**: `.agent/lab/vps/VPS-ROLE-ASSIGNMENT.md` — Validated capacity comparison and PROD/DEV split
- **Capacity Benchmark CSV**: `.agent/lab/vps/capacity-benchmark-2026-03-22.csv` — Raw benchmark snapshot

---

## ✔️ Before You SSH

1. Run **validation**: `bash .agent/lab/ssh-keys/validate-keys.sh`
2. Confirm **key ID** matches your target (check SELECTION-GUIDE.md)
3. Verify **IP address** from SETUP-CREDENTIALS.txt
4. Check **username** (ubuntu, root, deployment)
5. **Execute** SSH command
6. **Log result** to Jira with key ID + command + output

---

## ⚠️ Troubleshooting

See `.agent/lab/ssh-keys/README.md` — **Troubleshooting** section for:
- Connection refused
- Permission denied
- Host key verification failed
- Key file permissions issues

---

**Team Notes**: Never commit .pem files to git. All SSH operations must be logged in Jira comments with key ID for audit trail.
