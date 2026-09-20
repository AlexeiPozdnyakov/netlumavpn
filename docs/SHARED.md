# Shared Module (`NetlumaVPNShared`)

> Owner agents: `ios-developer` / `vpn-engineer`. These sources are compiled into
> the app, the tunnel extension, and the widget. This is the **canonical app↔extension
> boundary** — accuracy matters. For the exact identifier values see
> [`IDENTIFIERS.md`](IDENTIFIERS.md).

`NetlumaVPNShared` is a **source folder**, not a separate target — `project.yml`
adds its path to all three targets.

## `AppConstants` (`Models/AppConstants.swift`)

The single namespace of cross-target constants. Full identifier table in
[`IDENTIFIERS.md`](IDENTIFIERS.md). Key groups:

- Top level: `appName = "NetlumaVPN"`, `loggingSubsystem`, `appGroupIdentifier`,
  `tunnelProviderBundleIdentifier`, `keychainAccessGroup`.
- `AppGroupKeys`: `profiles.v1`, `selectedProfileID.v1`, `networkPreferences.v1`,
  `logs.v1`, `connectionSessionState.v1`, `connectionDisplayState.v1`.
- `TunnelOptions`: `startPayload.v1`.
- `Keychain`: `service = …NetlumaVPN.profiles`, `globalServerDeviceIDAccount = netlumavpn-global-device-id.v1`.
- `Backend`: reads the ignored bundled `Backend.local.plist` using
  `BackendConfiguration`. Without valid local HTTPS configuration, the endpoint is
  `https://api.netlumavpn.example` and both the mobile key and certificate pin are
  empty. See [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md).

> Header name strings (`X-NetlumaVPN-*`, `X-QuickVPN-*`) are **not** here — they live
> in `GlobalServerAPIClient.swift` (app target). There are no header constants in Shared.

## Models

### `VPNProfile` + `VPNProfileSecret` (`Models/VPNProfile.swift`)

The **metadata / secret split** that defines the boundary:

- **`VPNProfile`** (metadata → App Group JSON): `id: UUID`, `protocolType`, `host`,
  `port`, `security`, `networkType`, plus optionals for SNI/transport/path/flow/
  fingerprint/ALPN, Reality fields (`realityPublicKey`/`Fingerprint`/`ShortID`/`SpiderX`),
  WireGuard fields (`wireGuardPeerPublicKey`, `wireGuardLocalAddresses`,
  `wireGuardAllowedIPs`, `wireGuardPersistentKeepAlive`, `wireGuardMTU`,
  `wireGuardReserved`), `origin`, `managedServerID`, `remarks`, timestamps. The init
  normalizes blank strings → nil and empty arrays → nil.
- **`VPNProfileSecret`** (secret → Keychain): `userId` (VLESS/VMess), `password`
  (Trojan), `wireGuardPrivateKey`, `wireGuardPreSharedKey`.
- Joined by `profile.id` via `keychainAccount = "vpn-profile-<uuid>"`.
- `ResolvedVPNProfile { profile; secret }` recombines them; `TunnelStartPayload` wraps
  a `ResolvedVPNProfile` for the start-options payload.
- Enums: `VPNProtocolType` (`vless`/`vmess`/`trojan`/`wireguard`), `VPNTransportSecurity`
  (`none`/`tls`/`reality`), `VPNNetworkType` (`tcp`/`ws`/`grpc`/`httpupgrade`),
  `VPNProfileOrigin` (single case `netlumaVPNGlobal`).
- `isNetlumaVPNManaged == (origin == .netlumaVPNGlobal)` drives premium gating.

### `GlobalVPNServer` (`Models/GlobalVPNServer.swift`)

The backend server model. Decodes snake_case JSON via `CodingKeys`: `protocol` →
`protocolName`, `config_format` → `configFormat` (default `"uri"`), `is_available` →
`isAvailable`, `ip_mode` → `preferredIPMode` (default `.ipv4Only`).
`GlobalServerProfileIssue` is the profile-issue response (`profile_id`, `server_id`,
`protocol`, `config_format`, `config_url`); `requiresConfigDownload` is true when the
format isn't `uri` or the URL is `http(s)://`.

### `NetworkPreferences` (`Models/NetworkPreferences.swift`)

- `TunnelIPMode` (`ipv4AndIPv6` / `ipv4Only`; lenient decoder accepting many spellings).
- `TunnelOnDemandMode` (`disabled` / `always`).
- `TunnelPreferences`: `persistTunnel`, `ipMode`, `onDemandMode`, `includeAllNetworks`.
  `isOnDemandEnabled == persistTunnel && onDemandMode.isEnabled`.
- `DNSResolverKind` (`standard` = DoU / `doh` / `dot`) + `DNSResolver` +
  `DNSResolver.catalog` (11 presets: Google & Cloudflare × DoH/DoT/DoU × IPv4/IPv6).
