# iOS App (`NetlumaVPN` target)

> Owner agent: `ios-developer`. Covers the app shell, state, navigation, UI
> features, and the app-side service layer. For shared models/storage see
> [`SHARED.md`](SHARED.md); for the tunnel/protocols see [`VPN_TUNNEL.md`](VPN_TUNNEL.md);
> for the widget see [`WIDGET.md`](WIDGET.md).

SwiftUI, iOS 17+, `@Observable` (Observation framework — **no** `ObservableObject`).
UI-state types are `@MainActor`.

## App entry & lifecycle

- **`NetlumaVPNApp.swift`** — `@main`, attaches `@UIApplicationDelegateAdaptor(AppDelegate.self)`,
  single `WindowGroup { ContentView() }`. No state injected here.
- **`AppDelegate.swift`** — its only job is `FirebaseApp.configure()` in
  `didFinishLaunchingWithOptions`. Firebase delegate swizzling is disabled via
  `FirebaseAppDelegateProxyEnabled = false` in `Info.plist`.
- **`ContentView.swift`** — owns the root `@State private var model = AppModel()`,
  `selectedTab`, a `RootSheet?` enum, and `showsSplash`. Body: background gradient →
  `rootContent` → conditional `SplashScreenView`. Forces `.preferredColorScheme(.dark)`.
  - `rootContent`: if `model.hasCompletedOnboarding` → `appTabs`, else `OnboardingView`.
  - Splash is **time-based** (~1.05 s `Task.sleep`) — it kicks off
    `model.refreshStatus()` + `model.loadGlobalServers()` but dismisses on the timer,
    not on load completion.
  - `.onChange(of: scenePhase)` reloads global servers when the scene becomes active.
  - Presents 5 sheets via `RootSheet`: `.addProfile`, `.editProfile`, `.importProfile`,
    `.scanQRCode`, `.premium`.
- **Onboarding** (private types in `ContentView.swift`): a 3-page `TabView`
  (protocols pitch → security pitch → `PremiumPaywallView`). "Skip"/purchase/restore
  all call `model.completeOnboarding()`.

## `AppModel` — the root state holder

`@MainActor @Observable final class AppModel` (`NetlumaVPN/App/AppModel.swift`).
Single source of truth for UI state; every dependency is injectable for tests.

**Observable state (selected):** `profiles`, `selectedProfileID`, `status`,
`connectionStartedAt`, `networkPreferences`, `hasCompletedOnboarding`, `errorMessage`,
global-server state (`globalServers`, `isLoadingGlobalServers`, `activeGlobalServerID`,
`selectedGlobalServerID`, `globalServersErrorMessage`), and premium state
(`premiumPlans`, `isLoadingPremiumProducts`, `isPurchasingPremium`,
`hasActivePremiumSubscription`, `hasLoadedPremiumEntitlements`, `premiumProductsErrorMessage`).

**Owned services (all `@ObservationIgnored`, injectable):** `ProfileStorage`,
`NetworkPreferencesStorage`, `any VPNManaging` (→ `VPNManager`), `SessionStateStorage`,
`ConnectionDisplayStateStorage`, `any GlobalServerServicing` (→ `GlobalServerService`),
`any PremiumSubscriptionServicing` (→ `StoreKitPremiumSubscriptionService`),
`OnboardingCompletionStoring`, a `VPNConfigurationParser`, the NEVPN status observer.

**Key methods:**

| Method | Purpose |
|--------|---------|
| `toggleConnection() async -> PremiumGatedActionResult` | Main connect/disconnect entry; premium-gated |
| `selectProfile(_:) async` / `selectGlobalServer(_:) async -> PremiumGatedActionResult` | Choose active profile/server |
| `saveProfile(_:secret:) throws` / `importProfile(from:) throws` / `deleteProfile(_:)` | Profile CRUD (import parses via `VPNConfigurationParser`) |
| `loadGlobalServers(force:) async` | Fetch managed servers from the backend |
| `loadPremiumProducts(force:) async` / `purchasePremium(productID:) async -> Bool` / `restorePremiumPurchases() async -> Bool` / `refreshPremiumEntitlements() async` | StoreKit |
| `updateTunnelPreferences(_:)` / `selectDNSResolver(_:)` | Network prefs |
| `completeOnboarding()` / `refreshStatus() async` | Lifecycle |

- **Premium gating:** `PremiumAccessGate.requiresPremium(...)` returns `.requiresPremium`
  for any **NetlumaVPN-managed profile** or **selected global server** unless the user
  has an active subscription. User-imported profiles are **not** gated.
  `ContentView` maps `.requiresPremium` to presenting the `.premium` sheet.
