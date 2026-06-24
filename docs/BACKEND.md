# Backend (FastAPI)

> Owner agent: `backend-developer`. See also the `backend-server` skill. ⚠️ There
> are **two** FastAPI backends in this repo and they are easy to confuse — read §0
> before editing anything.

## 0. There are TWO backends — know which one is live

| | **A — Xray/WireGuard** | **B — sing-box** |
|---|---|---|
| Path | `archive/server_mvp/quickvpn_admin/app.py` | `server_mvp/quickvpn_singbox_admin/app.py` |
| Engine | Xray-core (VLESS Reality + Trojan) + WireGuard | sing-box (VLESS + Trojan) |
| Port | `127.0.0.1:8000` (`quickvpn-api.service`) | `127.0.0.1:8020` (`quickvpn-singbox-api.service`) |
| Deployed by provisioner? | **YES** — `provision-fresh-server.sh` sets `APP_SRC=…/archive/server_mvp/quickvpn_admin`; nginx proxies :8000 | **NO in the fresh-server scripts**, but the current `netlumavpn.example` production endpoint was observed returning `{"backend":"netlumavpn-singbox"}` on 2026-06-24 |
| Mobile headers accepted | **only** `x-quickvpn-*` | `x-netlumavpn-*` (primary), `x-quickvpn-*` (legacy fallback) |
| Server IDs | `quickvpn-mvp-eu-1`, `…-trojan`, `…-wireguard` | `netlumavpn-singbox-vless`, `netlumavpn-singbox-trojan` |
| Admin auth | HMAC session cookie + PBKDF2 passwords + `/login` | HTTP Basic (plaintext env password) |
| iOS integration tests target it? | no | **yes** (`GlobalServerIntegrationTests` expects `netlumavpn-singbox-*`) |

So: **the provisioning scripts ship backend A, but the current production endpoint,
iOS client tests, and `verify-fresh-server.sh` describe backend B.** Before any backend
task, confirm which app is actually running on the target VPS (e.g. `GET /api/v1/status`
returns `{"backend":"netlumavpn-singbox"}` for B). Log findings in
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

