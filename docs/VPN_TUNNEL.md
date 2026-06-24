# VPN Tunnel & Protocol Layer

> Owner agent: `vpn-engineer`. Covers the Packet Tunnel Extension and the
> protocol parsing/emission code in `NetlumaVPNShared`. This is the canonical VPN
> implementation — when a protocol detail is in doubt, this code (not the docs)
> wins, but keep this doc in sync. See also the `vpn-protocols` skill.

## Files

| File | Role |
|------|------|
| `NetlumaVPNTunnelExtension/PacketTunnelProvider.swift` | **Xray** extension's `NEPacketTunnelProvider` — proxy protocols only (VLESS/VMess/Trojan) |
| `NetlumaVPNTunnelExtension/XrayTunnelEngine.swift` | `XrayTunnelEngine` protocol; real (`SwiftyXrayKit`) vs `MockXrayTunnelEngine` |
| `NetlumaVPNWireGuardExtension/PacketTunnelProvider.swift` | **WireGuard** extension's `NEPacketTunnelProvider` — separate process, links wireguard-go only |
| `NetlumaVPNWireGuardExtension/WireGuardTunnelEngine.swift` | Native WireGuard engine (WireGuardKit `WireGuardAdapter`) + factory |
| `NetlumaVPNWireGuardExtension/WireGuardSimulatorShims.c` | Simulator-only no-op stubs for wireguard-go's mach-exception symbols |
| `NetlumaVPNShared/Services/PacketTunnelEngine.swift` | Shared `PacketTunnelEngine` protocol (used by both extensions; no Go dependency) |
| `NetlumaVPNShared/Services/VPNConfigurationParser.swift` | Import URL/config → `(VPNProfile, VPNProfileSecret)` |
| `NetlumaVPNShared/Services/XrayConfigBuilder.swift` | `ResolvedVPNProfile` → Xray-core outbound JSON |
| `NetlumaVPNShared/Services/WireGuardQuickConfigBuilder.swift` | `ResolvedVPNProfile` → `wg-quick` string (standalone exporter; the engine builds the config programmatically) |
| `NetlumaVPNShared/Services/TunnelNetworkSettingsBuilder.swift` | `NEPacketTunnelNetworkSettings` (routes + DNS) — Xray path only |

## Two packet-tunnel extensions (one Go runtime each)

