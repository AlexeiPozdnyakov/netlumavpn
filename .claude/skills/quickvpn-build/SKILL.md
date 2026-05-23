---
name: quickvpn-build
description: Recipes for regenerating the QuickVPN Xcode project from `project.yml` and building / testing the iOS app. Use when the user asks how to build QuickVPN, when `project.yml` was edited, when a new source file was added to a target, or when `xcodebuild` is failing in a way the user wants debugged.
---

# QuickVPN build & test recipes

QuickVPN uses **XcodeGen** as the source of truth. `QuickVPN.xcodeproj/` is
generated and must never be hand-edited.

## 1. Regenerate the project

After editing `project.yml`, moving Swift files between top-level folders,
or adding a new top-level folder that should be a source root:

```bash
xcodegen generate
```

If `xcodegen` is missing:
```bash
brew install xcodegen
```

XcodeGen picks up sources by **folder path**, recursively. You do not need
to list individual files in `project.yml`. Files added to existing source
roots (`QuickVPN/`, `QuickVPNShared/`, `QuickVPNTunnelExtension/`,
`QuickVPNWidget/`, `QuickVPNTests/`, `QuickVPNUITests/`) are picked up on
the next `xcodegen generate`.

## 2. Build for simulator

The standard target is iPhone 17 Pro (iOS 17 SDK).

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Common alternative destinations:
- `'platform=iOS Simulator,name=iPhone 16'` — older Xcode runners
- `'platform=iOS Simulator,id=<UDID>'` — exact simulator by UDID
- `'generic/platform=iOS'` — generic device (won't run, just compiles)

To list available destinations: `xcrun simctl list devices available`.

## 3. Build for device

Requires a real Apple Developer team with:
- Network Extensions (Packet Tunnel Provider) entitlement
- App Groups entitlement
- Keychain Sharing entitlement

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS,name=<your-device-name>' build
```

The simulator can compile and partially run the app, but actual VPN
routing only works on a physical device.

## 4. Unit tests

```bash
# All unit tests
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test

# Single class
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests/ProfileStorageTests test

# Single test (Swift Testing)
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests/QuickVPNTests/parsesVLESSRealityImportURL test
```

## 5. Network-dependent tests (opt-in)

`GlobalServerIntegrationTests` and the egress-validation cases require live
network. They are skipped unless `RUN_NETWORK_TESTS=1` is set.

```bash
RUN_NETWORK_TESTS=1 xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test
```

If the simulator runner doesn't inherit the env var, use the
test-runner-prefixed form:
```bash
xcodebuild ... -testRunnerEnv RUN_NETWORK_TESTS=1 ...
```
…or add it under **Scheme → Test → Arguments → Environment Variables** in
Xcode.

## 6. Egress validation (physical device only)

To prove traffic actually exits through a known VPN IP, connect QuickVPN
on a physical device, then run:

```bash
RUN_NETWORK_TESTS=1 \
QUICKVPN_EXPECTED_EGRESS_IP=<expected-ip> \
xcodebuild test \
  -project QuickVPN.xcodeproj \
  -scheme QuickVPN \
  -destination 'platform=iOS,name=<device-name>' \
  -only-testing:QuickVPNTests
```

This cannot be done on the simulator — iOS Packet Tunnel routing is
device-level.

## 7. UI tests

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNUITests test
```

UI tests are XCTest (not Swift Testing) and live in `QuickVPNUITests/`.

## 8. Clean build

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN clean
rm -rf ~/Library/Developer/Xcode/DerivedData/QuickVPN-*
```

## 9. Common failure modes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Multiple commands produce ...` after adding a file | XcodeGen ran with the file referenced twice (e.g. it was in two source roots) | Remove the duplicate path entry in `project.yml`, re-run `xcodegen generate` |
| `Package SwiftyXrayKit not found` | SPM cache cold | `xcodebuild ... -resolvePackageDependencies` once before building |
| `App Group is not entitled` on device | Entitlements missing or team mismatch | Check entitlements files reference `group.com.alekseipozdiakov.QuickVPN`; team in `project.yml` matches signing |
| `MockXrayTunnelEngine` used at runtime | SwiftyXrayKit didn't link (e.g. simulator-only path) | Expected on simulator; on device verify SPM resolved |
| Tests that touch network skipped | `RUN_NETWORK_TESTS` not set | Set the env var (or `TEST_RUNNER_RUN_NETWORK_TESTS`) |
