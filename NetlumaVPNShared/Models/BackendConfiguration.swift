import Foundation

/// Deployment values are supplied by an ignored Backend.local.plist, never source control.
struct BackendConfiguration {
    let mobileAPIBaseURL: String
    let mobileClientKey: String
    let mobileTLSCertificateSHA256Base64: String

    init(data: Data?) {
        if let data,
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           let baseURL = values["mobileAPIBaseURL"],
           let url = URL(string: baseURL),
           url.scheme == "https", url.host?.isEmpty == false,
           url.user == nil, url.password == nil {
            mobileAPIBaseURL = baseURL
            mobileClientKey = values["mobileClientKey"] ?? ""
            mobileTLSCertificateSHA256Base64 = values["mobileTLSCertificateSHA256Base64"] ?? ""
        } else {
            mobileAPIBaseURL = "https://api.netlumavpn.example"
            mobileClientKey = ""
            mobileTLSCertificateSHA256Base64 = ""
        }
    }
}
