---
name: vps-ops
description: Operational recipes for the QuickVPN production VPS — SSH, systemd services, nginx routing, Xray management, firewall, TLS cert rotation, and the deploy workflow. Use when the user asks "is the server up?", "deploy ops/...", "rotate the cert", "check Xray logs", or troubleshoots a backend outage.
---

# QuickVPN VPS ops cheat sheet

```
Provider IP : 192.0.2.10
Hostname    : quickvpn-mvp
OS          : Ubuntu 24.04 LTS
SSH key     : ~/.ssh/quickvpn_vps_ed25519
Users       : root (admin), quickadmin (sudo to restart xray only)
```

Full credentials and emergency console passwords: `QUICKVPN_MVP_SERVER.md`.
Do not copy that file's contents elsewhere.

## SSH

```bash
ssh -i ~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10
ssh -i ~/.ssh/quickvpn_vps_ed25519 quickadmin@192.0.2.10
```

Password auth is disabled. Brute-force attempts are throttled by fail2ban
(`ops/fail2ban/sshd.local`).

## Port plan

```
22/tcp       SSH (key-only, fail2ban)
80/tcp       nginx → admin UI + admin API; mobile routes BLOCKED here
443/tcp      nginx stream — SNI router:
             ├ SNI=vpn.netlumavpn.example → 127.0.0.1:8443 (mobile API HTTPS)
             └ * (everything else)                       → 127.0.0.1:1443 (Xray VLESS Reality)
127.0.0.1:1443  Xray VLESS Reality
127.0.0.1:8443  Mobile API (self-signed cert; pinned in iOS app)
127.0.0.1:8000  FastAPI uvicorn (admin UI + admin API)
127.0.0.1:10085 Xray stats API
```

ufw default-deny incoming; only `22/80/443` allowed.

## Active services

```bash
systemctl status xray quickvpn-api quickvpn-stats.timer nginx fail2ban
```

| Service | Source file | Purpose |
|---------|------------|---------|
| `xray.service` | distro | Xray-core 26.3.27, VLESS Reality |
| `quickvpn-api.service` | `ops/systemd/quickvpn-api.service` | uvicorn FastAPI |
| `quickvpn-stats.service` | `ops/systemd/quickvpn-stats.service` | Traffic stats job |
| `quickvpn-stats.timer` | `ops/systemd/quickvpn-stats.timer` | Periodic timer |
| `nginx.service` | distro | Reverse proxy |
| `fail2ban.service` | distro | SSH brute-force protection |

## Common commands

```bash
# Health snapshot
systemctl status xray quickvpn-api nginx | head -30

# Restart FastAPI after deploying new app.py
ssh root@192.0.2.10 'systemctl restart quickvpn-api'

# Restart Xray after profile mutation (or schema edit)
ssh root@192.0.2.10 'systemctl restart xray'

# Reload nginx after config change
ssh root@192.0.2.10 'nginx -t && systemctl reload nginx'

# Tail logs
journalctl -u quickvpn-api -f
journalctl -u xray -f
tail -f /var/log/xray/error.log

# Firewall
ufw status verbose

# Listening sockets
ss -ltnp | grep -E ':(22|80|443|1443|8443|8000|10085)'
```

## Server file layout

```
/opt/quickvpn/app/app.py                       # deployed FastAPI app
/opt/quickvpn/data/quickvpn.sqlite3            # database (WAL mode)
/etc/quickvpn/quickvpn.env                     # env vars (API keys, DB path, etc.)
/etc/quickvpn/tls/quickvpn-api.crt             # mobile API cert (pinned!)
/etc/quickvpn/tls/quickvpn-api.key
/usr/local/etc/xray/config.json                # Xray config (rewritten by app)
/etc/nginx/stream.d/quickvpn-stream.conf       # SNI router
/etc/nginx/conf.d/quickvpn.conf                # HTTP server (admin UI + API)
/var/log/xray/{access.log,error.log}
/root/quickvpn-app-credentials.txt
/root/quickvpn-initial-profile.txt
/root/quickvpn-ssh-credentials.txt
```

