# Identifiers, Headers & the QuickVPN → NetlumaVPN Rename

> These values are **invariants**. Changing one without changing all the others
> breaks code signing, the App Group, Keychain sharing, or backend auth. Read this
> before touching `project.yml`, any `.entitlements`, `AppConstants.swift`, or the
> API client.

## Canonical identifiers

| Thing | Value | Defined in |
|-------|-------|------------|
| App bundle ID | `com.alekseipozdiakov.NetlumaVPN` | `project.yml` |
| Tunnel bundle ID (Xray) | `com.alekseipozdiakov.NetlumaVPN.PacketTunnel` | `project.yml`, `AppConstants.tunnelProviderBundleIdentifier` |
| WireGuard tunnel bundle ID | `com.alekseipozdiakov.NetlumaVPN.WireGuard` | `project.yml`, `AppConstants.wireGuardTunnelProviderBundleIdentifier` (separate NE extension, own Go runtime) |
| Widget bundle ID | `com.alekseipozdiakov.NetlumaVPN.Widget` | `project.yml` |
| App Group | `group.com.alekseipozdiakov.NetlumaVPN` | `AppConstants.appGroupIdentifier`, all 4 `.entitlements` (app, Xray ext, WireGuard ext, widget) |
| Keychain access group | `6659MLRZ5F.com.alekseipozdiakov.NetlumaVPN.shared` | `AppConstants.keychainAccessGroup` (entitlements use `$(AppIdentifierPrefix)…`) |
| Keychain service | `com.alekseipozdiakov.NetlumaVPN.profiles` | `AppConstants.Keychain.service` |
| Apple Team ID | `6659MLRZ5F` | `project.yml` (`DEVELOPMENT_TEAM`) |
| Logging subsystem | `com.alekseipozdiakov.NetlumaVPN` | `AppConstants.loggingSubsystem` |
| Global device-ID Keychain account | `netlumavpn-global-device-id.v1` | `AppConstants.Keychain.globalServerDeviceIDAccount` |

If you ever change a bundle/group identifier, update **all** of:

1. [`project.yml`](../project.yml) (then `xcodegen generate`)
2. [`NetlumaVPN/NetlumaVPN.entitlements`](../NetlumaVPN/NetlumaVPN.entitlements)
3. [`NetlumaVPNTunnelExtension/NetlumaVPNTunnelExtension.entitlements`](../NetlumaVPNTunnelExtension/NetlumaVPNTunnelExtension.entitlements)
4. [`NetlumaVPNWidget/NetlumaVPNWidget.entitlements`](../NetlumaVPNWidget/NetlumaVPNWidget.entitlements)
5. [`NetlumaVPNShared/Models/AppConstants.swift`](../NetlumaVPNShared/Models/AppConstants.swift)

…and the Apple Developer portal (App IDs, App Group, Keychain group, provisioning).

### ⚠️ The `alekseipozdiakov` typo is load-bearing

Every identifier uses `com.alekseipozdiakov.…` — note **`pozdiakov`**, missing the
second “n” of the owner’s name (*pozdnyakov*). This typo is baked into the bundle
IDs, App Group, Keychain group, StoreKit product IDs, and the entitlements that
are registered in the Apple Developer portal. **Do not “correct” it.** Fixing the
spelling would invalidate provisioning and orphan every Keychain/App-Group item.

## StoreKit product IDs

| Plan | Product ID |
|------|------------|
| Weekly | `com.alekseipozdiakov.NetlumaVPN.premium.weekly` |
| Monthly | `com.alekseipozdiakov.NetlumaVPN.premium.monthly` |
| Yearly | `com.alekseipozdiakov.NetlumaVPN.premium.annual` |

Defined in `PremiumSubscriptionModels.swift` and `NetlumaVPN/Subscriptions.storekit`;
`PremiumSubscriptionTests` asserts they stay in sync.

## Backend / mobile-API headers

The iOS client (`GlobalServerAPIClient.swift`) sends **both** the new and the
legacy header names on every request, with the **same** value:

| Purpose | New header | Legacy header (also sent) |
|---------|-----------|----------------------------|
| Mobile client key | `X-NetlumaVPN-Client-Key` | `X-QuickVPN-Client-Key` |
| Device ID | `X-NetlumaVPN-Device-ID` | `X-QuickVPN-Device-ID` |
| Admin API key (server-side) | `X-NetlumaVPN-API-Key` | `X-QuickVPN-API-Key` |

Backend acceptance differs by backend (see [`BACKEND.md`](BACKEND.md)):

- **Xray/WireGuard backend (live):** reads **only** `x-quickvpn-*`.
- **sing-box backend (newer):** reads `x-netlumavpn-*` first, falls back to
  `x-quickvpn-*`.

Because the client sends both, it authenticates against either. **Do not remove
the `X-QuickVPN-*` headers** without confirming the live backend no longer needs
them.

### Mobile client key is local

The public history contains no deployment mobile key. `AppConstants.Backend` reads
an ignored `Backend.local.plist`; the default key is empty. A configured mobile key
is still embedded in the app binary and must be least-privilege. Never use an admin
key in client code. See [PUBLIC_REPOSITORY.md](PUBLIC_REPOSITORY.md).

## Rename status (QuickVPN → NetlumaVPN)

The rename is **partial**. Quick guide to what’s renamed vs not:

| Renamed to NetlumaVPN | Still QuickVPN |
|-----------------------|----------------|
| All Swift runtime constants (`AppConstants`, log categories) | Bundle-ID stem `com.alekseipozdiakov.NetlumaVPN` (kept on purpose) |
| Public domain `netlumavpn.example` | Backend dir `server_mvp/quickvpn_singbox_admin/`, `archive/server_mvp/quickvpn_admin/` |
| New header names (primary) | Live backend reads only `x-quickvpn-*`; server IDs `quickvpn-mvp-eu-1*` |
| sing-box backend + verify script | systemd units, env files, the `quickvpn` system user, ops paths |
| Test env var `NETLUMAVPN_EXPECTED_EGRESS_IP` | Some `.claude/agents/*.md` descriptions still say `QuickVPN`/`QuickVPNTests` |
| Keychain account `netlumavpn-global-device-id.v1` | `git` repo name `quickvpnapp`, the legacy server IDs |

When you touch a file, prefer the NetlumaVPN spelling for **new** runtime strings,
but do **not** mass-rename identifiers, server IDs, ops paths, or the `quickvpn`
system user — those are coordinated with the backend, provisioning, and Apple
portal. Log a [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) entry if you spot a fresh
mismatch.

_Last full analysis: 2026-06-24._