The iOS app sends **both** header families, so it authenticates against either backend;
the mismatch that bites is **server IDs** (a client pinned to one set won't see the
other's servers).

Both backends are single-file FastAPI apps (`fastapi==0.115.6`, `uvicorn==0.34.0`),
SQLite with WAL + foreign keys. Keep them single-file.

There is also a third, **dependency-free** stdlib admin sidecar
(`server_mvp/singbox_admin/singbox_admin.py`, :8010, also not provisioned) — a pure
operator UI over the sing-box config (no SQLite, no mobile API).

---

## 1. Endpoint map

### Backend A — `archive/server_mvp/quickvpn_admin/app.py` (LIVE, :8000)

**Admin UI** (session cookie):

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/`, `/support`, `/terms`, `/privacy` | Public marketing/support/legal website |
| POST | `/support` | Store a public support/feedback request |
| GET/POST | `/login`, `/logout` | sets/clears `quickvpn_session` cookie |
| GET | `/admin` | dashboard |
| GET | `/admin/feedback` | feedback triage dashboard |
| POST | `/admin/feedback/{id}/status` | mark feedback `new` / `in_review` / `resolved` / `archived` |
| POST | `/admin/profiles`, `/admin/profiles/{id}/revoke|enable|delete` | profile management |
| GET | `/admin/profiles/{id}` | profile detail |
| GET | `/health` | health |

**Admin API** (`X-QuickVPN-API-Key`): `GET /api/v1/status`, `POST /api/v1/profiles`,
`POST /api/v1/profiles/{id}/revoke`.

**Mobile API** (`X-QuickVPN-Client-Key` + `X-QuickVPN-Device-Id`):

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/mobile/servers` | list servers (`quickvpn-mvp-eu-1*`) |
| POST | `/api/v1/mobile/servers/{server_id}/profile` | issue/reuse per-device profile (returns the raw VLESS URL / credentials) |

- Device header validated `20 ≤ len ≤ 128`. **Only the `x-quickvpn-*` spelling is read.**
- **Dedup:** `normalized_device_key = "mobile:" + server_id + ":" + sha256(f"{server_id}:{device_id}")[:24]`, stored in the `profiles.device_name` column; reuse query
  `WHERE device_name=? AND status='active'`.

### Backend B — `server_mvp/quickvpn_singbox_admin/app.py` (:8020)

**Public website / Admin UI**:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/`, `/support`, `/terms`, `/privacy` | Public marketing/support/legal website |
| POST | `/support` | Store a public support/feedback request |
| GET | `/health` | health |
| GET | `/admin` | HTTP Basic profile dashboard |
| GET | `/admin/feedback` | HTTP Basic feedback triage dashboard |
| POST | `/admin/feedback/{id}/status` | mark feedback `new` / `in_review` / `resolved` / `archived` |
| POST | `/admin/profiles`, `/admin/profiles/{id}/delete` | profile management |

**Admin API** (`X-NetlumaVPN-API-Key`, legacy `X-QuickVPN-API-Key`):
`GET /api/v1/status`, `POST /api/v1/profiles`, `DELETE /api/v1/profiles/{id}`.

**Mobile API** (`X-NetlumaVPN-Client-Key`, legacy `X-QuickVPN-Client-Key`):

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/v1/mobile/servers` | list servers (`netlumavpn-singbox-*`) |
| POST | `/api/v1/mobile/servers/{server_id}/profile` | issue/reuse; returns an **indirected** `config_url` |
| GET | `/api/v1/mobile/profiles/{id}/config` | device-scoped sing-box JSON (`Cache-Control: no-store`) |

- Header reads use a `header_value(request, new, legacy_name=…)` helper → new name
  first, legacy fallback.
- **Dedup:** `device_key = sha256(f"{server_id}:{device_id}").hexdigest()` (full hex)
  in a dedicated `device_key` column; reuse `WHERE server_id=? AND device_key=? AND
  status='active'`. The `/config` route re-verifies ownership with
  `hmac.compare_digest`. This matches the `CLAUDE.md` dedup description exactly.

---

## 2. Auth model

**Backend A:**
- Admin session: `quickvpn_session` cookie = `"{user}:{expiry}:{HMAC-SHA256(SESSION_SECRET, …)}"`,
  12 h expiry, constant-time verify. `httponly`, `samesite=lax` (not `Secure`-flagged;
  relies on upstream TLS).
- Passwords: **PBKDF2-HMAC-SHA256, 260,000 iterations**, stored as
  `pbkdf2_sha256$<iters>$<salt>$<b64digest>`.
- API keys: `x-quickvpn-api-key` (admin), `x-quickvpn-client-key` (mobile), constant-time.

**Backend B / sidecar:** HTTP Basic only, password compared in cleartext from
`ADMIN_PASSWORD` env (no cookie, no PBKDF2). API keys constant-time with NetlumaVPN/
QuickVPN fallback.

**Rate limiting** (nginx, both): `/api/v1/mobile/` → `30r/m`, `burst=20 nodelay`,
`limit_req_status 429`.

---

## 3. Database schema (SQLite, WAL + `foreign_keys=ON`)

**Backend A** (5 tables):
- `users(id PK, name, status, created_at)`
- `profiles(id PK, user_id→users, device_name, protocol, credential_uuid UNIQUE, email UNIQUE, status, vless_url, wireguard_private_key, wireguard_public_key, wireguard_preshared_key, wireguard_address, upload_bytes, download_bytes, last_seen_at, created_at, revoked_at)` — note the mobile dedup key is stuffed into `device_name`.
- `traffic_samples(id, profile_id→profiles, upload_delta, download_delta, upload_total, download_total, sampled_at)` — filled by `collect-stats` from Xray's gRPC stats API.
- `audit_logs(id, actor, action, target, details, created_at)`.
- `feedback_requests(id PK, name, email, topic, message, ios_version, app_version, contact_consent, status, created_at, updated_at)` — public `/support` submissions shown in `/admin/feedback`.

**Backend B** (3 tables, no FKs):
- `profiles(id PK, username UNIQUE, user_name, device_name, server_id, device_key, status, source, trojan_config_url, vless_config_url, created_at, deleted_at)`.
- `audit_logs(...)`.
- `feedback_requests(id PK, name, email, topic, message, ios_version, app_version, contact_consent, status, created_at, updated_at)` — public `/support` submissions shown in `/admin/feedback`.
- On startup, `sync_existing_users` imports pre-existing sing-box users as
  `source='legacy'`, `server_id='legacy'`.

---

## 4. Provisioning the proxy engine

**Backend A (Xray/WireGuard)** — via CLI subcommands of the same `app.py`
(`__main__` is a CLI dispatcher, not a server):
- `hash-password <pw>` — generate a PBKDF2 admin hash.
- `collect-stats` — scrape Xray gRPC stats (`127.0.0.1:10085`) into `traffic_samples`
  (run by `quickvpn-stats.timer`).
- `render-xray` — write `/usr/local/etc/xray/config.json` (Reality VLESS on `1443`,
  Trojan on `2443`, stats on `10085`); applied via `systemctl restart xray`.
- `render-wireguard` — write `wg0.conf`; applied via `wg-quick@wg0`.

**Backend B (sing-box)** — `SingBoxManager`:
- `create_user`: append a Trojan password + VLESS UUID to the inbounds in
  `/etc/sing-box/config.json`, write per-client JSONs to a secret web dir.
- Atomic + validated: write to a temp file, run **`sing-box check -c <tmp>`**, only then
  `replace()` the live config (a bad config never goes live), then `systemctl reload
  sing-box.service`. `check_config`/`reload_service` are injected (so tests run rootless).

---

## 5. Local development & tests

```bash
# Backend A (live Xray/WireGuard backend)
cd archive/server_mvp/quickvpn_admin
python -m unittest test_app.py

# Backend B (sing-box)
cd server_mvp/quickvpn_singbox_admin
python test_app.py                      # rootless: check/reload are stubbed

# Sidecar
cd server_mvp/singbox_admin
python -m pytest test_singbox_admin.py
```

Backend A has `unittest` coverage for the public website, support feedback storage,
the admin feedback page, and dashboard degradation when the Xray stats binary is
unavailable. Backend B has `unittest` coverage for sing-box user/profile behavior, the
public website, support feedback storage, and the Basic Auth feedback admin page.

---

## 6. Gotchas

- **Edit the right `app.py`.** The fresh-server provisioner ships backend A, while the
  current `netlumavpn.example` endpoint was observed running backend B. Confirm before assuming.
- **Header acceptance differs** (A = quickvpn-only; B = both). The verify script uses
  both `x-netlumavpn-*` and legacy `x-quickvpn-*`.
- **Server IDs differ** between backends.
- **Secrets:** no live keys are committed; the provisioner/bootstrap generate passwords
  at runtime into root-owned 0600 files. The client-JSON web dir name
  (`ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA`) is a "secret URL" default in code/`env.example`.
- **Backend B & the sidecar run as root** (vs the `quickvpn` system user for A) — larger
  blast radius if you enable them.
- See [`OPS.md`](OPS.md) for ports, nginx routing, systemd, and the deploy workflow,
  and [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) for the consolidated discrepancy list.

_Last full analysis: 2026-06-24._
