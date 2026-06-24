---
description: Smoke-check the production backend — health, mobile API, admin URL
allowed-tools: Bash, Read
---

Run a fast health check against the live NetlumaVPN backend at
`https://netlumavpn.example`. Reports one line per check. SSH details, if needed,
are in `docs/SSH_ACCESS.md`.

## 1. Public health

```bash
curl -s -m 15 -o /dev/null -w "%{http_code}\n" \
  https://netlumavpn.example/health
```

Expected: `200`.

## 2. TLS sanity

Report issuer/subject/expiry. Certificate pinning is currently empty in
`AppConstants`, so this is a normal Let's Encrypt/system-trust check.

```bash
openssl s_client -connect netlumavpn.example:443 \
  -servername netlumavpn.example </dev/null 2>/dev/null \
| openssl x509 -noout -issuer -subject -enddate
```

## 3. Mobile API reachability

```bash
curl -sk -m 15 -o /dev/null -w "%{http_code}\n" \
  https://netlumavpn.example/api/v1/mobile/servers \
  -H "X-NetlumaVPN-Client-Key: $NETLUMAVPN_MOBILE_KEY"
```

Expected: `200`. If `401` → mobile key rejected. If `000` → endpoint
unreachable.

The user should set `NETLUMAVPN_MOBILE_KEY` in their shell, or this command
should be adapted to ask for it. Do not commit the key.

## 4. Admin URL reachability

```bash
curl -s -m 15 -o /dev/null -w "%{http_code}\n" \
  https://netlumavpn.example/admin
```

Expected: `200` or `401` depending on auth state.

## Final report format

```
Health:     200 / OK
TLS:        OK | EXPIRED | UNREACHABLE
Mobile API: 200 / OK
Admin URL:  200 or 401 / OK
```

If any check is anything other than green, surface the likely cause and
the next action (e.g. "Mobile API 401 → mobile client key likely rotated;
check `/etc/quickvpn/quickvpn.env` on the VPS over SSH port 22").
