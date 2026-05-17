import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = AppModel()
    @State private var selectedTab: QuickVPNTab = .home
    @State private var sheet: RootSheet?
    @State private var showsSplash = true

    var body: some View {
        ZStack {
            QuickVPNTheme.backgroundGradient
                .ignoresSafeArea()

            rootContent

            if showsSplash && model.hasCompletedOnboarding {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .tint(QuickVPNTheme.accent)
        .toolbarBackground(QuickVPNTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addProfile:
                NavigationStack {
                    ProfileEditorView(profile: nil, secret: nil) { profile, secret in
                        try model.saveProfile(profile, secret: secret)
                    }
                }
            case .editProfile(let profile):
                NavigationStack {
                    ProfileEditorView(
                        profile: profile,
                        secret: model.secret(for: profile)
                    ) { profile, secret in
                        try model.saveProfile(profile, secret: secret)
                    }
                }
            case .importProfile:
                NavigationStack {
                    ImportProfileView { value in
                        try model.importProfile(from: value)
                    }
                }
            case .scanQRCode:
                NavigationStack {
                    QRCodeImportView { value in
                        try model.importProfile(from: value)
                    }
                }
            case .premium:
                NavigationStack {
                    PremiumPaywallView()
                }
            }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }

            Task {
                await model.handlePendingWidgetAction()
                await model.loadGlobalServers()
            }
        }
        .task {
            await model.refreshStatus()
            Task {
                await model.loadGlobalServers()
            }
            await model.handlePendingWidgetAction()
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            withAnimation(.easeOut(duration: 0.28)) {
                showsSplash = false
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if model.hasCompletedOnboarding {
            appTabs
        } else {
            OnboardingView {
                withAnimation(.easeInOut(duration: 0.24)) {
                    showsSplash = false
                    model.completeOnboarding()
                }
            }
        }
    }

    @ViewBuilder
    private var appTabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(QuickVPNTab.visibleTabs) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.iconName)
                    }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: QuickVPNTab) -> some View {
        switch tab {
        case .home:
            NavigationStack {
                HomeConnectView(
                    status: model.status,
                    connectionStartedAt: model.connectionStartedAt,
                    selectedConnectionDisplayName: model.selectedConnectionDisplayName,
                    selectedProfile: model.selectedProfile,
                    profiles: model.profiles,
                    selectedProfileID: model.selectedProfileID,
                    globalServers: model.globalServers,
                    isLoadingGlobalServers: model.isLoadingGlobalServers,
                    globalServersErrorMessage: model.globalServersErrorMessage,
                    activeGlobalServerID: model.activeGlobalServerID,
                    selectedGlobalServerID: model.selectedGlobalServerID,
                    onToggleConnection: {
                        Task {
                            await model.toggleConnection()
                        }
                    },
                    onSelectProfile: model.selectProfile,
                    onEditProfile: { profile in
                        sheet = .editProfile(profile)
                    },
                    onDeleteProfile: model.deleteProfile,
                    onAddProfile: {
                        sheet = .addProfile
                    },
                    onImportProfile: {
                        sheet = .importProfile
                    },
                    onScanQRCode: {
                        sheet = .scanQRCode
                    },
                    onReloadGlobalServers: {
                        Task {
                            await model.loadGlobalServers(force: true)
                        }
                    },
                    onSelectGlobalServer: model.selectGlobalServer,
                    onOpenPremium: {
                        sheet = .premium
                    }
                )
            }
        case .servers:
            NavigationStack {
                ServersView(
                    profiles: model.profiles,
                    selectedProfileID: model.selectedProfileID,
                    onSelect: model.selectProfile,
                    onAddProfile: {
                        sheet = .addProfile
                    }
                )
            }
        case .protocols:
            NavigationStack {
                ProtocolsView(selectedProfile: model.selectedProfile)
            }
        case .settings:
            NavigationStack {
                SettingsView(model: model) {
                    sheet = .premium
                }
            }
        }
    }
}

