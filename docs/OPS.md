# Ops & Infrastructure

> Owner agent: `ops-engineer`. See also the `vps-ops` skill and
> [`REDEPLOY_FRESH_SERVER.md`](REDEPLOY_FRESH_SERVER.md). **Treat the production VPS
> as live** — never run destructive commands (`systemctl stop xray`, `ufw disable`,
> schema-changing `sqlite3` writes) without the user confirming.

The `ops/` directory is infrastructure-as-files: copies of what lives in `/etc`,
`/opt`, and systemd on the server, plus the bootstrap/provision/verify scripts.

## Domains & DNS

Current live VPS: `192.0.2.10`, SSH on port `22` as `root`. Use
[`SSH_ACCESS.md`](SSH_ACCESS.md) for exact commands and password-handling rules.
Do not use the old `192.0.2.10` host for live work.

Deploy domain: `netlumavpn.example`. DNS should point the root/www/API/admin/VPN
names at the live VPS IPv4.

## Port map

| Port | Listener | Backend |
|------|----------|---------|
| 22/tcp | sshd | live SSH admin access |
| 80/tcp | nginx http | ACME webroot + 308→HTTPS (404 for `/api/v1/mobile/`) |
| 443/tcp | nginx **stream** (`ssl_preread`) | SNI router (root/www/api/admin → backend, see below) |
| 8443 | nginx https vhost | `api.`/`admin.` → proxies `http://127.0.0.1:8000` |
| 2443 | Xray Trojan TLS | direct from stream (`trojan.`) |
| 1443 | Xray VLESS Reality | default stream backend (`vpn.` + everything else) |
| 8000 | uvicorn (backend A) | `quickvpn-api.service` |
| 8020 | uvicorn (backend B, sing-box) | `quickvpn-singbox-api.service` *(not provisioned)* |
| 8010 | stdlib http (sidecar) | `quickvpn-singbox-admin.service` *(not provisioned)* |
| 10085 | Xray gRPC stats API | scraped by `quickvpn-stats.timer` |
| 51820/udp | WireGuard `wg0` | UFW-allowed |

## nginx

- **`ops/nginx/quickvpn-stream.conf`** — `listen 443` with `ssl_preread on`, routes by
  `$ssl_preread_server_name`: root `netlumavpn.example`, `www.`, `api.`, and `admin.` →
  `127.0.0.1:8443`; `trojan.` → `127.0.0.1:2443`; default → `127.0.0.1:1443`.
  Requires `libnginx-mod-stream`.
- **`ops/nginx/quickvpn.conf`** — `:80` (ACME + redirect) and the
  `127.0.0.1:8443 ssl` vhost for root/www/api/admin that proxies `/` and the
  rate-limited `/api/v1/mobile/` (`30r/m`, `burst=20`) to
  **`http://127.0.0.1:8000`** (backend A). Root paths serve the marketing/support/legal
  website; `/admin` remains session-protected.

## systemd (`ops/systemd/`)

| Unit | User | ExecStart / behavior |
|------|------|----------------------|
| `quickvpn-api.service` | `quickvpn` | `uvicorn app:app --host 127.0.0.1 --port 8000 --proxy-headers`, `Restart=always`, `After/Wants=xray.service`, `EnvironmentFile=/etc/quickvpn/quickvpn.env` |
| `quickvpn-stats.service` | `quickvpn` | oneshot `python app.py collect-stats` |
| `quickvpn-stats.timer` | — | `OnBootSec=90`, `OnUnitActiveSec=60` (every minute) |
| `quickvpn-singbox-api.service` | **root** | `uvicorn app:app … --port 8020` *(not installed by provisioner)* |
| `quickvpn-singbox-admin.service` | **root** | `python3 singbox_admin.py` (:8010) *(not installed by provisioner)* |

Only the three `quickvpn-{api,stats.service,stats.timer}` units are installed by
`provision-fresh-server.sh`. The provisioner installs **Xray**, not sing-box.

