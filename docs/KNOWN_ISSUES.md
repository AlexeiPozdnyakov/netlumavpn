# Known Issues & Discrepancies

> Findings from the 2026-06-24 full analysis where the **code, the docs, the tests,
> and the deployment disagree** — or where there's a latent risk. Read this before
> trusting any single source. When you fix one, update or remove its entry (and the
> owning doc) in the same task. When you find a new one, add it here.

Severity: 🔴 likely production-affecting · 🟠 correctness/security risk · 🟡 cleanup/clarity.

## 🔴 1. Two backends; provisioner and current production disagree

- Provisioning deploys **backend A** (`archive/server_mvp/quickvpn_admin/app.py`,
  Xray/WireGuard, server IDs `quickvpn-mvp-eu-1*`, reads only `x-quickvpn-*`).
- The current `netlumavpn.example` production endpoint was observed on 2026-06-24 returning
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

## 🔴 14. WireGuard does not work; native WG can't coexist with the Xray (Go) engine

**Symptom:** a WireGuard profile reached `connected`, carried no traffic, then the extension was
killed → `NEVPNConnectionError.pluginFailed` (code 12), repeating. **Root cause:** routing WG
through Xray's `wireguard` outbound (a gVisor netstack) on top of SwiftyXrayKit's tun2socks
(a second netstack) ran **two userspace stacks** in the packet-tunnel extension and exceeded the
~50 MB NE memory limit → jetsam. VLESS/Trojan were unaffected (plain TCP/TLS outbound).

**Fix (code landed 2026-06-24):** WireGuard profiles now use a **native** engine
(`WireGuardTunnelEngine` → WireGuardKit / wireguard-go, one stack). `PacketTunnelProvider` branches
by protocol; the native adapter installs its own network settings (honoring the config's DNS and
`AllowedIPs`). The Swift code is dormant behind `#if canImport(WireGuardKit)`.

**Native WG attempted (vendored WireGuardKit) and reverted — two Go runtimes (2026-06-24):** Vendoring
`wireguard-apple` and linking it compiled and linked fine (after patching its manifest `5.3`→`5.5` and
`WireGuardKitC.h` for Xcode 26), but on device it **broke every protocol**: VLESS, Trojan **and** WG all
died with `pluginFailed`. Cause: the extension already statically links **Xray (Go)** via SwiftyXrayKit,
and wireguard-go is **also Go** → **two Go runtimes in one process**, which conflict and crash the
extension at launch. All WireGuardKit wiring (package, `WireGuardGoBridgeiOS` target, `Vendor/`, the
`ops/build-wireguard-go.sh` wrapper) was removed; `project.yml` is back to its known-good state and
VLESS/Trojan build/work again.

**Current state:** WG routes to `UnavailableWireGuardTunnelEngine` → fails fast with "The WireGuard engine
is not linked into this build." (clear error, no crash). The dormant `WireGuardTunnelEngine` +
`WireGuardQuickConfigBuilder` + the `wireGuardDNSServers` parsing stay in-tree (tested) but **must not** be
re-activated by re-adding WireGuardKit (see the ⚠️ banner in `WireGuardTunnelEngine.swift`).

**Real path forward:** native WG requires a **single Go engine serving all protocols** (VLESS/VMess/Trojan/
WireGuard) in place of Xray — e.g. **sing-box** (which the backend already runs). That's a wholesale engine
replacement, not an add-on. (`VPN_TUNNEL.md` → "WireGuard engine — currently unsupported".)

The earlier DNS work (2026-06-24) — parsing `DNS =` into `wireGuardDNSServers` and the
`TunnelNetworkSettingsBuilder.dnsOverrideServers` override — was a correct but secondary fix; with
the native engine the WG config's DNS is applied directly, so that builder override is currently
unused by production (kept, with tests, as a generic capability).

_Last full analysis: 2026-06-24._
