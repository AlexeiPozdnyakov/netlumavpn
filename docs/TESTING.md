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
4. If you touched the backend, run the matching `pytest` file.

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

# Backend (sing-box backend + sidecar)
cd server_mvp/quickvpn_singbox_admin && python -m pytest test_app.py
cd server_mvp/singbox_admin && python -m pytest test_singbox_admin.py
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
| `NetlumaVPNTests.swift` | `VPNConfigurationParser` (VLESS/Reality/XTLS, ws/httpupgrade/grpc, Trojan, WireGuard, sing-box JSON), `XrayConfigBuilder`, `TunnelNetworkSettingsBuilder`, `ConnectionDiagnostics` | hermetic, except 3 network-gated probes |
| `HomeConnectLogicTests.swift` | `VPNConnectionStatus.isHomeSessionActive`, `NetlumaVPNTab` (== `[.home,.settings]`), `ProfileSwipeState`, `GlobalServerRowState`, `VPNProfile.isNetlumaVPNManaged` | hermetic |
| `ProfileStorageTests.swift` | `ProfileStorage` (delete reassigns selection, secret rollback), onboarding store, `SessionStateStorage`, `ConnectionDisplayStateStorage` expiry | hermetic (throwaway suite + `InMemorySecureValueStorage`) |
| `NetworkPreferencesTests.swift` | `NetworkPreferencesStorage` round-trip, DNS resolution (DoH/DoT), IPv4-only, excluded routes vs `includeAllNetworks`, `SessionInfo` mapping | hermetic |
| `PremiumSubscriptionTests.swift` | `.storekit` ↔ `PremiumProductKind` sync, plan presentation, `PremiumAccessGate` | hermetic, but reads repo files via `#filePath` |
| `LocalizationResourceTests.swift` | `Bundle.main.localizations` includes `en`+`ru`, a few localized strings | hermetic (needs the app `.lproj` in the test host) |
| `GlobalServerIntegrationTests.swift` | `GlobalServerAPIClient` (dual headers, retry-once, error reporting), `GlobalServerService` parsing, `AppModel` flows + premium gating, device-ID persistence | mostly hermetic (mock `NetlumaVPNHTTPClient`); 2 network-gated tests hit the live backend (expect `netlumavpn-singbox-*`) |
| `FirebaseIntegrationTests.swift` | Firebase wiring verified by **reading source as text** (project.yml deps + dSYM script, `FirebaseApp.configure()` in `AppDelegate`, proxy disabled, purchase logged before `transaction.finish()`) | hermetic (filesystem-coupled) |

**Shared fake:** `InMemorySecureValueStorage` (conforms to `SecureValueStorage`) — the
only standalone reusable fake. Other fakes (`MockNetlumaVPNHTTPClient`,
`MockNetworkErrorReporter`, `MockVPNManager`, `MockGlobalServerService`,
`MockPremiumSubscriptionService`, `FixedDeviceIdentityStore`, `InMemoryOnboardingStore`)
are defined privately inside `GlobalServerIntegrationTests.swift`. Inject them via the
protocols: `SecureValueStorage`, `NetlumaVPNHTTPClient`, `NetworkErrorReporting`,
`VPNManaging`, `GlobalServerServicing`, `PremiumSubscriptionServicing`,
`GlobalServerDeviceIdentifying`, `OnboardingCompletionStoring`.

## UI tests (`NetlumaVPNUITests/`)

XCTest. `NetlumaVPNUITests.testLaunchShowsVisibleTabs` asserts the tab bar has Home +
Settings and **not** Servers/Protocols. `testExample` is empty boilerplate.
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
- **Backend A** (`archive/.../quickvpn_admin/app.py`) has no test file.

When you add coverage for any of these, update this table.

_Last full analysis: 2026-06-24._