The app ships **two** `NEPacketTunnelProvider` extensions, each linking a *single* Go runtime so they
never collide in one process (linking Xray (Go) and wireguard-go (Go) together crashes the extension —
see "WireGuard extension" + `KNOWN_ISSUES.md` #14):

- **`NetlumaVPNTunnelExtension`** (`@objc(PacketTunnelProvider)`, links **SwiftyXrayKit/Xray**) — proxy
  protocols (VLESS / VMess / Trojan).
- **`NetlumaVPNWireGuardExtension`** (`@objc(PacketTunnelProvider)`, links **WireGuardKit/wireguard-go**,
  **not** SwiftyXrayKit) — WireGuard only.

The app routes each profile to the right one by `providerBundleIdentifier`
(`AppConstants.providerBundleIdentifier(for:)`); see [`APP.md`](APP.md) → `VPNManager`. Both providers
share the same profile-resolution helper (three-tier fallback on `AppConstants.TunnelOptions.startPayload`
→ `selectedProfileID` → `ProfileStorage`), store `any PacketTunnelEngine?` (protocol in shared code), and
on `stopTunnel` do `await activeEngine?.stop()`.

**Xray extension `startTunnel`:** guards that the profile is **not** `.wireguard` (that would be a routing
bug), then `XrayTunnelEngineFactory.make(packetFlow:)`, builds `NEPacketTunnelNetworkSettings` via
`TunnelNetworkSettingsBuilder` (**routing driven by `engine.routesDefaultTraffic`**), `await
setTunnelNetworkSettings(...)`, `await engine.start(...)`, mark session, reload widgets.

**WireGuard extension `startTunnel`:** guards that the profile **is** `.wireguard`, then
`WireGuardTunnelEngineFactory.make(provider:)` → `WireGuardTunnelEngine`. The `WireGuardAdapter` installs
its **own** `NEPacketTunnelNetworkSettings` (addresses / DNS / routes from the config), so this provider
does **NOT** call `setTunnelNetworkSettings` / `TunnelNetworkSettingsBuilder`.

⚠️ Neither provider has a packet read/write loop — `SwiftyXrayKit`'s `XRayTunnel` and WireGuardKit's
`WireGuardAdapter` own the packet I/O.

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

## WireGuard extension (native, process-isolated)

WireGuard runs natively (wireguard-go via WireGuardKit) in its **own** extension,
`NetlumaVPNWireGuardExtension`, so its Go runtime never shares a process with Xray's.

**Why a separate extension.** Linking Xray (Go) and wireguard-go (Go) into one extension puts **two Go
runtimes in one process**; they conflict and crash the extension at launch →
`NEVPNConnectionError.pluginFailed` (code 12) for **every** protocol (VLESS/Trojan too, verified
2026-06-24). The official WireGuard app ships only wireguard-go (one runtime). So WG gets a dedicated
process; the Xray extension is untouched. (An earlier attempt to run WG *through* Xray's `wireguard`
outbound also failed — that stacks wireguard-go's gVisor netstack on tun2socks's, blowing the ~50 MB NE
memory limit.)

**Engine.** `WireGuardTunnelEngine` (gated `#if canImport(WireGuardKit)`) builds a WireGuardKit
`TunnelConfiguration` **programmatically** from the profile/secret (`PrivateKey` / `InterfaceConfiguration`
(addresses, DNS, MTU) / `PeerConfiguration` (publicKey, preSharedKey, endpoint, allowedIPs, keepalive)) and
runs `WireGuardAdapter.start(tunnelConfiguration:)`. The adapter installs its own network settings. The
`wg-quick` string parser lives in wireguard-apple's *app* target (not the `WireGuardKit` library), so it
isn't importable — hence the programmatic build. Log markers: `Using native WireGuard tunnel engine`,
`Native WireGuard engine started`. `WireGuardKit` not linked ⇒ `UnavailableWireGuardTunnelEngine` throws a
clear error (defensive only).

**Build wiring (vendored + Go bridge).** `WireGuardKit` is vendored at `Vendor/wireguard-apple`
(tag 1.0.16-27) as a **local** SPM package with two committed patches required for Xcode 26:
`Package.swift` tools-version `5.3`→`5.5`, and `WireGuardKitC.h` `+#include <sys/types.h>`. The
`WireGuardGoBridgeiOS` external-build target runs the Go-bridge `Makefile` via `ops/build-wireguard-go.sh`
(puts Homebrew `go` on PATH) to produce `libwg-go.a`. **Go (`brew install go`) is required to build** the
project. The vendored Makefile doesn't map `iphonesimulator`, so the simulator slice builds `GOOS=darwin`
and is missing the iOS mach-exception symbols — `WireGuardSimulatorShims.c` provides no-op stubs **for the
simulator only** (device builds get the real ones from `libwg-go.a`; WG can't run on the simulator anyway).

`wireGuardReserved` (Xray/AmneziaWG obfuscation) isn't supported by native WireGuard. **Invariant:** the WG
extension must never link SwiftyXrayKit and the Xray extension must never link WireGuardKit.

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
  The `[Interface]` `DNS =` list (and `dns=` on the URL form) is captured into
  `VPNProfile.wireGuardDNSServers` and becomes the tunnel DNS at connect time (see
  `TunnelNetworkSettingsBuilder`). It has no editor field, so `ProfileFormData.makeProfile`
  carries it over from the existing profile on edit.

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

`makeSettings(routesDefaultTraffic: Bool, preferences:, dnsOverrideServers: [String]? = nil) -> NEPacketTunnelNetworkSettings`.

- Tunnel remote `127.0.0.1`, **MTU 1360**.
- **IPv4**: a dynamically chosen `10.<n>.5.2` address (avoids in-use `10.<n>.` prefixes).
  - `routesDefaultTraffic` → `includedRoutes = [default]`; if `includeAllNetworks == false`
    also `excludedRoutes = [10/8, 172.16/12, 192.168/16]` (LAN bypasses tunnel). If
    `includeAllNetworks == true`, nothing is excluded (full capture).
  - else (mock) → `includedRoutes = []` (nothing routed).
- **IPv6**: only when `ipMode == .ipv4AndIPv6` (address `fd00:88::2/128`).
- **DNS**: set **only** when `routesDefaultTraffic`.
  - **`dnsOverrideServers` present** (a WireGuard profile's own `DNS =` servers, passed by
    `PacketTunnelProvider`) → plain `NEDNSSettings(servers:)` with those IPs, `matchDomains = [""]`,
    **and** a `/32` (or `/128`) included route is added for each server so it reaches the tunnel
    even when it sits inside an excluded LAN range (e.g. an internal `172.16.x.x` resolver). This
    mirrors the official WireGuard client; without it the tunnel connected but resolved nothing.
  - **otherwise** → `preferences.selectedDNSResolver` → `NEDNSSettings` (DoU) /
    `NEDNSOverHTTPSSettings` (DoH) / `NEDNSOverTLSSettings` (DoT), `matchDomains = [""]`.

## Gotchas (read before touching protocol code)

- Mock engine ⇒ no routes/DNS ⇒ "connected but no traffic" (by design).
- **WireGuard runs in its own extension** (`NetlumaVPNWireGuardExtension`, wireguard-go only). **Never**
  add SwiftyXrayKit to it or WireGuardKit to the Xray extension/app — two Go runtimes in one process crash
  it for *all* protocols. Building requires **Go** (the wireguard-go bridge). See "WireGuard extension".
- `TunnelNetworkSettingsBuilder.dnsOverrideServers` is **unused now** (the native WG engine derives DNS
  from the config); kept with tests. WG `DNS =` is parsed into `wireGuardDNSServers`.
- Reality without `pbk` parses but fails at build time, not import time.
- Unknown transport `type=` silently degrades to TCP.
- `XrayTunnelEngineError.engineUnavailable` is defined but never thrown.
- Import (sing-box dialect) ≠ emission (Xray dialect); don't conflate them.
- VMess support is intentionally minimal; extend the parser/builder together if you add
  fields, and add tests for both directions (see [`TESTING.md`](TESTING.md) — VMess
  currently has **no** parse/build test).

_Last full analysis: 2026-06-24._
