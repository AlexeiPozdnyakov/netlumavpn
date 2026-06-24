# Widget (`NetlumaVPNWidget` target)

> Owner agent: `ios-developer`. A Home Screen widget that controls the VPN
> **directly** (no main-app round-trip). Shares models/storage with the app via
> [`NetlumaVPNShared`](SHARED.md).

## Files

| File | Role |
|------|------|
| `NetlumaVPNWidget/NetlumaVPNWidget.swift` | Widget definition, timeline provider, views, state loader |
| `NetlumaVPNWidget/ToggleVPNConnectionIntent.swift` | Connect / Disconnect / Toggle App Intents |
| `NetlumaVPNWidget/WidgetVPNController.swift` | Drives `NETunnelProviderManager` from the extension |
| `NetlumaVPNWidget/Info.plist` | `NSExtensionPointIdentifier = com.apple.widgetkit-extension` |
| `NetlumaVPNWidget/NetlumaVPNWidget.entitlements` | NE + App Group + Keychain group |

## Widget definition

- `@main NetlumaVPNWidgetBundle` exposes one widget: `NetlumaVPNWidget` (kind
  `"NetlumaVPNWidget"`), a **`StaticConfiguration`** using `NetlumaVPNWidgetProvider`.
- **Supported families: `.systemSmall` and `.systemMedium` only.** ⚠️ Despite the
  "Lock Screen widget" framing elsewhere, there are **no accessory (lock-screen)
  families**. The view switch only special-cases `.systemMedium`; everything else falls
  to the small view.
- **Timeline provider** `NetlumaVPNWidgetProvider`: refresh policy `.after` —
  2 s while transitioning, 180 s connected, 900 s otherwise.
- **State** `NetlumaVPNWidgetState`: `status`, `selectedProfile`, optional
  `sessionInfo` + `latencyMS`, with display strings via `L10n`.
- **State loader** `NetlumaVPNWidgetStateLoader`: reads profiles via `ProfileStorage`,
  status via `WidgetVPNController().currentStatus()`, and (only when connected, on the
  full timeline path) fetches geo from `ipapi.co` (1 s timeout) and TCP latency via
  `ConnectionDiagnostics`.
- **Small view**: status + power button + location/profile name. **Medium view**: power
  button + status + location + IP & latency pills. Neither view renders a live
  connection-duration timer (the data exists but isn't surfaced).

## App Intents (`ToggleVPNConnectionIntent.swift`)

Three iOS-17 interactive-widget `AppIntent`s, all `openAppWhenRun = false` (run
in-process, don't launch the app):

| Intent | Calls |
|--------|-------|
| `ConnectVPNConnectionIntent` | `WidgetVPNController().connectSelectedProfile()` |
| `DisconnectVPNConnectionIntent` | `WidgetVPNController().disconnectConnection()` |
| `ToggleVPNConnectionIntent` | `WidgetVPNController().toggleConnection()` |

Each logs via `AppLogger` (category `.vpn`) and calls
`WidgetCenter.shared.reloadAllTimelines()`. The rendered power button picks **Connect**
or **Disconnect** based on `state.status.isWidgetSessionActive`; `ToggleVPNConnectionIntent`
is effectively only a Shortcuts/Siri action.

## `WidgetVPNController`

A `struct` that **drives `NETunnelProviderManager` directly** — the widget process
starts/stops the tunnel itself; it does **not** signal the app. Injects
`ProfileStorage`, `NetworkPreferencesStorage`, `SessionStateStorage`,
`ConnectionDisplayStateStorage`.

- **`currentStatus(...)`**: optionally returns the cached `connectionDisplayState` if
  within a **5 s** window (optimistic UI without hitting NetworkExtension); otherwise
  loads the manager and reconciles against the cached state.
- **`connect(profile:)`**: persists selection, writes optimistic `.connecting`, builds
  `ResolvedVPNProfile` (joins the **Keychain secret**) → `TunnelStartPayload`, prepares/
  configures the manager (`providerBundleIdentifier = tunnelProviderBundleIdentifier`,
  `serverAddress`, `providerConfiguration[selectedProfileID]`, on-demand rules), then
  `startVPNTunnel(options:)` with `selectedProfileID` + `startPayload`. Writes session +
  display state, reloads timelines. On failure → `.failed`.
- **`disconnect()`**: optimistic `.disconnecting`, `stopVPNTunnel()`, clears session state.
- **`selectedProfile()`**: selected profile, else first profile (and persists it).
- **`loadExistingManager()`**: matches by `providerBundleIdentifier == tunnelProviderBundleIdentifier`
  **or** `localizedDescription == AppConstants.appName` (loose match).

## Shared data path

The widget reads/writes the **same** App Group keys and Keychain items as the app
(see [`SHARED.md`](SHARED.md)): `profiles.v1`, `selectedProfileID.v1`,
`networkPreferences.v1`, `connectionSessionState.v1`, `connectionDisplayState.v1`, plus
per-profile secrets and the `startPayload.v1` start option. **No pending-action queue**
— the only async coupling is the 5 s display-state cache.

## Entitlements / Info.plist

- `com.apple.developer.networking.networkextension` → `["packet-tunnel-provider"]`
- `com.apple.security.application-groups` → `["group.com.alekseipozdiakov.NetlumaVPN"]`
- `keychain-access-groups` → `["$(AppIdentifierPrefix)com.alekseipozdiakov.NetlumaVPN.shared"]`
- `NSExtensionPointIdentifier` = `com.apple.widgetkit-extension`
- Bundle ID `com.alekseipozdiakov.NetlumaVPN.Widget` (from `project.yml`).

## Gotchas

- No lock-screen accessory families (only small/medium).
- The widget does network I/O (`ipapi.co` + latency probe) on the timeline path and
  pulls the **plaintext secret** out of the Keychain into a `TunnelStartPayload` — same
  as the app, but worth knowing for a privacy/perf pass.
- The 5 s optimistic cache can show stale status if a tunnel dies out-of-band.
- The widget target has **no automated tests** — see [`TESTING.md`](TESTING.md).

_Last full analysis: 2026-06-24._
