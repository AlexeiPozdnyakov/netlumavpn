//
//  NetlumaVPNTests.swift
//  NetlumaVPNTests
//
//  Created by Alexei Pozdnyakov on 5/10/26.
//

import Foundation
import NetworkExtension
import Testing
@testable import NetlumaVPN

struct NetlumaVPNTests {
    private let providedRealityURL = "vless://00000000-0000-4000-8000-000000000017@www.node1.example-vpn.test:443/?type=tcp&security=reality&pbk=TestRealityPublicKeyPlaceholderThirdParty00&fp=chrome&sni=node1.example-vpn.test&sid=0a1b2c&spx=%2F#STEAL"
    private let providedTrojanGRPCURL = "trojan://00000000-0000-4000-8000-000000000018@node1.example-vpn.test:443/?type=grpc&serviceName=%2F2053%2FExampleGrpcServicePathToken000&authority=node1.example-vpn.test&security=tls#GRPC"
    private let providedVLESSHTTPUpgradeURL = "vless://00000000-0000-4000-8000-000000000019@node1.example-vpn.test:443/?type=httpupgrade&path=%2F2073%2FExampleHttpUpgradePathToken000&host=node1.example-vpn.test&security=tls#HTTPU"
    private let providedVLESSWSURL = "vless://00000000-0000-4000-8000-000000000020@node1.example-vpn.test:443/?type=ws&path=%2F2083%2FExampleWebsocketPathToken00000&host=node1.example-vpn.test&security=tls#WS"
    private let providedVLESSXTLSURL = "vless://00000000-0000-4000-8000-000000000021@www.node1.example-vpn.test:443/?type=tcp&security=tls&fp=chrome&alpn=http%2F1.1&sni=www.node1.example-vpn.test&flow=xtls-rprx-vision#XTLS"
    private let providedWireGuardConfig = """
    [Interface]
    PrivateKey = private-key
    Address = 10.7.0.2/32, fd42:42:42::2/128
    MTU = 1280
    Reserved = 1, 2, 3

    [Peer]
    PublicKey = peer-public-key
    PresharedKey = pre-shared-key
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = wg.example.com:51820
    PersistentKeepalive = 25
    """

    @Test func parsesVLESSImportURL() throws {
        let url = "vless://11111111-1111-1111-1111-111111111111@vpn.example.com:443?security=tls&type=ws&sni=vpn.example.com&path=%2Fsocket#Office"

        let (profile, secret) = try VPNConfigurationParser().parse(url)

        #expect(profile.protocolType == .vless)
        #expect(profile.host == "vpn.example.com")
        #expect(profile.port == 443)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .ws)
        #expect(profile.path == "/socket")
        #expect(profile.remarks == "Office")
        #expect(secret.userId == "11111111-1111-1111-1111-111111111111")
    }