## Deploy workflow

The repository keeps deployable assets under `ops/` and `server_mvp/`. A
fresh deploy is:

```bash
# 1. App code
rsync -a server_mvp/quickvpn_admin/ root@192.0.2.10:/opt/quickvpn/app/
ssh root@192.0.2.10 'cd /opt/quickvpn/app && /opt/quickvpn/.venv/bin/pip install -r requirements.txt'

# 2. systemd units
rsync -a ops/systemd/ root@192.0.2.10:/etc/systemd/system/
ssh root@192.0.2.10 'systemctl daemon-reload && systemctl restart quickvpn-api quickvpn-stats.timer'

# 3. nginx
rsync -a ops/nginx/quickvpn.conf       root@192.0.2.10:/etc/nginx/conf.d/quickvpn.conf
rsync -a ops/nginx/quickvpn-stream.conf root@192.0.2.10:/etc/nginx/stream.d/quickvpn-stream.conf
ssh root@192.0.2.10 'nginx -t && systemctl reload nginx'

# 4. fail2ban
rsync -a ops/fail2ban/sshd.local root@192.0.2.10:/etc/fail2ban/jail.d/
ssh root@192.0.2.10 'systemctl reload fail2ban'
```

Confirm with the user before running the full sequence — `systemctl restart
quickvpn-api` drops in-flight requests, and `systemctl restart xray` drops
all current VPN sessions.

## TLS cert rotation

The mobile API cert (`/etc/quickvpn/tls/quickvpn-api.crt`) is pinned in the
iOS binary. Rotation order is FIXED:

1. Generate the new cert with `Subject Alternative Name: DNS:vpn.netlumavpn.example, IP Address:192.0.2.10`.
2. Compute the new SPKI SHA256 base64:
   ```bash
   openssl x509 -in newcert.crt -pubkey -noout \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256 -binary \
     | openssl enc -base64
   ```
3. Update `AppConstants.Backend.mobileTLSCertificateSHA256Base64` in the iOS app.
4. Ship a new build. Wait for adoption.
5. **Only then** swap the cert on the server:
   ```bash
   scp newcert.crt root@192.0.2.10:/etc/quickvpn/tls/quickvpn-api.crt
   scp newcert.key root@192.0.2.10:/etc/quickvpn/tls/quickvpn-api.key
   ssh root@192.0.2.10 'systemctl reload nginx'
   ```

If you swap before the build ships, every QuickVPN install in the wild
breaks immediately.

## Probing from your laptop

```bash
# TLS pin sanity check
openssl s_client -connect vpn.netlumavpn.example:443 \
  -servername vpn.netlumavpn.example </dev/null 2>/dev/null \
| openssl x509 -pubkey -noout \
| openssl pkey -pubin -outform DER \
| openssl dgst -sha256 -binary \
| openssl enc -base64

# Mobile API (with pin)
curl -v -m 15 https://vpn.netlumavpn.example/api/v1/mobile/servers \
  -H "X-QuickVPN-Client-Key: <MOBILE_KEY>"

# Admin API
curl -m 15 http://192.0.2.10/api/v1/status \
  -H "X-QuickVPN-API-Key: <ADMIN_KEY>"
```

## Emergency checklist

If users report "VPN won't connect":

1. `ss -ltnp | grep 443` — is anything listening on 443?
2. `systemctl status xray` — is Xray up?
3. `journalctl -u xray --since "10 minutes ago" | tail -50` — recent errors?
4. `journalctl -u nginx --since "10 minutes ago" | tail -30` — SNI router OK?
5. `tail /var/log/xray/error.log` — Reality handshake failures?
6. `ufw status` — did somebody close 443?

If users report "App won't reach backend":

1. Compute live TLS pin → compare to `AppConstants.swift`.
2. `curl -kv https://vpn.netlumavpn.example/api/v1/mobile/servers` — endpoint up?
3. `journalctl -u quickvpn-api --since "10 minutes ago"` — auth errors? 5xx?
4. `ss -ltnp | grep 8443` — nginx routing reaching the backend?