- **Widget refresh:** state-changing methods call `WidgetCenter.shared.reloadAllTimelines()`.
- **Onboarding storage:** `OnboardingCompletionStoring` (default
  `UserDefaultsOnboardingCompletionStore`, key `hasCompletedOnboarding.v1`).

## Navigation

`NetlumaVPNTab` is an enum with **only two cases: `.home` and `.settings`**
(`house` / `gearshape` icons). `appTabs` builds a `TabView`; `.home` →
`HomeConnectView` in a `NavigationStack`, `.settings` → `SettingsView`. There are
**no** Servers/Protocols tabs (the UI test `testLaunchShowsVisibleTabs` asserts they
are absent).

## UI features

### Connection — `Features/Connection/HomeConnectView.swift` (~1115 lines)

A **stateless, value-driven** view: it takes ~13 `let` inputs (status, dates,
profiles, global servers, IDs, flags) and ~10 callback closures; its only local
state is the swipe-row tracking `openProfileRowID`. `ContentView` wires the closures
back to `AppModel`.

- **Session card:** status dot + title + `selectedConnectionDisplayName`, a live
  `ConnectionDurationText` (HH:MM:SS via `TimelineView(.periodic(by:1))`), the big
  76 pt circular **power button** (`onToggleConnection`, disabled while
  `.disconnecting`), and a "Session details" link → `SessionInfoView`.
- **LOCAL PROFILES** section: filters out managed profiles, shows only `prefix(2)`,
  custom `SwipeableProfileConnectRow` (swipe to Edit/Delete).
- **GLOBAL SERVERS** section: `PRO`/`FAILED` badge, loading/retry rows, country flags.
- The file also holds the testable presentation types `ProfileSwipeState`,
  `GlobalServerRowState`, and the `VPNConnectionStatus` styling extension — these are
  what `HomeConnectLogicTests` exercises (there is **no** `HomeConnectLogic` type).

### Settings — `Features/Settings/`

- **`SettingsView`** — header, a conditional premium banner (`shouldShowPremiumBanner`),
  and rows: **Session** → `SessionInfoView`, **Tunnel** → `TunnelSettingsView`,
  **DNS** → `DNSSettingsView`, plus **Terms of Use** / **Privacy Policy** →
  `LegalDocumentView` (a `WKWebView` wrapper; prefers a bundled localized
  `Terms.html`/`Privacy.html`, else falls back to inline English HTML).
- **`TunnelSettingsView`** (binds `TunnelPreferences`): Persist Tunnel, IP Settings
  (`TunnelIPMode`), On Demand (`TunnelOnDemandMode`), Include All Networks.
- **`DNSSettingsView`**: selectable list from `DNSResolver.catalog`.
- **`SessionInfoView`** + **`SessionInfoService`**: fetches the current public
  IP/geo from **`ipapi.co`** (third-party, no auth, no pinning; degrades to empty on
  failure) so the user can confirm the VPN changed their egress.

### Profiles — `Features/Profiles/`

- **`ProfileEditorView`** (Add/Edit): a `Form` whose sections adapt to the selected
  `VPNProtocolType` — Credentials (VLESS/VMess user ID, Trojan password), Transport
  (security/network/SNI/path/flow/ALPN/fingerprint), Reality, or WireGuard fields.
- **`ProfileFormData`**: a plain struct modeling the entire editor;
  `makeProfile(existingProfile:) throws -> (VPNProfile, VPNProfileSecret)` validates and
  splits metadata vs secret. Errors are `ProfileFormError` (port range 1–65535, MTU
  576–9000, reserved bytes 0–255, missing credentials, etc.).
- **`ImportProfileView`**: paste a config URL → `model.importProfile(from:)`.
- **`QRCodeImportView`**: full `AVCaptureSession` QR scanner (camera permission states),
  scanned string → `onImport`.
- **`ProfileListView`** appears to be **dead code** (not referenced by `ContentView`,
  uses raw colors instead of the theme) — verify before relying on or deleting it.

### Premium — `Features/Premium/`

- **`PremiumPaywallView`** — presentational only; driven by injected
  `plans`/flags/closures. Shows hero, feature checklist, plan picker (weekly/monthly/
  yearly with savings badge), CTA, restore, and legal links. Used both in onboarding
  and from Settings.
- **`PremiumSubscriptionModels`** — `PremiumProductKind`, `PremiumSubscriptionPlan`,
  intro-offer models, `PremiumAccessGate`, `PremiumGatedActionResult`.

## App-side services (`NetlumaVPN/Services/`)

### `VPNManager` (`VPNManaging`)

`@MainActor`. Owns the `NETunnelProviderManager` lifecycle.

