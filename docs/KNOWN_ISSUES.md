# Known Issues & Discrepancies

> Findings from the 2026-06-24 full analysis where the **code, the docs, the tests,
> and the deployment disagree** — or where there's a latent risk. Read this before
> trusting any single source. When you fix one, update or remove its entry (and the
> owning doc) in the same task. When you find a new one, add it here.

Severity: 🔴 likely production-affecting · 🟠 correctness/security risk · 🟡 cleanup/clarity.

## 🔴 1. Two backends; provisioner and current production disagree

- Provisioning deploys **backend A** (`archive/server_mvp/quickvpn_admin/app.py`,
  Xray/WireGuard, server IDs `quickvpn-mvp-eu-1*`, reads only `x-quickvpn-*`).
- The current `netlumavpn.example` production endpoint was observed again on 2026-07-29 returning
  `{"backend":"netlumavpn-singbox"}`, and the iOS `GlobalServerIntegrationTests` plus
  `verify-fresh-server.sh` also target **backend B** (`server_mvp/quickvpn_singbox_admin/app.py`,
  sing-box, IDs `netlumavpn-singbox-*`).
- The app sends **both** header families, so auth works against either — but a client
  expecting `netlumavpn-singbox-*` server IDs won't see backend A's servers.
- **Action:** make the provisioner, tests, client, and DNS/live deploy flow agree on one
  backend. Until then, confirm with `GET /api/v1/status` before editing or deploying.
  (`BACKEND.md` §0, `OPS.md`.)

## 🟠 2. TLS certificate pinning is inert

`AppConstants.Backend.mobileTLSCertificateSHA256Base64 = ""`. The pinning delegate maps
an empty pin to "disabled" and falls through to `.performDefaultHandling`, so **no
pinning happens** despite `CLAUDE.md` claiming the app pins. The implementation hashes
the **leaf DER certificate** (CryptoKit SHA256), not the SPKI — so when populating it,
generate the pin the same way:
`openssl x509 -in cert.pem -outform der | openssl dgst -sha256 -binary | base64`.
`GlobalServerAPIError.certificatePinMismatch` is defined but never thrown (the delegate
cancels the challenge instead). (`APP.md`, `SHARED.md`.)

## 🟠 3. Committed mobile client key

`AppConstants.Backend.mobileClientKey` is a real 64-hex key in source, shipped in the
binary. Intentionally least-privilege, but treat it as public and rotate it server-side
if it leaks. Never put the admin key in client code. (`IDENTIFIERS.md`.)

## 🟠 4. `AppLogger` does not redact

Logging is `privacy: .public` with no automatic redaction — the "never log secrets"
guarantee is convention-only. Always use `safeProfileLabel`/`safeProfileID` and never
pass hosts/credentials/keys/generated config to the logger. (`SHARED.md`.)

## 🟠 5. Backend B & sidecar run as root with cleartext-password Basic auth

If anyone enables `quickvpn-singbox-api.service` / `quickvpn-singbox-admin.service`,
note they run as **root** and use HTTP Basic with the password compared in cleartext
from `ADMIN_PASSWORD` (no PBKDF2, no session). Backend A (the `quickvpn` user + HMAC
cookie + PBKDF2) is the safer model. (`BACKEND.md`.)

## 🟡 6. Russian UI is effectively unlocalized

There is no `Localizable.strings`/`.xcstrings` table, so `L10n.string(...)` →
`NSLocalizedString` returns the English key. Only `InfoPlist.strings` and the `ru.lproj`
legal HTML are localized; `en.lproj` is even missing `Terms.html`/`Privacy.html` (English
falls back to inline HTML in `SettingsView.swift`). The code is L10n-ready; it just needs
a strings table. (`APP.md`.)

## 🟡 7. Mock engine "connects" but routes nothing

On builds without `SwiftyXrayKit`, `MockXrayTunnelEngine` makes the tunnel show
**Connected** while installing no default route and no DNS → zero traffic. Check the log
marker (`Using SwiftyXrayKit tunnel engine` vs the mock warning) when diagnosing
"connected but no internet." (`VPN_TUNNEL.md`.)

## 🟡 8. `AppGroupStorage` is file-based JSON, not UserDefaults

`CLAUDE.md` describes the boundary as "UserDefaults (App Group)", but it's an atomic
JSON-file store under the App Group container. Write failures are silently swallowed.
Don't reason about it as `UserDefaults` (no KVO, etc.). (`SHARED.md`.)

## 🟡 9. Stale references in `CLAUDE.md` / `.claude/` tooling

`CLAUDE.md` and several `.claude/agents/*.md` / skills still say `QuickVPN`,
`QuickVPNTests`, `server_mvp/quickvpn_admin/app.py` as "production", and the old
`QUICKVPN_EXPECTED_EGRESS_IP` env var. The canonical project is `NetlumaVPN.xcodeproj` /
`NetlumaVPN/`; tests are in `NetlumaVPNTests/`; the egress env var is
`NETLUMAVPN_EXPECTED_EGRESS_IP`. (`IDENTIFIERS.md`, `TESTING.md`.)

## 🟡 10. `.claude/worktrees/quizzical-ritchie-ea76c0/` is an old QuickVPN-named copy

A full older copy of the project (under the `QuickVPN` name, its own `.xcodeproj`/tests)
lives there. Greps for `QuickVPN` will hit it — ignore it when reasoning about the live app.

## 🟡 11. Likely dead code

