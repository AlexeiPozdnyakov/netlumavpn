# VPN Tunnel & Protocol Layer

> Owner agent: `vpn-engineer`. Covers the Packet Tunnel Extension and the
> protocol parsing/emission code in `NetlumaVPNShared`. This is the canonical VPN
> implementation — when a protocol detail is in doubt, this code (not the docs)
> wins, but keep this doc in sync. See also the `vpn-protocols` skill.

## Files

| File | Role |
|------|------|
| `NetlumaVPNTunnelExtension/PacketTunnelProvider.swift` | `NEPacketTunnelProvider` subclass — tunnel lifecycle |
| `NetlumaVPNTunnelExtension/XrayTunnelEngine.swift` | Real (`SwiftyXrayKit`) vs `MockXrayTunnelEngine` |
| `NetlumaVPNShared/Services/VPNConfigurationParser.swift` | Import URL/config → `(VPNProfile, VPNProfileSecret)` |
| `NetlumaVPNShared/Services/XrayConfigBuilder.swift` | `ResolvedVPNProfile` → Xray-core outbound JSON |
| `NetlumaVPNShared/Services/TunnelNetworkSettingsBuilder.swift` | `NEPacketTunnelNetworkSettings` (routes + DNS) |

## `PacketTunnelProvider`

`@objc(PacketTunnelProvider) final class PacketTunnelProvider: NEPacketTunnelProvider`.
Holds `ProfileStorage`, `NetworkPreferencesStorage`, `SessionStateStorage`, and an
`XrayTunnelEngine?`.

**`startTunnel(options:completionHandler:)`** (inside a `Task`):

1. `resolvedProfile(from: options)` — three-tier fallback keyed on
   `AppConstants.TunnelOptions.startPayload`: decode `TunnelStartPayload` from `Data`,
   then `NSData`, else fall back to `selectedProfileID` (from options →
   `providerConfiguration` → `ProfileStorage`) + `profileStorage.resolvedProfile(id:)`.
   When a payload is present the secret comes from it — **not** re-fetched.
2. `XrayTunnelEngineFactory.make(packetFlow:)` picks the engine.
3. Build `NEPacketTunnelNetworkSettings` via `TunnelNetworkSettingsBuilder` —
   **routing mode is driven by `engine.routesDefaultTraffic`**, not by preferences.
4. `await setTunnelNetworkSettings(...)` (a `withCheckedThrowingContinuation` wrapper).
5. `await engine.start(with: resolvedProfile)`.
6. `sessionStateStorage.markConnectionStarted()`, reload widget timelines, succeed.

On error: clear `connectionStartedAt`, reload timelines, `AppLogger.error`, fail the
completion handler.

**`stopTunnel`**: `await engine?.stop()`, clear session state, reload timelines.

⚠️ **There is no packet read/write loop in this file.** `packetFlow` is handed to the
engine; `SwiftyXrayKit`'s `XRayTunnel` owns the actual packet I/O. The mock engine
receives no `packetFlow` and processes nothing. The provider never calls
`cancelTunnelWithError` and overrides no `sleep`/`wake`/`handleAppMessage`.

## `XrayTunnelEngine`

`protocol XrayTunnelEngine { var routesDefaultTraffic: Bool { get }; func start(with:) async throws; func stop() async }`.
Selection is compile-time via `#if canImport(SwiftyXrayKit)`:

- **`SwiftyXrayTunnelEngine` (real, `routesDefaultTraffic = true`):** builds config via
  `XrayConfigBuilder`, writes it to a runtime dir (`…/XrayRuntime` in the App Group
  container), runs `XRayTunnel(packetFlow:).run(dataDir:config:.json(...)finalConfigPath:)`.
  Log: `Using SwiftyXrayKit tunnel engine`.
- **`MockXrayTunnelEngine` (fallback, `routesDefaultTraffic = false`):** builds the
  config, validates it parses as JSON, and idles. **Opens no sockets, takes no
  `packetFlow`, proxies nothing.** Because `routesDefaultTraffic == false`, the network
  settings install **no default route and no DNS** → the tunnel shows Connected but
  carries zero traffic. Log: `SwiftyXrayKit is not linked; falling back to mock tunnel engine`.

This is the #1 “connected but no internet” gotcha on simulator/CI builds. The log
markers are the unambiguous signal of which engine ran.

## `VPNConfigurationParser`

Entry: **`func parse(_ rawValue: String) throws -> (VPNProfile, VPNProfileSecret)`**.
Dispatch order:

1. Contains `[Interface]` **and** `[Peer]` → WireGuard INI parser.
2. Starts with `{` → sing-box JSON parser.
3. Else by URL scheme: `vless://` / `trojan://` → user-info URL parser;
   `vmess://` → base64-JSON parser; `wireguard://` / `wg://` → WG URL parser;
   anything else → `unsupportedScheme`.

Errors: `VPNConfigurationParserError` (`.unsupportedScheme`, `.unsupportedSecurity`,
`.invalidURL`, `.invalidVMessPayload`, `.invalidSingBoxPayload`, `.invalidWireGuardValue`,
`.missingRequiredField`).

### Per-protocol input formats

