# QuickVPN Architecture

## System overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│ iOS device                                                              │
│                                                                         │
│  ┌──────────────────────────┐     ┌──────────────────────────────────┐  │
│  │ QuickVPN.app (main)      │     │ QuickVPNWidget (extension)       │  │
│  │  ┌────────────────────┐  │     │  WidgetKit + App Intents         │  │
│  │  │ @Observable        │  │     │  ToggleVPNConnectionIntent       │  │
│  │  │ AppModel           │  │     │  queues an action in App Group   │  │
│  │  │  ├ profiles        │  │     │  → main app reads on launch      │  │
│  │  │  ├ status          │  │     └──────────────────────────────────┘  │
│  │  │  ├ globalServers   │  │                                            │
│  │  │  └ prefs           │  │                                            │
│  │  └────────┬───────────┘  │                                            │
│  │           │              │                                            │
│  │  Services:│              │                                            │
│  │  ├ VPNManager → NEVPN…   │                                            │
│  │  ├ GlobalServerService   │                                            │
│  │  └ ProfileStorage        │                                            │
│  └────────┬──────────┬──────┘                                            │
│           │          │                                                   │
│   AppGroup│   Keychain                                                   │
│   metadata│   secrets                                                    │
│           │  (shared access group)                                       │
│           ▼          ▼                                                   │
│  ┌──────────────────────────────────────────────┐                        │
│  │ QuickVPNTunnelExtension (NEPacketTunnelProvider)                   │  │
│  │  ├ reads VPNProfile (AppGroup) + secret (Keychain)                  │  │
│  │  ├ XrayConfigBuilder → outbound JSON                                │  │
│  │  ├ TunnelNetworkSettingsBuilder → routes + DNS                      │  │
│  │  └ XrayTunnelEngine (SwiftyXrayKit  | MockXrayTunnelEngine)         │  │
│  └──────────────┬──────────────────────────────────────────────────────┘ │
│                 │ NEPacketTunnelFlow                                     │
└─────────────────┼────────────────────────────────────────────────────────┘
                  │
                  ▼ encrypted tunnel (VLESS Reality / VMess / Trojan / WG)
        ┌──────────────────────────────────────────┐
        │ VPS — 192.0.2.10 (Ubuntu 24.04)       │
        │                                          │
        │  443/tcp  ── nginx stream (SNI router) ──┐
        │           ┌───────────────────────────┐  │
        │           │ SNI = quickvpn-api.…sslip │  │
        │           │ → 127.0.0.1:8443 (HTTPS)  │  │
        │           └─────────┬─────────────────┘  │
        │                     │ mobile API         │
        │                     ▼                    │
        │           ┌───────────────────────────┐  │
        │           │ uvicorn FastAPI :8000     │  │
        │           │   admin UI + admin API    │  │
        │           │   SQLite + audit_logs     │  │
        │           └───────────────────────────┘  │
        │                                          │
        │   * (everything else) → 127.0.0.1:1443   │
        │                                          │
        │                     ▼                    │
        │           ┌───────────────────────────┐  │
        │           │ Xray-core 26.3.27         │  │
        │           │   VLESS Reality           │  │
        │           │   stats API :10085        │  │
        │           └─────────┬─────────────────┘  │
        │                     │                    │
        │                     ▼                    │
        │            (real internet)               │
        │                                          │
        │  80/tcp   ── nginx http ── admin UI + admin API
        │  22/tcp   ── SSH key-only, fail2ban
        └──────────────────────────────────────────┘
