# NetlumaVPN

MVP iOS VPN client built with SwiftUI, NetworkExtension, Packet Tunnel Extension, App Groups, Keychain storage, and an Xray/tun2socks-backed packet tunnel integration.

This project is intended only for legal connections to servers you own or are authorized to use.

## What Is Included

- Main SwiftUI app with connection status, profile list, manual profile editor, URL import, QR code import, and settings.
- `VPNProfile` model for VLESS, VMess, Trojan, and WireGuard profile metadata.
- Keychain storage for user IDs, passwords, and WireGuard private keys.
- App Group storage for non-sensitive profile metadata and selected profile ID.
- `NETunnelProviderManager` setup for a Packet Tunnel provider.
- Packet Tunnel Extension with `NEPacketTunnelProvider`, DNS, IPv4/IPv6 settings, and default route setup.
- `XrayConfigBuilder` that generates Xray-compatible JSON outbound config.
- VLESS Reality metadata import and Xray config generation (`pbk`, `fp`, `sid`, `spx`, optional `flow`).
- WireGuard `.conf` import plus Xray WireGuard outbound generation.
- Real packet-flow integration through `SwiftyXrayKit` when the SPM dependency is available.
- `MockXrayTunnelEngine` fallback for builds where the real engine is not linked.
- Sanitized connection logs in Unified Logging and in the Settings diagnostics screen.
- XcodeGen-based project generation through `project.yml`.

## Project Structure

```text
NetlumaVPN/
  App/
    AppModel.swift
    ContentView.swift
    NetlumaVPNApp.swift
  Features/
    Connection/
    Profiles/
    Settings/
  Services/
    VPNManager.swift
  Assets.xcassets/
  Info.plist
  NetlumaVPN.entitlements

NetlumaVPNShared/
  Models/
  Services/

NetlumaVPNTunnelExtension/
  PacketTunnelProvider.swift
  XrayTunnelEngine.swift
  Info.plist
  NetlumaVPNTunnelExtension.entitlements

NetlumaVPNTests/
project.yml
```

## Run

1. Install XcodeGen if needed: `brew install xcodegen`.
2. Generate the Xcode project: `xcodegen generate`.
3. Open `NetlumaVPN.xcodeproj`.
4. Select the `NetlumaVPN` scheme.
5. Use a real Apple Developer team with Network Extension support enabled.
6. Build and run on a physical device for actual VPN permission behavior.

The simulator can compile the project, but Packet Tunnel VPN behavior is limited and should be validated on device.

## Required Apple Capabilities

Enable these for both the app ID and the Packet Tunnel extension app ID where applicable:

- Network Extensions: Packet Tunnel Provider.
- App Groups: `group.com.alekseipozdiakov.NetlumaVPN`.
- Keychain Sharing: `$(AppIdentifierPrefix)com.alekseipozdiakov.NetlumaVPN.shared`.
- Camera usage description for QR import: `NSCameraUsageDescription`.

If you change the bundle ID or Apple Team ID, update:

- `project.yml`
- `NetlumaVPN/NetlumaVPN.entitlements`
- `NetlumaVPNTunnelExtension/NetlumaVPNTunnelExtension.entitlements`
- `NetlumaVPNShared/Models/AppConstants.swift`

## Real Xray-Core Integration Points

The tunnel engine uses `SwiftyXrayKit` when the package is linked:

- `XRayTunnel(packetFlow:)` reads packets from `NEPacketTunnelFlow`.
- `XrayConfigBuilder` provides the Xray JSON.
- Packet Tunnel installs IPv4 default routes only when the real engine is active; IPv6 routes are installed when the tunnel IP mode is set to dual-stack.
- DNS is scoped to the tunnel with `matchDomains = [""]`.

If `SwiftyXrayKit` is not linked, the project falls back to `MockXrayTunnelEngine`:

- Replace `MockXrayTunnelEngine` in `NetlumaVPNTunnelExtension/XrayTunnelEngine.swift`.
- Keep the `XrayTunnelEngine` protocol as the app-facing abstraction.
- Use `XrayConfigBuilder` as the JSON config source, or replace it with a stricter model if your Xray iOS bridge requires it.
- Wire the real engine from `PacketTunnelProvider.startTunnel`.
- Add the required packet/TUN adapter. Xray-core alone does not automatically consume `NEPacketTunnelFlow` packets.

While `MockXrayTunnelEngine` is active, NetlumaVPN does not install the default route. The tunnel can connect for lifecycle testing without breaking normal internet, but no traffic is proxied until a real engine is linked.

For a real full-tunnel connection, the logs should include:

- `Using SwiftyXrayKit tunnel engine`
- `Tunnel engine default-route mode enabled`
- `Real Xray engine started`

If the logs mention the mock engine or `default-route mode disabled`, the VPN status can become Connected but normal traffic will not go through the tunnel.

Do not log generated configs in production because they may contain user IDs or passwords.

## Logs

Open **Settings -> Connection Logs** in the app to see sanitized events from the main app and Packet Tunnel Extension. The same events are also written with `os.Logger` under subsystem `com.alekseipozdiakov.NetlumaVPN`.

The log messages intentionally do not include passwords, user IDs, generated Xray JSON, or full server endpoints.

## Privacy Notes

- Passwords and user IDs are stored in Keychain.
- UserDefaults/App Groups store only profile metadata and selected profile ID.
- The code avoids printing passwords, tokens, private keys, or generated Xray configs.
- Remove or redact any additional diagnostics before shipping.

## Verification

Current local checks:

- `NetlumaVPN` builds successfully for iOS Simulator.
- `NetlumaVPNTests` passes.

Optional network diagnostics are gated so normal test runs stay deterministic:

```sh
RUN_NETWORK_TESTS=1 xcodebuild test \
  -project NetlumaVPN.xcodeproj \
  -scheme NetlumaVPN \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:NetlumaVPNTests
```

If the command-line environment does not reach the simulator test runner, set `RUN_NETWORK_TESTS=1` in **Scheme -> Test -> Arguments -> Environment Variables**. In Codex/XcodeBuildMCP, pass it through `testRunnerEnv`; the tests also accept the prefixed `TEST_RUNNER_RUN_NETWORK_TESTS=1` form.

Those tests verify:

- VLESS Reality URL parsing for the provided config.
- Xray Reality JSON generation.
- Packet Tunnel network settings include IPv4 default routes, optional IPv6 default routes, and tunnel DNS when the real engine is active.
- TCP reachability to the provided VLESS Reality server.
- Basic HTTPS internet reachability.
- Public egress IP reachability through `api.ipify.org`.

To assert that traffic is exiting through a known VPN IP, connect NetlumaVPN on a physical device, then run the network tests with:

```sh
RUN_NETWORK_TESTS=1 NETLUMAVPN_EXPECTED_EGRESS_IP=<expected-ip> xcodebuild test \
  -project NetlumaVPN.xcodeproj \
  -scheme NetlumaVPN \
  -destination 'platform=iOS,name=<device-name>' \
  -only-testing:NetlumaVPNTests
```

Full VPN egress validation still needs a physical device because iOS Packet Tunnel permission and routing are device-level behavior.
