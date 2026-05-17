# QuickVPN — Claude Code Project Context

This file is auto-loaded by Claude Code at the start of every session.
It documents conventions, layout, and guardrails that all agents must follow.

## What is QuickVPN

A multi-protocol iOS VPN client (VLESS Reality, VMess, Trojan, WireGuard) with a
Packet Tunnel Extension, Lock Screen widget, and a Python FastAPI backend that
issues per-device profiles. The repo also contains the `ops/` files used to
provision the production VPS.

The mobile app talks to the backend with **TLS certificate pinning** (SHA256 base64
pin in `AppConstants.Backend.mobileTLSCertificateSHA256Base64`). The tunnel
extension proxies real traffic through `SwiftyXrayKit` and falls back to
`MockXrayTunnelEngine` when the package is not linked.

## Repository layout

```
QuickVPN/                       # Main app target (SwiftUI)
  App/                          # AppModel, ContentView, tabs, splash, app entry
  Features/                     # Connection, Profiles, Servers, Settings, Premium, Protocols
  Services/                     # VPNManager, GlobalServerAPIClient, GlobalServerService
  Design/                       # QuickVPNTheme
  Assets.xcassets               # Images, colors
  Info.plist                    # NSCameraUsageDescription, etc.
  QuickVPN.entitlements         # App Groups, Keychain Sharing, Network Extensions

QuickVPNShared/                 # Shared sources for app + extension + widget
  Models/                       # VPNProfile, AppConstants, NetworkPreferences, GlobalVPNServer, AppLogEvent
  Services/                     # ProfileStorage, KeychainStorage, AppGroupStorage,
                                # VPNConfigurationParser, XrayConfigBuilder,
                                # TunnelNetworkSettingsBuilder, AppLogger,
                                # AppLogStore, NetworkPreferencesStorage,
                                # ConnectionDiagnostics

QuickVPNTunnelExtension/        # NEPacketTunnelProvider
  PacketTunnelProvider.swift
  XrayTunnelEngine.swift        # SwiftyXrayKit + MockXrayTunnelEngine fallback
  Info.plist
  QuickVPNTunnelExtension.entitlements

QuickVPNWidget/                 # WidgetKit + App Intents
  QuickVPNWidget.swift
  ToggleVPNConnectionIntent.swift
  WidgetVPNController.swift
  QuickVPNWidget.entitlements

QuickVPNTests/                  # Unit tests (Swift Testing, not XCTest)
QuickVPNUITests/                # UI tests (XCUITest)

server_mvp/quickvpn_admin/      # Python FastAPI backend (admin + mobile API)
  app.py                        # ~775 lines, single-file FastAPI app
  requirements.txt              # fastapi==0.115.6, uvicorn[standard]==0.34.0

ops/                            # VPS provisioning files (copied to /etc, /opt on the server)
  bootstrap-quickvpn-ssh.sh
  systemd/{quickvpn-api.service, quickvpn-stats.service, quickvpn-stats.timer}
  nginx/{quickvpn.conf, quickvpn-stream.conf}
  fail2ban/sshd.local

project.yml                     # XcodeGen — single source of truth for the Xcode project
QuickVPN.xcodeproj/             # Generated; do NOT hand-edit
README.md                       # Public README
QUICKVPN_MVP_SERVER.md          # Server runbook (contains live secrets — never publish)
design.pen                      # Pencil design file (use the `pencil` MCP tools to read)
```

## Tech stack

| Layer | Tech | Version / notes |
|------|------|-----------------|
| iOS deployment target | iOS | 17.0 |
| Language | Swift | 5.0 |
| UI | SwiftUI + `@Observable` macro | no `ObservableObject` |
| VPN | `NetworkExtension` / `NEPacketTunnelProvider` | native |
| Xray engine | `SwiftyXrayKit` | 1.1.0 (SPM, optional) |
| Widget | WidgetKit + App Intents | iOS 17 |
| Storage | UserDefaults (App Group) + Keychain | shared access group |
| Tests | Swift Testing (`@Test`, `#expect`) | NOT XCTest for unit tests |
| UI tests | XCUITest | XCTest based |
| Project gen | XcodeGen | 2.42+ |
| Backend | FastAPI 0.115.6 + Uvicorn 0.34.0 | single-file `app.py` |
| Database | SQLite | WAL mode |
| Server proxy | nginx (stream + http) | TLS terminated for mobile API only |
| Server service | systemd | `xray`, `quickvpn-api`, `quickvpn-stats.timer` |

## Identifiers (DO NOT change without updating all four locations)

- Bundle ID: `com.alekseipozdiakov.QuickVPN`
- Tunnel bundle ID: `com.alekseipozdiakov.QuickVPN.PacketTunnel`
- Widget bundle ID: `com.alekseipozdiakov.QuickVPN.Widget`
- App Group: `group.com.alekseipozdiakov.QuickVPN`
- Keychain Sharing: `6659MLRZ5F.com.alekseipozdiakov.QuickVPN.shared`
- Apple Team ID: `6659MLRZ5F`

If you change any of these, update **all** of:
1. `project.yml`
2. `QuickVPN/QuickVPN.entitlements`
3. `QuickVPNTunnelExtension/QuickVPNTunnelExtension.entitlements`
4. `QuickVPNWidget/QuickVPNWidget.entitlements`
5. `QuickVPNShared/Models/AppConstants.swift`

## Build & run

