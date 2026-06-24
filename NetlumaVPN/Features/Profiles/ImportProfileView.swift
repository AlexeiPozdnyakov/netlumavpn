import SwiftUI

struct ImportProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var errorMessage: String?
    @State private var isImporting = false

    let onImport: (String) async throws -> Void

    var body: some View {
        Form {
            Section {
                TextEditor(text: $value)
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isImporting)
            } header: {
                Text("Configuration URL")
            } footer: {
                Text("Paste a config link (vless://, vmess://, trojan://, or WireGuard), or an https:// link to a .json profile.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(NetlumaVPNTheme.backgroundGradient)
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NetlumaVPNTheme.backgroundGradient, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isImporting)
            }

            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Import") {
                        importProfile()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert(
            "Could Not Import",
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

    private func importProfile() {
        let captured = value
        isImporting = true
        Task {
            do {
                try await onImport(captured)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}
