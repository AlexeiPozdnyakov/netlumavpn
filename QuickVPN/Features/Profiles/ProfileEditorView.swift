import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var form: ProfileFormData
    @State private var errorMessage: String?

    private let profile: VPNProfile?
    private let onSave: (VPNProfile, VPNProfileSecret) throws -> Void

    init(
        profile: VPNProfile?,
        secret: VPNProfileSecret?,
        onSave: @escaping (VPNProfile, VPNProfileSecret) throws -> Void
    ) {
        self.profile = profile
        self.onSave = onSave
        _form = State(initialValue: ProfileFormData(profile: profile, secret: secret))
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $form.remarks)
                    .textInputAutocapitalization(.words)

                Picker("Protocol", selection: $form.protocolType) {
                    ForEach(VPNProtocolType.allCases) { protocolType in
                        Text(protocolType.title).tag(protocolType)
                    }
                }

                TextField("Host", text: $form.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Port", text: $form.port)
                    .keyboardType(.numberPad)
            }

            if form.protocolType == .wireguard {
                Section("WireGuard") {
                    SecureField("Private Key", text: $form.wireGuardPrivateKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Peer Public Key", text: $form.wireGuardPeerPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Preshared Key", text: $form.wireGuardPreSharedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Interface Address", text: $form.wireGuardAddresses)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Allowed IPs", text: $form.wireGuardAllowedIPs)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Persistent Keepalive", text: $form.wireGuardPersistentKeepAlive)
                        .keyboardType(.numberPad)

                    TextField("MTU", text: $form.wireGuardMTU)
                        .keyboardType(.numberPad)

                    TextField("Reserved Bytes", text: $form.wireGuardReserved)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } else {
                Section("Credentials") {
                    switch form.protocolType {
                    case .vless, .vmess:
                        TextField("User ID", text: $form.userId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                    case .trojan:
                        SecureField("Password", text: $form.password)
                            .textContentType(.password)
                    case .wireguard:
                        EmptyView()
                    }
                }

                Section("Transport") {
                    Picker("Security", selection: $form.security) {
                        ForEach(VPNTransportSecurity.allCases) { security in
                            Text(security.title).tag(security)
                        }
                    }

                    Picker("Network", selection: $form.networkType) {
                        ForEach(VPNNetworkType.allCases) { networkType in
                            Text(networkType.title).tag(networkType)
                        }
                    }

                    TextField("SNI", text: $form.sni)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if form.networkType != .tcp {
                        TextField(transportHostTitle, text: $form.transportHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    TextField(pathTitle, text: $form.path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if form.security == .tls {
                        TextField("TLS Fingerprint", text: $form.tlsFingerprint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("ALPN", text: $form.tlsALPN)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if form.protocolType == .vless {
                        TextField("Flow", text: $form.flow)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }

            if form.security == .reality {
                Section("Reality") {
                    TextField("Public Key", text: $form.realityPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Fingerprint", text: $form.realityFingerprint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Short ID", text: $form.realityShortID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Spider X", text: $form.realitySpiderX)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(QuickVPNTheme.backgroundGradient)
        .navigationTitle(profile == nil ? "Add Profile" : "Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QuickVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
            }
        }
        .onChange(of: form.protocolType) { _, _ in
            form.applyDefaultsForSelectedProtocol()
        }
        .alert(
            "Could Not Save",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var pathTitle: String {
        switch form.networkType {
        case .tcp:
            "Path"
        case .ws:
            "WebSocket Path"
        case .grpc:
            "gRPC Service"
        case .httpupgrade:
            "HTTP Upgrade Path"
        }
    }

    private var transportHostTitle: String {
        switch form.networkType {
        case .tcp:
            "Transport Host"
        case .ws, .httpupgrade:
            "Host Header"
        case .grpc:
            "Authority"
        }
    }

    private func save() {
        do {
            let (profile, secret) = try form.makeProfile(existingProfile: profile)
            try onSave(profile, secret)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
