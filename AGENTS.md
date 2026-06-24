# AGENTS.md — Operating protocol for NetlumaVPN

This file is the instruction set for **Codex and any other coding agent** working in
this repository. (Claude Code reads the same rules from [`CLAUDE.md`](CLAUDE.md);
the project's Claude Code subagent/skill/command index is the separate file
[`docs/AGENTS.md`](docs/AGENTS.md) — different file, different job.)

NetlumaVPN is a multi-protocol iOS VPN client (VLESS+Reality, VMess, Trojan,
WireGuard) with a Packet Tunnel Extension, a Home Screen widget, StoreKit 2
subscriptions, Firebase telemetry, and a Python/FastAPI backend that issues per-device
profiles.

---

## The workflow you MUST follow on every task

Apply this to **every** task, **no matter how small** — a typo fix follows the same
loop as a feature.

1. **Read the documentation first.** Start at [`docs/README.md`](docs/README.md), then
   open the document(s) that own the area you're about to change (ownership map below).
   **Do not start editing before you've read the relevant docs.** The `docs/` folder is
   the source of truth — more current than this file or any code comment.
2. **Do the work**, respecting the [guardrails](#guardrails-never-violate-these).
3. **Write or extend tests, and run them.** Then run the **full** test suite to confirm
   you broke nothing else. Exact commands: [`docs/TESTING.md`](docs/TESTING.md). A task
   is **not complete** until its tests are written and the whole suite is green.
4. **Update the documentation** in the same change set: reflect what you did in the
   owning doc, and add/update [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) if you found
   or resolved a discrepancy. Out-of-date docs are treated as a bug.

Definition of done: **code → tests written → all tests pass → docs updated.**

---

## Where to read / what to update (ownership map)

| Working on… | Read & update |
|-------------|---------------|
| iOS app UI, `AppModel`, app-side services | [`docs/APP.md`](docs/APP.md) |
| Shared models, storage, logging (`NetlumaVPNShared`) | [`docs/SHARED.md`](docs/SHARED.md) |
| Tunnel extension, URL parsing, Xray config, network settings | [`docs/VPN_TUNNEL.md`](docs/VPN_TUNNEL.md) |
| Widget / App Intents | [`docs/WIDGET.md`](docs/WIDGET.md) |
| FastAPI backend(s) | [`docs/BACKEND.md`](docs/BACKEND.md) |
| nginx / systemd / fail2ban / deploy | [`docs/OPS.md`](docs/OPS.md) |
| Tests | [`docs/TESTING.md`](docs/TESTING.md) |
| Identifiers, bundle IDs, headers, the rename | [`docs/IDENTIFIERS.md`](docs/IDENTIFIERS.md) |
| Anything — sanity check | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) |

---

## Build, run & test commands

```bash
# Xcode project is generated from project.yml — regenerate after editing it / moving files
xcodegen generate

# Build for the simulator
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Unit tests (Swift Testing, hermetic — the default for every task)
xcodebuild -project NetlumaVPN.xcodeproj -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNTests test

# Network-dependent tests (live backend)
RUN_NETWORK_TESTS=1 xcodebuild … -only-testing:NetlumaVPNTests test

# UI tests (XCUITest)
xcodebuild … -only-testing:NetlumaVPNUITests test

# Backend tests
cd server_mvp/quickvpn_singbox_admin && python -m pytest test_app.py
cd server_mvp/singbox_admin && python -m pytest test_singbox_admin.py
```

- **Unit tests use Swift Testing** (`@Test`/`#expect`), **not** XCTest. UI tests use XCTest.
- Packet-tunnel routing only works on a **physical device** with the Network Extensions
  entitlement. The simulator compiles and runs the UI/logic but cannot route real VPN
  traffic (and without `SwiftyXrayKit` linked, the mock engine routes nothing — the UI
  shows "Connected" but no traffic flows).

---

## Repository layout (essentials)

```
NetlumaVPN/                 # Main app (SwiftUI): App/, Features/, Services/, Design/
NetlumaVPNShared/           # Models + storage + logging shared with extension & widget
NetlumaVPNTunnelExtension/  # NEPacketTunnelProvider + XrayTunnelEngine
NetlumaVPNWidget/           # WidgetKit + App Intents
NetlumaVPNTests/            # Swift Testing unit tests
NetlumaVPNUITests/          # XCUITest
server_mvp/                 # FastAPI backends (sing-box) + stdlib sidecar
archive/server_mvp/quickvpn_admin/app.py   # the Xray/WireGuard backend the provisioner actually deploys
ops/                        # nginx, systemd, fail2ban, provision/deploy/verify scripts
project.yml                 # XcodeGen — single source of truth for the Xcode project
docs/                       # ← READ THESE; the source of truth
```

---

## Guardrails (never violate these)

1. **Never hand-edit `NetlumaVPN.xcodeproj/`.** Edit [`project.yml`](project.yml) and run
   `xcodegen generate`.
2. **Never commit secrets.** The only file with live keys is `NETLUMAVPN_MVP_SERVER.md`
   (gitignored). Everything else references secrets by name.
3. **Never change the canonical identifiers** (bundle IDs, App Group, Keychain group,
   Team ID) without updating all five locations listed in
   [`docs/IDENTIFIERS.md`](docs/IDENTIFIERS.md). The `com.alekseipozdiakov.…` spelling is
   a deliberate, load-bearing typo — do not "fix" it.
4. **Logging goes through `AppLogger` only** — no `print(...)`, no new logger paths.
   Never log secrets (user IDs, passwords, keys, generated config, full endpoints). Note
   `AppLogger` does **not** auto-redact; use `safeProfileLabel`/`safeProfileID`.
5. **Treat the production VPS as live.** Do not run destructive commands
   (`systemctl stop xray`, `ufw disable`, schema-changing `sqlite3` writes) without the
   user confirming.
6. **Do not read `design.pen` with text tools** — it's an encrypted Pencil design file.
7. **Keep the backend single-file.** Don't introduce a package layout without a strong
   reason.

---

## Things that will trip you up (see `docs/KNOWN_ISSUES.md` for the full list)

- **TLS pinning is currently inert** (`mobileTLSCertificateSHA256Base64` is empty).
- **Two backends.** The provisioner deploys the Xray/WireGuard one
  (`archive/server_mvp/quickvpn_admin/app.py`, server IDs `quickvpn-mvp-eu-1*`); the
  sing-box one (`server_mvp/quickvpn_singbox_admin/app.py`, IDs `netlumavpn-singbox-*`)
  is what the iOS tests target. Confirm which is live before backend work.
- **The app sends both `X-NetlumaVPN-*` and `X-QuickVPN-*` headers** — don't delete the
  legacy ones without backend coordination.
- **`AppGroupStorage` is file-based JSON**, not `UserDefaults`.
- **The project is mid-rename (QuickVPN→NetlumaVPN)** — don't mass-rename identifiers,
  server IDs, ops paths, or the `quickvpn` system user.

_Last full analysis: 2026-06-24. Update the docs in the same task as your code change._
