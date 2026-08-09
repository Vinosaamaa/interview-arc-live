import SwiftUI

struct GroqCredentialSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let isSaving: Bool
    let errorMessage: String?
    let onSave: (String) async -> Bool

    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(LivePalette.candidate)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect Groq transcription")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Your key is read back from this app’s macOS Keychain after saving and is never shown again.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(LivePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("After you stop a segment, its audio is sent to Groq for transcription. The source M4A remains in Live’s private local recovery storage.")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(LivePalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SecureField("Groq API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .disabled(isSaving)
                .onSubmit { save() }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(LivePalette.warning)
                    .accessibilityLabel("Credential setup error: \(errorMessage)")
            }

            HStack {
                Text("Existing recordings remain private and recoverable if setup fails.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(LivePalette.muted)

                Spacer()

                Button("Not now") { dismiss() }
                    .disabled(isSaving)

                Button(action: save) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save key")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(LivePalette.candidate)
                .disabled(isSaving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 500)
        .background(LivePalette.paper)
    }

    private func save() {
        let submittedKey = key
        Task {
            if await onSave(submittedKey) {
                key = ""
                dismiss()
            }
        }
    }
}
