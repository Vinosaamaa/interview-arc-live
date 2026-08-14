import SwiftUI

struct LiveIntegrationSetupView: View {
    let isWorking: Bool
    let errorMessage: String?
    let onSave: @MainActor (String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Connect Interview Arc", systemImage: "link.badge.plus")
                .font(.system(.title2, design: .rounded, weight: .semibold))
            Text("In Interview Arc, choose Connect and create a personal token. Paste it here once. It is sent only to the versioned /live/v1 API and never to Excalidraw, Groq, Codex, or Voice.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Personal integration token", text: $token)
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .accessibilityLabel("Interview Arc personal integration token")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(.callout, design: .rounded))
            }

            HStack {
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use until quit") {
                    submit(untilQuit: true)
                }
                .disabled(isSubmissionDisabled)
                Button("Save to Keychain") {
                    submit(untilQuit: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmissionDisabled)
            }
        }
        .padding(26)
        .frame(width: 520)
        .interactiveDismissDisabled(isWorking || isSubmitting)
    }

    private var isSubmissionDisabled: Bool {
        isWorking
            || isSubmitting
            || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit(untilQuit: Bool) {
        guard !isSubmissionDisabled else { return }
        let submitted = token
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            await onSave(submitted, untilQuit)
            token = ""
        }
    }
}
