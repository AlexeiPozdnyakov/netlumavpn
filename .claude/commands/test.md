---
description: Run QuickVPNTests on the iPhone 17 Pro simulator (hermetic, no network)
allowed-tools: Bash
---

Run the unit-test target. Network-dependent tests are skipped unless
`RUN_NETWORK_TESTS=1` (use `/test-network` for that).

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test
```

If a specific class or test is requested, narrow the `-only-testing` flag:

```bash
# class
-only-testing:QuickVPNTests/ProfileStorageTests

# Swift Testing single function
-only-testing:QuickVPNTests/QuickVPNTests/parsesVLESSRealityImportURL
```

Report:
- Pass / fail count.
- Names of failed `@Test` methods (Swift Testing parallelises — show by name, not by order).
- The first failing `#expect` message for each failure.
