import SwiftUI

struct ImportProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var errorMessage: String?

    let onImport: (String) throws -> Void

    var body: some View {
        Form {
            Section("Configuration URL") {
                TextEditor(text: $value)
                    .frame(minHeight: 140)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .scrollContentBackground(.hidden)
        .background(QuickVPNTheme.backgroundGradient)
        .navigationTitle("Import")
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
                Button("Import") {
                    importProfile()
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        do {
            try onImport(value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
