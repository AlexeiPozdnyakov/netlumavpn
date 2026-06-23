---
description: Show the steps to deploy `ops/` and `server_mvp/` to the QuickVPN VPS
allowed-tools: Bash, Read
---

Do NOT execute production deploys without explicit user confirmation in the
turn. For a freshly recreated empty VPS, use `docs/REDEPLOY_FRESH_SERVER.md`
and `ops/deploy-fresh-server.sh`; the old `192.0.2.10` sequence below is
only for legacy partial deploys while that server still exists.

## Fresh empty VPS

```bash
NEW_SERVER_IP=<new-ipv4> \
QUICKVPN_DOMAIN=netlumavpn.example \
QUICKVPN_MOBILE_API_KEY='<AppConstants.Backend.mobileClientKey>' \
QUICKVPN_CERTBOT_EMAIL='<email-for-letsencrypt>' \
./ops/deploy-fresh-server.sh
```

Before running it, DNS A records for `api`, `admin`, `vpn`, and `trojan`
must already point to the new IP.

## What gets deployed

| Source (repo) | Destination (VPS) | Restart needed |
|---------------|-------------------|----------------|
| `server_mvp/quickvpn_admin/` | `/opt/quickvpn/app/` | `quickvpn-api` |
| `ops/systemd/*.service`, `*.timer` | `/etc/systemd/system/` | `daemon-reload` + restart units |
| `ops/nginx/quickvpn.conf` | `/etc/nginx/conf.d/quickvpn.conf` | `nginx reload` |
| `ops/nginx/quickvpn-stream.conf` | `/etc/nginx/stream.d/quickvpn-stream.conf` | `nginx reload` |
| `ops/fail2ban/sshd.local` | `/etc/fail2ban/jail.d/sshd.local` | `fail2ban reload` |

## Confirm scope with user

Read git status and ask the user which subset they want to deploy:
- (a) FastAPI app only
- (b) nginx only
- (c) systemd only
- (d) fail2ban only
- (e) Everything

Do not assume "everything" — partial deploys are common.

## Deploy commands (template — confirm before running)

```bash
# Pre-flight: confirm SSH works
ssh -i ~/.ssh/quickvpn_vps_ed25519 -o ConnectTimeout=5 root@192.0.2.10 'uname -a'

# (a) FastAPI app
rsync -a --delete server_mvp/quickvpn_admin/ root@192.0.2.10:/opt/quickvpn/app/
ssh root@192.0.2.10 'cd /opt/quickvpn/app && /opt/quickvpn/.venv/bin/pip install -r requirements.txt'
ssh root@192.0.2.10 'systemctl restart quickvpn-api'
ssh root@192.0.2.10 'systemctl status quickvpn-api --no-pager | head -10'

# (b) nginx
rsync -a ops/nginx/quickvpn.conf       root@192.0.2.10:/etc/nginx/conf.d/quickvpn.conf
rsync -a ops/nginx/quickvpn-stream.conf root@192.0.2.10:/etc/nginx/stream.d/quickvpn-stream.conf
ssh root@192.0.2.10 'nginx -t && systemctl reload nginx'

# (c) systemd
rsync -a ops/systemd/ root@192.0.2.10:/etc/systemd/system/
ssh root@192.0.2.10 'systemctl daemon-reload'
ssh root@192.0.2.10 'systemctl restart quickvpn-api quickvpn-stats.timer'

# (d) fail2ban
rsync -a ops/fail2ban/sshd.local root@192.0.2.10:/etc/fail2ban/jail.d/sshd.local
ssh root@192.0.2.10 'systemctl reload fail2ban'
```

## Post-deploy verification

```bash
# Run the health-check
curl -m 15 http://192.0.2.10/api/v1/status -H "X-QuickVPN-API-Key: <ADMIN_KEY>"
curl -kv -m 15 https://vpn.netlumavpn.example/api/v1/mobile/servers \
  -H "X-QuickVPN-Client-Key: <MOBILE_KEY>"
```

If either fails, run `journalctl -u quickvpn-api --since "5 minutes ago"` on
the VPS and surface the first error line.

## Guardrails

- Never `systemctl stop` a service without a follow-up restart.
- Never run `ufw disable`, `iptables -F`, or schema-changing `sqlite3`
  writes from this command.
- If the user has a TLS cert change in flight, do NOT swap the cert as part
  of this deploy — that requires a coordinated iOS release (see
  `.claude/skills/vps-ops/SKILL.md`, "TLS cert rotation").
