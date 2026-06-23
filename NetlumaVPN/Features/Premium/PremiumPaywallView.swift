import SwiftUI

struct PremiumPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    let plans: [PremiumSubscriptionPlan]
    let isLoadingProducts: Bool
    let isPurchasing: Bool
    let productsErrorMessage: String?
    let showsCloseButton: Bool
    let showsStepDots: Bool
    let onClose: (() -> Void)?
    let onPurchase: (String) -> Void
    let onRestore: () -> Void
    let onRetry: (() -> Void)?

    @State private var selectedProductID: String?

    init(
        plans: [PremiumSubscriptionPlan] = [],
        isLoadingProducts: Bool = false,
        isPurchasing: Bool = false,
        productsErrorMessage: String? = nil,
        showsCloseButton: Bool = true,
        showsStepDots: Bool = false,
        onClose: (() -> Void)? = nil,
        onPurchase: @escaping (String) -> Void = { _ in },
        onRestore: @escaping () -> Void = {},
        onRetry: (() -> Void)? = nil
    ) {
        self.plans = plans
        self.isLoadingProducts = isLoadingProducts
        self.isPurchasing = isPurchasing
        self.productsErrorMessage = productsErrorMessage
        self.showsCloseButton = showsCloseButton
        self.showsStepDots = showsStepDots
        self.onClose = onClose
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onRetry = onRetry
    }

    var body: some View {
        ZStack {
            NetlumaVPNTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    hero
                    featureList
                    planPicker
                    actionBlock
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: selectDefaultPlanIfNeeded)
        .onChange(of: plans) { _, _ in
            selectDefaultPlanIfNeeded()
        }
    }

    private var selectedPlan: PremiumSubscriptionPlan? {
        if let selectedProductID,
           let selectedPlan = plans.first(where: { $0.productID == selectedProductID }) {
            return selectedPlan
        }

        return recommendedPlan
    }

    private var recommendedPlan: PremiumSubscriptionPlan? {
        plans.first(where: \.hasEligibleFreeTrial)
        ?? plans.first(where: { $0.kind == .annual })
        ?? plans.first
    }

    private var topBar: some View {
        HStack {
            if showsCloseButton {
                Button {
                    if let onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(NetlumaVPNTheme.card.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Close Premium"))
            } else {
                Color.clear
                    .frame(width: 32, height: 32)
            }

            Spacer()

            if showsStepDots {
                PremiumPaywallStepDots()
            } else {
                Text("Premium")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(NetlumaVPNTheme.card.opacity(0.72), in: Capsule())
            }

            Spacer()

            Button(action: onRestore) {
                Text("Restore")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 33)
                    .background(NetlumaVPNTheme.card.opacity(0.72), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing)
        }
        .frame(height: 44)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image("OnboardingPaywallIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 172, height: 172)
                .frame(width: 104, height: 104)
                .padding(.top, 4)

            VStack(spacing: 7) {
                Text("NetlumaVPN Premium")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)

                Text("Faster secure access and private browsing across all your devices.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            PremiumPaywallCheckRow(text: "Unlimited VPN speed and encrypted traffic")
            PremiumPaywallCheckRow(text: "Premium server locations")
            PremiumPaywallCheckRow(text: "Works on iPhone, iPad with one subscription")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var planPicker: some View {
        if isLoadingProducts && plans.isEmpty {
            PremiumPaywallStatusRow(
                icon: nil,
                title: "Loading App Store prices",
                subtitle: "Fetching localized products from StoreKit."
            )
        } else if plans.isEmpty {
            VStack(spacing: 10) {
                PremiumPaywallStatusRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "Plans unavailable",
                    subtitle: productsErrorMessage ?? L10n.string("Please try again later.")
                )

                if let onRetry {
                    Button(action: onRetry) {
                        HStack(spacing: 8) {
                            if isLoadingProducts {
                                ProgressView()
                                    .tint(NetlumaVPNTheme.primaryText)
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .heavy))
                            }

                            Text("Retry")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(NetlumaVPNTheme.card.opacity(0.92), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingProducts)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(plans) { plan in
                    Button {
                        selectedProductID = plan.productID
                    } label: {
                        PremiumPlanChoiceRow(
                            plan: plan,
                            savingsBadge: annualSavingsBadge(for: plan),
                            isSelected: selectedPlan?.productID == plan.productID
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionBlock: some View {
        VStack(spacing: 10) {
            Button {
                guard let selectedPlan else {
                    return
                }

                onPurchase(selectedPlan.productID)
            } label: {
                HStack(spacing: 8) {
                    if isPurchasing {
                        ProgressView()
                            .tint(NetlumaVPNTheme.onAccent)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .heavy))
                    }

                    Text(PremiumPaywallPresentation.primaryButtonTitle(for: selectedPlan))
                }
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(NetlumaVPNTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(NetlumaVPNTheme.accent, in: Capsule())
                .opacity(selectedPlan == nil || isPurchasing ? 0.72 : 1)
            }
            .buttonStyle(.plain)
            .disabled(selectedPlan == nil || isPurchasing)

            Text("Auto-renews unless canceled at least 24 hours before the trial or billing period ends.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NetlumaVPNTheme.mutedText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            PremiumPaywallLegalLinks()
        }
        .padding(.top, 4)
    }

    private func selectDefaultPlanIfNeeded() {
        guard !plans.isEmpty else {
            selectedProductID = nil
            return
        }

        if let selectedProductID,
           plans.contains(where: { $0.productID == selectedProductID }) {
            return
        }

        selectedProductID = recommendedPlan?.productID
    }

    private func annualSavingsBadge(for plan: PremiumSubscriptionPlan) -> String? {
        guard plan.kind == .annual,
              let annualPrice = plan.price,
              let monthlyPrice = plans.first(where: { $0.kind == .monthly })?.price,
              monthlyPrice > 0 else {
            return plan.badge
        }

        let yearlyMonthlyPrice = monthlyPrice * Decimal(12)
        guard yearlyMonthlyPrice > annualPrice else {
            return plan.badge
        }

        let savings = (yearlyMonthlyPrice - annualPrice) / yearlyMonthlyPrice
        let percent = NSDecimalNumber(decimal: savings * Decimal(100)).intValue
        guard percent > 0 else {
            return plan.badge
        }

        return L10n.format("SAVE %d%%", percent)
    }
}

private struct PremiumPaywallStepDots: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(NetlumaVPNTheme.border)
                .frame(width: 6, height: 6)
            Circle()
                .fill(NetlumaVPNTheme.border)
                .frame(width: 6, height: 6)
            Capsule()
                .fill(NetlumaVPNTheme.accent)
                .frame(width: 18, height: 6)
        }
    }
}

private struct PremiumPaywallCheckRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.accent)

            Text(L10n.string(text))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PremiumPlanChoiceRow: View {
    let plan: PremiumSubscriptionPlan
    let savingsBadge: String?
    let isSelected: Bool

    private var isTrialPlan: Bool {
        plan.hasEligibleFreeTrial
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(plan.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)

                    if let badge = isTrialPlan ? plan.badge : savingsBadge {
                        Text(badge)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(isTrialPlan ? NetlumaVPNTheme.onAccent : NetlumaVPNTheme.blue)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(
                                isTrialPlan ? NetlumaVPNTheme.accent : NetlumaVPNTheme.blue.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                }

                Text(plan.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(isTrialPlan ? L10n.string("TRIAL") : plan.displayPrice)
                .font(.system(size: isTrialPlan ? 11 : 17, weight: .heavy))
                .foregroundStyle(isTrialPlan ? NetlumaVPNTheme.onAccent : NetlumaVPNTheme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, isTrialPlan ? 10 : 0)
                .frame(height: isTrialPlan ? 26 : nil)
                .background(
                    isTrialPlan ? NetlumaVPNTheme.accent : Color.clear,
                    in: Capsule()
                )
        }
        .padding(.horizontal, 14)
        .frame(minHeight: isTrialPlan ? 72 : 68)
        .background(
            isTrialPlan && isSelected ? Color(hex: "#10251F") : NetlumaVPNTheme.card.opacity(0.92),
            in: RoundedRectangle(cornerRadius: isTrialPlan ? 20 : 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: isTrialPlan ? 20 : 18, style: .continuous)
                .stroke(isSelected ? NetlumaVPNTheme.accent : NetlumaVPNTheme.borderSubtle, lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct PremiumPaywallStatusRow: View {
    let icon: String?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.warning)
                    .frame(width: 34, height: 34)
            } else {
                ProgressView()
                    .tint(NetlumaVPNTheme.accent)
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(title))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                Text(L10n.string(subtitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(NetlumaVPNTheme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
        }
    }
}

private struct PremiumPaywallLegalLinks: View {
    var body: some View {
        HStack(spacing: 6) {
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
        .foregroundStyle(NetlumaVPNTheme.secondaryText)
        .tint(NetlumaVPNTheme.secondaryText)
    }
}

#Preview {
    NavigationStack {
        PremiumPaywallView(
            plans: [
                PremiumSubscriptionPlan(
                    kind: .weekly,
                    displayName: "Weekly Premium",
                    displayPrice: "$4.99",
                    price: Decimal(4.99),
                    isEligibleForIntroOffer: true,
                    introductoryOffer: PremiumIntroOffer(
                        paymentMode: .freeTrial,
                        periodValue: 3,
                        periodUnit: .day,
                        periodCount: 1
                    )
                ),
                PremiumSubscriptionPlan(
                    kind: .monthly,
                    displayName: "Monthly Premium",
                    displayPrice: "$9.99",
                    price: Decimal(9.99),
                    isEligibleForIntroOffer: false,
                    introductoryOffer: nil
                ),
                PremiumSubscriptionPlan(
                    kind: .annual,
                    displayName: "Annual Premium",
                    displayPrice: "$49.99",
                    price: Decimal(49.99),
                    isEligibleForIntroOffer: false,
                    introductoryOffer: nil
                )
            ],
            showsStepDots: true
        )
    }
}