private enum RootSheet: Identifiable {
    case addProfile
    case editProfile(VPNProfile)
    case importProfile
    case scanQRCode
    case premium

    var id: String {
        switch self {
        case .addProfile:
            "add-profile"
        case .editProfile(let profile):
            "edit-\(profile.id.uuidString)"
        case .importProfile:
            "import-profile"
        case .scanQRCode:
            "scan-qr-code"
        case .premium:
            "premium"
        }
    }
}

private struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .protocols

    var body: some View {
        NavigationStack {
            ZStack {
                QuickVPNTheme.backgroundGradient
                    .ignoresSafeArea()

                TabView(selection: $step) {
                    OnboardingProtocolsScreen(step: $step, onSkip: onComplete)
                        .tag(OnboardingStep.protocols)

                    OnboardingSecureScreen(step: $step, onSkip: onComplete)
                        .tag(OnboardingStep.secure)

                    OnboardingPaywallScreen(onComplete: onComplete)
                        .tag(OnboardingStep.paywall)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

private struct OnboardingProtocolsScreen: View {
    @Binding var step: OnboardingStep
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(currentStep: .protocols, trailingTitle: "Skip", trailingAction: onSkip)

            ScrollView {
                VStack(spacing: 18) {
                    OnboardingAssetIcon(
                        name: "OnboardingProtocolsIcon",
                        layoutSize: 88,
                        visualSize: 148
                    )
                    .padding(.top, 4)

                    VStack(spacing: 7) {
                        Text("Powerful Protocols")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                            .multilineTextAlignment(.center)

                        Text("Choose the protocol that fits you best - modern, secure, and ultra-fast.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickVPNTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 8) {
                        OnboardingProtocolRow(
                            icon: "figure.run",
                            iconColor: QuickVPNTheme.blue,
                            title: "VLESS",
                            badge: "MODERN",
                            badgeColor: QuickVPNTheme.blue,
                            subtitle: "Stealthy, low overhead, censorship resistant."
                        )

                        OnboardingProtocolRow(
                            icon: "shield.lefthalf.filled",
                            iconColor: QuickVPNTheme.purple,
                            title: "VMess",
                            badge: "FLEXIBLE",
                            badgeColor: QuickVPNTheme.purple,
                            subtitle: "Versatile masking with strong obfuscation."
                        )

                        OnboardingProtocolRow(
                            icon: "link",
                            iconColor: QuickVPNTheme.warning,
                            title: "Trojan",
                            badge: "STEALTH",
                            badgeColor: QuickVPNTheme.warning,
                            subtitle: "Imitates HTTPS - invisible to firewalls."
                        )

                        OnboardingProtocolRow(
                            icon: "bolt.fill",
                            iconColor: QuickVPNTheme.accent,
                            title: "WireGuard",
                            badge: "FASTEST",
                            badgeColor: QuickVPNTheme.accent,
                            subtitle: "Modern, lightweight, blazing fast."
                        )
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            OnboardingBottomButton(title: "Continue") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    step = .secure
                }
            }
        }
        .background(QuickVPNTheme.backgroundGradient)
    }
}

private struct OnboardingSecureScreen: View {
    @Binding var step: OnboardingStep
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(currentStep: .secure, trailingTitle: "Skip", trailingAction: onSkip)

            ScrollView {
                VStack(spacing: 18) {
                    SecureOrbitHero()
                        .padding(.top, 12)

                    VStack(spacing: 7) {
                        Text("Browse with Confidence")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                            .multilineTextAlignment(.center)

                        Text("Military-grade encryption shields every connection - Wi-Fi, mobile, anywhere.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickVPNTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 28)

                    VStack(spacing: 10) {
                        OnboardingSecureRow(
                            icon: "lock.fill",
                            iconColor: QuickVPNTheme.accent,
                            title: "End-to-end encrypted tunnel",
                            subtitle: "Nobody between you and the web."
                        )

                        OnboardingSecureRow(
                            icon: "location.slash.fill",
                            iconColor: QuickVPNTheme.blue,
                            title: "Hide your IP and location",
                            subtitle: "Stay anonymous on any network."
                        )

                        OnboardingSecureRow(
                            icon: "wifi",
                            iconColor: QuickVPNTheme.purple,
                            title: "Safe on public Wi-Fi",
                            subtitle: "Cafes, airports, hotels - fully protected."
                        )
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            OnboardingBottomButton(title: "Continue") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    step = .paywall
                }
            }
        }
        .background(QuickVPNTheme.backgroundGradient)
    }
}

private struct OnboardingPaywallScreen: View {
    let onComplete: () -> Void

    @State private var selectedPlan: OnboardingPlanOption = .weekly
    @State private var showsRestoreAlert = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingPaywallTopBar(
                currentStep: .paywall,
                onClose: onComplete,
                onRestore: {
                    showsRestoreAlert = true
                }
            )

            ScrollView {
                VStack(spacing: 14) {
                    OnboardingAssetIcon(
                        name: "OnboardingPaywallIcon",
                        layoutSize: 104,
                        visualSize: 172
                    )
                    .padding(.top, 4)

                    VStack(spacing: 6) {
                        Text("QuickVPN Premium")
                            .font(.system(size: 24, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.primaryText)
                            .multilineTextAlignment(.center)

                        Text("Faster secure access and private browsing across all your devices.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(QuickVPNTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 26)

                    VStack(alignment: .leading, spacing: 8) {
                        PaywallCheckRow(text: "Unlimited VPN speed and encrypted traffic")
                        PaywallCheckRow(text: "Premium server locations with no ads")
                        PaywallCheckRow(text: "Works on iPhone, iPad, and Mac with one subscription")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 2)

                    VStack(spacing: 10) {
                        ForEach(OnboardingPlanOption.allCases) { plan in
                            Button {
                                selectedPlan = plan
                            } label: {
                                OnboardingPlanRow(plan: plan, isSelected: selectedPlan == plan)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 2)
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 9) {
                OnboardingBottomButton(title: "Start Free Trial", icon: "sparkles") {
                    onComplete()
                }

                Text("Auto-renews unless canceled at least 24 hours before the trial or billing period ends.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(QuickVPNTheme.mutedText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                PaywallLegalLinks()
            }
            .padding(.bottom, 12)
        }
        .background(QuickVPNTheme.backgroundGradient)
        .alert("Purchases are not connected yet", isPresented: $showsRestoreAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Restore is a placeholder until real subscription handling is added.")
        }
    }
}

private struct OnboardingTopBar: View {
    let currentStep: OnboardingStep
    let trailingTitle: String
    let trailingAction: () -> Void

    var body: some View {
        HStack {
            OnboardingStepDots(currentStep: currentStep)

            Spacer()

            Button(action: trailingAction) {
                Text(trailingTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(QuickVPNTheme.card.opacity(0.72), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(height: 52)
    }
}

private struct OnboardingPaywallTopBar: View {
    let currentStep: OnboardingStep
    let onClose: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(QuickVPNTheme.card.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            OnboardingStepDots(currentStep: currentStep)

            Spacer()

            Button(action: onRestore) {
                Text("Restore")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(QuickVPNTheme.card.opacity(0.72), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(height: 52)
    }
}

private struct OnboardingStepDots: View {
    let currentStep: OnboardingStep

    var body: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step == currentStep ? QuickVPNTheme.accent : QuickVPNTheme.border)
                    .frame(width: step == currentStep ? 18 : 6, height: 5)
            }
        }
    }
}

private struct OnboardingAssetIcon: View {
    let name: String
    let layoutSize: CGFloat
    let visualSize: CGFloat

    var body: some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: visualSize, height: visualSize)
            .frame(width: layoutSize, height: layoutSize)
    }
}

private struct SecureOrbitHero: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(
                    LinearGradient(
                        colors: [
                            QuickVPNTheme.accent.opacity(0.30),
                            QuickVPNTheme.blue.opacity(0.22),
                            QuickVPNTheme.background.opacity(0.4)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )

            ForEach([120.0, 170.0, 220.0], id: \.self) { size in
                Circle()
                    .stroke(QuickVPNTheme.primaryText.opacity(0.10), lineWidth: 1)
                    .frame(width: size, height: size)
            }

            OnboardingAssetIcon(
                name: "OnboardingSecureIcon",
                layoutSize: 124,
                visualSize: 204
            )

            OrbitMiniIcon(systemImage: "laptopcomputer", color: QuickVPNTheme.blue)
                .offset(x: -130, y: -10)

            OrbitMiniIcon(systemImage: "globe", color: QuickVPNTheme.blue)
                .offset(x: 128, y: -88)

            OrbitMiniIcon(systemImage: "iphone", color: QuickVPNTheme.purple)
                .offset(x: 134, y: 72)

            OrbitMiniIcon(systemImage: "lock.fill", color: QuickVPNTheme.warning)
                .offset(x: -120, y: 100)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
}

private struct OrbitMiniIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(QuickVPNTheme.card.opacity(0.86), in: Circle())
            .overlay {
                Circle()
                    .stroke(color.opacity(0.34), lineWidth: 1)
            }
    }
}

private struct OnboardingProtocolRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let badge: String
    let badgeColor: Color
    let subtitle: String

    var body: some View {
        OnboardingInsetCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.primaryText)

                        Text(badge)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(badgeColor, in: Capsule())
                    }

                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 62)
        }
    }
}

private struct OnboardingSecureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        OnboardingInsetCard {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(QuickVPNTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(subtitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(QuickVPNTheme.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
        }
    }
}

private struct PaywallCheckRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(QuickVPNTheme.accent)

            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(QuickVPNTheme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingPlanRow: View {
    let plan: OnboardingPlanOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(plan.title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(QuickVPNTheme.primaryText)

                    if let badge = plan.badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(QuickVPNTheme.onAccent)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(QuickVPNTheme.accent, in: Capsule())
                    }
                }

                Text(plan.subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(QuickVPNTheme.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            Text(plan.price)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(QuickVPNTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: plan == .weekly ? 72 : 58)
        .background(
            QuickVPNTheme.card.opacity(isSelected ? 0.98 : 0.82),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? QuickVPNTheme.accent : QuickVPNTheme.borderSubtle, lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct OnboardingInsetCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(QuickVPNTheme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(QuickVPNTheme.borderSubtle, lineWidth: 1)
            }
    }
}

private struct OnboardingBottomButton: View {
    let title: String
    var icon = "arrow.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .heavy))
            }
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(QuickVPNTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(QuickVPNTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

private struct PaywallLegalLinks: View {
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
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(QuickVPNTheme.secondaryText)
        .tint(QuickVPNTheme.secondaryText)
    }
}

private enum OnboardingPlanOption: String, CaseIterable, Identifiable {
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly:
            "Weekly"
        case .monthly:
            "Monthly"
        case .yearly:
            "Yearly"
        }
    }

    var subtitle: String {
        switch self {
        case .weekly:
            "3-day free trial, then $4.99/week"
        case .monthly:
            "Flexible plan, billed every month"
        case .yearly:
            "Best value for always-on privacy"
        }
    }

    var price: String {
        switch self {
        case .weekly:
            "TRIAL"
        case .monthly:
            "$9.99"
        case .yearly:
            "$49.99"
        }
    }

    var badge: String? {
        switch self {
        case .weekly:
            nil
        case .monthly:
            nil
        case .yearly:
            "SAVE 58%"
        }
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case protocols
    case secure
    case paywall

    var id: Int { rawValue }
}

#Preview {
    ContentView()
}
