# Hard Reset + Reinstall Checklist (DEV First, PROD Second)

Date: 2026-03-22

## Target Mapping
- DEV (lower capacity): 161.97.112.80, key `_private/keys/contabo-rescue`, user `root`
- PROD (higher capacity): 167.86.69.250, key `_private/keys/customer1`, user `root`

## Phase 1 — Clean PROD (must remain clean)

1. Connect:
```bash
ssh -i "_private/keys/customer1" root@167.86.69.250
```

2. Hard reset:
```bash
/usr/local/bin/k3s-uninstall.sh || true
/usr/local/bin/k3s-agent-uninstall.sh || true
rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni/net.d /opt/cni /var/lib/containerd /run/k3s
rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service
rm -f /etc/systemd/system/k3s.service.env /etc/systemd/system/k3s-agent.service.env
rm -rf /root/.kube /root/.kaanbal /root/.software-factory
systemctl daemon-reload || true
docker system prune -af || true
```

3. Verify PROD is clean:
```bash
test -d /var/lib/rancher && echo "rancher present" || echo "rancher absent"
systemctl list-unit-files | grep k3s || echo "no k3s units"
ss -ltnp | grep :3000 || echo "installer not listening"
```

Expected:
- `rancher absent`
- `no k3s units`
- `installer not listening`

## Phase 2 — Reset + Run Installer on DEV

1. Connect:
```bash
ssh -i "_private/keys/contabo-rescue" root@161.97.112.80
```

2. Reset DEV:
```bash
/usr/local/bin/k3s-uninstall.sh || true
/usr/local/bin/k3s-agent-uninstall.sh || true
rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/cni/net.d /opt/cni /var/lib/containerd /run/k3s
rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service
rm -f /etc/systemd/system/k3s.service.env /etc/systemd/system/k3s-agent.service.env
rm -rf /root/.kube /root/.kaanbal /root/.software-factory
systemctl daemon-reload || true
docker system prune -af || true
```

3. Start installer (background):
```bash
cd /home/ubuntu/softwarefactory
nohup bash ./install.sh > /var/log/kaanbal-installer-dev.log 2>&1 < /dev/null &
```

4. Check installer:
```bash
ss -ltnp | grep :3000
tail -n 25 /var/log/kaanbal-installer-dev.log
```

Expected:
- Port `3000` listening with python3 installer

5. Get startup token:
```bash
grep KB_SETUP_TOKEN /root/.software-factory/installer.env
```

## Access URL
- DEV installer: `http://161.97.112.80:3000`
- Open with token from `/root/.software-factory/installer.env`

## Operational Rule (your policy)
- Iterate only on DEV until version is proven functional.
- Keep PROD clean until promotion.
- Deploy to PROD only after DEV validation gates pass.
