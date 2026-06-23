import Foundation
import NetworkExtension
import Testing
@testable import NetlumaVPN

struct NetworkPreferencesTests {
    @Test func storageRoundTripsTunnelAndDNSPreferences() {
        let suiteName = "NetlumaVPNTests-\(UUID().uuidString)"
        let appGroupStorage = AppGroupStorage(suiteName: suiteName)
        let storage = NetworkPreferencesStorage(appGroupStorage: appGroupStorage)
        defer {
            appGroupStorage.removeObject(forKey: AppConstants.AppGroupKeys.networkPreferences)
        }

        let preferences = NetworkPreferences(
            tunnel: TunnelPreferences(
                persistTunnel: true,
                ipMode: .ipv4Only,
                onDemandMode: .always,
                includeAllNetworks: true
            ),
            selectedDNSResolverID: "dot-cloudflare-ipv4"
        )

        storage.save(preferences)

        #expect(storage.load() == preferences)
    }

    @Test func tunnelBuilderUsesSelectedDoHResolver() throws {
        let preferences = NetworkPreferences(
            selectedDNSResolverID: "doh-google-ipv4"
        )

        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: preferences
        )
        let dnsSettings = try #require(settings.dnsSettings as? NEDNSOverHTTPSSettings)

        #expect(dnsSettings.servers == ["8.8.8.8"])
        #expect(dnsSettings.matchDomains == [""])
        #expect(dnsSettings.serverURL?.absoluteString == "https://dns.google/dns-query")
    }

    @Test func tunnelBuilderUsesSelectedDoTResolver() throws {
        let preferences = NetworkPreferences(
            selectedDNSResolverID: "dot-cloudflare-ipv6"
        )

        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: preferences
        )
        let dnsSettings = try #require(settings.dnsSettings as? NEDNSOverTLSSettings)

        #expect(dnsSettings.servers == ["2606:4700:4700::1111"])
        #expect(dnsSettings.matchDomains == [""])
        #expect(dnsSettings.serverName == "cloudflare-dns.com")
    }

    @Test func tunnelBuilderHonorsIPv4OnlyMode() throws {
        let preferences = NetworkPreferences(
            tunnel: TunnelPreferences(ipMode: .ipv4Only)
        )

        let settings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: preferences
        )
        let ipv4Settings = try #require(settings.ipv4Settings)

        #expect(ipv4Settings.includedRoutes?.isEmpty == false)
        #expect(settings.ipv6Settings == nil)
    }

    @Test func tunnelBuilderLeavesPrivateRoutesExcludedUnlessAllNetworksIsEnabled() throws {
        let splitPreferences = NetworkPreferences(
            tunnel: TunnelPreferences(includeAllNetworks: false)
        )
        let splitSettings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: splitPreferences
        )
        let splitIPv4Settings = try #require(splitSettings.ipv4Settings)

        let allNetworksPreferences = NetworkPreferences(
            tunnel: TunnelPreferences(includeAllNetworks: true)
        )
        let allNetworksSettings = TunnelNetworkSettingsBuilder().makeSettings(
            routesDefaultTraffic: true,
            preferences: allNetworksPreferences
        )
        let allNetworksIPv4Settings = try #require(allNetworksSettings.ipv4Settings)

        #expect(splitIPv4Settings.excludedRoutes?.isEmpty == false)
        #expect((allNetworksIPv4Settings.excludedRoutes?.isEmpty ?? true))
    }

    @Test func sessionInfoResponseMapsIPv4Address() {
        let response = IPAPISessionResponse(
            ip: "192.0.2.10",
            asn: "AS3216",
            org: "PJSC VimpelCom",
            countryCode: "RU",
            city: "Novosibirsk",
            region: "Novosibirsk Oblast",
            latitude: 55.02259,
            longitude: 82.93175
        )

        let info = SessionInfo(response: response)

        #expect(info.ipv4 == "192.0.2.10")
        #expect(info.ipv6 == nil)
        #expect(info.asn == "AS3216")
        #expect(info.organization == "PJSC VimpelCom")
        #expect(info.countryCode == "RU")
        #expect(info.city == "Novosibirsk")
        #expect(info.region == "Novosibirsk Oblast")
        #expect(info.latitude == 55.02259)
        #expect(info.longitude == 82.93175)
    }

    @Test func sessionInfoResponseMapsIPv6Address() {
        let response = IPAPISessionResponse(
            ip: "2606:4700:4700::1111",
            asn: nil,
            org: nil,
            countryCode: nil,
            city: nil,
            region: nil,
            latitude: nil,
            longitude: nil
        )

        let info = SessionInfo(response: response)

        #expect(info.ipv4 == nil)
        #expect(info.ipv6 == "2606:4700:4700::1111")
    }
}
