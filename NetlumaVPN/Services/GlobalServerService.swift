import Foundation

protocol GlobalServerServicing {
    func fetchServers() async throws -> [GlobalVPNServer]
    func provisionProfile(for server: GlobalVPNServer) async throws -> (VPNProfile, VPNProfileSecret)
}

struct GlobalServerService: GlobalServerServicing {
    private let apiClient: GlobalServerAPIClient
    private let parser: VPNConfigurationParser

    init(
        apiClient: GlobalServerAPIClient = GlobalServerAPIClient(),
        parser: VPNConfigurationParser = VPNConfigurationParser()
    ) {
        self.apiClient = apiClient
        self.parser = parser
    }

    func fetchServers() async throws -> [GlobalVPNServer] {
        try await apiClient.fetchServers()
    }

    func provisionProfile(for server: GlobalVPNServer) async throws -> (VPNProfile, VPNProfileSecret) {
        let issue = try await apiClient.issueProfile(for: server)
        guard issue.configURL.nilIfBlank != nil else {
            throw GlobalServerAPIError.invalidIssuedProfile
        }

        let rawConfig = issue.requiresConfigDownload
            ? try await apiClient.downloadConfig(for: issue)
            : issue.configURL
        var (profile, secret) = try parser.parse(rawConfig)
        profile.origin = .netlumaVPNGlobal
        profile.managedServerID = server.id
        profile.remarks = server.profileRemarks
        profile.updatedAt = Date()
        return (profile, secret)
    }
}
