---
description: Run QuickVPNUITests (XCUITest) on the iPhone 17 Pro simulator
allowed-tools: Bash
---

Run the UI test bundle. UI tests use XCUITest (not Swift Testing) and live
in `QuickVPNUITests/`.

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNUITests test
```

UI tests are slower than unit tests and can flake when the simulator is
cold. If a test fails:
1. Re-run the same `-only-testing:` once.
2. If still failing, attach the failure screenshot (Xcode saves it under
   DerivedData → `Logs/Test/`) when reporting.

Report:
- Pass / fail count.
- Failing `testFoo` names with the first XCTest failure message.
