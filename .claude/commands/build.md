---
description: Build the QuickVPN app for the iPhone 17 Pro simulator
allowed-tools: Bash
---

Compile the `QuickVPN` scheme for the standard simulator destination. This
also builds the tunnel extension and widget as part of the scheme.

```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

If the build fails with `Multiple commands produce`, run `/regen` first —
XcodeGen often resolves duplicate-source issues.

If `Package SwiftyXrayKit not found`, resolve SPM deps:
```bash
xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN -resolvePackageDependencies
```

Report build status (success / first failing diagnostic line) — do not
paste the full multi-thousand-line log unless the user asks.