| Protocol | Accepted input | Secret field |
|----------|----------------|--------------|
| **VLESS** | `vless://USERID@host:port?security=&type=&sni=&pbk=&sid=&spx=&fp=&flow=&alpn=&path=&host=&serviceName=#remarks` | `userId` |
| **Trojan** | `trojan://PASSWORD@host:port?…` (same query handling as VLESS) | `password` |
| **VMess** | `vmess://<base64-json>` (`ps,add,port,id,net,host,path,tls,sni`) | `userId` |
| **WireGuard** | INI text (`[Interface]`/`[Peer]`) **or** `wireguard://`/`wg://` URL | `wireGuardPrivateKey` (+ optional `wireGuardPreSharedKey`) |
| **sing-box JSON** | object with `outbounds[]`; first `vless`/`trojan` outbound only | `userId` / `password` |

Notable behaviors:

- **Reality**: `pbk` (`realityPublicKey`), `sid` (`realityShortID`), `spx`
  (`realitySpiderX`) are read **unconditionally**; `fp`/`alpn`/`tlsFingerprint` are
  gated on the security value. A `security=reality` link with no `pbk` **parses fine
  but fails later** in `XrayConfigBuilder` (`missingRealityPublicKey`).
- **Unknown `type=`** silently becomes `.tcp` (no error) — likely fails to connect.
- **VMess** import is narrow: no `fp`/`alpn`/`flow`/reality; `alterId` is always 0
  (AEAD only); port is parsed from a string.
- **sing-box JSON** import supports only VLESS/Trojan (VMess/WireGuard throw) and never
  produces Reality (`.tls`/`.none` only).
- **WireGuard** INI takes only the **first** `[Interface]` and **first** `[Peer]`;
  `reserved` must be ≥3 ints each 0–255; MTU 576–9000; endpoint supports `[ipv6]:port`.

## `XrayConfigBuilder`

`func buildConfigData(for: ResolvedVPNProfile) throws -> Data` — emits **Xray-core**
JSON (`JSONSerialization`, sorted keys), validated with `isValidJSONObject`.

Top-level: a single SOCKS inbound (`local-socks`, `127.0.0.1:10808`, `udp:true`,
`sniffing.enabled:false`) and one proxy outbound. **No `routing`, no `dns`, no
`freedom`/`block` outbounds** — all routing/DNS control lives in the NE network
settings instead.

Outbound by protocol:

- **VLESS** → `settings.vnext[].users[] = { id, encryption:"none", flow? }` + `streamSettings`.
- **VMess** → `vnext[].users[] = { id, alterId:0, security:"auto" }` + `streamSettings`.
- **Trojan** → `settings.servers[] = { address, port, password }` + `streamSettings`.
- **WireGuard** → `settings = { secretKey, address[], peers[{endpoint,publicKey,preSharedKey?,keepAlive?,allowedIPs?}], noKernelTun:true, domainStrategy:"ForceIP" }` + optional top-level `mtu`/`reserved`. **No `streamSettings`.**

`streamSettings(for:)`: `{ network, security }` plus —
- **TLS** → `tlsSettings { serverName: sni ?? host, fingerprint?, alpn? }`.
- **Reality** → `realitySettings { serverName, fingerprint (default "chrome"), publicKey (required), shortId, spiderX (default "/") }`.
- Transport: `ws` → `wsSettings { path, headers.Host }`; `grpc` → `grpcSettings { serviceName, authority? }`; `httpupgrade` → `httpupgradeSettings { path, host? }`; `tcp` → none.

> ⚠️ The parser accepts **sing-box** JSON shapes (`server`, `server_port`, `uuid`,
> `transport.service_name`, `tls.utls.fingerprint`) but the builder emits **Xray-core**
> shapes (`vnext`, `streamSettings`, `realitySettings`). The two dialects are not
> interchangeable — import normalizes into `VPNProfile`, emission re-serializes to Xray.

## `TunnelNetworkSettingsBuilder`

`makeSettings(routesDefaultTraffic: Bool, preferences:) -> NEPacketTunnelNetworkSettings`.

- Tunnel remote `127.0.0.1`, **MTU 1360**.
- **IPv4**: a dynamically chosen `10.<n>.5.2` address (avoids in-use `10.<n>.` prefixes).
  - `routesDefaultTraffic` → `includedRoutes = [default]`; if `includeAllNetworks == false`
    also `excludedRoutes = [10/8, 172.16/12, 192.168/16]` (LAN bypasses tunnel). If
    `includeAllNetworks == true`, nothing is excluded (full capture).
  - else (mock) → `includedRoutes = []` (nothing routed).
- **IPv6**: only when `ipMode == .ipv4AndIPv6` (address `fd00:88::2/128`).
- **DNS**: set **only** when `routesDefaultTraffic`, from `preferences.selectedDNSResolver`
  → `NEDNSSettings` (DoU) / `NEDNSOverHTTPSSettings` (DoH) / `NEDNSOverTLSSettings` (DoT),
  `matchDomains = [""]`.

## Gotchas (read before touching protocol code)

- Mock engine ⇒ no routes/DNS ⇒ "connected but no traffic" (by design).
- Reality without `pbk` parses but fails at build time, not import time.
- Unknown transport `type=` silently degrades to TCP.
- `XrayTunnelEngineError.engineUnavailable` is defined but never thrown.
- Import (sing-box dialect) ≠ emission (Xray dialect); don't conflate them.
- VMess support is intentionally minimal; extend the parser/builder together if you add
  fields, and add tests for both directions (see [`TESTING.md`](TESTING.md) — VMess
  currently has **no** parse/build test).

_Last full analysis: 2026-06-24._
