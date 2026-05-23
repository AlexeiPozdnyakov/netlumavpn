# Multi-Protocol Global VPN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VLESS Reality, Trojan TLS, and WireGuard as selectable QuickVPN Global options backed by the VPS.

**Architecture:** Keep VLESS Reality on the existing 443 Reality route. Add Trojan TLS behind `trojan.netlumavpn.example` on the same external 443 via nginx stream SNI routing. Run native WireGuard on UDP 51820 and issue one peer per mobile device.

**Tech Stack:** FastAPI + SQLite admin API, Xray, nginx stream, Linux WireGuard, Swift/iOS Network Extension.

---

### Task 1: Server Contract

**Files:**
- Modify: `server_mvp/quickvpn_admin/app.py`
- Test: `python3 -m py_compile server_mvp/quickvpn_admin/app.py`

- [ ] Add protocol-aware server IDs: `quickvpn-mvp-eu-1`, `quickvpn-mvp-eu-1-trojan`, and `quickvpn-mvp-eu-1-wireguard`.
- [ ] Store protocol-specific credentials in the existing `profiles` table, adding WireGuard key/address columns.
- [ ] Return protocol-specific `config_url` values from `/api/v1/mobile/servers/{server_id}/profile`.

### Task 2: Runtime Config

**Files:**
- Modify: `server_mvp/quickvpn_admin/app.py`
- Server: `/etc/quickvpn/quickvpn.env`, `/etc/nginx/stream.d/quickvpn-stream.conf`, `/etc/bind/zones/db.netlumavpn.example`, `/etc/wireguard/wg0.conf`

- [ ] Render Xray VLESS and Trojan inbounds from active profiles.
- [ ] Render WireGuard peers from active WireGuard profiles.
- [ ] Configure DNS/TLS/SNI routing and open `51820/udp`.

### Task 3: iOS Client

**Files:**
- Modify: `QuickVPNShared/Models/GlobalVPNServer.swift`
- Modify: `QuickVPNTests/GlobalServerIntegrationTests.swift`
- Existing parser/builder: `QuickVPNShared/Services/VPNConfigurationParser.swift`, `QuickVPNShared/Services/XrayConfigBuilder.swift`

- [ ] Decode three global server entries.
- [ ] Preserve per-protocol server IDs in managed profiles.
- [ ] Include the protocol name in global profile display names so the user can distinguish the choice.

### Task 4: Verification

- [ ] Run focused Swift tests for global server integration and protocol parsing.
- [ ] Deploy server app and restart services.
- [ ] Verify API returns three servers and issues parseable VLESS, Trojan, and WireGuard profiles.
- [ ] Verify Xray config test passes, nginx reloads, and WireGuard interface is active.
