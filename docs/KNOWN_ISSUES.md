# Known Issues & Discrepancies

> Findings from the 2026-06-24 full analysis where the **code, the docs, the tests,
> and the deployment disagree** — or where there's a latent risk. Read this before
> trusting any single source. When you fix one, update or remove its entry (and the
> owning doc) in the same task. When you find a new one, add it here.

Severity: 🔴 likely production-affecting · 🟠 correctness/security risk · 🟡 cleanup/clarity.

## 🔴 1. Two backends; provisioner ships the one the client tests don't target

- Provisioning deploys **backend A** (`archive/server_mvp/quickvpn_admin/app.py`,
  Xray/WireGuard, server IDs `quickvpn-mvp-eu-1*`, reads only `x-quickvpn-*`).
- The iOS `GlobalServerIntegrationTests` and `verify-fresh-server.sh` target **backend B**
  (`server_mvp/quickvpn_singbox_admin/app.py`, sing-box, IDs `netlumavpn-singbox-*`).
- The app sends **both** header families, so auth works against either — but a client
  expecting `netlumavpn-singbox-*` server IDs won't see backend A's servers.
- **Action:** confirm which backend is actually live (`GET /api/v1/status`), then make
  the provisioner, tests, and client agree. Until then, don't assume either is "the"
  backend. (`BACKEND.md` §0, `OPS.md`.)

## 🔴 2. `verify-fresh-server.sh` sends a header backend A rejects

`verify-fresh-server.sh` calls the mobile API with **only** `X-NetlumaVPN-Client-Key`.
Backend A reads only `x-quickvpn-client-key` → the verify step would **401** against a
freshly-provisioned (backend-A) server. Either add the legacy header to the script or
finish migrating the live server to B. (`OPS.md`.)

## 🟠 3. TLS certificate pinning is inert

`AppConstants.Backend.mobileTLSCertificateSHA256Base64 = ""`. The pinning delegate maps
an empty pin to "disabled" and falls through to `.performDefaultHandling`, so **no
pinning happens** despite `CLAUDE.md` claiming the app pins. The implementation hashes
the **leaf DER certificate** (CryptoKit SHA256), not the SPKI — so when populating it,
generate the pin the same way:
`openssl x509 -in cert.pem -outform der | openssl dgst -sha256 -binary | base64`.
`GlobalServerAPIError.certificatePinMismatch` is defined but never thrown (the delegate
cancels the challenge instead). (`APP.md`, `SHARED.md`.)

## 🟠 4. Committed mobile client key

`AppConstants.Backend.mobileClientKey` is a real 64-hex key in source, shipped in the
binary. Intentionally least-privilege, but treat it as public and rotate it server-side
if it leaks. Never put the admin key in client code. (`IDENTIFIERS.md`.)

## 🟠 5. `AppLogger` does not redact

Logging is `privacy: .public` with no automatic redaction — the "never log secrets"
guarantee is convention-only. Always use `safeProfileLabel`/`safeProfileID` and never
pass hosts/credentials/keys/generated config to the logger. (`SHARED.md`.)

## 🟠 6. Backend B & sidecar run as root with cleartext-password Basic auth

If anyone enables `quickvpn-singbox-api.service` / `quickvpn-singbox-admin.service`,
note they run as **root** and use HTTP Basic with the password compared in cleartext
from `ADMIN_PASSWORD` (no PBKDF2, no session). Backend A (the `quickvpn` user + HMAC
cookie + PBKDF2) is the safer model. (`BACKEND.md`.)

## 🟡 7. Russian UI is effectively unlocalized

There is no `Localizable.strings`/`.xcstrings` table, so `L10n.string(...)` →
`NSLocalizedString` returns the English key. Only `InfoPlist.strings` and the `ru.lproj`
legal HTML are localized; `en.lproj` is even missing `Terms.html`/`Privacy.html` (English
falls back to inline HTML in `SettingsView.swift`). The code is L10n-ready; it just needs
a strings table. (`APP.md`.)

## 🟡 8. Mock engine "connects" but routes nothing

On builds without `SwiftyXrayKit`, `MockXrayTunnelEngine` makes the tunnel show
**Connected** while installing no default route and no DNS → zero traffic. Check the log
marker (`Using SwiftyXrayKit tunnel engine` vs the mock warning) when diagnosing
"connected but no internet." (`VPN_TUNNEL.md`.)

## 🟡 9. `AppGroupStorage` is file-based JSON, not UserDefaults

`CLAUDE.md` describes the boundary as "UserDefaults (App Group)", but it's an atomic
JSON-file store under the App Group container. Write failures are silently swallowed.
Don't reason about it as `UserDefaults` (no KVO, etc.). (`SHARED.md`.)

## 🟡 10. Stale references in `CLAUDE.md` / `.claude/` tooling

`CLAUDE.md` and several `.claude/agents/*.md` / skills still say `QuickVPN`,
`QuickVPNTests`, `server_mvp/quickvpn_admin/app.py` as "production", and the old
`QUICKVPN_EXPECTED_EGRESS_IP` env var. The canonical project is `NetlumaVPN.xcodeproj` /
`NetlumaVPN/`; tests are in `NetlumaVPNTests/`; the egress env var is
`NETLUMAVPN_EXPECTED_EGRESS_IP`. (`IDENTIFIERS.md`, `TESTING.md`.)

## 🟡 11. `.claude/worktrees/quizzical-ritchie-ea76c0/` is an old QuickVPN-named copy

A full older copy of the project (under the `QuickVPN` name, its own `.xcodeproj`/tests)
lives there. Greps for `QuickVPN` will hit it — ignore it when reasoning about the live app.

## 🟡 12. Likely dead code

- `NetlumaVPN/Features/Profiles/ProfileListView.swift` — not referenced by `ContentView`
  (home uses `HomeConnectView`'s own swipe rows); uses raw colors, not the theme.
- `ToggleVPNConnectionIntent` — the rendered widget button uses the explicit
  Connect/Disconnect intents; Toggle survives only as a Shortcuts/Siri action.
- `XrayTunnelEngineError.engineUnavailable` — defined, never thrown.
- `NetlumaVPNUITests.testExample` — empty boilerplate.

Verify before deleting.

## 🟡 13. UX papercuts

- Home screen caps local profiles at `prefix(2)` while the `ACTIVE: %d` badge shows the
  full count, and there's no "see all profiles" affordance.
- Splash dismisses on a ~1.05 s timer regardless of whether `loadGlobalServers()` /
  `refreshStatus()` finished.
- Widget has no live connection-duration UI (the data is persisted but unused), and no
  lock-screen accessory family.

_Last full analysis: 2026-06-24._
