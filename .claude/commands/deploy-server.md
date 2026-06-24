---
description: Show the steps to deploy `ops/` and `server_mvp/` to the QuickVPN VPS
allowed-tools: Bash, Read
---

Do NOT execute production deploys without explicit user confirmation in the
turn. Current production SSH is documented in `docs/SSH_ACCESS.md`:
`root@192.0.2.10` on port `22`. Do not use the old `192.0.2.10`
host for live work.

## Fresh empty VPS

```bash
NEW_SERVER_IP=192.0.2.10 \
SSH_PORT=22 \
SSH_USER=root \
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
ssh -p 22 -o ConnectTimeout=5 root@192.0.2.10 'uname -a'

# (a) FastAPI app
rsync -a --delete -e 'ssh -p 22' server_mvp/quickvpn_singbox_admin/ root@192.0.2.10:/opt/quickvpn-singbox-api/app/
ssh -p 22 root@192.0.2.10 'systemctl restart quickvpn-singbox-api'
ssh -p 22 root@192.0.2.10 'systemctl status quickvpn-singbox-api --no-pager | head -10'

# (b) nginx
ssh -p 22 root@192.0.2.10 'nginx -t && systemctl reload nginx'

# (c) systemd
rsync -a -e 'ssh -p 22' ops/systemd/ root@192.0.2.10:/etc/systemd/system/
ssh -p 22 root@192.0.2.10 'systemctl daemon-reload'
ssh -p 22 root@192.0.2.10 'systemctl restart quickvpn-singbox-api'

# (d) fail2ban
rsync -a -e 'ssh -p 22' ops/fail2ban/sshd.local root@192.0.2.10:/etc/fail2ban/jail.d/sshd.local
ssh -p 22 root@192.0.2.10 'systemctl reload fail2ban'
```

## Post-deploy verification

```bash
# Run the health-check
curl -m 15 https://netlumavpn.example/health
curl -m 15 https://netlumavpn.example/api/v1/mobile/servers \
  -H "X-NetlumaVPN-Client-Key: <MOBILE_KEY>"
```

If either fails, run `journalctl -u quickvpn-singbox-api --since "5 minutes ago"`
on the VPS and surface the first error line.

## Guardrails

- Never `systemctl stop` a service without a follow-up restart.
- Never run `ufw disable`, `iptables -F`, or schema-changing `sqlite3`
  writes from this command.
- If the user has a TLS cert change in flight, do NOT swap the cert as part
  of this deploy — that requires a coordinated iOS release (see
  `.claude/skills/vps-ops/SKILL.md`, "TLS cert rotation").
