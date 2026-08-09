import SwiftUI

struct GroqCredentialSetupView: View {
    @Environment(\.dismiss) private var dismiss

    let isSaving: Bool
    let errorMessage: String?
    let onSaveToKeychain: (String) async -> Bool
    let onUseUntilQuit: (String) async -> Bool

    @State private var key = ""
    @State private var activeSubmission: CredentialSubmission?

    private enum CredentialSubmission {
        case keychain
        case untilQuit
    }

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
                    Text("Choose whether this app remembers the key in macOS Keychain or keeps it only until you quit.")
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
                .disabled(isSubmissionInFlight)
                .privacySensitive()
                .onSubmit { saveToKeychain() }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(LivePalette.warning)
                    .accessibilityLabel("Credential setup error: \(errorMessage)")
            }

            VStack(alignment: .leading, spacing: 14) {
                credentialChoice(
                    title: "Save to Keychain",
                    detail: "Persists for future launches on this Mac. The saved value is never displayed after verification.",
                    submission: .keychain,
                    action: saveToKeychain
                )
                credentialChoice(
                    title: "Use until quit",
                    detail: "Keeps the key only in this app’s memory. You must enter it again after quitting or relaunching.",
                    submission: .untilQuit,
                    action: useUntilQuit
                )
            }

            HStack {
                Text("If setup fails, existing source recordings remain local and recoverable.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(LivePalette.muted)

                Spacer()

                Button("Not now") { dismiss() }
                    .disabled(isSubmissionInFlight)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 540)
        .background(LivePalette.paper)
    }

    @ViewBuilder
    private func credentialChoice(
        title: String,
        detail: String,
        submission: CredentialSubmission,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            if submission == .keychain {
                Button(action: action) {
                    actionLabel(title: title, submission: submission)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tint(LivePalette.candidate)
                .disabled(isActionDisabled)
                .accessibilityHint(detail)
            } else {
                Button(action: action) {
                    actionLabel(title: title, submission: submission)
                }
                .buttonStyle(.bordered)
                .tint(LivePalette.candidate)
                .disabled(isActionDisabled)
                .accessibilityHint(detail)
            }
        }
    }

    @ViewBuilder
    private func actionLabel(
        title: String,
        submission: CredentialSubmission
    ) -> some View {
        if activeSubmission == submission {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(submission == .keychain ? "Saving…" : "Using…")
            }
        } else {
            Text(title)
        }
    }

    private var isActionDisabled: Bool {
        isSubmissionInFlight
            || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSubmissionInFlight: Bool {
        isSaving || activeSubmission != nil
    }

    private func saveToKeychain() {
        let submittedKey = key
        activeSubmission = .keychain
        Task { @MainActor in
            let didSave = await onSaveToKeychain(submittedKey)
            activeSubmission = nil
            if didSave {
                key = ""
                dismiss()
            }
        }
    }

    private func useUntilQuit() {
        let submittedKey = key
        activeSubmission = .untilQuit
        Task { @MainActor in
            let didUse = await onUseUntilQuit(submittedKey)
            activeSubmission = nil
            if didUse {
                key = ""
                dismiss()
            }
        }
    }
}
