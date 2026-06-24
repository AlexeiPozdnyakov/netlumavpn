---
name: vps-ops
description: Operational recipes for the QuickVPN production VPS — SSH, systemd services, nginx routing, Xray management, firewall, TLS cert rotation, and the deploy workflow. Use when the user asks "is the server up?", "deploy ops/...", "rotate the cert", "check Xray logs", or troubleshoots a backend outage.
---

# QuickVPN VPS ops cheat sheet

For a freshly recreated empty VPS, use `docs/REDEPLOY_FRESH_SERVER.md` and
`ops/deploy-fresh-server.sh`. For current production SSH access, read
`docs/SSH_ACCESS.md` first.

```
Provider IP : 192.0.2.10
SSH port    : 22
Public host : netlumavpn.example
Users       : root
```

The root password is not stored in this repository. Ask the user for it in the
active chat or use a secure secret channel. Never copy passwords into committed
docs or command files.

## SSH

```bash
ssh -p 22 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  root@192.0.2.10
```

Do not try the old `192.0.2.10` host or default port `22` for live work.
If a local deploy key is installed later, use `ssh -p 22 -i
~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10`.

## Port plan

```
22/tcp    SSH admin access
80/tcp      nginx HTTP / ACME / redirect
443/tcp     nginx HTTPS for netlumavpn.example + VPN websocket paths
127.0.0.1:8020  quickvpn-singbox-api (FastAPI / uvicorn)
127.0.0.1:8010  quickvpn-singbox-admin sidecar, if installed
```

Do not assume port `22` is open. Do not change firewall or SSH port without the
user explicitly asking.

## Active services

```bash
ssh -p 22 root@192.0.2.10 'systemctl status nginx sing-box quickvpn-singbox-api --no-pager'
```

| Service | Source file | Purpose |
|---------|------------|---------|
| `nginx.service` | distro | Reverse proxy |
| `sing-box.service` | server-installed | Existing VPN engine; do not overwrite casually |
| `quickvpn-singbox-api.service` | `ops/systemd/quickvpn-singbox-api.service` | FastAPI admin/mobile API |
| `quickvpn-singbox-admin.service` | `ops/systemd/quickvpn-singbox-admin.service` | optional local admin sidecar |

## Common commands

```bash
# Health snapshot
ssh -p 22 root@192.0.2.10 'hostname; date; systemctl --no-pager --type=service --state=running | grep -E "nginx|sing-box|quickvpn" || true'

# Restart FastAPI after deploying new app.py
ssh -p 22 root@192.0.2.10 'systemctl restart quickvpn-singbox-api'

# Reload nginx after config change
ssh -p 22 root@192.0.2.10 'nginx -t && systemctl reload nginx'

# Tail logs
ssh -p 22 root@192.0.2.10 'journalctl -u quickvpn-singbox-api -f'
ssh -p 22 root@192.0.2.10 'journalctl -u sing-box -f'

# Firewall
ssh -p 22 root@192.0.2.10 'ufw status verbose'

# Listening sockets
ssh -p 22 root@192.0.2.10 'ss -ltnup | grep -E ":(80|443|22|8010|8020)\\b" || true'
```

## Server file layout

```
/opt/quickvpn-singbox-api/app/             # deployed sing-box FastAPI app
/etc/quickvpn/quickvpn.env                 # env vars (API keys, public URLs)
/etc/nginx/                                # live nginx config
/etc/letsencrypt/live/netlumavpn.example/      # Let's Encrypt cert
/root/netlumavpn-domain-backup-*/          # backup made before domain/nginx changes
```

## Deploy workflow

The repository keeps deployable assets under `ops/` and `server_mvp/`. Confirm
scope with the user before changing production. Typical app-only deploy:

```bash
rsync -a --delete -e 'ssh -p 22' \
  server_mvp/quickvpn_singbox_admin/ \
  root@192.0.2.10:/opt/quickvpn-singbox-api/app/
ssh -p 22 root@192.0.2.10 'systemctl restart quickvpn-singbox-api'
```

For fresh rebuilds, use `docs/REDEPLOY_FRESH_SERVER.md` and remember to pass
`SSH_PORT=22` if targeting the current live VPS.

## TLS cert rotation

The current public cert is Let's Encrypt for `netlumavpn.example`. A deploy hook
reloads nginx after renewal. iOS certificate pinning is currently empty in
`AppConstants`, so the app relies on normal system trust.

## Probing from your laptop

```bash
curl -m 15 https://netlumavpn.example/health
curl -m 15 https://netlumavpn.example/api/v1/mobile/servers \
  -H "X-NetlumaVPN-Client-Key: <MOBILE_KEY>"
curl -I -m 15 https://netlumavpn.example/admin
```

## Emergency checklist

If users report "VPN won't connect":

1. `ss -ltnp | grep 443` — is anything listening on 443?
2. `systemctl status sing-box` — is sing-box up?
3. `journalctl -u sing-box --since "10 minutes ago" | tail -50` — recent errors?
4. `journalctl -u nginx --since "10 minutes ago" | tail -30` — nginx OK?
5. `ufw status` — did somebody close 443?

If users report "App won't reach backend":

1. `curl -m 15 https://netlumavpn.example/health` — endpoint up?
2. `curl -m 15 https://netlumavpn.example/api/v1/mobile/servers -H "X-NetlumaVPN-Client-Key: <MOBILE_KEY>"` — mobile auth OK?
3. `journalctl -u quickvpn-singbox-api --since "10 minutes ago"` — auth errors? 5xx?
4. `ss -ltnp | grep 8020` — API service listening?
