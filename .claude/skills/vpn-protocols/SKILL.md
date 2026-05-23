---
name: vpn-protocols
description: VPN URL parsing and Xray-core JSON config shapes used by QuickVPN — VLESS (with Reality and TLS), VMess, Trojan, WireGuard. Use when reading or writing `VPNConfigurationParser.swift`, `XrayConfigBuilder.swift`, or adding a new protocol/transport, or interpreting an unfamiliar VPN import URL.
---

# QuickVPN protocol cheat sheet

QuickVPN parses four protocol families into a single internal model
(`VPNProfile` + `VPNProfileSecret`), then emits Xray-core JSON for three
of them. WireGuard is handled by Xray's native WG outbound.

## Internal model split

```swift
struct VPNProfile        // metadata — stored in UserDefaults via App Group
struct VPNProfileSecret  // userId / password / privateKey — stored in Keychain
```

The two are joined by `profile.id`. Never serialise `VPNProfileSecret`
outside Keychain.

## URL formats accepted

### VLESS

```
vless://<uuid>@<host>:<port>?<query>#<remarks>
```

Query keys:
| Key | Meaning |
|------|---------|
| `type` | `tcp` / `ws` / `grpc` / `httpupgrade` |
| `security` | `none` / `tls` / `reality` |
| `sni` | TLS SNI |
| `alpn` | comma-separated, e.g. `h2,http/1.1` |
| `fp` | fingerprint, e.g. `chrome` |
| `flow` | `xtls-rprx-vision` for Vision flow |
| `path` | for `ws` and `httpupgrade` |
| `host` | virtual host header for `ws` and `httpupgrade` |
| `serviceName` | for `grpc` |
| `authority` | gRPC authority header |
| `pbk` | Reality public key (base64 url-safe) |
| `sid` | Reality short ID (hex) |
| `spx` | Reality SpiderX path, usually `/` |
| `encryption` | `none` (Reality requires explicit `none`) |

Reality example:
```
vless://00000000-0000-4000-8000-000000000042@192.0.2.10:443/?security=reality&encryption=none&pbk=REPLACE_WITH_LOCAL_VALUE&fp=chrome&type=tcp&sni=www.microsoft.com&sid=REPLACE_WITH_LOCAL_VALUE&spx=%2F&flow=xtls-rprx-vision#MVP%20Test
```

### VMess

Two forms exist in the wild:

1. **Base64-encoded JSON** (legacy v2rayN format):
   ```
   vmess://<base64-of-json>
   ```
   The decoded JSON has keys: `add`, `port`, `id` (uuid), `aid` (alterId),
   `net` (`tcp` / `ws` / `grpc`), `tls` (`""` or `"tls"`), `sni`, `path`, `host`.

2. **URL-encoded** (modern):
   ```
   vmess://<uuid>@<host>:<port>?<query>
   ```
   Same query keys as VLESS where applicable.

`VPNConfigurationParser` tries Base64 first, then falls back to URL form.

### Trojan

```
trojan://<password>@<host>:<port>?<query>#<remarks>
```

Security is implied TLS — Trojan over plain TCP is rejected by the parser.

Query keys mirror VLESS for transport: `type=tcp|ws|grpc`, `sni`, `alpn`,
`path`, `host`, `serviceName`, `authority`.

Important: Trojan's "password" goes into `VPNProfileSecret.password`, not
`userId`.

### WireGuard

Import is a `.conf` text blob, two sections:

```ini
[Interface]
PrivateKey = <base64>
Address = <ipv4-cidr>, <ipv6-cidr>
MTU = 1280
Reserved = 1, 2, 3        # optional Xray-specific tunnel reserved bytes

[Peer]
PublicKey = <base64>
PresharedKey = <base64>   # optional
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = <host>:<port>
PersistentKeepalive = 25
```

`PrivateKey` and `PresharedKey` go to Keychain. `PublicKey`, `Endpoint`,
`AllowedIPs` go to metadata.

## Xray outbound JSON shapes

`XrayConfigBuilder` emits these. They mirror Xray-core's documented schema —
do not invent field names.

### VLESS Reality outbound
```json
{
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "<host>",
      "port": 443,
      "users": [{
        "id": "<uuid>",
        "encryption": "none",
        "flow": "xtls-rprx-vision"
      }]
    }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "serverName": "<sni>",
      "fingerprint": "chrome",
      "publicKey": "<pbk>",
      "shortId": "<sid>",
      "spiderX": "/"
    }
  }
}
```

### VLESS WS+TLS outbound
```json
{
  "protocol": "vless",
  "settings": {
    "vnext": [{ "address": "...", "port": 443, "users": [{ "id": "...", "encryption": "none" }] }]
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": { "serverName": "...", "alpn": ["h2","http/1.1"], "fingerprint": "chrome" },
    "wsSettings": { "path": "/socket", "headers": { "Host": "..." } }
  }
}
```

### Trojan outbound
```json
{
  "protocol": "trojan",
  "settings": {
    "servers": [{ "address": "...", "port": 443, "password": "...", "flow": null }]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": { "serverName": "...", "alpn": [...], "fingerprint": "chrome" }
  }
}
```

### WireGuard outbound (Xray)
```json
{
  "protocol": "wireguard",
  "settings": {
    "secretKey": "<private-key>",
    "address": ["10.7.0.2/32", "fd42:42:42::2/128"],
    "peers": [{
      "publicKey": "<peer-pub>",
      "preSharedKey": "<psk-or-empty>",
      "endpoint": "wg.example.com:51820",
      "allowedIPs": ["0.0.0.0/0", "::/0"],
      "keepAlive": 25
    }],
    "mtu": 1280,
    "reserved": [1, 2, 3]
  }
}
```

## Parser invariants

- Required fields produce a typed `VPNConfigurationParserError`. Optional
  fields default to sensible values.
- Query-key order does not matter.
- `pbk`, `sid`, and `spx` are required when `security=reality`.
- `flow=xtls-rprx-vision` is only valid for VLESS over TCP with TLS or
  Reality — combining it with `ws`/`grpc` is rejected.
- Trojan over plain TCP (no TLS) is rejected.
- WireGuard import without `[Interface]` PrivateKey or `[Peer]` PublicKey
  is rejected.

## Where to look

| Concern | File |
|---------|------|
| URL → `VPNProfile` + `VPNProfileSecret` | `QuickVPNShared/Services/VPNConfigurationParser.swift` |
| `VPNProfile` → Xray JSON | `QuickVPNShared/Services/XrayConfigBuilder.swift` |
| Tunnel settings (routes, DNS) | `QuickVPNShared/Services/TunnelNetworkSettingsBuilder.swift` |
| Test coverage of every shape above | `QuickVPNTests/QuickVPNTests.swift` |