```

## Targets and their responsibilities

| Target | Type | Responsibility |
|--------|------|----------------|
| `QuickVPN` | iOS app | UI, state (`AppModel`), backend client, NEVPN configuration |
| `QuickVPNTunnelExtension` | Packet Tunnel | Reads shared config, drives `XrayTunnelEngine`, owns packet flow |
| `QuickVPNWidget` | Widget extension | Lock-screen toggle via App Intent (queues action through App Group) |
| `QuickVPNShared` (folder, not a target) | Source root | Models + services shared across all three targets |
| `QuickVPNTests` | Unit test bundle | Swift Testing (`@Test`) — parsing, storage, logic |
| `QuickVPNUITests` | UI test bundle | XCUITest — flow tests |
| `server_mvp/quickvpn_admin/app.py` | FastAPI app | Admin UI + admin API + mobile API + Xray reconfig |

## Boundary contracts

### App ↔ Extension (App Group + Keychain)

- `AppGroupStorage` writes JSON blobs under keys defined in
  `AppConstants.AppGroupKeys` (e.g. `profiles.v1`, `selectedProfileID.v1`,
  `networkPreferences.v1`, `connectionSessionState.v1`,
  `connectionDisplayState.v1`, `pendingWidgetAction.v1`, `logs.v1`).
- `KeychainStorage` holds per-profile secrets under
  `AppConstants.Keychain.service`, scoped to
  `AppConstants.keychainAccessGroup`.
- The extension never calls the backend — everything it needs must be in
  App Group + Keychain at tunnel-start time.
- The extension passes additional data through
  `NETunnelProviderProtocol.providerConfiguration[AppConstants.TunnelOptions.startPayload]`
  when needed (large blobs that shouldn't go through Keychain).

### App ↔ Backend (HTTPS with TLS pin)

- All requests through `GlobalServerAPIClient`.
- Base URL: `AppConstants.Backend.mobileAPIBaseURL`.
- Headers: `X-QuickVPN-Client-Key` and `X-QuickVPN-Device-ID`.
- TLS pin: `URLSessionDelegate` validates SPKI SHA256 against
  `AppConstants.Backend.mobileTLSCertificateSHA256Base64`.

### App ↔ Widget (App Group)

- Widget writes a "pending action" (`connect` / `disconnect` / `toggle`)
  under `AppConstants.AppGroupKeys.pendingWidgetAction`.
- Main app picks it up on launch / foreground via
  `WidgetActionStorage.consumePendingAction()` and applies it via
  `VPNManager`.

### Backend ↔ Xray (filesystem + systemctl)

- Profile mutations rewrite `/usr/local/etc/xray/config.json`.
- `subprocess.run(["systemctl", "restart", "xray"])` reloads Xray.
- The service user has a sudoers entry for this exact command only.

## State management

- `AppModel` is `@MainActor` + `@Observable`. It is the single source of
  truth for UI state.
- Storage abstractions are protocol-typed so tests can substitute in-memory
  fakes (`InMemorySecureValueStorage`).
- Connection state is observed from `NEVPNStatusDidChange` notifications
  in `VPNManager`, then bridged into `AppModel.status`.
- Display state (last-known status for cold launches) is persisted via
  `ConnectionDisplayStateStorage` so the home tab doesn't flicker on app
  resume.

## Per-device profile dedup

The mobile API hashes `sha256(server_id:device_id)` to look up an existing
active profile before issuing a new one. This:

- Prevents iOS uninstall → reinstall from leaking orphan profiles.
- Lets the iOS app refresh its profile without burning capacity on Xray.
- Removes the need to surface a raw VLESS URL to the user.

The device ID is generated on first launch by
`GlobalServerDeviceIdentityStore` and stored in the shared keychain.

## Mock engine fallback

`SwiftyXrayKit` is an optional SPM dependency. When not linked (e.g.
simulator-only builds or CI without the package), the tunnel extension
substitutes `MockXrayTunnelEngine`:

- Lifecycle still completes (start → set settings → idle → stop).
- Default route is NOT installed, so the device's normal internet keeps
  working — useful for plumbing tests.
- No traffic is actually proxied; the connection status will show
  `Connected` but no egress is happening.

The unified log includes a clear marker (`Using SwiftyXrayKit tunnel engine`
vs `Using MockXrayTunnelEngine`) so it's never ambiguous which engine is
running.

## What's NOT in the architecture (yet)

- No multi-region backend — the schema and mobile API support multiple
  `server_id`s but only `quickvpn-mvp-eu-1` is provisioned.
- No paid tier — `QuickVPN/Features/Premium/PremiumPaywallView.swift` is a
  stub.
- No protocol-picker UI — `QuickVPN/Features/Protocols/ProtocolsView.swift`
  is a stub.
- No remote config / feature flags.
- No push notifications for disconnect events.
- No persistent traffic history graphs — only current-session counters.
- No backup / restore of profiles via iCloud or similar.

## Useful entry points when reading the code

| Question | Start here |
|----------|------------|
| What does the app do on launch? | `QuickVPN/App/QuickVPNApp.swift` → `AppModel.init` |
| How does a connection get established? | `VPNManager.swift` → `PacketTunnelProvider.startTunnel` |
| How is a VLESS URL parsed? | `QuickVPNShared/Services/VPNConfigurationParser.swift` |
| What does Xray see? | `QuickVPNShared/Services/XrayConfigBuilder.swift` |
| How does the widget toggle the VPN? | `QuickVPNWidget/ToggleVPNConnectionIntent.swift` → `WidgetActionStorage` |
| How are global servers fetched? | `QuickVPN/Services/GlobalServerService.swift` |
| What does the backend serve? | `server_mvp/quickvpn_admin/app.py` (single file) |
| How is the VPS configured? | `ops/` (systemd + nginx + fail2ban) |
