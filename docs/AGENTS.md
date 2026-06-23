# NetlumaVPN agents, skills, and commands

This is the index of project-level Claude Code helpers. They're loaded
automatically by Claude Code when you run the CLI from this repo root (or
any subdirectory).

## Subagents

Project subagents live under `.claude/agents/`. Each is a focused expert
with a narrowed tool set. Use them by invoking the `Agent` tool with
`subagent_type: "<name>"`, or by typing the name in FleetView.

| Agent | When to use |
|-------|-------------|
| [`ios-developer`](../.claude/agents/ios-developer.md) | SwiftUI views, `AppModel`, feature folders, app-side services, widget |
| [`vpn-engineer`](../.claude/agents/vpn-engineer.md) | URL parsing (VLESS/VMess/Trojan/WireGuard), Xray JSON, Packet Tunnel extension |
| [`backend-developer`](../.claude/agents/backend-developer.md) | `server_mvp/quickvpn_singbox_admin/app.py`, FastAPI endpoints, SQLite |
| [`ops-engineer`](../.claude/agents/ops-engineer.md) | `ops/` files — systemd, nginx, fail2ban, deploy workflow |
| [`swift-tester`](../.claude/agents/swift-tester.md) | New Swift Testing unit tests in `NetlumaVPNTests/` |
| [`ui-tester`](../.claude/agents/ui-tester.md) | XCUITest flow tests in `NetlumaVPNUITests/` |
| [`integration-tester`](../.claude/agents/integration-tester.md) | iOS ↔ backend cross-boundary verification, TLS pinning |
| [`security-reviewer`](../.claude/agents/security-reviewer.md) | Pre-merge audit: secrets, pinning, entitlements, auth |

### Picking the right agent

- **"Add a tab"** → `ios-developer`
- **"Support a new VPN protocol"** → `vpn-engineer`
- **"Add a backend endpoint"** → `backend-developer`
- **"Tighten nginx rate-limit"** → `ops-engineer`
- **"Add a test for the WireGuard parser"** → `swift-tester`
- **"Smoke-test the onboarding flow"** → `ui-tester`
- **"Verify TLS pin matches the live cert"** → `integration-tester`
- **"Audit this PR for secret leaks"** → `security-reviewer`

When work spans two areas (e.g. an iOS feature that needs a new endpoint),
the right call is usually to spawn both `backend-developer` and
`ios-developer` and wire them up, rather than asking one to do the other's
job.

## Skills

Project skills live under `.claude/skills/`. They're reference material the
main session can pull in on demand — not commands.

| Skill | What it covers |
|-------|----------------|
| [`quickvpn-build`](../.claude/skills/quickvpn-build/SKILL.md) | XcodeGen + xcodebuild recipes, common failures |
| [`vpn-protocols`](../.claude/skills/vpn-protocols/SKILL.md) | URL formats and Xray JSON shapes for every supported protocol |
| [`backend-server`](../.claude/skills/backend-server/SKILL.md) | FastAPI endpoint map, DB schema, auth model, local dev |
| [`vps-ops`](../.claude/skills/vps-ops/SKILL.md) | Production VPS — SSH, services, ports, cert rotation |

## Slash commands

| Command | Effect |
|---------|--------|
| `/regen` | `xcodegen generate` |
| `/build` | Build `NetlumaVPN` for iPhone 17 Pro simulator |
| `/test` | Run `NetlumaVPNTests` (hermetic) |
| `/test-network` | Run tests with `RUN_NETWORK_TESTS=1` |
| `/ui-test` | Run `NetlumaVPNUITests` |
| `/health-check` | Probe live backend: TLS pin, mobile API, admin API |
| `/server-logs` | Tail recent VPS logs (api / xray / nginx) |
| `/deploy-server` | Surface deploy commands for `ops/` + `server_mvp/` (requires user confirmation to execute) |

## How everything fits together

```
CLAUDE.md                       — project context auto-loaded every session

.claude/
  agents/                       — subagent definitions
    ios-developer.md
    vpn-engineer.md
    backend-developer.md
    ops-engineer.md
    swift-tester.md
    ui-tester.md
    integration-tester.md
    security-reviewer.md
  skills/                       — reference material the model can pull in
    quickvpn-build/SKILL.md
    vpn-protocols/SKILL.md
    backend-server/SKILL.md
    vps-ops/SKILL.md
  commands/                     — slash commands
    regen.md
    build.md
    test.md
    test-network.md
    ui-test.md
    health-check.md
    server-logs.md
    deploy-server.md
  settings.local.json           — per-checkout permissions (not committed)

docs/                           — long-form docs for humans
  ARCHITECTURE.md               — system diagram + boundary contracts
  AGENTS.md                     — this file
```

## Conventions for adding more agents / skills / commands

1. Keep the description in the frontmatter sharp enough that the auto-picker
   can route to it. Bad: "iOS stuff". Good: "Use this agent for SwiftUI
   views, `AppModel`, and app-side services — NOT tunnel extension or
   backend code."
2. Always list the negative scope ("Do NOT use for…") so the auto-picker
   doesn't grab it when a better fit exists.
3. Set `tools:` to the minimum needed. Read/Grep/Glob is fine for review
   agents; only give Write/Edit/Bash to agents that need to mutate state.
4. For commands, set `allowed-tools:` and write the exact bash invocation
   in the body. The body is the prompt the model sees when the command is
   invoked.
5. For skills, the file is named `SKILL.md` inside a folder named after the
   skill. The folder name is the slug used to invoke the skill.

## Not in this repo

- `.claude/settings.local.json` is per-checkout and not committed. It
  contains the user's pre-approved Bash commands.
- Live secrets are NOT in any agent / skill / command file — they're only
  in `NETLUMAVPN_MVP_SERVER.md` (also gitignored).