- `connect(profile:)`: persists selection, builds `ResolvedVPNProfile` via
  `ProfileStorage.resolvedProfile(id:)`, JSON-encodes a `TunnelStartPayload`, configures
  an `NETunnelProviderProtocol` (`providerBundleIdentifier =
  AppConstants.tunnelProviderBundleIdentifier`, `serverAddress = profile.displayEndpoint`,
  `providerConfiguration = [selectedProfileID: uuid]`), sets on-demand rules from prefs,
  saves+reloads preferences, then `startVPNTunnel(options:)` with `selectedProfileID`
  (NSString) + `startPayload` (NSData). **Secrets travel in the start options, not in
  `providerConfiguration`.**
- `disconnect()`: `stopVPNTunnel()`.
- `observeConnectionState(_:)`: registers a `NEVPNStatusDidChange` observer, bridges
  `NEVPNStatus` → `VPNConnectionStatus`, logs disconnect errors via `AppLogger`.

### `GlobalServerAPIClient`

Pinned HTTPS client for the mobile API.

- Base URL from `AppConstants.Backend.mobileAPIBaseURL`; sends dual client-key +
  device-id headers (see [`IDENTIFIERS.md`](IDENTIFIERS.md)).
- Endpoints: `fetchServers()` → `GET /api/v1/mobile/servers` (filters `isAvailable`,
  retries once on transient errors); `issueProfile(for:)` → `POST
  /api/v1/mobile/servers/{id}/profile`; `downloadConfig(for:)` → `GET issue.configURL`.
- **TLS pinning** (`PinnedCertificateHTTPClient`, a `URLSessionDelegate`): hashes the
  **leaf DER certificate** with CryptoKit SHA256 and compares against the configured
  pin. On mismatch it cancels the challenge. **The pin constant is empty, so pinning is
  currently disabled** (`.performDefaultHandling`). `GlobalServerAPIError.certificatePinMismatch`
  exists but is never thrown.
- Failures are reported to `FirebaseTelemetryReporter` (host/path/status only).

### `GlobalServerService` (`GlobalServerServicing`)

Thin orchestration over the API client + parser: `fetchServers()`, and
`provisionProfile(for:)` which issues a profile, downloads-or-inlines the config,
parses it via `VPNConfigurationParser`, and stamps `origin = .netlumaVPNGlobal`,
`managedServerID`, and `remarks`. Returns the `(VPNProfile, VPNProfileSecret)` pair —
it does **not** persist.

### `GlobalServerDeviceIdentityStore`

Load-or-create a per-device UUID, persisted in the **Keychain** (account
`netlumavpn-global-device-id.v1`). Backs the dedup device header.

### `PremiumSubscriptionService` (`StoreKitPremiumSubscriptionService`)

**Real StoreKit 2**, not a stub: `Product.products(for:)`, `purchase()`,
`Transaction.currentEntitlements`, `Transaction.updates`, `AppStore.sync()`. Maps
products to `PremiumSubscriptionPlan`s with intro-offer/trial detection. Reports
purchase lifecycle to Firebase. ⚠️ StoreKit products only load via Xcode ⌘R with the
`.storekit` config, **not** headless `xcodebuild` (see [`TESTING.md`](TESTING.md)).

### `FirebaseTelemetryReporter`

Singleton conforming to `NetworkErrorReporting` + `PremiumPurchaseAnalyticsReporting`.
Logs `network_request_failed` and `premium_purchase_*` events to Analytics +
Crashlytics. **Logs no secrets** — only method/host/path/status/attempt-count/
product-id/error-domain. No-op stand-ins exist for tests. It talks to Firebase
directly (not through `AppLogger`).

## Theme & localization

- **`Design/NetlumaVPNTheme.swift`** — dark palette namespace (background, surface,
  card, mint `accent #34D399`, etc.), `Color(hex:)`, `CapsuleIconButtonStyle`, and the
  `NetlumaVPNCard` container used across Settings.
- **Localization** — English + Russian. All UI strings go through
  `L10n.string(...)` / `L10n.format(...)` (wrappers over `NSLocalizedString`).
  ⚠️ There is **no `Localizable.strings`/`.xcstrings` table**, so `NSLocalizedString`
  returns the key — i.e. in-app UI renders the English source and Russian UI is
  effectively unlocalized. Only `InfoPlist.strings` and the `ru.lproj` legal HTML are
  truly localized. `en.lproj` is missing `Terms.html`/`Privacy.html` (English falls
  back to inline HTML). See [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

## Conventions for this target

- `@Observable` + `@MainActor`; inject dependencies via protocols so tests can fake them.
- Keep feature views stateless/value-driven where possible (`HomeConnectView` is the
  reference pattern); put testable logic in plain types (`ProfileFormData`,
  `ProfileSwipeState`) rather than inside view bodies.
- Never log secrets; use `AppLogger` (no `print`).
- After any change here, update this doc and add Swift Testing coverage
  (see [`TESTING.md`](TESTING.md)).

_Last full analysis: 2026-06-24._
