import SwiftUI

struct ProfileListView: View {
    let profiles: [VPNProfile]
    let selectedProfileID: UUID?
    let onSelect: (VPNProfile) -> Void
    let onEdit: (VPNProfile) -> Void
    let onDelete: (VPNProfile) -> Void

    var body: some View {
        Section("Profiles") {
            if profiles.isEmpty {
                ContentUnavailableView(
                    "No Profiles",
                    systemImage: "server.rack",
                    description: Text("Add a permitted VPN server configuration to begin.")
                )
            } else {
                ForEach(profiles) { profile in
                    ProfileRowView(
                        profile: profile,
                        isSelected: profile.id == selectedProfileID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(profile)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            onDelete(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            onEdit(profile)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
    }
}

private struct ProfileRowView: View {
    let profile: VPNProfile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.headline)
                Text("\(profile.protocolType.title) · \(profile.displayEndpoint)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(profile.transportSummaryTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension VPNProfile {
    var transportSummaryTitle: String {
        protocolType == .wireguard ? "UDP" : networkType.title
    }
}
