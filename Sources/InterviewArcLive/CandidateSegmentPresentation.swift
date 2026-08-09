import SwiftUI

struct CandidateSegmentPresentation: Identifiable, Equatable {
    enum Lifecycle: Equatable {
        case preparing
        case recording
        case finalizing
        case transcribing
        case ready
        case partial
        case preserved
        case excluded
        case recoverable
        case failed

        var title: String {
            switch self {
            case .preparing: "Preparing microphone"
            case .recording: "Recording"
            case .finalizing: "Saving recording"
            case .transcribing: "Transcribing"
            case .ready: "Ready"
            case .partial: "Recovered partial recording"
            case .preserved: "Recording preserved"
            case .excluded: "Excluded · recording preserved"
            case .recoverable: "Needs attention"
            case .failed: "Recording unavailable"
            }
        }

        var symbol: String {
            switch self {
            case .preparing: "mic.badge.plus"
            case .recording: "waveform"
            case .finalizing: "tray.and.arrow.down.fill"
            case .transcribing: "text.badge.star"
            case .ready: "checkmark.circle.fill"
            case .partial: "exclamationmark.circle.fill"
            case .preserved: "waveform.circle.fill"
            case .excluded: "minus.circle.fill"
            case .recoverable: "arrow.clockwise.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }
    }

    enum Quality: Equatable {
        case verified
        case bestAvailable
        case possibleContamination

        var title: String {
            switch self {
            case .verified: "Verified transcript"
            case .bestAvailable: "Best available"
            case .possibleContamination: "Possible contamination"
            }
        }

        var symbol: String {
            switch self {
            case .verified: "checkmark.seal.fill"
            case .bestAvailable: "text.magnifyingglass"
            case .possibleContamination: "exclamationmark.bubble.fill"
            }
        }
    }

    enum TranscriptionAction: Equatable {
        case initial
        case retry

        var title: String {
            switch self {
            case .initial: "Transcribe"
            case .retry: "Retry transcript"
            }
        }

        var symbol: String {
            switch self {
            case .initial: "text.badge.plus"
            case .retry: "arrow.clockwise"
            }
        }
    }

    let id: String
    let ordinal: Int
    let lifecycle: Lifecycle
    let duration: String?
    let transcript: String?
    let detail: String
    let quality: Quality?
    let canPlay: Bool
    let transcriptionAction: TranscriptionAction?
    let canExclude: Bool
}

struct CandidateSegmentCard: View {
    let segment: CandidateSegmentPresentation
    let isBusy: Bool
    let onPlay: () -> Void
    let onTranscribe: () -> Void
    let onExclude: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("SEGMENT \(segment.ordinal)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(0.8)

                Label(segment.lifecycle.title, systemImage: segment.lifecycle.symbol)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(lifecycleColor)

                Spacer(minLength: 8)

                if let duration = segment.duration {
                    Text(duration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(LivePalette.muted)
                }
            }

            if let transcript = segment.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(.body, design: .rounded))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(segment.detail)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsFooter {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let quality = segment.quality {
                            Label(quality.title, systemImage: quality.symbol)
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(qualityColor(quality))
                        }

                        Spacer(minLength: 8)

                        if segment.canPlay {
                            Button(action: onPlay) {
                                Label("Play", systemImage: "play.fill")
                            }
                            .disabled(isBusy)
                            .accessibilityHint("Plays this preserved source recording")
                        }
                    }

                    if segment.transcriptionAction != nil || segment.canExclude {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { recoveryActions }
                            VStack(alignment: .leading, spacing: 8) { recoveryActions }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(LivePalette.room.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: segment.lifecycle == .recording ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Segment \(segment.ordinal), \(segment.lifecycle.title)")
    }

    private var lifecycleColor: Color {
        switch segment.lifecycle {
        case .ready: LivePalette.candidate
        case .recording: LivePalette.handoff
        case .partial, .recoverable, .failed: LivePalette.warning
        case .preserved: LivePalette.interviewer
        case .excluded: LivePalette.muted
        case .preparing, .finalizing, .transcribing: LivePalette.interviewer
        }
    }

    private var borderColor: Color {
        segment.lifecycle == .recording
            ? LivePalette.handoff
            : LivePalette.line
    }

    private var showsFooter: Bool {
        segment.quality != nil
            || segment.canPlay
            || segment.transcriptionAction != nil
            || segment.canExclude
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if let action = segment.transcriptionAction {
            Button(action: onTranscribe) {
                Label(action.title, systemImage: action.symbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(LivePalette.candidate)
            .disabled(isBusy)
            .accessibilityHint(
                action == .initial
                    ? "Starts the first explicit Groq transcription request"
                    : "Starts one explicit Groq transcription retry"
            )
        }

        if segment.canExclude {
            Button(action: onExclude) {
                Label("Exclude from answer", systemImage: "minus.circle")
            }
            .disabled(isBusy)
            .help("Keeps the source recording but omits this segment from Hand off")
            .accessibilityHint("Preserves the recording and omits this segment from Hand off")
        }
    }

    private func qualityColor(_ quality: CandidateSegmentPresentation.Quality) -> Color {
        switch quality {
        case .verified: LivePalette.candidate
        case .bestAvailable: LivePalette.interviewer
        case .possibleContamination: LivePalette.warning
        }
    }
}
