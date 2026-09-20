import Foundation
import Testing
@testable import NetlumaVPN

struct BackendConfigurationTests {
    @Test func missingConfigurationUsesNoCredentials() {
        let configuration = BackendConfiguration(data: nil)
        #expect(configuration.mobileAPIBaseURL == "https://api.netlumavpn.example")
        #expect(configuration.mobileClientKey.isEmpty)
        #expect(configuration.mobileTLSCertificateSHA256Base64.isEmpty)
    }

    @Test func localConfigurationLoadsDeploymentValues() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "mobileAPIBaseURL": "https://backend.example/api",
            "mobileClientKey": "unit-test-key",
            "mobileTLSCertificateSHA256Base64": "unit-test-pin"
        ], format: .xml, options: 0)
        let configuration = BackendConfiguration(data: data)
        #expect(configuration.mobileAPIBaseURL == "https://backend.example/api")
        #expect(configuration.mobileClientKey == "unit-test-key")
        #expect(configuration.mobileTLSCertificateSHA256Base64 == "unit-test-pin")
    }

    @Test(arguments: ["http://backend.example", "not a URL", "https://user:password@backend.example"])
    func unsafeURLsDiscardCredentials(_ baseURL: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "mobileAPIBaseURL": baseURL,
            "mobileClientKey": "unit-test-key"
        ], format: .xml, options: 0)
        let configuration = BackendConfiguration(data: data)
        #expect(configuration.mobileAPIBaseURL == "https://api.netlumavpn.example")
        #expect(configuration.mobileClientKey.isEmpty)
    }

    @Test func malformedConfigurationUsesNoCredentials() {
        let configuration = BackendConfiguration(data: Data("invalid plist".utf8))
        #expect(configuration.mobileClientKey.isEmpty)
        #expect(configuration.mobileAPIBaseURL == "https://api.netlumavpn.example")
    }
}
