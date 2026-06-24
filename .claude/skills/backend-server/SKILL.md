---
name: backend-server
description: QuickVPN FastAPI backend reference — endpoint map, SQLite schema, auth model, mobile API client/device headers, Xray restart workflow, and local-dev setup. Use when reading or editing `server_mvp/quickvpn_admin/app.py`, calling the admin or mobile API with `curl`, or wiring a new client integration.
---

# QuickVPN backend cheat sheet

Single-file FastAPI app in `server_mvp/quickvpn_admin/app.py` (~775 lines).
Pinned to `fastapi==0.115.6`, `uvicorn[standard]==0.34.0`.

## Endpoint map

| Surface | Path | Auth | Notes |
|---------|------|------|-------|
| Admin UI | `GET /login` | none (renders form) | Login page |
| Admin UI | `POST /login` | username+password | Issues HMAC-signed session cookie (12h) |
| Admin UI | `GET /admin` | session cookie | Dashboard |
| Admin UI | `POST /admin/profiles` | session cookie | Create profile |
| Admin UI | `GET /admin/profiles/{id}` | session cookie | Detail + VLESS URL |
| Admin UI | `POST /admin/profiles/{id}/revoke` | session cookie | Revoke |
| Admin UI | `POST /admin/profiles/{id}/enable` | session cookie | Re-enable |
| Admin API | `GET /api/v1/status` | `X-QuickVPN-API-Key` | Health |
| Admin API | `POST /api/v1/profiles` | `X-QuickVPN-API-Key` | Create profile (machine) |
| Admin API | `POST /api/v1/profiles/{id}/revoke` | `X-QuickVPN-API-Key` | Revoke (machine) |
| Mobile API | `GET /api/v1/mobile/servers` | `X-QuickVPN-Client-Key` | List global servers |
| Mobile API | `POST /api/v1/mobile/servers/{id}/profile` | `X-QuickVPN-Client-Key` + `X-QuickVPN-Device-ID` | Issue or reuse a per-device profile |

## Auth model

Three independent credentials:

1. **Admin UI session cookie** — HMAC-signed, 12h TTL, set on successful
   `POST /login`. Stores `username`, `expires_at`, `session_id`.
2. **Admin API key** (`X-QuickVPN-API-Key`) — full power, hardcoded env var
   on the VPS, NEVER in the iOS app binary.
3. **Mobile client key** (`X-QuickVPN-Client-Key`) — least privilege; can
   list mobile servers and issue/reuse one profile per device. This IS
   embedded in the iOS app binary; rotate it by issuing a new app build.

Mobile mutation routes also require `X-QuickVPN-Device-ID` — the backend
hashes `sha256(server_id:device_id)` to look up an existing active profile,
so a device that re-issues never accumulates orphan profiles.

## DB schema (SQLite, WAL, foreign keys ON)

```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',  -- active | revoked
    created_at TEXT NOT NULL
);

CREATE TABLE profiles (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_name TEXT,
    protocol TEXT NOT NULL DEFAULT 'vless',
    credential_uuid TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',  -- active | revoked
    vless_url TEXT NOT NULL,
    upload_bytes INTEGER NOT NULL DEFAULT 0,
    download_bytes INTEGER NOT NULL DEFAULT 0,
    last_seen_at TEXT,
    created_at TEXT NOT NULL,
    revoked_at TEXT
);

CREATE TABLE traffic_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id TEXT NOT NULL REFERENCES profiles(id),
    upload_delta INTEGER NOT NULL,
    download_delta INTEGER NOT NULL,
    upload_total INTEGER NOT NULL,
    download_total INTEGER NOT NULL,
    sampled_at TEXT NOT NULL
);

CREATE TABLE audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT,
    details TEXT,
    created_at TEXT NOT NULL
);
```

`profiles.email` is a synthetic per-profile address used by Xray-core to
distinguish users in its inbound `clients` array. `credential_uuid` is the
VLESS user ID (Xray's `id` field).

## Xray config workflow

1. `profiles` mutation (create/revoke/enable) inserts/updates row.
2. App reads all active profiles, renders the Xray `inbounds.settings.clients`
   list, writes `/usr/local/etc/xray/config.json`.
3. `subprocess.run(["systemctl", "restart", "xray"])` — service account has
   sudoers entry for this exact command.
4. Audit log entry appended.

If the JSON is malformed, ALL clients drop. Validate before writing.

## Mobile API flow (iOS side)

```
GlobalServerService.refreshAvailableServers
  → GlobalServerAPIClient.fetchAvailableServers
    → GET /api/v1/mobile/servers
       Headers: X-QuickVPN-Client-Key, X-QuickVPN-Device-ID
    → returns [GlobalVPNServer]

User taps "Connect to <server>"
  → GlobalServerService.provisionProfile(serverID:)
    → GlobalServerAPIClient.issueProfile(serverID:deviceID:deviceName:)
      → POST /api/v1/mobile/servers/{id}/profile
         Body: { "device_name": "iPhone" }
         Headers: X-QuickVPN-Client-Key, X-QuickVPN-Device-ID
      → returns { "profile_id", "vless_url", "expires_at" }
    → VPNConfigurationParser.parse(vless_url) → VPNProfile + secret
    → ProfileStorage.save(profile, secret)
    → VPNManager.startTunnel(profile)
```

TLS pinning: every request from `GlobalServerAPIClient` validates the
server cert's SPKI SHA256 against
`AppConstants.Backend.mobileTLSCertificateSHA256Base64`. Mismatch → request
fails immediately.

## Local dev

```bash
cd server_mvp/quickvpn_admin
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

QUICKVPN_DB_PATH=./local.sqlite3 \
QUICKVPN_ADMIN_USERNAME=admin \
QUICKVPN_ADMIN_PASSWORD=local \
QUICKVPN_API_KEY=${QUICKVPN_API_KEY} \
QUICKVPN_MOBILE_CLIENT_KEY=local-mobile \
QUICKVPN_SESSION_SECRET=$(openssl rand -hex 32) \
uvicorn app:app --host 127.0.0.1 --port 8000 --reload
```

Probe locally:
```bash
curl -s http://127.0.0.1:8000/api/v1/status \
  -H "X-QuickVPN-API-Key: ${QUICKVPN_API_KEY}"

curl -s http://127.0.0.1:8000/api/v1/mobile/servers \
  -H "X-QuickVPN-Client-Key: local-mobile" \
  -H "X-QuickVPN-Device-ID: dev-laptop"
```

Note that mobile profile issuance touches Xray on the local box — it expects
`/usr/local/etc/xray/config.json` and `systemctl`. For pure endpoint-shape
testing without Xray, monkey-patch the restart call (or set a flag in your
local env to skip it).

## Production reach

```bash
# Health
curl -m 15 https://netlumavpn.example/health

# Mobile API over HTTPS
curl -m 15 https://netlumavpn.example/api/v1/mobile/servers \
  -H "X-NetlumaVPN-Client-Key: <MOBILE_KEY>"
```

Live secrets are not stored in committed docs. Ask the user for them in the
active chat or use a secure secret channel.

## Common gotchas

- **Forgetting `X-QuickVPN-Device-ID` on mobile mutations** → 400.
- **Using the admin key on a mobile route** → 401 (and an audit log entry).
- **DB writes outside a transaction** → can leave `profiles` and Xray
  config out of sync.
- **Logging the whole profile object** → leaks the VLESS URL (which contains
  the user UUID). Log only `profile.id` and metadata.
- **Adding a new column without an idempotent `ALTER TABLE`** → breaks
  every deploy after the first.
