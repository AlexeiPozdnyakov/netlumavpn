---
description: Run network-dependent tests (live backend) with RUN_NETWORK_TESTS=1
allowed-tools: Bash
---

Run the unit tests with the live-network flag set, which enables
`GlobalServerIntegrationTests` and any other test gated on
`RUN_NETWORK_TESTS=1`.

These tests talk to the live mobile API at
`https://netlumavpn.example` and validate the public mobile API path.

```bash
RUN_NETWORK_TESTS=1 xcodebuild -project QuickVPN.xcodeproj -scheme QuickVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:QuickVPNTests test
```

If the simulator runner doesn't inherit the env var, use the prefixed form:

```bash
xcodebuild ... -testRunnerEnv RUN_NETWORK_TESTS=1 ...
```

Failures here usually mean:
1. TLS pin mismatch → check `AppConstants.Backend.mobileTLSCertificateSHA256Base64`
   against the live cert (see `.claude/skills/vps-ops/SKILL.md`).
2. Backend down → check `systemctl status quickvpn-api` on the VPS.
3. Mobile key rejected → key was rotated.

Report which scenario applies, not just "tests failed".
