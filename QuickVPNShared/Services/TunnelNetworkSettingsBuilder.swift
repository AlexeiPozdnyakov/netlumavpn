import Foundation
import NetworkExtension

#if canImport(Darwin)
import Darwin
#endif

struct TunnelNetworkSettingsBuilder {
    static let dnsServers = DNSResolver.defaultResolver.servers

    func makeSettings(
        routesDefaultTraffic: Bool,
        preferences: NetworkPreferences = NetworkPreferences()
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: 1360)

        let ipv4Settings = NEIPv4Settings(
            addresses: [Self.localTunnelIPv4Address()],
            subnetMasks: ["255.255.255.255"]
        )

        if routesDefaultTraffic {
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
            if preferences.tunnel.includeAllNetworks == false {
                ipv4Settings.excludedRoutes = Self.privateIPv4Routes
            }
        } else {
            ipv4Settings.includedRoutes = []
        }
        settings.ipv4Settings = ipv4Settings

        if preferences.tunnel.ipMode == .ipv4AndIPv6 {
            let ipv6Settings = NEIPv6Settings(
                addresses: ["fd00:88::2"],
                networkPrefixLengths: [128]
            )
            if routesDefaultTraffic {
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            } else {
                ipv6Settings.includedRoutes = []
            }
            settings.ipv6Settings = ipv6Settings
        }

        if routesDefaultTraffic {
            settings.dnsSettings = makeDNSSettings(for: preferences.selectedDNSResolver)
        }

        return settings
    }

    private func makeDNSSettings(for resolver: DNSResolver) -> NEDNSSettings {
        let settings: NEDNSSettings
        switch resolver.kind {
        case .standard:
            settings = NEDNSSettings(servers: resolver.servers)
        case .doh:
            let dohSettings = NEDNSOverHTTPSSettings(servers: resolver.servers)
            dohSettings.serverURL = resolver.serverURL
            settings = dohSettings
        case .dot:
            let dotSettings = NEDNSOverTLSSettings(servers: resolver.servers)
            dotSettings.serverName = resolver.serverName
            settings = dotSettings
        }

        settings.matchDomains = [""]
        return settings
    }

    private static var privateIPv4Routes: [NEIPv4Route] {
        [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
    }

    private static func localTunnelIPv4Address() -> String {
        let usedAddresses = currentIPv4InterfaceAddresses()
        for subnet in 5...250 where usedAddresses.contains(where: { $0.hasPrefix("10.\(subnet).") }) == false {
            return "10.\(subnet).5.2"
        }
        return "10.250.5.2"
    }

    private static func currentIPv4InterfaceAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  let socketAddress = current.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var address = socketAddress.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(address.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                addresses.append(String(cString: hostname))
            }
        }

        return addresses
    }
}
