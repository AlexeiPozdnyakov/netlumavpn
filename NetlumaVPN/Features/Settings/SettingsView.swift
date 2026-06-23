import SwiftUI
import WebKit

struct SettingsView: View {
    let model: AppModel
    let onOpenPremium: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if model.shouldShowPremiumBanner {
                    planCard
                }
                primarySettings
                legalSettings
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .background(NetlumaVPNTheme.backgroundGradient)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(NetlumaVPNTheme.primaryText)
            Text("Manage subscription and preferences")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NetlumaVPNTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var planCard: some View {
        NetlumaVPNCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PREMIUM")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(NetlumaVPNTheme.secondaryText)
                        Text("Unlock NetlumaVPN Global")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(NetlumaVPNTheme.primaryText)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(model.premiumBannerPriceText)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(NetlumaVPNTheme.accent)
                        Text(premiumBannerCaption)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    }
                }

                HStack(spacing: 8) {
                    PremiumPill(title: "Global")
                }

                HStack {
                    Text(premiumBannerStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    Spacer()
                    Button(action: onOpenPremium) {
                        Text("View plans")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(NetlumaVPNTheme.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                            .background(NetlumaVPNTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPremium)
    }

    private var premiumBannerCaption: String {
        if model.premiumPlans.contains(where: \.hasEligibleFreeTrial) {
            return L10n.string("Trial available")
        }

        if model.isLoadingPremiumProducts {
            return L10n.string("StoreKit")
        }

        return L10n.string("Premium plans")
    }

    private var premiumBannerStatusText: String {
        model.premiumProductsErrorMessage ?? L10n.string("Global servers require Premium")
    }

    private var primarySettings: some View {
        NetlumaVPNCard {
            VStack(spacing: 0) {
                NavigationLink {
                    SessionInfoView()
                } label: {
                    SettingsNavigationRow(
                        icon: "waveform.path.ecg",
                        iconColor: NetlumaVPNTheme.blue,
                        title: "Session",
                        subtitle: model.status.title
                    )
                }

                divider

                NavigationLink {
                    TunnelSettingsView(
                        preferences: Binding(
                            get: { model.networkPreferences.tunnel },
                            set: { model.updateTunnelPreferences($0) }
                        )
                    )
                } label: {
                    SettingsNavigationRow(
                        icon: "lock.shield",
                        iconColor: NetlumaVPNTheme.accentSoft,
                        title: "Tunnel",
                        subtitle: "\(model.networkPreferences.tunnel.ipMode.title) · \(model.networkPreferences.tunnel.onDemandMode.title)"
                    )
                }

                divider

                NavigationLink {
                    DNSSettingsView(
                        selectedResolverID: model.networkPreferences.selectedDNSResolverID,
                        onSelect: model.selectDNSResolver
                    )
                } label: {
                    SettingsNavigationRow(
                        icon: "globe",
                        iconColor: NetlumaVPNTheme.purple,
                        title: "DNS",
                        subtitle: model.selectedDNSResolver.title
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var legalSettings: some View {
        NetlumaVPNCard {
            VStack(spacing: 0) {
                NavigationLink {
                    LegalDocumentView(document: .terms)
                } label: {
                    SettingsNavigationRow(
                        icon: "doc.text",
                        iconColor: NetlumaVPNTheme.blue,
                        title: "Terms of Use",
                        subtitle: "Legal agreement"
                    )
                }

                divider

                NavigationLink {
                    LegalDocumentView(document: .privacy)
                } label: {
                    SettingsNavigationRow(
                        icon: "hand.raised.fill",
                        iconColor: NetlumaVPNTheme.accentSoft,
                        title: "Privacy Policy",
                        subtitle: "Data and privacy"
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(NetlumaVPNTheme.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 58)
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        LegalWebView(html: document.html)
            .background(NetlumaVPNTheme.background)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(NetlumaVPNTheme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct LegalWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else {
            return
        }

        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var loadedHTML: String?
    }
}

enum LegalDocument: String, Identifiable {
    case terms
    case privacy

    var id: String { rawValue }

    var title: String {
        return switch self {
        case .terms:
            L10n.string("Terms of Use")
        case .privacy:
            L10n.string("Privacy Policy")
        }
    }

    var html: String {
        LegalHTMLTemplate.page(title: title, bodyHTML: bodyHTML)
    }

    private var bodyHTML: String {
        if let localizedBodyHTML {
            return localizedBodyHTML
        }

        return switch self {
        case .terms:
            #"""
            <p class="effective">Effective date: May 15, 2026</p>

            <h1>Terms of Use</h1>

            <p>These Terms of Use ("Terms") govern your access to and use of NetlumaVPN, an iOS application that helps you import VPN/proxy profiles, configure an iOS Network Extension tunnel, manage tunnel and DNS preferences, and review connection information. By downloading, opening, or using NetlumaVPN, you agree to these Terms. If you do not agree, do not use the app.</p>

            <h2>1. The Service</h2>
            <p>NetlumaVPN is a client application. It can store user-provided VPN profiles, start and stop a VPN tunnel through Apple's Network Extension framework, show connection status, keep local diagnostics, and display session information such as the public IP address visible from your device. NetlumaVPN may also present Premium features, plans, or trial offers when those features are available through Apple's in-app purchase system.</p>
            <p>Unless a screen clearly says otherwise, NetlumaVPN does not itself provide a VPN server, internet access, or a third-party subscription. If you import a configuration from another provider, that provider controls the server endpoint and may have its own terms, privacy practices, logging policies, bandwidth limits, and legal obligations.</p>

            <h2>2. Eligibility and Device Requirements</h2>
            <p>You must be old enough to use apps and online services in your country or have permission from a parent or legal guardian. You are responsible for having a compatible iPhone or iPad, an Apple ID, internet connectivity, and any third-party VPN profile or subscription needed to connect.</p>

            <h2>3. VPN Profiles and Credentials</h2>
            <p>You are responsible for every VPN profile, QR code, link, hostname, key, user identifier, password, certificate, or other credential that you import into NetlumaVPN. You must have the right to use each profile. Do not import stolen, shared without permission, abusive, or unauthorized credentials.</p>
            <p>NetlumaVPN may store profile metadata in the app's local storage and sensitive profile values in device-protected storage such as Keychain-backed storage. You are responsible for securing your device, passcode, backups, and any exported or shared configuration data.</p>

            <h2>4. Acceptable Use</h2>
            <p>You agree not to use NetlumaVPN to break the law, harm others, bypass access controls in a way that violates another service's rules, distribute malware, send spam, attack networks, infringe intellectual property, stalk or harass people, or conceal activity that you are not legally allowed to perform. You are responsible for complying with laws that apply to you, including laws about encryption, VPN use, sanctions, export controls, and online content.</p>

            <h2>5. Premium, Subscriptions, and Payments</h2>
            <p>If NetlumaVPN offers paid features, purchases are processed by Apple through the App Store. Pricing, trials, renewal terms, refunds, cancellation, family sharing, taxes, and payment methods are handled by Apple and your Apple ID settings. You can manage or cancel subscriptions in your Apple account settings.</p>
            <p>Screens that say purchases are not connected or are placeholders do not start a real payment. When a real purchase flow is available, Apple's purchase confirmation sheet will show the product, price, and renewal information before you are charged.</p>

            <h2>6. VPN Limitations</h2>
            <p>A VPN can improve privacy on some networks, but it does not make you anonymous, immune from tracking, or protected from every security risk. Websites, apps, operating systems, DNS resolvers, VPN providers, payment processors, analytics services, and network operators may still process data depending on how you use the device and which services you choose.</p>
            <p>Connection speed, availability, routing, latency, access to websites, and compatibility depend on your device, local network, internet provider, selected profile, server provider, and Apple system behavior. NetlumaVPN does not guarantee uninterrupted or error-free connections.</p>

            <h2>7. Permissions</h2>
            <p>NetlumaVPN may ask iOS to install or update a VPN configuration so the tunnel can operate. iOS controls the permission prompt and may require device authentication. You can remove VPN configurations or disable VPN permissions in iOS settings.</p>

            <h2>8. Third-Party Services</h2>
            <p>NetlumaVPN may interact with third-party services you choose, such as VPN server providers, DNS resolvers, Apple's App Store and StoreKit systems, and an IP information service used to display session details. Third-party services are not controlled by NetlumaVPN and may have separate terms and privacy policies.</p>

            <h2>9. Intellectual Property</h2>
            <p>NetlumaVPN, including its app design, code, branding, text, and other materials, is owned by the app operator or its licensors and is protected by intellectual property laws. These Terms give you a limited, personal, non-transferable right to use the app on Apple devices you own or control, subject to these Terms and Apple's rules.</p>

            <h2>10. Feedback</h2>
            <p>If you send ideas, bug reports, suggestions, or other feedback, you allow the app operator to use that feedback without payment or obligation, while you keep ownership of any rights you already have in your own materials.</p>

            <h2>11. No Warranty</h2>
            <p>NetlumaVPN is provided "as is" and "as available." To the maximum extent allowed by law, the app operator disclaims warranties of merchantability, fitness for a particular purpose, non-infringement, availability, accuracy, and security. Some jurisdictions do not allow certain warranty exclusions, so parts of this section may not apply to you.</p>

            <h2>12. Limitation of Liability</h2>
            <p>To the maximum extent allowed by law, the app operator will not be liable for indirect, incidental, special, consequential, exemplary, or punitive damages, or for lost profits, lost data, loss of goodwill, service interruption, device failure, network restrictions, third-party provider actions, or inability to use a VPN profile. Where liability cannot be excluded, it is limited to the amount you paid for NetlumaVPN during the twelve months before the event giving rise to the claim.</p>

            <h2>13. Termination</h2>
            <p>You may stop using NetlumaVPN at any time. The app operator may suspend or discontinue the app or any feature if necessary for security, legal, operational, or business reasons. Sections that by their nature should survive termination will continue to apply.</p>

            <h2>14. Changes</h2>
            <p>These Terms may be updated from time to time. Material changes will be reflected by updating the effective date or by providing another appropriate notice. Your continued use of NetlumaVPN after changes become effective means you accept the updated Terms.</p>

            <h2>15. Governing Law and Consumer Rights</h2>
            <p>These Terms are governed by the laws applicable where the app operator is established, excluding conflict-of-law rules, unless mandatory consumer protection laws in your country give you additional rights. Nothing in these Terms limits rights that cannot legally be waived.</p>

            <h2>16. Contact</h2>
            <p>For questions about these Terms, use the support contact shown in the App Store listing or another official support channel provided for NetlumaVPN.</p>
            """#
        case .privacy:
            #"""
            <p class="effective">Effective date: May 15, 2026</p>

            <h1>Privacy Policy</h1>

            <p>This Privacy Policy explains how NetlumaVPN handles information when you use the app. NetlumaVPN is designed primarily as an on-device VPN client: it imports and stores VPN profiles, configures an iOS VPN tunnel, and shows connection information. The app operator is responsible for the app itself, while third-party VPN providers, DNS resolvers, Apple, and other services may process data under their own policies.</p>

            <h2>1. Information Stored on Your Device</h2>
            <p>NetlumaVPN may store the following information locally on your device or in the app group's local storage so the app, widget, and tunnel extension can work:</p>
            <ul>
                <li>VPN profile metadata, such as protocol type, host, port, security mode, network type, remarks, and selected profile identifier.</li>
                <li>Sensitive profile values, such as user identifiers, keys, passwords, or other credentials, using device-protected storage where available.</li>
                <li>Network preferences, including DNS resolver choice, IP mode, on-demand mode, and tunnel routing options.</li>
                <li>Connection display state, connection start time, selected profile, widget toggle requests, and app diagnostics or logs.</li>
                <li>Settings such as whether onboarding has been completed.</li>
            </ul>
            <p>This local information is used to operate the app, start the VPN tunnel, display your current setup, support widgets, and help diagnose connection behavior. Deleting the app or removing profiles may delete this local information, subject to iOS behavior, backups, and Keychain retention rules.</p>

            <h2>2. VPN Traffic</h2>
            <p>When you connect, iOS routes network traffic through the active VPN tunnel according to the selected profile and tunnel settings. If the profile connects to a third-party server, that server provider may see connection metadata and traffic that reaches it. NetlumaVPN does not promise that a third-party VPN provider is private, safe, lawful, or no-log.</p>
            <p>NetlumaVPN is not designed to inspect, sell, or build advertising profiles from your browsing content. However, the tunnel must process packets locally enough to pass them through the configured VPN engine and Apple's Network Extension system.</p>

            <h2>3. Session Information Lookup</h2>
            <p>If you open session information features, NetlumaVPN may request public IP and approximate network/location metadata from an IP information service, currently ipapi.co. That request may reveal your current public IP address and standard request metadata to that service. NetlumaVPN uses an ephemeral URL session for this lookup and displays the returned information in the app.</p>

            <h2>4. DNS Resolvers and Third Parties</h2>
            <p>If you choose an encrypted DNS resolver or another DNS option in NetlumaVPN, DNS queries may be sent to that selected resolver while the tunnel is active. DNS providers may process query data according to their own privacy policies. Apple may process App Store, purchase, crash, and device information according to Apple's policies.</p>

            <h2>5. Payments and Premium Features</h2>
            <p>If paid features are enabled, purchases are handled by Apple through StoreKit and the App Store. NetlumaVPN may receive non-sensitive transaction status needed to unlock features, such as whether a purchase or subscription is active. Apple handles payment details, billing information, refunds, and subscription management.</p>

            <h2>6. Data Not Intentionally Collected by NetlumaVPN</h2>
            <p>NetlumaVPN does not intentionally require you to create an account in the current app flow, does not ask for your real name in order to connect, and does not intentionally collect payment card numbers. Any account, billing, or subscription information handled by Apple is governed by Apple's terms and privacy policy.</p>

            <h2>7. Sharing of Information</h2>
            <p>NetlumaVPN may share information only as needed to operate the app, comply with law, protect rights and safety, complete transactions through Apple, or interact with services you choose, such as VPN servers, DNS resolvers, and the session information provider. The app operator does not sell personal information for advertising.</p>

            <h2>8. Retention</h2>
            <p>Local profiles, settings, logs, and connection state remain on your device until you delete them, clear related data where the app provides controls, uninstall the app, or iOS removes them. Diagnostic logs are limited in size and older entries may be replaced by newer entries. Third-party providers may retain data according to their own policies.</p>

            <h2>9. Security</h2>
            <p>NetlumaVPN uses platform security features such as iOS sandboxing, app group storage, and protected storage for sensitive profile values where available. No app or network system can guarantee perfect security. You should keep iOS updated, protect your device with a passcode, and import profiles only from providers you trust.</p>

            <h2>10. Your Choices</h2>
            <p>You can delete imported profiles, change DNS and tunnel settings, disconnect the VPN, remove VPN configurations in iOS settings, manage subscriptions in your Apple ID settings, and uninstall NetlumaVPN. You can avoid opening session information features if you do not want an IP information service to receive a lookup request.</p>

            <h2>11. Children</h2>
            <p>NetlumaVPN is not directed to children under 13 or the minimum age required by local law. If you believe a child provided personal information through NetlumaVPN, use the official support contact so the issue can be reviewed.</p>

            <h2>12. International Use</h2>
            <p>VPN laws and privacy rights vary by country. You are responsible for using NetlumaVPN lawfully where you are located. Third-party services may process data in countries other than your own.</p>

            <h2>13. Changes</h2>
            <p>This Privacy Policy may be updated from time to time. The effective date will be changed when the policy is updated. Continued use of NetlumaVPN after an update means the updated policy applies to your use of the app.</p>

            <h2>14. Contact</h2>
            <p>For privacy questions or requests, use the support contact shown in the App Store listing or another official support channel provided for NetlumaVPN. Because most NetlumaVPN data is stored locally on your device, the app operator may not be able to access or delete local data remotely.</p>
            """#
        }
    }

    private var localizedBodyHTML: String? {
        let resourceName = switch self {
        case .terms:
            "Terms"
        case .privacy:
            "Privacy"
        }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "html") else {
            return nil
        }

        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private enum LegalHTMLTemplate {
    static func page(title: String, bodyHTML: String) -> String {
        #"""
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>\#(title)</title>
            <style>
                :root {
                    color-scheme: dark;
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
                    background: #0B0F1A;
                    color: #F8FAFC;
                }

                * {
                    box-sizing: border-box;
                }

                body {
                    margin: 0;
                    padding: 24px 20px 42px;
                    background: linear-gradient(145deg, #0B0F1A 0%, #102A30 100%);
                    font-size: 15px;
                    line-height: 1.62;
                    -webkit-text-size-adjust: 100%;
                }

                h1 {
                    margin: 8px 0 18px;
                    font-size: 30px;
                    line-height: 1.05;
                    letter-spacing: 0;
                }

                h2 {
                    margin: 26px 0 8px;
                    font-size: 17px;
                    line-height: 1.25;
                    letter-spacing: 0;
                }

                p {
                    margin: 0 0 12px;
                    color: #CBD5E1;
                }

                ul {
                    margin: 0 0 14px;
                    padding-left: 21px;
                    color: #CBD5E1;
                }

                li {
                    margin: 0 0 8px;
                    padding-left: 2px;
                }

                .effective {
                    display: inline-flex;
                    margin: 0 0 14px;
                    padding: 7px 10px;
                    border: 1px solid #2A3349;
                    border-radius: 999px;
                    background: #151B2B;
                    color: #94A3B8;
                    font-size: 12px;
                    font-weight: 700;
                }
            </style>
        </head>
        <body>
            \#(bodyHTML)
        </body>
        </html>
        """#
    }
}

private struct PremiumPill: View {
    let title: String

    var body: some View {
        Text(L10n.string(title))
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(NetlumaVPNTheme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(NetlumaVPNTheme.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(NetlumaVPNTheme.borderSubtle, lineWidth: 1)
            }
    }
}

private struct SettingsNavigationRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var isPremiumLocked = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.primaryText)
                Text(L10n.string(subtitle))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NetlumaVPNTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if isPremiumLocked {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .heavy))
                    Text("PRO")
                        .font(.system(size: 8, weight: .heavy))
                }
                .foregroundStyle(NetlumaVPNTheme.onAccent)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(NetlumaVPNTheme.accent, in: Capsule())
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NetlumaVPNTheme.mutedText)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .contentShape(Rectangle())
    }
}
