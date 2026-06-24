import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = AppModel()
    @State private var selectedTab: NetlumaVPNTab = .home
    @State private var sheet: RootSheet?
    @State private var showsSplash = true

    var body: some View {
        ZStack {
            NetlumaVPNTheme.backgroundGradient
                .ignoresSafeArea()

            rootContent

            if showsSplash && model.hasCompletedOnboarding {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .tint(NetlumaVPNTheme.accent)
        .toolbarBackground(NetlumaVPNTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .sheet(item: $sheet) { presentedSheet in
            switch presentedSheet {
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
                        try await model.importProfile(from: value)
                    }
                }
            case .scanQRCode:
                NavigationStack {
                    QRCodeImportView { value in
                        try await model.importProfile(from: value)
                    }
                }
            case .premium:
                NavigationStack {
                    PremiumPaywallView(
                        plans: model.premiumPlans,
                        isLoadingProducts: model.isLoadingPremiumProducts,
                        isPurchasing: model.isPurchasingPremium,
                        productsErrorMessage: model.premiumProductsErrorMessage,
                        onPurchase: { productID in
                            Task { @MainActor in
                                if await model.purchasePremium(productID: productID) {
                                    sheet = nil
                                }
                            }
                        },
                        onRestore: {
                            Task { @MainActor in
                                if await model.restorePremiumPurchases() {
                                    sheet = nil
                                }
                            }
                        },
                        onRetry: {
                            Task { @MainActor in
                                await model.loadPremiumProducts(force: true)
                            }
                        }
                    )
                    .task {
                        await model.loadPremiumProducts(force: model.premiumProductsErrorMessage != nil)
                    }
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
                await model.loadGlobalServers()
            }
        }
        .task {
            await model.refreshStatus()
            Task {
                await model.loadGlobalServers()
            }
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
            OnboardingView(model: model) {
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
            ForEach(NetlumaVPNTab.visibleTabs) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.iconName)
                    }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: NetlumaVPNTab) -> some View {
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
                        Task { @MainActor in
                            if await model.toggleConnection() == .requiresPremium {
                                sheet = .premium
                            }
                        }
                    },
                    onSelectProfile: { profile in
                        Task {
                            await model.selectProfile(profile)
                        }
                    },
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
                    onSelectGlobalServer: { server in
                        Task { @MainActor in
                            if await model.selectGlobalServer(server) == .requiresPremium {
                                sheet = .premium
                            }
                        }
                    },
                    onOpenPremium: {
                        sheet = .premium
                    }
                )
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
    let model: AppModel
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .protocols

    var body: some View {
        NavigationStack {
            ZStack {
                NetlumaVPNTheme.backgroundGradient
                    .ignoresSafeArea()

                TabView(selection: $step) {
                    OnboardingProtocolsScreen(step: $step, onSkip: onComplete)
                        .tag(OnboardingStep.protocols)

                    OnboardingSecureScreen(step: $step, onSkip: onComplete)
                        .tag(OnboardingStep.secure)

                    PremiumPaywallView(
                        plans: model.premiumPlans,
                        isLoadingProducts: model.isLoadingPremiumProducts,
                        isPurchasing: model.isPurchasingPremium,
                        productsErrorMessage: model.premiumProductsErrorMessage,
                        showsStepDots: true,
                        onClose: onComplete,
                        onPurchase: { productID in
                            Task { @MainActor in
                                if await model.purchasePremium(productID: productID) {
                                    onComplete()
                                }
                            }
                        },
                        onRestore: {
                            Task { @MainActor in
                                if await model.restorePremiumPurchases() {
                                    onComplete()
                                }
                            }
                        },
                        onRetry: {
                            Task { @MainActor in
                                await model.loadPremiumProducts(force: true)
                            }
                        }
                    )
                    .task {
                        await model.loadPremiumProducts(force: model.premiumProductsErrorMessage != nil)
                    }
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
        OnboardingScreenScaffold {
            OnboardingTopBar(currentStep: .protocols, trailingTitle: "Skip", trailingAction: onSkip)
        } footer: {
            OnboardingBottomButton(title: "Continue") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    step = .secure
                }
            }
        } content: {
            VStack(spacing: 18) {
                OnboardingAssetIcon(
                    name: "OnboardingProtocolsIcon",
                    layoutSize: 88,
                    visualSize: 148
                )
                .padding(.top, 10)

                VStack(spacing: 7) {
                    Text("Powerful Protocols")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                        .multilineTextAlignment(.center)

                    Text("Choose the protocol that fits you best — modern, secure, and ultra-fast.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)

                VStack(spacing: 10) {
                    OnboardingProtocolRow(
                        icon: "sparkles",
                        iconColor: NetlumaVPNTheme.blue,
                        title: "VLESS",
                        badge: "MODERN",
                        badgeColor: NetlumaVPNTheme.blue,
                        subtitle: "Stealthy, low overhead, censorship resistant"
                    )

                    OnboardingProtocolRow(
                        icon: "shield",
                        iconColor: NetlumaVPNTheme.purple,
                        title: "VMess",
                        badge: "FLEXIBLE",
                        badgeColor: NetlumaVPNTheme.purple,
                        subtitle: "Versatile masking with strong obfuscation"
                    )

                    OnboardingProtocolRow(
                        icon: "theatermasks",
                        iconColor: NetlumaVPNTheme.warning,
                        title: "Trojan",
                        badge: "STEALTH",
                        badgeColor: NetlumaVPNTheme.warning,
                        subtitle: "Imitates HTTPS — invisible to firewalls"
                    )

                    OnboardingProtocolRow(
                        icon: "bolt.fill",
                        iconColor: NetlumaVPNTheme.accent,
                        title: "WireGuard",
                        badge: "FASTEST",
                        badgeColor: NetlumaVPNTheme.accent,
                        subtitle: "Modern, lightweight, blazing fast"
                    )
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 20)
        }
    }
}

private struct OnboardingSecureScreen: View {
    @Binding var step: OnboardingStep
    let onSkip: () -> Void

    var body: some View {
        OnboardingScreenScaffold {
            OnboardingTopBar(currentStep: .secure, trailingTitle: "Skip", trailingAction: onSkip)
        } footer: {
            OnboardingBottomButton(title: "Continue") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    step = .paywall
                }
            }
        } content: {
            VStack(spacing: 18) {
                SecureOrbitHero()
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    Text("Browse with Confidence")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                        .multilineTextAlignment(.center)

                    Text("Military-grade encryption shields every connection — Wi-Fi, mobile, anywhere.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)

                VStack(spacing: 10) {
                    OnboardingSecureRow(
                        icon: "lock.fill",
                        iconColor: NetlumaVPNTheme.accent,
                        title: "End-to-end encrypted tunnel",
                        subtitle: "Nobody between you and the web"
                    )

                    OnboardingSecureRow(
                        icon: "eye.slash.fill",
                        iconColor: NetlumaVPNTheme.blue,
                        title: "Hide your IP and location",
                        subtitle: "Stay anonymous on any network"
                    )

                    OnboardingSecureRow(
                        icon: "wifi",
                        iconColor: NetlumaVPNTheme.purple,
                        title: "Safe on public Wi-Fi",
                        subtitle: "Cafes, airports, hotels — fully protected"
                    )
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 20)
        }
    }
}

private struct OnboardingScreenScaffold<Header: View, Footer: View, Content: View>: View {
    let header: Header
    let footer: Footer
    let content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        ZStack {
            NetlumaVPNTheme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                content
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
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
                Text(L10n.string(trailingTitle))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(NetlumaVPNTheme.card.opacity(0.72), in: Capsule())
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
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step == currentStep ? NetlumaVPNTheme.accent : NetlumaVPNTheme.border)
                    .frame(width: step == currentStep ? 18 : 6, height: 6)
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
                            NetlumaVPNTheme.accent.opacity(0.30),
                            NetlumaVPNTheme.blue.opacity(0.22),
                            NetlumaVPNTheme.background.opacity(0.4)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )

            ForEach([120.0, 170.0, 220.0], id: \.self) { size in
                Circle()
                    .stroke(NetlumaVPNTheme.primaryText.opacity(0.10), lineWidth: 1)
                    .frame(width: size, height: size)
            }

            OnboardingAssetIcon(
                name: "OnboardingSecureIcon",
                layoutSize: 124,
                visualSize: 204
            )

            OrbitMiniIcon(systemImage: "laptopcomputer", color: NetlumaVPNTheme.blue)
                .offset(x: -130, y: -10)

            OrbitMiniIcon(systemImage: "globe", color: NetlumaVPNTheme.blue)
                .offset(x: 128, y: -88)

            OrbitMiniIcon(systemImage: "iphone", color: NetlumaVPNTheme.purple)
                .offset(x: 134, y: 72)

            OrbitMiniIcon(systemImage: "lock.fill", color: NetlumaVPNTheme.warning)
                .offset(x: -120, y: 100)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
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
            .background(NetlumaVPNTheme.card.opacity(0.86), in: Circle())
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
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(iconColor)
                    .frame(width: 44, height: 44)
                    .background(NetlumaVPNTheme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(L10n.string(title))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(NetlumaVPNTheme.primaryText)

                        Text(L10n.string(badge))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(badge == "FASTEST" ? NetlumaVPNTheme.onAccent : badgeColor)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(
                                badge == "FASTEST" ? badgeColor : badgeColor.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }

                    Text(L10n.string(subtitle))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 72)
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
                    .frame(width: 36, height: 36)
                    .background(NetlumaVPNTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NetlumaVPNTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(L10n.string(subtitle))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
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
            .background(NetlumaVPNTheme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
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
                Text(L10n.string(title))
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .heavy))
            }
            .font(.system(size: 17, weight: .heavy))
            .foregroundStyle(NetlumaVPNTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(NetlumaVPNTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 8)
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
