---
description: Smoke-check the production backend — TLS pin, mobile API, admin API
allowed-tools: Bash, Read
---

Run a fast health check against the live QuickVPN backend at
`192.0.2.10`. Reports one line per check.

## 1. TLS pin sanity

Recompute the live cert SPKI hash and report it. Compare to
`AppConstants.Backend.mobileTLSCertificateSHA256Base64` in
`QuickVPNShared/Models/AppConstants.swift` and call out a mismatch.

```bash
openssl s_client -connect vpn.netlumavpn.example:443 \
  -servername vpn.netlumavpn.example </dev/null 2>/dev/null \
| openssl x509 -pubkey -noout \
| openssl pkey -pubin -outform DER \
| openssl dgst -sha256 -binary \
| openssl enc -base64
```

## 2. Mobile API reachability

```bash
curl -sk -m 15 -o /dev/null -w "%{http_code}\n" \
  https://vpn.netlumavpn.example/api/v1/mobile/servers \
  -H "X-QuickVPN-Client-Key: $QUICKVPN_MOBILE_KEY"
```

Expected: `200`. If `401` → mobile key rejected. If `000` → endpoint
unreachable.

Mobile key is in `QUICKVPN_MVP_SERVER.md` (`Mobile client key`). The user
should set `QUICKVPN_MOBILE_KEY` in their shell, or this command should be
adapted to ask for it.

## 3. Admin API reachability

```bash
curl -s -m 15 -o /dev/null -w "%{http_code}\n" \
  http://192.0.2.10/api/v1/status \
  -H "X-QuickVPN-API-Key: $QUICKVPN_ADMIN_KEY"
```

Expected: `200`.

## Final report format

```
TLS pin:    OK | MISMATCH | UNREACHABLE
Mobile API: 200 / OK
Admin API:  200 / OK
```

If any check is anything other than green, surface the likely cause and
the next action (e.g. "Mobile API 401 → mobile client key likely rotated;
check `/etc/quickvpn/quickvpn.env` on the VPS").
