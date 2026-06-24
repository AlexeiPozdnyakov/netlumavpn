// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.
// NetlumaVPN patch: 5.3 -> 5.5. Upstream uses .macOS(.v12)/.iOS(.v15) (PackageDescription 5.5 APIs)
// under a 5.3 tools-version, which Xcode 26's strict manifest compiler rejects. Vendored from
// WireGuard/wireguard-apple @ tag 1.0.16-27. See docs/VPN_TUNNEL.md.

import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(name: "WireGuardKit", targets: ["WireGuardKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WireGuardKit",
            dependencies: ["WireGuardKitGo", "WireGuardKitC"]
        ),
        .target(
            name: "WireGuardKitC",
            dependencies: [],
            publicHeadersPath: "."
        ),
        .target(
            name: "WireGuardKitGo",
            dependencies: [],
            exclude: [
                "goruntime-boottime-over-monotonic.diff",
                "go.mod",
                "go.sum",
                "api-apple.go",
                "Makefile"
            ],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        )
    ]
)