## fail2ban

`ops/fail2ban/sshd.local`: jail `[sshd]`, `backend=systemd`, `maxretry=5`,
`findtime=10m`, `bantime=1h` → installed to `/etc/fail2ban/jail.d/sshd.local`.

## Scripts

- **`bootstrap-quickvpn-ssh.sh`** — installs an SSH pubkey for `root` + a `quickadmin`
  sudo user, generates random passwords into `/root/quickvpn-ssh-credentials.txt`
  (0600), grants `quickadmin` NOPASSWD sudo for `systemctl {restart,reload,status} xray`
  + `journalctl`.
- **`provision-fresh-server.sh`** (run as root on the VPS) — installs packages
  (nginx + stream module, certbot, fail2ban, ufw, wireguard-tools, sqlite3,
  python3-venv), installs Xray-core, creates the `quickvpn` user + dirs, rsyncs
  **`archive/server_mvp/quickvpn_admin`** → `/opt/quickvpn/app`, builds the venv,
  generates secrets (Reality x25519, WireGuard keypair, `SESSION_SECRET`, `API_KEY`,
  admin PBKDF2 hash), writes `/etc/quickvpn/quickvpn.env` (0640 root:quickvpn), issues a
  Let's Encrypt cert for root/`www`/`api`/`admin`/`trojan`, installs a renewal deploy-hook (copies
  the cert to `/etc/xray/certs/` for Trojan), renders Xray + WireGuard configs, opens
  UFW (22/80/443 tcp, 51820 udp), enables IPv4 forwarding, and starts `xray`,
  `wg-quick@wg0`, `quickvpn-api`, `quickvpn-stats.timer`. **Requires
  `QUICKVPN_MOBILE_API_KEY` to match `AppConstants.Backend.mobileClientKey`.**
- **`deploy-fresh-server.sh`** (run locally) — rsyncs `archive/`, `ops/`, `server_mvp/`
  to `/tmp/quickvpn-deploy` on `NEW_SERVER_IP`, then runs the provisioner remotely.
  Accepts both `NETLUMAVPN_*` and `QUICKVPN_*` env-var spellings.
- **`verify-fresh-server.sh`** (run locally) — `dig` root + the 5 subdomains, curl
  root website pages (`/`, `/support`, `/privacy`, `/terms`), `admin/login`,
  `api/api/v1/status`, and (with a key) `api/api/v1/mobile/servers` using both
  `X-NetlumaVPN-Client-Key` and legacy `X-QuickVPN-Client-Key`, then print the TLS cert
  via `openssl s_client`.

## Deploy workflow

`/deploy-server` surfaces the commands; the user must confirm execution. Typical flow:
`deploy-fresh-server.sh` (rsync + remote provision) → `verify-fresh-server.sh`. The
full runbook is [`REDEPLOY_FRESH_SERVER.md`](REDEPLOY_FRESH_SERVER.md).
`/health-check` and `/server-logs` help confirm a running server.

## Gotchas

- The deployed backend is **A** (Xray/WireGuard), not the sing-box one. The
  sing-box/admin units exist but aren't wired up (and run as root). See
  [`BACKEND.md`](BACKEND.md).
- TLS for the website/backend and Trojan reuses the `api.<domain>` Let's Encrypt cert
  path (shared SANs for root/`www`/`api`/`admin`/`trojan`); provision expands that
  existing cert lineage with `--cert-name api.<domain>`.
- Cert renewal must re-copy to `/etc/xray/certs/` and reload nginx (the deploy-hook does
  this) — Xray won't pick up a renewed cert otherwise.
- Naming churn: the `quickvpn` system user, service names, env files, and ops paths are
  still `quickvpn`; only the public domain and some env aliases are `netlumavpn`. Don't
  mass-rename without coordinating the whole deploy.

_Last full analysis: 2026-06-24._
