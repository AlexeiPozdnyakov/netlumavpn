---
description: Tail recent logs from the production VPS (quickvpn-api, xray, nginx)
allowed-tools: Bash
---

Pull the last few minutes of logs from the production VPS, one service at a
time, so the user can correlate an incident.

Default window: last 10 minutes. Adjust if the user mentions a longer span.

```bash
# quickvpn-api (FastAPI / uvicorn)
ssh -i ~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10 \
  'journalctl -u quickvpn-api --since "10 minutes ago" --no-pager' | tail -100

# xray (VLESS Reality engine)
ssh -i ~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10 \
  'journalctl -u xray --since "10 minutes ago" --no-pager' | tail -100

# xray access/error logs
ssh -i ~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10 \
  'tail -100 /var/log/xray/error.log'

# nginx
ssh -i ~/.ssh/quickvpn_vps_ed25519 root@192.0.2.10 \
  'journalctl -u nginx --since "10 minutes ago" --no-pager' | tail -50
```

Surface only:
- The first error line per service in the window (or "no errors").
- A summary count of warnings.

Do not paste full logs back to the user — they're long and contain sensitive
data (client IPs, profile IDs). Quote specific lines only.
