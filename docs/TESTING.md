# Testing

> Owner agents: `swift-tester` (unit), `ui-tester` (XCUITest), `integration-tester`
> (iOS↔backend). **Every task must add/extend tests and leave the whole suite green.**

## The test rule (mandatory, every task)

For **every** change — feature, bugfix, or one-liner:

1. **Add or extend tests** that cover the behavior you changed. New logic → new
   `@Test`. Bugfix → a regression test that fails before your fix and passes after.
2. **Run your new tests** and confirm they pass.
3. **Run the full unit suite** (`NetlumaVPNTests`) and confirm nothing else broke.
   Run UI tests too if you touched UI/navigation.
4. If you touched the backend, run the matching Python test file.

A task is not done until its tests exist and the suite is green. If something is
genuinely untestable (e.g. live `NetworkExtension` on-device behavior), say so
explicitly and cover the largest testable seam (the protocol-typed dependency).

## How to run

```bash
# Regenerate the project first if project.yml or the file layout changed
xcodegen generate            # or: /regen

# Hermetic unit tests (no network) — the default
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNTests test           # or: /test

# Network-dependent tests (hit the live backend)
RUN_NETWORK_TESTS=1 xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNTests test           # or: /test-network

# UI tests (XCUITest)
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNUITests test         # or: /ui-test

# Backend
cd archive/server_mvp/quickvpn_admin && python -m unittest test_app.py
cd server_mvp/quickvpn_singbox_admin && python test_app.py
cd server_mvp/singbox_admin && python test_singbox_admin.py
```

- **Unit tests use Swift Testing** (`import Testing`, `@Test`, `#expect`, `try #require`)
  — **not** XCTest. UI tests use XCTest. Don't mix them.