- ⚠️ There is **no split-tunnel / per-app routing** — the only tunnel-scope toggle is
  the full-tunnel `includeAllNetworks` flag.

### Small models

- `AppLogEvent` (`Models/AppLogEvent.swift`): `AppLogLevel` (info/warning/error),
  `AppLogCategory` (`app`/`vpn`/`tunnel`/`xray`/`storage`/`importConfig`), and the event struct.
- `VPNConnectionStatus` (`Models/VPNConnectionStatus.swift`): `disconnected`/`connecting`/
  `connected`/`disconnecting`/`failed`, plus `VPNConnectionState { status; connectedDate }`.

## Storage services (`Services/`)

### `ProfileStorage`

Orchestrates the metadata/secret split. Injects `AppGroupStorage` +
`any SecureValueStorage` (default `KeychainStorage`).

- `saveProfile(_:secret:)`: validates the secret for the protocol, **writes the
  Keychain secret first, then the metadata; rolls back the Keychain entry if metadata
  persistence fails** (keeps both stores consistent).
- `resolvedProfile(id:)` joins metadata + secret and re-validates.
- `validate(secret:for:)`: VLESS/VMess need `userId`, Trojan needs `password`, WireGuard
  needs `wireGuardPrivateKey` — else `ProfileStorageError.missingCredential`.
- Selection stored under `selectedProfileID.v1`.

### `KeychainStorage` (`SecureValueStorage`)

- **`protocol SecureValueStorage`** is the **only test-injection seam** in this module
  (`save`/`load`/`delete`). Tests use `InMemorySecureValueStorage`.
- `kSecClassGenericPassword`, `service` + `accessGroup` defaults from `AppConstants`.
- Items written with **`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`** so the
  on-demand-launched tunnel extension can read them while the device is locked;
  `ThisDeviceOnly` blocks iCloud Keychain sync.
- **Access-group fallback**: every op tries `[accessGroup, nil]`, so it works in the
  simulator/tests where the shared-group entitlement may be absent (logs a warning).

### `AppGroupStorage` (and friends)

- ⚠️ **File-based JSON store, NOT `UserDefaults`.** Writes `<sanitizedKey>.json`
  atomically into a `NetlumaVPNShared` subdir of the App Group container, falling back
  to Application Support when the container is unavailable (e.g. in tests). **Write
  failures are silently swallowed.**
- Same file also defines `SessionStateStorage` (`connectionStartedAt` under
  `connectionSessionState.v1`) and `ConnectionDisplayStateStorage`
  (`{status, updatedAt, connectionStartedAt}` under `connectionDisplayState.v1`, with a
  **20 s `maxStateAge`** — stale state is cleared). These back the widget/lock-screen
  display so the UI doesn't flicker.

### `NetworkPreferencesStorage`

Loads/saves `NetworkPreferences` under `networkPreferences.v1`; returns defaults on
miss/decode-failure.

## Logging — `AppLogger` + `AppLogStore`

`AppLogger` is the **only sanctioned logger** (`enum AppLogger`): `info` / `warning` /
`error`. Dual sink: OSLog (`subsystem = loggingSubsystem`, category = the log category)
**and** an `AppLogEvent` appended to `AppLogStore` (last 300 events as JSON under
`logs.v1`, shared with the extension so tunnel-side logs surface in the app).

⚠️ **No automatic redaction.** Messages are logged `privacy: .public`, so the
"never log secrets" guarantee is **convention at the call site**. Use the helpers
`safeProfileLabel(_:)` (→ `"<proto>#<first8ofUUID>"`) and `safeProfileID(_:)`; never
pass hosts, user IDs, passwords, keys, or generated config to the logger. There are
**no `print(...)` calls** anywhere — keep it that way.

## `ConnectionDiagnostics`

Async network probes (no secrets, no logging): `checkTCPReachability(host:port:)`
(Network.framework `NWConnection`), `checkInternetReachability()` (apple.com test page),
`fetchPublicIPAddress()` (`api.ipify.org`), `measureTCPConnectLatency(host:port:)`.
Used by the egress-IP validation flow and the widget's latency pill.

## `Localization.swift`

`enum L10n`: `string(_:)` → `NSLocalizedString`; `format(_:_:)` → `String(format:)`.
See the localization caveat in [`APP.md`](APP.md) — there is no strings table backing it.

## Test seams summary

The only protocol abstraction here is `SecureValueStorage`. `AppGroupStorage`,
`ProfileStorage`, `AppLogStore`, `NetworkPreferencesStorage`, `SessionStateStorage`,
`ConnectionDisplayStateStorage` are concrete structs injected by value — tests point
`AppGroupStorage` at a throwaway suite/temp dir and inject an `InMemorySecureValueStorage`.
See [`TESTING.md`](TESTING.md).

_Last full analysis: 2026-06-24._