    @Test func parsesVLESSRealityImportURL() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedRealityURL)

        #expect(profile.protocolType == .vless)
        #expect(profile.security == .reality)
        #expect(profile.networkType == .tcp)
        #expect(profile.host == "www.node1.example-vpn.test")
        #expect(profile.port == 443)
        #expect(profile.realityPublicKey == "TestRealityPublicKeyPlaceholderThirdParty00")
        #expect(profile.realityFingerprint == "chrome")
        #expect(profile.realityShortID == "0a1b2c")
        #expect(profile.realitySpiderX == "/")
        #expect(profile.remarks == "STEAL")
        #expect(secret.userId == "00000000-0000-4000-8000-000000000017")
    }

    @Test func parsesProvidedTrojanGRPCImportURL() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedTrojanGRPCURL)

        #expect(profile.protocolType == .trojan)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .grpc)
        #expect(profile.host == "node1.example-vpn.test")
        #expect(profile.port == 443)
        #expect(profile.path == "/2053/ExampleGrpcServicePathToken000")
        #expect(profile.transportHost == "node1.example-vpn.test")
        #expect(profile.remarks == "GRPC")
        #expect(secret.password == "00000000-0000-4000-8000-000000000018")
    }

    @Test func parsesProvidedVLESSHTTPUpgradeImportURL() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedVLESSHTTPUpgradeURL)

        #expect(profile.protocolType == .vless)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .httpupgrade)
        #expect(profile.path == "/2073/ExampleHttpUpgradePathToken000")
        #expect(profile.transportHost == "node1.example-vpn.test")
        #expect(profile.remarks == "HTTPU")
        #expect(secret.userId == "00000000-0000-4000-8000-000000000019")
    }

    @Test func parsesProvidedVLESSWebSocketImportURL() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedVLESSWSURL)

        #expect(profile.protocolType == .vless)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .ws)
        #expect(profile.path == "/2083/ExampleWebsocketPathToken00000")
        #expect(profile.transportHost == "node1.example-vpn.test")
        #expect(profile.remarks == "WS")
        #expect(secret.userId == "00000000-0000-4000-8000-000000000020")
    }

    @Test func parsesProvidedVLESSXTLSImportURL() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedVLESSXTLSURL)

        #expect(profile.protocolType == .vless)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .tcp)
        #expect(profile.sni == "www.node1.example-vpn.test")
        #expect(profile.flow == "xtls-rprx-vision")
        #expect(profile.tlsFingerprint == "chrome")
        #expect(profile.tlsALPN == ["http/1.1"])
        #expect(profile.remarks == "XTLS")
        #expect(secret.userId == "00000000-0000-4000-8000-000000000021")
    }

    @Test func parsesWireGuardConfiguration() throws {
        let (profile, secret) = try VPNConfigurationParser().parse(providedWireGuardConfig)

        #expect(profile.protocolType == .wireguard)
        #expect(profile.host == "wg.example.com")
        #expect(profile.port == 51820)
        #expect(profile.security == .none)
        #expect(profile.networkType == .tcp)
        #expect(profile.wireGuardPeerPublicKey == "peer-public-key")
        #expect(profile.wireGuardLocalAddresses == ["10.7.0.2/32", "fd42:42:42::2/128"])
        #expect(profile.wireGuardAllowedIPs == ["0.0.0.0/0", "::/0"])
        #expect(profile.wireGuardPersistentKeepAlive == 25)
        #expect(profile.wireGuardMTU == 1280)
        #expect(profile.wireGuardReserved == [1, 2, 3])
        #expect(profile.wireGuardDNSServers == nil)
        #expect(secret.wireGuardPrivateKey == "private-key")
        #expect(secret.wireGuardPreSharedKey == "pre-shared-key")
    }

    @Test func parsesWireGuardConfigurationDNSServers() throws {
        // Mirrors a wg-quick config that pins internal resolvers (fake keys).
        let config = """
        [Interface]
        PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        Address = 10.3.61.120/32
        DNS = 172.16.4.15, 172.16.30.15, 172.16.10.15
        MTU = 1420

        [Peer]
        PublicKey = aGVsbG8td29ybGQtZmFrZS1wZWVyLXB1YmtleS0xMjM0NTY=
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0
        PresharedKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        PersistentKeepalive = 16
        """

        let (profile, _) = try VPNConfigurationParser().parse(config)

        #expect(profile.protocolType == .wireguard)
        #expect(profile.wireGuardDNSServers == ["172.16.4.15", "172.16.30.15", "172.16.10.15"])
    }

    @Test func buildsWireGuardQuickConfigFromProfile() throws {
        let profile = VPNProfile(
            protocolType: .wireguard,
            host: "vpn.example.com",
            port: 51820,
            security: .none,
            networkType: .tcp,
            wireGuardPeerPublicKey: "PEERPUBLICKEY=",
            wireGuardLocalAddresses: ["10.3.61.120/32"],
            wireGuardAllowedIPs: ["0.0.0.0/0"],
            wireGuardPersistentKeepAlive: 16,
            wireGuardMTU: 1420,
            wireGuardDNSServers: ["172.16.4.15", "172.16.30.15"],
            remarks: "WG"
        )
        let secret = VPNProfileSecret(wireGuardPrivateKey: "PRIVATEKEY=", wireGuardPreSharedKey: "PRESHAREDKEY=")

        let config = try WireGuardQuickConfigBuilder().makeQuickConfig(
            for: ResolvedVPNProfile(profile: profile, secret: secret)
        )

        #expect(config.contains("[Interface]"))
        #expect(config.contains("PrivateKey = PRIVATEKEY="))
        #expect(config.contains("Address = 10.3.61.120/32"))
        #expect(config.contains("DNS = 172.16.4.15, 172.16.30.15"))
        #expect(config.contains("MTU = 1420"))
        #expect(config.contains("[Peer]"))
        #expect(config.contains("PublicKey = PEERPUBLICKEY="))
        #expect(config.contains("PresharedKey = PRESHAREDKEY="))
        #expect(config.contains("Endpoint = vpn.example.com:51820"))
        #expect(config.contains("AllowedIPs = 0.0.0.0/0"))
        #expect(config.contains("PersistentKeepalive = 16"))
    }

    @Test func wireGuardQuickConfigReparsesToEquivalentProfile() throws {
        // The wg-quick string we hand to WireGuardKit must be valid and complete. Re-parsing
        // it through our own parser is a strong round-trip sanity check.
        let profile = VPNProfile(
            protocolType: .wireguard,
            host: "vpn.example.com",
            port: 51820,
            security: .none,
            networkType: .tcp,
            wireGuardPeerPublicKey: "PEERPUBLICKEY=",
            wireGuardLocalAddresses: ["10.3.61.120/32"],
            wireGuardAllowedIPs: ["0.0.0.0/0"],
            wireGuardPersistentKeepAlive: 16,
            wireGuardMTU: 1420,
            wireGuardDNSServers: ["172.16.4.15"],
            remarks: "WG"
        )
        let secret = VPNProfileSecret(wireGuardPrivateKey: "PRIVATEKEY=", wireGuardPreSharedKey: "PRESHAREDKEY=")

        let config = try WireGuardQuickConfigBuilder().makeQuickConfig(
            for: ResolvedVPNProfile(profile: profile, secret: secret)
        )
        let (reparsed, reparsedSecret) = try VPNConfigurationParser().parse(config)

        #expect(reparsed.protocolType == .wireguard)
        #expect(reparsed.host == "vpn.example.com")
        #expect(reparsed.port == 51820)
        #expect(reparsed.wireGuardPeerPublicKey == "PEERPUBLICKEY=")
        #expect(reparsed.wireGuardLocalAddresses == ["10.3.61.120/32"])
        #expect(reparsed.wireGuardDNSServers == ["172.16.4.15"])
        #expect(reparsed.wireGuardMTU == 1420)
        #expect(reparsed.wireGuardPersistentKeepAlive == 16)
        #expect(reparsedSecret.wireGuardPrivateKey == "PRIVATEKEY=")
        #expect(reparsedSecret.wireGuardPreSharedKey == "PRESHAREDKEY=")
    }

    @Test func parsesSingBoxVLESSWebSocketJSONConfiguration() throws {
        let config = """
        {
          "outbounds": [
            {
              "tag": "direct",
              "type": "direct"
            },
            {
              "tag": "proxy",
              "type": "vless",
              "server": "vpn.netlumavpn.example",
              "server_port": 443,
              "uuid": "22222222-2222-2222-2222-222222222222",
              "flow": "",
              "tls": {
                "enabled": true,
                "server_name": "vpn.netlumavpn.example",
                "alpn": ["http/1.1"],
                "utls": {
                  "enabled": true,
                  "fingerprint": "chrome"
                }
              },
              "transport": {
                "type": "ws",
                "path": "/example-websocket-path",
                "headers": {
                  "Host": "vpn.netlumavpn.example"
                }
              }
            }
          ]
        }
        """

        let (profile, secret) = try VPNConfigurationParser().parse(config)

        #expect(profile.protocolType == .vless)
        #expect(profile.host == "vpn.netlumavpn.example")
        #expect(profile.port == 443)
        #expect(profile.security == .tls)
        #expect(profile.networkType == .ws)
        #expect(profile.path == "/example-websocket-path")
        #expect(profile.transportHost == "vpn.netlumavpn.example")
        #expect(profile.sni == "vpn.netlumavpn.example")
        #expect(profile.tlsFingerprint == "chrome")
        #expect(profile.tlsALPN == ["http/1.1"])
        #expect(secret.userId == "22222222-2222-2222-2222-222222222222")
    }

    @Test func parsesSingBoxTrojanWebSocketJSONConfiguration() throws {
        let config = """
        {
          "outbounds": [
            {
              "tag": "proxy",
              "type": "trojan",
              "server": "vpn.netlumavpn.example",
              "server_port": 443,
              "password": "test-password",
              "tls": {
                "enabled": true,
                "server_name": "vpn.netlumavpn.example"
              },
              "transport": {
                "type": "ws",
                "path": "/qJt70CthfCVnNk7bojBbRPilA5xNnK"
              }
            }
          ]
        }
        """

        let (profile, secret) = try VPNConfigurationParser().parse(config)

        #expect(profile.protocolType == .trojan)
        #expect(profile.networkType == .ws)
        #expect(profile.path == "/qJt70CthfCVnNk7bojBbRPilA5xNnK")
        #expect(secret.password == "test-password")
    }

    @Test func buildsXrayOutboundConfig() throws {
        let profile = VPNProfile(
            protocolType: .trojan,
            host: "vpn.example.com",
            port: 443,
            security: .tls,
            networkType: .tcp,
            sni: "vpn.example.com",
            remarks: "Office"
        )
        let resolved = ResolvedVPNProfile(
            profile: profile,
            secret: VPNProfileSecret(password: "test-password")
        )

        let data = try XrayConfigBuilder().buildConfigData(for: resolved)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        let outbound = try #require(outbounds.first)

        #expect(outbound["protocol"] as? String == "trojan")
    }

    @Test func buildsVLESSRealityOutboundConfig() throws {
        let profile = VPNProfile(
            protocolType: .vless,
            host: "example.com",
            port: 443,
            security: .reality,
            networkType: .tcp,
            sni: "example.com",
            flow: "xtls-rprx-vision",
            realityPublicKey: "public-key",
            realityFingerprint: "chrome",
            realityShortID: "0a1b2c",
            realitySpiderX: "/",
            remarks: "Office"
        )
        let resolved = ResolvedVPNProfile(
            profile: profile,
            secret: VPNProfileSecret(userId: "00000000-0000-4000-8000-000000000017")
        )

        let data = try XrayConfigBuilder().buildConfigData(for: resolved)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        let outbound = try #require(outbounds.first)
        let streamSettings = try #require(outbound["streamSettings"] as? [String: Any])
        let realitySettings = try #require(streamSettings["realitySettings"] as? [String: Any])
        let settings = try #require(outbound["settings"] as? [String: Any])
        let vnext = try #require(settings["vnext"] as? [[String: Any]])
        let server = try #require(vnext.first)
        let users = try #require(server["users"] as? [[String: Any]])
        let user = try #require(users.first)

        #expect(streamSettings["security"] as? String == "reality")
        #expect(realitySettings["publicKey"] as? String == "public-key")
        #expect(realitySettings["fingerprint"] as? String == "chrome")
        #expect(realitySettings["shortId"] as? String == "0a1b2c")
        #expect(user["flow"] as? String == "xtls-rprx-vision")
    }

    @Test func buildsProvidedTrojanGRPCOutboundConfig() throws {
        let outbound = try outboundConfig(from: providedTrojanGRPCURL)
        let streamSettings = try #require(outbound["streamSettings"] as? [String: Any])
        let tlsSettings = try #require(streamSettings["tlsSettings"] as? [String: Any])
        let grpcSettings = try #require(streamSettings["grpcSettings"] as? [String: Any])

        #expect(outbound["protocol"] as? String == "trojan")
        #expect(streamSettings["network"] as? String == "grpc")
        #expect(tlsSettings["serverName"] as? String == "node1.example-vpn.test")
        #expect(grpcSettings["serviceName"] as? String == "/2053/ExampleGrpcServicePathToken000")
        #expect(grpcSettings["authority"] as? String == "node1.example-vpn.test")
    }

    @Test func buildsProvidedVLESSHTTPUpgradeOutboundConfig() throws {
        let outbound = try outboundConfig(from: providedVLESSHTTPUpgradeURL)
        let streamSettings = try #require(outbound["streamSettings"] as? [String: Any])
        let httpUpgradeSettings = try #require(streamSettings["httpupgradeSettings"] as? [String: Any])

        #expect(outbound["protocol"] as? String == "vless")
        #expect(streamSettings["network"] as? String == "httpupgrade")
        #expect(httpUpgradeSettings["path"] as? String == "/2073/ExampleHttpUpgradePathToken000")
        #expect(httpUpgradeSettings["host"] as? String == "node1.example-vpn.test")
    }

    @Test func buildsProvidedVLESSWebSocketOutboundConfig() throws {
        let outbound = try outboundConfig(from: providedVLESSWSURL)
        let streamSettings = try #require(outbound["streamSettings"] as? [String: Any])
        let wsSettings = try #require(streamSettings["wsSettings"] as? [String: Any])
        let headers = try #require(wsSettings["headers"] as? [String: String])

        #expect(outbound["protocol"] as? String == "vless")
        #expect(streamSettings["network"] as? String == "ws")
        #expect(wsSettings["path"] as? String == "/2083/ExampleWebsocketPathToken00000")
        #expect(headers["Host"] == "node1.example-vpn.test")
    }

    @Test func buildsProvidedVLESSXTLSOutboundConfig() throws {
        let outbound = try outboundConfig(from: providedVLESSXTLSURL)
        let streamSettings = try #require(outbound["streamSettings"] as? [String: Any])
        let tlsSettings = try #require(streamSettings["tlsSettings"] as? [String: Any])
        let settings = try #require(outbound["settings"] as? [String: Any])
        let vnext = try #require(settings["vnext"] as? [[String: Any]])
        let server = try #require(vnext.first)
        let users = try #require(server["users"] as? [[String: Any]])
        let user = try #require(users.first)

        #expect(streamSettings["network"] as? String == "tcp")
        #expect(tlsSettings["serverName"] as? String == "www.node1.example-vpn.test")
        #expect(tlsSettings["fingerprint"] as? String == "chrome")
        #expect(tlsSettings["alpn"] as? [String] == ["http/1.1"])
        #expect(user["flow"] as? String == "xtls-rprx-vision")
    }

    @Test func buildsWireGuardOutboundConfig() throws {
        let outbound = try outboundConfig(from: providedWireGuardConfig)
        let settings = try #require(outbound["settings"] as? [String: Any])
        let peers = try #require(settings["peers"] as? [[String: Any]])
        let peer = try #require(peers.first)

        #expect(outbound["protocol"] as? String == "wireguard")
        #expect(outbound["streamSettings"] == nil)
        #expect(settings["secretKey"] as? String == "private-key")
        #expect(settings["address"] as? [String] == ["10.7.0.2/32", "fd42:42:42::2/128"])
        #expect(settings["noKernelTun"] as? Bool == true)
        #expect(settings["domainStrategy"] as? String == "ForceIP")
        #expect(settings["mtu"] as? Int == 1280)
        #expect(settings["reserved"] as? [Int] == [1, 2, 3])
        #expect(peer["endpoint"] as? String == "wg.example.com:51820")
        #expect(peer["publicKey"] as? String == "peer-public-key")
        #expect(peer["preSharedKey"] as? String == "pre-shared-key")
        #expect(peer["keepAlive"] as? Int == 25)
        #expect(peer["allowedIPs"] as? [String] == ["0.0.0.0/0", "::/0"])
    }

    @Test func realTunnelNetworkSettingsInstallDefaultRoutesAndDNS() throws {
        let preferences = NetworkPreferences(
            tunnel: TunnelPreferences(ipMode: .ipv4AndIPv6)
        )
        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: preferences
        )
        let ipv4Settings = try #require(settings.ipv4Settings)
        let ipv6Settings = try #require(settings.ipv6Settings)
        let dnsSettings = try #require(settings.dnsSettings)

        let hasIPv4DefaultRoute = ipv4Settings.includedRoutes?.contains { route in
            route.destinationAddress == "0.0.0.0" && route.destinationSubnetMask == "0.0.0.0"
        } ?? false

        #expect(settings.tunnelRemoteAddress == "127.0.0.1")
        #expect(hasIPv4DefaultRoute)
        #expect((ipv6Settings.includedRoutes?.isEmpty ?? true) == false)
        #expect(dnsSettings.servers == TunnelNetworkSettingsBuilder.dnsServers)
        #expect(dnsSettings.matchDomains == [""])
    }

    @Test func defaultTunnelNetworkSettingsUseIPv4Only() throws {
        let settings = TunnelNetworkSettingsBuilder().makeSettings(routesDefaultTraffic: true)
        let ipv4Settings = try #require(settings.ipv4Settings)

        #expect(ipv4Settings.includedRoutes?.isEmpty == false)
        #expect(settings.ipv6Settings == nil)
    }

    @Test func mockTunnelNetworkSettingsDoNotCaptureDefaultTraffic() throws {
        let preferences = NetworkPreferences(
            tunnel: TunnelPreferences(ipMode: .ipv4AndIPv6)
        )
        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: false,
            preferences: preferences
        )
        let ipv4Settings = try #require(settings.ipv4Settings)
        let ipv6Settings = try #require(settings.ipv6Settings)

        #expect(ipv4Settings.includedRoutes?.isEmpty ?? true)
        #expect(ipv6Settings.includedRoutes?.isEmpty ?? true)
        #expect(settings.dnsSettings == nil)
    }

    @Test func wireGuardDNSOverrideUsesConfigResolversAndRoutesThemThroughTunnel() throws {
        let resolvers = ["172.16.4.15", "172.16.30.15", "172.16.10.15"]
        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: NetworkPreferences(),
            dnsOverrideServers: resolvers
        )

        let dnsSettings = try #require(settings.dnsSettings)
        #expect(dnsSettings.servers == resolvers)
        #expect(dnsSettings.matchDomains == [""])

        let ipv4Settings = try #require(settings.ipv4Settings)
        // The internal resolvers sit inside 172.16/12, which is excluded as LAN. Each one
        // must have a /32 included route so it overrides the exclude and reaches the tunnel.
        for resolver in resolvers {
            let hasHostRoute = ipv4Settings.includedRoutes?.contains { route in
                route.destinationAddress == resolver && route.destinationSubnetMask == "255.255.255.255"
            } ?? false
            #expect(hasHostRoute)
        }
        // The default route and the LAN-bypass excludes are still installed.
        let hasDefaultRoute = ipv4Settings.includedRoutes?.contains { route in
            route.destinationAddress == "0.0.0.0" && route.destinationSubnetMask == "0.0.0.0"
        } ?? false
        #expect(hasDefaultRoute)
        #expect(ipv4Settings.excludedRoutes?.isEmpty == false)
    }

    @Test func wireGuardDNSOverrideIsIgnoredWhenNotRoutingDefaultTraffic() throws {
        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: false,
            dnsOverrideServers: ["172.16.4.15"]
        )

        #expect(settings.dnsSettings == nil)
    }

    @Test func networkDiagnosticsFlagAcceptsDirectAndPrefixedEnvironment() {
        #expect(Self.networkTestsEnabled(environment: ["RUN_NETWORK_TESTS": "1"]))
        #expect(Self.networkTestsEnabled(environment: ["TEST_RUNNER_RUN_NETWORK_TESTS": "1"]))
        #expect(Self.networkTestsEnabled(environment: [:]) == false)
    }

    @Test func providedRealityServerIsTCPReachableWhenNetworkTestsEnabled() async throws {
        guard Self.networkTestsEnabled else {
            return
        }

        let (profile, _) = try VPNConfigurationParser().parse(providedRealityURL)
        let isReachable = await ConnectionDiagnostics().checkTCPReachability(
            host: profile.host,
            port: profile.port
        )

        #expect(isReachable)
    }

    @Test func internetProbeWorksWhenNetworkTestsEnabled() async {
        guard Self.networkTestsEnabled else {
            return
        }

        let isReachable = await ConnectionDiagnostics().checkInternetReachability()

        #expect(isReachable)
    }

    @Test func publicIPAddressProbeWorksWhenNetworkTestsEnabled() async throws {
        guard Self.networkTestsEnabled else {
            return
        }

        let ipAddress = try #require(await ConnectionDiagnostics().fetchPublicIPAddress())
        if let expectedIPAddress = Self.expectedEgressIPAddress {
            #expect(ipAddress == expectedIPAddress)
        } else {
            #expect(ipAddress.contains(".") || ipAddress.contains(":"))
        }
    }

    private static var networkTestsEnabled: Bool {
        networkTestsEnabled(environment: ProcessInfo.processInfo.environment)
    }

    private static func networkTestsEnabled(environment: [String: String]) -> Bool {
        environment["RUN_NETWORK_TESTS"] == "1"
        || environment["TEST_RUNNER_RUN_NETWORK_TESTS"] == "1"
    }

    private static var expectedEgressIPAddress: String? {
        let environment = ProcessInfo.processInfo.environment
        return environment["NETLUMAVPN_EXPECTED_EGRESS_IP"]?.nilIfBlank
        ?? environment["TEST_RUNNER_NETLUMAVPN_EXPECTED_EGRESS_IP"]?.nilIfBlank
    }

    private func outboundConfig(from importURL: String) throws -> [String: Any] {
        let (profile, secret) = try VPNConfigurationParser().parse(importURL)
        let data = try XrayConfigBuilder().buildConfigData(
            for: ResolvedVPNProfile(profile: profile, secret: secret)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try #require(json["outbounds"] as? [[String: Any]])
        return try #require(outbounds.first)
    }
}
