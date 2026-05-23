---
description: Regenerate the Xcode project from project.yml using XcodeGen
allowed-tools: Bash
---

Run `xcodegen generate` at the repo root to regenerate `QuickVPN.xcodeproj`
from `project.yml`. Run this whenever:

- A Swift file is added, removed, or moved between top-level folders.
- `project.yml` itself is edited (targets, deps, settings, schemes).
- A new SPM package is added.

If `xcodegen` is missing, install it: `brew install xcodegen`.

After generation, do NOT edit `QuickVPN.xcodeproj/` by hand.

```bash
xcodegen generate
```