- `NetlumaVPN/Features/Profiles/ProfileListView.swift` — not referenced by `ContentView`
  (home uses `HomeConnectView`'s own swipe rows); uses raw colors, not the theme.
- `ToggleVPNConnectionIntent` — the rendered widget button uses the explicit
  Connect/Disconnect intents; Toggle survives only as a Shortcuts/Siri action.
- `XrayTunnelEngineError.engineUnavailable` — defined, never thrown.
- `NetlumaVPNUITests.testExample` — empty boilerplate.

Verify before deleting.

## 🟡 12. UX papercuts

- ~~Home screen caps local profiles at `prefix(2)`~~ — **fixed 2026-06-24**: the
  `LOCAL PROFILES` list now renders every profile (it already lives in a `ScrollView`),
  so the list matches the `ACTIVE: %d` badge.
- Splash dismisses on a ~1.05 s timer regardless of whether `loadGlobalServers()` /
  `refreshStatus()` finished.
- Widget has no live connection-duration UI (the data is persisted but unused), and no
  lock-screen accessory family.

## 🟠 13. Remote config import accepts plaintext `http` and only single configs

`RemoteConfigDownloader` (used by `AppModel.importProfile(from:)`) downloads a config file
from any user-supplied `http(s)` link. Two scope notes:

- **`http` (plaintext) links are accepted**, not just `https`. A profile fetched over `http`
  can be observed/tampered in transit (it carries VPN credentials). Acceptable for the common
  case of `http` subscription links, but prefer `https`. Tighten to https-only if threat model
  requires it.
- **Only a single config is parsed.** The downloaded body is handed straight to
  `VPNConfigurationParser`, which understands one sing-box JSON config or one
  `vless://`/`trojan://`/WireGuard config. **Multi-config subscription bundles** (newline lists
  or base64-encoded sets) are **not** supported — the parser will take the first proxy outbound
  / fail. (`APP.md` → `RemoteConfigDownloader`.)

## 🟠 14. WireGuard runs in a separate extension (build-verified; device runtime pending)

**History.** WG never worked through Xray: its `wireguard` outbound (a gVisor netstack) on top of
SwiftyXrayKit's tun2socks (a second netstack) blew the ~50 MB NE memory limit → `connected`, no traffic,
then `pluginFailed`. The first native fix linked WireGuardKit/wireguard-go **into the Xray extension** —
that put **two Go runtimes in one process** and crashed **all** protocols (VLESS/Trojan too). Reverted.

**Fix (2026-06-24): process isolation.** WireGuard now runs in its **own** extension
`NetlumaVPNWireGuardExtension` (bundle id `com.alekseipozdiakov.NetlumaVPN.WireGuard`) that links **only**
WireGuardKit/wireguard-go — one Go runtime, like the official WG app. The Xray extension
(`NetlumaVPNTunnelExtension`) is untouched (Xray only). `VPNManager`/`WidgetVPNController` route each
profile to the right extension by `providerBundleIdentifier` and enforce the single-active-tunnel rule
(stop + disable on-demand for the other extension before starting). `PacketTunnelEngine` was extracted to
`NetlumaVPNShared` so both extensions share it without either importing the other's Go dependency.

**Verified here:** simulator `xcodebuild build` + the 99-test suite pass; the WG extension binary contains
wireguard-go and **zero** Xray symbols and links no SwiftyXrayCore (one Go runtime per process, confirmed
via `strings`/`otool`).

**Caveats / still device-only:**
- **Go (`brew install go`) is now a build prerequisite** (wireguard-go bridge); CI too. The simulator slice
  uses `WireGuardSimulatorShims.c` no-op stubs (the vendored Makefile doesn't map `iphonesimulator`).
- **On-device runtime not yet confirmed:** the actual WG handshake/traffic, protocol switching
  (Xray↔WG, single active tunnel), and **provisioning the new App ID** (Network Extensions + the shared App
  Group + Keychain group on Team `6659MLRZ5F`) can only be verified on a physical device. Auto-signing
  should register it; manual portal setup may be needed if it doesn't.
- `wireGuardReserved` (Xray/AmneziaWG obfuscation) is unsupported natively.
- **Invariant:** never add SwiftyXrayKit to the WG extension or WireGuardKit to the Xray extension/app.
- `Vendor/wireguard-apple` (with its two patches) must be committed so it persists.

(`VPN_TUNNEL.md` → "WireGuard extension (native, process-isolated)".)

## 🟠 15. Main app declares `ITSAppUsesNonExemptEncryption = false`, failing `AppStoreSubmissionTests`

`AppStoreSubmissionTests.shippingBundlesDeclareExportComplianceCodeBuildSetting` expects
**all four** shipping bundles to set `ITSAppUsesNonExemptEncryption = true`, but
`NetlumaVPN/Info.plist` (the main app) currently has it `false`. The three extensions
(`NetlumaVPNTunnelExtension`, `NetlumaVPNWireGuardExtension`, `NetlumaVPNWidget`) already
have `true`. This is the **only** red test in `NetlumaVPNTests` and is unrelated to the
subscription logic. **Action:** decide the correct value for the main app (the client
ships VPN crypto, so `true` is likely right) and make the plist + test agree, or relax the
test for the main bundle. (`APP.md` → "App Store archive metadata".)

## 🔴 16. Public subdomain DNS / TLS verification is incomplete

The production website root and `/setup` respond successfully over HTTPS, but the
full `ops/verify-fresh-server.sh` check found two infrastructure gaps on 2026-07-29:

- `vpn.netlumavpn.example` and `trojan.netlumavpn.example` currently return no A record.
- `admin.netlumavpn.example` resolves to the live VPS, but the certificate presented there
  does not include `admin.netlumavpn.example`, so strict TLS verification fails.

This is separate from the public root website and sing-box API deployment. Restore the
missing DNS records and reissue/attach a certificate with the expected SANs before
claiming that the full production verification script is green. (`OPS.md`.)

_Last full analysis: 2026-06-24. Findings #15–16 updated through 2026-07-29._