```bash
# Regenerate Xcode project after editing project.yml or moving files
xcodegen generate

# Build for simulator
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run unit tests
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test

# Run network-dependent tests (skipped by default)
RUN_NETWORK_TESTS=1 xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test
```

Packet Tunnel behaviour requires a **physical device** with a real Apple
Developer team that has Network Extensions entitlement. The simulator can
compile and partially run, but actual VPN routing only works on device.

## Conventions

### Swift
- Prefer `@Observable` (Observation framework) over `ObservableObject` + `@Published`.
- `@MainActor` on UI-state types (`AppModel`, view models).
- Use **Swift Testing** (`@Test`, `#expect`) for new unit tests; existing UI tests stay on XCTest.
- Wrap storage with protocols (e.g. `OnboardingCompletionStoring`) so tests can inject in-memory fakes — see `QuickVPNTests/InMemorySecureValueStorage.swift`.
- Never log secrets: passwords, user IDs (`secret.userId`), private keys, generated Xray JSON, full server endpoints. `AppLogger` is the only sanctioned logger; do not add `print(...)` calls.
- Mock fallback pattern: every external engine must have a `Mock*` fallback for testability. See `XrayTunnelEngine`.

### Architecture
- **MVVM with `@Observable`.** `AppModel` is the single root state holder; feature views observe it through `Bindable`/`@Environment`.
- **Boundary between app and extension is `AppGroupStorage` + `KeychainStorage`.** Anything the extension needs at tunnel start is persisted through these stores. The extension does not call the backend.
- **VPN profiles are split**: metadata (`VPNProfile`) → UserDefaults via App Group; secrets (`VPNProfileSecret`) → Keychain (shared access group). They are joined by `profile.id`.
- **Backend-issued profiles**: `GlobalServerService` calls `/api/v1/mobile/servers/{id}/profile` with a per-device `X-QuickVPN-Device-ID` header; the backend dedupes by `sha256(server_id:device_id)`.

### Backend
- Single-file FastAPI app, deliberately. Do not introduce package layout without a strong reason.
- All admin routes require an HMAC-signed session cookie; all API routes require `X-QuickVPN-API-Key` (admin) or `X-QuickVPN-Client-Key` (mobile).
- Mobile routes are rate-limited at the nginx layer (`30r/m`, burst `20`).
- Passwords hashed with PBKDF2-SHA256 (260k iterations).
- Database is SQLite with WAL + foreign keys; do not silently drop FK enforcement.

### Ops
- Production server: `192.0.2.10` (Ubuntu 24.04). See `QUICKVPN_MVP_SERVER.md` for full credentials and service map.
- SSH is key-only via `/Users/alexeipozdnyakov/.ssh/quickvpn_vps_ed25519`.
- nginx `stream` SNI-routes `vpn.netlumavpn.example` → `127.0.0.1:8443` (mobile API), all other 443 traffic → `127.0.0.1:1443` (Xray VLESS Reality).

## Guardrails for agents

1. **Never edit `QuickVPN.xcodeproj/` by hand.** Always edit `project.yml` and run `xcodegen generate`.
2. **Do not read `design.pen` with `Read`/`Grep`.** Use the `pencil` MCP tools (`pencil:open_document`, `pencil:get_screenshot`, etc.).
3. **Never commit secrets.** `QUICKVPN_MVP_SERVER.md` is the only file with live keys; everything else must reference them by name only.
4. **Do not change identifiers without updating all five locations** listed above.
5. **Do not introduce new logger paths** alongside `AppLogger`. Sanitization lives there.
6. **Treat the production VPS as live.** Do not run destructive commands (`systemctl stop xray`, `ufw disable`, schema-changing `sqlite3` writes) without the user confirming.
7. **When in doubt about a VPN protocol detail**, consult `VPNConfigurationParser.swift` (parsing) and `XrayConfigBuilder.swift` (config emission) — they are the canonical implementations.
8. **Use Swift Testing for new unit tests.** Mixing `XCTest` and `Testing` inside `QuickVPNTests/` will compile but is confusing — the convention is `Testing` for unit, `XCTest` for UI.

## Specialist agents

This repo ships with project-level subagents under `.claude/agents/`. Prefer them
over the `general-purpose` agent when the task fits:

| Agent | Use for |
|-------|---------|
| `ios-developer` | SwiftUI features, `AppModel` changes, view code |
| `vpn-engineer` | VLESS/VMess/Trojan/WireGuard parsing, Xray config, Packet Tunnel |
| `backend-developer` | `server_mvp/quickvpn_admin/app.py`, FastAPI endpoints, SQLite |
| `ops-engineer` | nginx, systemd, ufw, fail2ban, VPS deployment |
| `swift-tester` | Writing Swift Testing unit tests with in-memory fakes |
| `security-reviewer` | Pre-merge security review of VPN code, secrets, pinning |

Slash commands under `.claude/commands/`:

- `/regen` — run `xcodegen generate`
- `/build` — build for the iPhone 17 Pro simulator
- `/test` — run `QuickVPNTests`
- `/test-network` — run network-dependent tests with `RUN_NETWORK_TESTS=1`
- `/deploy-server` — rsync `ops/` + `server_mvp/` to the VPS and restart services

Skills under `.claude/skills/`:

- `quickvpn-build` — xcodegen + xcodebuild recipes
- `vpn-protocols` — VLESS/VMess/Trojan/WireGuard URL parsing and Xray JSON shape
- `backend-server` — FastAPI endpoint map, DB schema, mobile API auth
