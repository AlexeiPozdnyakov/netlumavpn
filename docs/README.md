# NetlumaVPN — Project Documentation

> **This folder is the single source of truth for how NetlumaVPN works.**
> Every agent (Claude Code, Codex, or human) must read the relevant document
> here **before** starting any task, and **update** it after finishing.
> See [Mandatory workflow](#mandatory-workflow-for-every-task) below — it is not optional.

NetlumaVPN is a multi-protocol iOS VPN client (VLESS + Reality, VMess, Trojan,
WireGuard) with a Packet Tunnel Extension, a Home Screen widget, StoreKit 2
subscriptions, Firebase telemetry, and a Python/FastAPI backend that issues
per-device profiles. The full client is ~12.4k lines of Swift across four
targets; the backend is ~1.3k lines of Python.

---

## Mandatory workflow for every task

Apply this to **every** task, **no matter how small** — a one-line fix follows
the same loop as a feature.

1. **Read the docs first.** Open [`docs/README.md`](README.md) (this file), then
   the document(s) that own the area you are about to touch (see the
   [ownership map](#documentation-map--ownership) below). Do **not** start editing
   code before you have read the relevant doc(s) and the matching guardrails in
   [`/CLAUDE.md`](../CLAUDE.md).
2. **Do the work**, following the conventions and guardrails in the docs and
   `CLAUDE.md`. Never change the [canonical identifiers](IDENTIFIERS.md) or commit
   secrets.
3. **Write or extend tests for your change, and run them.** Then run the **full**
   test suite to confirm you broke nothing else. See
   [`docs/TESTING.md`](TESTING.md) for the exact commands. Tests are part of the
   task, not a follow-up — a task is not done until its tests are written and
   green (and the rest of the suite is still green).
4. **Update the docs.** Reflect what you changed in the document(s) that own the
   area, and add or update an entry in [`docs/KNOWN_ISSUES.md`](KNOWN_ISSUES.md)
   if you discovered or resolved a discrepancy. If you changed how something is
   built/run/tested, update that too. Stale docs are treated as a bug.

A task is **complete** only when: code changes done → new/updated tests written
→ all tests pass → docs updated.

---

## Documentation map / ownership

Read the doc whose area you are touching. When you finish, update that same doc.

| Document | Covers | Matching specialist agent |
|----------|--------|---------------------------|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | System overview, target layout, boundary contracts, data flows | (all) |
| [`IDENTIFIERS.md`](IDENTIFIERS.md) | Bundle IDs, App Group, Keychain group, Team ID, header names, the QuickVPN→NetlumaVPN rename | (all) |
| [`APP.md`](APP.md) | iOS app: `AppModel`, navigation, UI features (Connection / Settings / Profiles / Premium), theme, localization, app-side services (`VPNManager`, `GlobalServer*`, Premium, Firebase) | `ios-developer` |
| [`SHARED.md`](SHARED.md) | `NetlumaVPNShared`: `AppConstants`, models (`VPNProfile`, `GlobalVPNServer`, `NetworkPreferences`…), storage (`ProfileStorage` / `KeychainStorage` / `AppGroupStorage`), `AppLogger`, `ConnectionDiagnostics` — the app↔extension boundary | `ios-developer` / `vpn-engineer` |
| [`VPN_TUNNEL.md`](VPN_TUNNEL.md) | Tunnel extension (`PacketTunnelProvider`, `XrayTunnelEngine`), URL parsing (`VPNConfigurationParser`), Xray JSON (`XrayConfigBuilder`), network settings (`TunnelNetworkSettingsBuilder`) | `vpn-engineer` |
| [`WIDGET.md`](WIDGET.md) | Home Screen widget, App Intents, `WidgetVPNController` | `ios-developer` |
| [`BACKEND.md`](BACKEND.md) | The two FastAPI backends, endpoints, auth, SQLite schema, sing-box / Xray provisioning | `backend-developer` |
| [`OPS.md`](OPS.md) | nginx (stream + http), systemd, fail2ban, the port map, deploy / verify scripts | `ops-engineer` |
| [`SSH_ACCESS.md`](SSH_ACCESS.md) | Current production SSH host, port `22`, safe connection commands, known-hosts and copy recipes | `ops-engineer` |
| [`TESTING.md`](TESTING.md) | Test inventory, how to run tests, coverage gaps, the test workflow | `swift-tester` / `ui-tester` / `integration-tester` |
| [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) | Live discrepancies & risks found during analysis (read before trusting any single source) | (all) |
| [`AGENTS.md`](AGENTS.md) | Index of the project's Claude Code subagents, skills, and slash commands | (all) |

> **Note on the two `AGENTS.md` files.** [`docs/AGENTS.md`](AGENTS.md) is the
> *index of Claude Code helpers* (subagents/skills/commands). The repo-root
> [`/AGENTS.md`](../AGENTS.md) is the *operating protocol for Codex and other
> agents*. They are different files with different jobs.

---

## Quick start

```bash
# Regenerate the Xcode project after editing project.yml or moving files
xcodegen generate

# Build for the simulator
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run the hermetic unit tests (no network)
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNTests test
```

Slash commands wrap these: `/regen`, `/build`, `/test`, `/test-network`,
`/ui-test`. See [`TESTING.md`](TESTING.md) for the full matrix and
[`AGENTS.md`](AGENTS.md) for the command list.

---

## Read this before trusting any single source

The project is mid-rename from **QuickVPN → NetlumaVPN**, and there are two
parallel backends. Several authoritative-looking sources disagree with the
actual code. The most important traps (full list in
[`KNOWN_ISSUES.md`](KNOWN_ISSUES.md)):

- **TLS certificate pinning is currently inert** — `AppConstants.Backend.mobileTLSCertificateSHA256Base64` is an empty string, so the (correct) pinning code has nothing to compare against.
- **Two backends exist.** The provisioning scripts deploy the **Xray/WireGuard** backend (`archive/server_mvp/quickvpn_admin/app.py`, server IDs `quickvpn-mvp-eu-1*`). The newer **sing-box** backend (`server_mvp/quickvpn_singbox_admin/app.py`, server IDs `netlumavpn-singbox-*`) is what the iOS client tests and `verify-fresh-server.sh` target. Confirm which one is live before backend work.
- **The app sends both `X-NetlumaVPN-*` and legacy `X-QuickVPN-*` headers**, so it authenticates against either backend.
- **`AppGroupStorage` is a file-based JSON store**, not `UserDefaults`.
- **The identifier stem is `com.alekseipozdiakov.…`** (misspelled — missing the second “n” of *pozdnyakov*). This typo is load-bearing; never “fix” it. See [`IDENTIFIERS.md`](IDENTIFIERS.md).

---

_Last full analysis: 2026-06-24. When you change the code, change the docs in the
same task._
