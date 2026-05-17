import SwiftUI

struct PremiumPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    let showsCloseButton: Bool
    let primaryButtonTitle: String
    let footnote: String
    let onContinue: (() -> Void)?

    @State private var selectedPlan: PremiumPlan = .annual
    @State private var placeholderMessage: PremiumPlaceholderMessage?

    init(
        showsCloseButton: Bool = true,
        primaryButtonTitle: String = "Continue",
        footnote: String = "Placeholder only. No payment will be started until StoreKit is wired.",
        onContinue: (() -> Void)? = nil
    ) {
        self.showsCloseButton = showsCloseButton
        self.primaryButtonTitle = primaryButtonTitle
        self.footnote = footnote
        self.onContinue = onContinue
    }

    var body: some View {
        ZStack {
            QuickVPNTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    closeBar
                    hero
                    featureList
                    planPicker
                    actionBlock
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .alert(
            "Purchases are not connected yet",
            isPresented: Binding(
                get: { placeholderMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        placeholderMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                placeholderMessage = nil
            }
        } message: {
            Text(placeholderMessage?.message ?? "")
        }
    }

    @ViewBuilder
    private var closeBar: some View {
        if showsCloseButton {
            HStack {
                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(QuickVPNTheme.card, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Premium")
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(QuickVPNTheme.accent.opacity(0.16))
                    .frame(width: 82, height: 82)

                Circle()
                    .stroke(QuickVPNTheme.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: 82, height: 82)

                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.accent)
            }

            VStack(spacing: 7) {
                Text("QuickVPN Premium")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text("Unlock global locations, smarter tools, and deeper connection insights.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var featureList: some View {
        QuickVPNCard {
            VStack(spacing: 0) {
                PremiumFeatureRow(
                    icon: "server.rack",
                    iconColor: QuickVPNTheme.blue,
                    title: "Global servers",
                    subtitle: "Fast locations for travel and daily routing."
                )

                divider

                PremiumFeatureRow(
                    icon: "sparkles",
                    iconColor: QuickVPNTheme.accent,
                    title: "Smart protocol picks",
                    subtitle: "Recommended profiles for the current network."
                )

                divider

                PremiumFeatureRow(
                    icon: "chart.xyaxis.line",
                    iconColor: QuickVPNTheme.warning,
                    title: "Traffic statistics",
                    subtitle: "Session history and usage snapshots."
                )

                divider

                PremiumFeatureRow(
                    icon: "point.topleft.down.curvedto.point.bottomright.up",
                    iconColor: QuickVPNTheme.purple,
                    title: "Proxy sharing",
                    subtitle: "Share your protected tunnel with nearby devices."
                )
            }
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            ForEach(PremiumPlan.allCases) { plan in
                Button {
                    selectedPlan = plan
                } label: {
                    PremiumPlanRow(plan: plan, isSelected: selectedPlan == plan)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionBlock: some View {
        VStack(spacing: 12) {
            Button {
                if let onContinue {
                    onContinue()
                } else {
                    placeholderMessage = .purchase(selectedPlan)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(primaryButtonTitle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .heavy))
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(QuickVPNTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(QuickVPNTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            legalLinks

            Button {
                placeholderMessage = .restore
            } label: {
                Text("Restore Purchase")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)

            Text(footnote)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(QuickVPNTheme.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var legalLinks: some View {
        HStack(spacing: 8) {
            NavigationLink {
                LegalDocumentView(document: .terms)
            } label: {
                Text("Terms of Use")
            }

            Text("•")

            NavigationLink {
                LegalDocumentView(document: .privacy)
            } label: {
                Text("Privacy Policy")
            }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(QuickVPNTheme.secondaryText)
        .tint(QuickVPNTheme.secondaryText)
        .frame(minHeight: 24)
    }

    private var divider: some View {
        Rectangle()
            .fill(QuickVPNTheme.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 60)
    }
}

private struct PremiumFeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct PremiumPlanRow: View {
    let plan: PremiumPlan
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.mutedText)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(plan.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                        .lineLimit(1)

                    if let badge = plan.badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(QuickVPNTheme.accent, in: Capsule())
                    }
                }

                Text(plan.subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer()

            Text(plan.price)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(QuickVPNTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
        .background(
            isSelected ? QuickVPNTheme.accent.opacity(0.14) : QuickVPNTheme.card,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.borderSubtle, lineWidth: 1)
        }
    }
}

private enum PremiumPlan: String, CaseIterable, Identifiable {
    case monthly
    case annual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly:
            "Monthly"
        case .annual:
            "Annual"
        }
    }

    var subtitle: String {
        switch self {
        case .monthly:
            "Flexible access, cancel anytime"
        case .annual:
            "Best value for everyday protection"
        }
    }

    var price: String {
        switch self {
        case .monthly:
            "$6.99"
        case .annual:
            "$39.99"
        }
    }

    var badge: String? {
        switch self {
        case .monthly:
            nil
        case .annual:
            "SAVE 52%"
        }
    }
}

private enum PremiumPlaceholderMessage {
    case purchase(PremiumPlan)
    case restore

    var message: String {
        switch self {
        case .purchase(let plan):
            "The \(plan.title.lowercased()) plan is selected, but the purchase flow is stubbed for now."
        case .restore:
            "Restore is a placeholder until real subscription handling is added."
        }
    }
}

#Preview {
    NavigationStack {
        PremiumPaywallView()
    }
}
