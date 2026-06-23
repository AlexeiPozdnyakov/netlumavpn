import SwiftUI

struct SessionInfoView: View {
    @State private var sessionInfo = SessionInfo.empty
    @State private var isLoading = true

    private let service: SessionInfoService

    init(
        service: SessionInfoService = .live
    ) {
        self.service = service
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NetlumaVPNCard {
                    VStack(spacing: 0) {
                        ForEach(infoRows) { row in
                            SessionInfoRow(title: row.title, value: row.value)
                            if row.id != infoRows.last?.id {
                                Rectangle()
                                    .fill(NetlumaVPNTheme.borderSubtle)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .redacted(reason: isLoading ? .placeholder : [])
                }

                Text("Your IP address is a unique identifier associated with your online activity, similar to a return address on a letter.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(NetlumaVPNTheme.backgroundGradient)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NetlumaVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await load()
        }
    }

    private var infoRows: [SessionInfoDisplayRow] {
        [
            SessionInfoDisplayRow(title: "IPv4", value: sessionInfo.ipv4),
            SessionInfoDisplayRow(title: "IPv6", value: sessionInfo.ipv6),
            SessionInfoDisplayRow(title: "ASN", value: sessionInfo.asn),
            SessionInfoDisplayRow(title: "AS Organization", value: sessionInfo.organization),
            SessionInfoDisplayRow(title: "Country", value: sessionInfo.countryCode),
            SessionInfoDisplayRow(title: "City", value: sessionInfo.city),
            SessionInfoDisplayRow(title: "Region", value: sessionInfo.region),
            SessionInfoDisplayRow(title: "Latitude", value: sessionInfo.latitude.map { String(format: "%.5f", $0) }),
            SessionInfoDisplayRow(title: "Longitude", value: sessionInfo.longitude.map { String(format: "%.5f", $0) })
        ]
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            sessionInfo = try await service.fetch()
        } catch {
            sessionInfo = .empty
        }
    }
}

private struct SessionInfoDisplayRow: Identifiable {
    let title: String
    let value: String?

    var id: String { title }
}

private struct SessionInfoRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(L10n.string(title))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
            Spacer()
            Text(value?.nilIfBlank ?? "-")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NetlumaVPNTheme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 45)
    }
}