- ⚠️ **StoreKit caveat:** `.storekit` products only load via Xcode ⌘R (with the
  scheme's `storeKitConfiguration`), **not** headless `xcodebuild`. The premium tests
  parse the `.storekit` file as JSON so they don't need the runtime, but live purchase
  flows can't be exercised headlessly.

## Network-test gating

`NetlumaVPNTests` and `GlobalServerIntegrationTests` enable their network tests when
**either** `RUN_NETWORK_TESTS=1` **or** `TEST_RUNNER_RUN_NETWORK_TESTS=1` is set
(Xcode prefixes runner env vars). The egress-IP assertion reads
**`NETLUMAVPN_EXPECTED_EGRESS_IP`** (or `TEST_RUNNER_NETLUMAVPN_EXPECTED_EGRESS_IP`).
⚠️ Some agent descriptions still reference the old `QUICKVPN_EXPECTED_EGRESS_IP` name —
the code uses the `NETLUMAVPN_` form.

⚠️ **Network-gated tests are silent no-ops when the flag is off** (`guard … else { return }`)
— they pass green without asserting anything. A green hermetic run does **not** mean the
live network path was verified.

## Unit test inventory (`NetlumaVPNTests/`)

| File | Covers | Hermetic? |
|------|--------|-----------|
| `NetlumaVPNTests.swift` | `VPNConfigurationParser` (VLESS/Reality/XTLS, ws/httpupgrade/grpc, Trojan, WireGuard incl. `DNS =`, sing-box JSON), `XrayConfigBuilder`, `WireGuardQuickConfigBuilder` (wg-quick emission + re-parse round-trip), `TunnelNetworkSettingsBuilder` (incl. DNS override + per-resolver `/32` routes), `ConnectionDiagnostics` | hermetic, except 3 network-gated probes |
| `HomeConnectLogicTests.swift` | `VPNConnectionStatus.isHomeSessionActive`, `NetlumaVPNTab` (== `[.home,.settings]`), `ProfileSwipeState`, `GlobalServerRowState`, `VPNProfile.isNetlumaVPNManaged` | hermetic |
| `ProfileStorageTests.swift` | `ProfileStorage` (delete reassigns selection, secret rollback), onboarding store, `SessionStateStorage`, `ConnectionDisplayStateStorage` expiry | hermetic (throwaway suite + `InMemorySecureValueStorage`) |
| `NetworkPreferencesTests.swift` | `NetworkPreferencesStorage` round-trip, DNS resolution (DoH/DoT), IPv4-only, excluded routes vs `includeAllNetworks`, `SessionInfo` mapping | hermetic |
| `PremiumSubscriptionTests.swift` | `.storekit` ↔ `PremiumProductKind` sync, plan presentation, `PremiumAccessGate.requiresPremium` | hermetic, but reads repo files via `#filePath` |
| `PremiumLifecycleTests.swift` | Subscription **lifecycle** in `AppModel`: `bootstrapPremium()` pulls in an active sub + suppresses the banner / shows it for free users, the `Transaction.updates` observer starts once, and losing the sub (via foreground refresh **or** observer revocation) disconnects a live managed session; plus `PremiumAccessGate.shouldRevokeActiveSession` | hermetic (throwaway suite + `ControllablePremiumService` / `RecordingVPNManager` fakes) |
| `DebugSubscriptionManagementTests.swift` | The Settings **Debug-only** manage-subscriptions shortcut (`.manageSubscriptionsSheet`) exists and is wrapped in `#if DEBUG` so the Release/App Store binary never ships a "cancel subscription" affordance | hermetic (reads `SettingsView.swift` source via `#filePath`) |
| `LocalizationResourceTests.swift` | `Bundle.main.localizations` includes `en`+`ru`, a few localized strings | hermetic (needs the app `.lproj` in the test host) |
| `GlobalServerIntegrationTests.swift` | `GlobalServerAPIClient` (dual headers, retry-once, error reporting), `GlobalServerService` parsing, `AppModel` flows + premium gating, device-ID persistence | mostly hermetic (mock `NetlumaVPNHTTPClient`); 2 network-gated tests hit the live backend (expect `netlumavpn-singbox-*`) |
| `FirebaseIntegrationTests.swift` | Firebase wiring verified by **reading source as text** (project.yml deps + dSYM script, `FirebaseApp.configure()` in `AppDelegate`, proxy disabled, purchase logged before `transaction.finish()`) | hermetic (filesystem-coupled) |
| `AppStoreSubmissionTests.swift` | App Store upload metadata: export-compliance code build-setting placeholders in shipping plists, local xcconfig/helper wiring for GUI archives without committing the code, full iPad orientation list for multitasking validation, and archive-time vendor framework dSYM generation in `project.yml` | hermetic (filesystem-coupled) |
| `RemoteConfigDownloaderTests.swift` | `RemoteConfigDownloader.remoteConfigURL(from:)` link classification (http(s) vs direct config), `download(from:)` behaviour (2xx/empty/oversized/non-2xx/bad-scheme) via a `URLProtocol` stub, and `AppModel.importProfile(from:)` orchestration (downloads an `https` JSON link, parses a `vless://` link without downloading, surfaces download failures) | hermetic (`.serialized` download suite + throwaway suite + `InMemorySecureValueStorage`) |

## Backend test inventory

| File | Covers | Hermetic? |
|------|--------|-----------|
| `archive/server_mvp/quickvpn_admin/test_app.py` | Backend A public website routes, support feedback storage, admin feedback status updates, and dashboard degradation when Xray stats are unavailable | hermetic (temporary SQLite + patched stats where needed) |
| `server_mvp/quickvpn_singbox_admin/test_app.py` | Backend B sing-box profile creation/reuse/config/delete flows, public website routes, support feedback storage, and Basic Auth feedback admin status updates | hermetic (temp config/client dir + stubbed check/reload) |
| `server_mvp/singbox_admin/test_singbox_admin.py` | Stdlib sidecar admin behavior | hermetic |

**Shared fake:** `InMemorySecureValueStorage` (conforms to `SecureValueStorage`) — the
only standalone reusable fake. Other fakes (`MockNetlumaVPNHTTPClient`,
`MockNetworkErrorReporter`, `MockVPNManager`, `MockGlobalServerService`,
`MockPremiumSubscriptionService`, `FixedDeviceIdentityStore`, `InMemoryOnboardingStore`)
are defined privately inside `GlobalServerIntegrationTests.swift`. Inject them via the
protocols: `SecureValueStorage`, `NetlumaVPNHTTPClient`, `NetworkErrorReporting`,
`VPNManaging`, `GlobalServerServicing`, `PremiumSubscriptionServicing`,
`GlobalServerDeviceIdentifying`, `OnboardingCompletionStoring`.

## UI tests (`NetlumaVPNUITests/`)

XCTest. `NetlumaVPNUITests.testLaunchShowsVisibleTabs` launches in English, skips
onboarding when needed, and asserts the tab bar has Home + Settings and **not**
Servers/Protocols. `testExample` is empty boilerplate.
`NetlumaVPNUITestsLaunchTests` is the standard launch-screenshot template.

## Coverage gaps — where to add tests

These production types currently have **no** dedicated tests; prioritize them when you
touch the area:

- **VMess** parse/build (every other protocol is covered, VMess is not).
- **Tunnel runtime:** `PacketTunnelProvider`, `XrayTunnelEngine` / `MockXrayTunnelEngine`
  selection and lifecycle (`TunnelNetworkSettingsBuilder` *is* covered).
- **Widget:** the entire `NetlumaVPNWidget` target (`WidgetVPNController`, intents).
- **`VPNManager`** (real `NETunnelProviderManager` handling — only the mock is tested).
- **`AppLogger`/`AppLogStore`** sanitization (notable given the no-secrets guardrail),
  **`KeychainStorage`** (only the in-memory fake is tested), **`AppGroupStorage`**.

When you add coverage for any of these, update this table.

_Last full analysis: 2026-06-24._
