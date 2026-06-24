#!/bin/sh
# Builds the wireguard-go-bridge (libwg-go.a) for the WireGuardGoBridgeiOS target.
#
# Xcode GUI builds run with a minimal PATH that does NOT include Homebrew's bin
# directory, so `make` can't find the `go` toolchain and the build fails with
# "go: command not found". This wrapper prepends the usual Homebrew locations
# (Apple Silicon + Intel) so the bridge builds the same from Xcode and the CLI.
#
# Requires Go (brew install go). See docs/VPN_TUNNEL.md → native WireGuard extension.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec /usr/bin/make "$@"
