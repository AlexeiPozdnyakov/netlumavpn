# NetlumaVPN Architecture

> Start here for the big picture, then read the component doc for the area you're
> touching (see [`docs/README.md`](README.md)). For exact identifiers see
> [`IDENTIFIERS.md`](IDENTIFIERS.md); for the discrepancies this diagram glosses
> over, see [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

## System overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│ iOS device                                                              │
│                                                                         │
│  ┌──────────────────────────┐     ┌──────────────────────────────────┐  │
│  │ NetlumaVPN.app (main)    │     │ NetlumaVPNWidget (extension)     │  │
│  │  ┌────────────────────┐  │     │  WidgetKit + App Intents         │  │
│  │  │ @Observable        │  │     │  Connect/Disconnect/Toggle       │  │
│  │  │ AppModel           │  │     │  intents drive the tunnel        │  │
│  │  │  ├ profiles        │  │     │  DIRECTLY via WidgetVPNController │  │
│  │  │  ├ status          │  │     │  (no pending-action queue)       │  │
│  │  │  ├ globalServers   │  │     └──────────────────────────────────┘  │
│  │  │  ├ premium…        │  │                                            │
│  │  │  └ prefs           │  │                                            │
│  │  └────────┬───────────┘  │                                            │
│  │           │              │                                            │
│  │  App-side services:      │                                            │
│  │  ├ VPNManager → NEVPN…   │   AppDelegate → FirebaseApp.configure()    │
│  │  ├ GlobalServerService   │   FirebaseTelemetryReporter (Analytics +   │
│  │  ├ PremiumSubscription…  │     Crashlytics; no secrets)               │
│  │  └ ProfileStorage        │                                            │
│  └────────┬──────────┬──────┘                                            │
│           │          │                                                   │
│   App Group│   Keychain (shared access group)                            │
│   (file    │   per-profile secrets + device ID                           │
│    JSON)   │                                                              │
│           ▼          ▼                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ NetlumaVPNTunnelExtension (NEPacketTunnelProvider)                 │  │
│  │  ├ reads ResolvedVPNProfile from start-options payload            │  │
│  │  │   (TunnelStartPayload) — metadata + Keychain secret            │  │
│  │  ├ XrayConfigBuilder      → Xray-core outbound JSON               │  │
│  │  ├ TunnelNetworkSettingsBuilder → routes + DNS (full tunnel)      │  │
│  │  └ XrayTunnelEngine: SwiftyXrayKit  |  MockXrayTunnelEngine       │  │
│  └──────────────┬─────────────────────────────────────────────────────┘ │
│                 │ NEPacketTunnelFlow (handled inside SwiftyXrayKit)     │
└─────────────────┼────────────────────────────────────────────────────────┘
                  │
                  ▼ encrypted tunnel (VLESS Reality / VMess / Trojan / WG)
        ┌──────────────────────────────────────────┐
        │ VPS behind netlumavpn.example                │
        │                                          │
        │  443/tcp ── nginx STREAM (ssl_preread) ──┐
        │     SNI root/www/api./admin. → 127.0.0.1:8443 │  (website + admin + mobile API)
        │     SNI trojan.      → 127.0.0.1:2443    │  (Trojan TLS)
        │     default (vpn.)   → 127.0.0.1:1443    │  (Xray VLESS Reality)
        │                                          │
        │  8443  nginx https vhost → 127.0.0.1:8000 (uvicorn FastAPI)
        │  8000  FastAPI: admin UI + admin API + mobile API + provisioning
        │        SQLite (WAL, FK on) + audit_logs                          │
        │                                          │
        │  10085 Xray gRPC stats API (scraped by quickvpn-stats.timer)
        │  51820/udp WireGuard wg0                 │
        │  80/tcp  nginx http (ACME + 308→HTTPS)   │
        │  22/tcp SSH admin access (live VPS)    │
        └──────────────────────────────────────────┘
```

> **Which backend is on :8000?** The provisioning scripts deploy the
> **Xray/WireGuard** FastAPI app (`archive/server_mvp/quickvpn_admin/app.py`).
> A newer **sing-box** app (`server_mvp/quickvpn_singbox_admin/app.py`, :8020) and
> a stdlib sidecar (:8010) exist in the tree but are **not** wired by the fresh-server
> provisioner. Current `netlumavpn.example/api/v1/status` was observed on 2026-06-24
> returning `netlumavpn-singbox`, so always confirm the live target before backend work.
> See [`BACKEND.md`](BACKEND.md) and [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

## Targets and their responsibilities

| Target | Type | Responsibility |
|--------|------|----------------|
| `NetlumaVPN` | iOS app | UI, state (`AppModel`), backend client, NEVPN config, StoreKit, Firebase init |
| `NetlumaVPNTunnelExtension` | Packet Tunnel (`app-extension`) | Reads the start payload, builds Xray config + network settings, drives `XrayTunnelEngine` |
| `NetlumaVPNWidget` | Widget (`app-extension`) | Home Screen widget; Connect/Disconnect/Toggle App Intents drive the tunnel directly |
| `NetlumaVPNShared` | Source folder (compiled into all three targets) | Models + storage + logging shared across app, extension, widget |
| `NetlumaVPNTests` | Unit test bundle | **Swift Testing** (`@Test`/`#expect`) — parsing, config build, storage, logic |
| `NetlumaVPNUITests` | UI test bundle | **XCUITest** — launch + tab smoke tests |

The four build targets, packages (Firebase, SwiftyXrayKit), and schemes are
defined in [`project.yml`](../project.yml) — the **single source of truth** for
the Xcode project. Never hand-edit `NetlumaVPN.xcodeproj`; run `xcodegen generate`.

## Boundary contracts

### App ↔ Extension (start-options payload + App Group + Keychain)

- The app/widget start the tunnel with two start options:
  `AppConstants.AppGroupKeys.selectedProfileID` (the profile UUID string) and
  `AppConstants.TunnelOptions.startPayload` — a JSON-encoded `TunnelStartPayload`
  wrapping a `ResolvedVPNProfile` (`VPNProfile` metadata **+** its `VPNProfileSecret`
  from the Keychain). The extension decodes this directly; it does **not** re-read
  the secret from storage when a payload is present.
- `providerConfiguration` carries only `selectedProfileID` — **no secrets**.
- `AppGroupStorage` (file-based JSON under the App Group container) holds
  `profiles.v1`, `selectedProfileID.v1`, `networkPreferences.v1`, `logs.v1`,
  `connectionSessionState.v1`, `connectionDisplayState.v1`.
- `KeychainStorage` holds per-profile secrets (`service = …NetlumaVPN.profiles`)
  and the per-device global ID, scoped to the shared access group, with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the extension can read
  them on on-demand launch.
- **The extension never calls the backend.** Everything it needs is in the start
  payload + App Group + Keychain at tunnel-start time.

### App ↔ Backend (HTTPS mobile API)

- All requests go through `GlobalServerAPIClient` (in `NetlumaVPN/Services/`).
- Base URL: `AppConstants.Backend.mobileAPIBaseURL` = `https://netlumavpn.example`.
- Headers: **both** `X-NetlumaVPN-Client-Key` and legacy `X-QuickVPN-Client-Key`
  (same key), and **both** `X-NetlumaVPN-Device-ID` / `X-QuickVPN-Device-ID`.
- TLS pin: a `URLSessionDelegate` validates the **leaf certificate** SHA256
  (CryptoKit, full DER cert — *not* SPKI) against
  `AppConstants.Backend.mobileTLSCertificateSHA256Base64`. **That constant is
  currently empty, so pinning is disabled** (`.performDefaultHandling`).
- Endpoints: `GET /api/v1/mobile/servers`, `POST /api/v1/mobile/servers/{id}/profile`.

### App ↔ Widget (App Group + Keychain, no queue)

- The widget reads the same profiles, selected profile, display state, App Group,
  and Keychain as the app, and controls the tunnel **directly** through
  `WidgetVPNController` (loads `NETunnelProviderManager`, calls start/stop).
- There is **no pending-action queue**. The only “queue-like” mechanism is the
  optimistic `connectionDisplayState.v1` cache (valid 5 s) for instant UI.

### Backend ↔ proxy engine (filesystem + systemctl)

- **Live backend (Xray/WireGuard):** the `render-xray` / `render-wireguard` CLI
  writes `/usr/local/etc/xray/config.json` and `wg0.conf`, applied via
  `systemctl restart xray` / `wg-quick@wg0`.
- **sing-box backend (not provisioned):** mutates `/etc/sing-box/config.json`,
  validates with `sing-box check`, reloads `sing-box.service` (atomic
  write-then-replace, so a bad config never goes live).

## State management

- `AppModel` is `@MainActor` + `@Observable`, the single source of truth for UI
  state. Feature views are mostly **stateless and value-driven** — `ContentView`
  passes snapshots + callbacks down (e.g. `HomeConnectView`).
- All storage and service dependencies are **protocol-typed and injected** so
  tests substitute in-memory fakes (`SecureValueStorage`, `VPNManaging`,
  `GlobalServerServicing`, `PremiumSubscriptionServicing`, `OnboardingCompletionStoring`).
- Connection status is observed from `NEVPNStatusDidChange` in `VPNManager`, then
  bridged into `AppModel.status`.
- Display state (last-known status) is persisted via `ConnectionDisplayStateStorage`
  (20 s freshness window) so the home tab and widget don’t flicker on resume.

## Per-device profile dedup

The mobile API hashes `sha256(server_id:device_id)` to find an existing active
profile before issuing a new one. This prevents reinstall churn, lets the client
refresh without burning server capacity, and avoids surfacing a raw VLESS URL.
The device ID is a UUID generated once by `GlobalServerDeviceIdentityStore` and
stored in the shared Keychain (account `netlumavpn-global-device-id.v1`).
(The two backends implement the dedup key slightly differently — see
[`BACKEND.md`](BACKEND.md).)

## Mock engine fallback

`SwiftyXrayKit` is an **optional** SPM dependency, selected at compile time via
`#if canImport(SwiftyXrayKit)`. When it is not linked, the extension uses
`MockXrayTunnelEngine`:

- The lifecycle still completes (start → set settings → idle → stop) and the UI
  shows **Connected**, but `routesDefaultTraffic == false`, so
  `TunnelNetworkSettingsBuilder` installs **no default route and no DNS** —
  **zero traffic is proxied**. This is the classic “connected but no internet”
  trap on simulator/CI builds.
- The unified log states which engine is running
  (`Using SwiftyXrayKit tunnel engine` vs the mock’s
  `SwiftyXrayKit is not linked; falling back to mock tunnel engine`).

## Telemetry

- `AppDelegate.application(_:didFinishLaunchingWithOptions:)` calls
  `FirebaseApp.configure()`. Swizzling is disabled
  (`FirebaseAppDelegateProxyEnabled = false`) for SwiftUI.
- `FirebaseTelemetryReporter` logs network-failure events and premium-purchase
  lifecycle events to Analytics + Crashlytics. It reports only host/path/status/
  product-id — **never** keys, device IDs, query strings, or full URLs.
- All local logging goes through `AppLogger` (OSLog + an in-app `AppLogStore`).
  No `print(...)`. See [`SHARED.md`](SHARED.md).

## What's NOT in the architecture (yet)

- No multi-region backend (schema supports multiple `server_id`s; only one region
  is provisioned).
- No Lock Screen accessory widget — the widget is `.systemSmall` / `.systemMedium`
  only.
- Only two tabs (`Home`, `Settings`) — no standalone Servers/Protocols tabs.
- No remote config / feature flags, no disconnect push notifications.
- No persistent traffic-history graphs (only current-session counters server-side).
- No iCloud backup/restore of profiles.

## Useful entry points when reading the code

| Question | Start here |
|----------|------------|
| What happens on launch? | `NetlumaVPN/App/NetlumaVPNApp.swift` → `AppDelegate` → `ContentView` → `AppModel.init` |
| How does a connection get established? | `AppModel.toggleConnection` → `VPNManager.connect` → `PacketTunnelProvider.startTunnel` |
| How is a VLESS/VMess/Trojan/WG URL parsed? | `NetlumaVPNShared/Services/VPNConfigurationParser.swift` |
| What JSON does Xray see? | `NetlumaVPNShared/Services/XrayConfigBuilder.swift` |
| How does the widget toggle the VPN? | `NetlumaVPNWidget/ToggleVPNConnectionIntent.swift` → `WidgetVPNController` |
| How are global servers fetched / profiles issued? | `NetlumaVPN/Services/GlobalServerService.swift` + `GlobalServerAPIClient.swift` |
| What does the backend serve? | `archive/server_mvp/quickvpn_admin/app.py` (fresh-server provisioner) / `server_mvp/quickvpn_singbox_admin/app.py` (observed on current production 2026-06-24) |
| How is the VPS configured? | `ops/` (nginx + systemd + fail2ban + provision scripts) |

_Last full analysis: 2026-06-24._
