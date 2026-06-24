---
description: Tail recent logs from the production VPS (quickvpn-api, xray, nginx)
allowed-tools: Bash
---

Pull the last few minutes of logs from the production VPS, one service at a
time, so the user can correlate an incident.

Default window: last 10 minutes. Adjust if the user mentions a longer span.
Current SSH details are in `docs/SSH_ACCESS.md`: `root@192.0.2.10`, port
`22`. Do not use the old `192.0.2.10` host.

```bash
# sing-box FastAPI / uvicorn
ssh -p 22 root@192.0.2.10 \
  'journalctl -u quickvpn-singbox-api --since "10 minutes ago" --no-pager' | tail -100

# sing-box VPN engine
ssh -p 22 root@192.0.2.10 \
  'journalctl -u sing-box --since "10 minutes ago" --no-pager' | tail -100

# nginx
ssh -p 22 root@192.0.2.10 \
  'journalctl -u nginx --since "10 minutes ago" --no-pager' | tail -50
```

Surface only:
- The first error line per service in the window (or "no errors").
- A summary count of warnings.

Do not paste full logs back to the user — they're long and contain sensitive
data (client IPs, profile IDs). Quote specific lines only.
