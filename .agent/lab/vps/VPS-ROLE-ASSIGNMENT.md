# Contabo VPS Role Assignment (Validated)

Date: 2026-03-22  
Scope: 2 Contabo VPS nodes (dev/prod split)

## Decision Summary

- **PROD**: `167.86.69.250` (higher capacity)
- **DEV**: `161.97.112.80` (lower capacity)

This assignment follows your rule: "the stronger VPS is prod, the smaller one is dev".

---

## Validation Evidence (Live SSH)

### VPS A — 161.97.112.80
- Hostname: `vmi3123463`
- CPU cores: `6`
- RAM (total): `11,960 MB` (~12 GB)
- Disk (sda): `214,748,364,800 bytes` (~200 GB)
- Root FS: `193G`
- Successful access: `root@161.97.112.80` with `_private/keys/contabo-rescue`

### VPS B — 167.86.69.250
- Hostname: `vmi3166489`
- CPU cores: `8`
- RAM (total): `24,031 MB` (~24 GB)
- Disk (sda): `429,496,729,600 bytes` (~400 GB)
- Root FS: `387G`
- Successful access: `root@167.86.69.250` with `_private/keys/customer1`

---

## Why PROD = 167.86.69.250

Compared to 161.97.112.80, this host has:
- `+33%` CPU cores (8 vs 6)
- `+100%` RAM (24 GB vs 12 GB)
- `+100%` disk (400 GB vs 200 GB)

So it is the correct production candidate by raw capacity.

---

## Environment Policy You Defined (Interpreted)

Your statement:
"primero debemos dejar las 2 como nuevas, luego correr el instalador siempre en modo dev, cuando tenga una version funcional probada ya desplegare en prod"

Operational meaning:
1. **Reset both VPS to clean baseline** (no drift, no legacy state)
2. **Develop and iterate only in DEV** (161.97.112.80)
3. **Promote to PROD only after validated DEV build** (167.86.69.250)
4. PROD is treated as the real system target, not experimentation

This is a solid release strategy: DEV for fast iteration, PROD for stable promotion.

---

## SSH Access Matrix (Current)

| VPS | Role | User | Working Key | Status |
|-----|------|------|-------------|--------|
| 161.97.112.80 | DEV | root | `_private/keys/contabo-rescue` | ✅ OK |
| 167.86.69.250 | PROD | root | `_private/keys/customer1` | ✅ OK |
| 161.97.112.80 | DEV | ubuntu | `_private/keys/contabo.pem` | ❌ denied |
| 167.86.69.250 | PROD | ubuntu | `_private/keys/contabo.pem` | ❌ denied |

Note: prefer provisioning an `ubuntu` user + standard key policy later for consistency.

---

## Recommended Next Execution Pattern

1. Hard reset both nodes
2. Install in DEV only (`161.97.112.80`)
3. Run full validation checklist in DEV
4. If all gates pass, deploy same version to PROD (`167.86.69.250`)
5. Keep PROD changes controlled (no ad-hoc manual experiments)

---

## Command Templates

### DEV (lower capacity)
```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80
```

### PROD (higher capacity)
```bash
ssh -i "_private/keys/customer1" root@167.86.69.250
```

### Quick capacity check (any host)
```bash
ssh -i "<key>" root@<ip> "hostname; nproc; free -m; lsblk -b -dn -o NAME,SIZE; df -h /"
```
