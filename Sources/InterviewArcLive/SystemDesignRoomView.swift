import InterviewArcLiveCore
import SwiftUI

struct SystemDesignRoomView: View {
    @ObservedObject var model: SystemDesignRoomModel
    let onCollapse: () -> Void
    @State private var isModelRemovalConfirmationPresented = false

    init(
        model: SystemDesignRoomModel,
        onCollapse: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onCollapse = onCollapse
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            question
            if let errorMessage = model.errorMessage {
                recoveryBanner(errorMessage)
            }
            if let codexMessage = model.codexAttentionMessage {
                codexReadinessBanner(codexMessage)
            }

            HSplitView {
                transcript
                    .frame(minWidth: 330, idealWidth: 410, maxWidth: 520)
                board
                    .frame(minWidth: 560)
            }

            floorRail
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(LivePalette.room)
        .foregroundStyle(LivePalette.ink)
        .sheet(isPresented: $model.isCredentialSetupPresented) {
            GroqCredentialSetupView(
                isSaving: model.isSavingCredential,
                errorMessage: model.credentialErrorMessage,
                onSaveToKeychain: model.saveGroqCredential,
                onUseUntilQuit: model.useGroqCredentialUntilQuit
            )
        }
        .confirmationDialog(
            "Remove Mara’s local model?",
            isPresented: $isModelRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove exact model revision", role: .destructive) {
                Task { await model.removeSpeechModel() }
            }
            Button("Keep model", role: .cancel) {}
        } message: {
            Text("This removes only the pinned public model and its Live-owned cache. Sessions, transcripts, and private interviewer WAVs stay on this Mac.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            LiveMark()
                .frame(width: 30, height: 30)
            Text("Interview Arc Live")
                .font(.system(.headline, design: .rounded, weight: .semibold))
            Spacer()

            Menu {
                Picker("Turn-taking", selection: turnModeRawSelection) {
                    ForEach(model.availableTurnModes, id: \.rawValue) { mode in
                        Text(model.turnModeTitle(mode)).tag(mode.rawValue)
                    }
                }
                Divider()
                Text(model.endpointShadowPresentation.title)
                Text(model.endpointShadowPresentation.detail)
                if model.needsGroqCredential {
                    Button("Add Groq key") { model.presentCredentialSetup() }
                }
                Button("Check Codex") { Task { await model.checkCodex() } }
            } label: {
                HStack(spacing: 7) {
                    Text("System design")
                    Text("·")
                        .foregroundStyle(LivePalette.muted)
                    Text(model.statusMessage)
                        .foregroundStyle(LivePalette.ink)
                        .lineLimit(1)
                        .frame(width: 86, alignment: .leading)
                        .help(model.statusMessage)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("System design room status")
            .accessibilityValue(model.statusMessage)

            headerDivider

            Menu {
                Text(model.speechReadinessPresentation.title)
                Text(model.speechReadinessPresentation.detail)
                if model.speechReadinessPresentation.canDownload {
                    Button("Download local voice model") {
                        model.startSpeechModelDownload()
                    }
                }
                if model.speechReadinessPresentation.canCancel {
                    Button("Cancel model download") {
                        model.cancelSpeechModelDownload()
                    }
                }
                if model.showsSpeechMuteControl {
                    Button(model.isSpeechMuted ? "Unmute Mara" : "Mute Mara") {
                        Task { await model.toggleSpeechMute() }
                    }
                }
                if model.speechReadinessPresentation.canRemove {
                    Button("Remove local voice model", role: .destructive) {
                        isModelRemovalConfirmationPresented = true
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text("Mara")
                    Text("·")
                    Text("Staff Engineer")
                    if !model.isSpeechReady {
                        speechAttentionBadge
                    }
                }
                .foregroundStyle(LivePalette.navy)
            }
            .menuStyle(.borderlessButton)

            Spacer()

            Label("Private", systemImage: "lock")
            Text("·")
                .foregroundStyle(LivePalette.muted)
            Text(
                model.latestBoardRevision != nil && !model.isBoardDraftDirty
                    ? "Saved"
                    : "Local"
            )
                .foregroundStyle(LivePalette.muted)
            Button(action: onCollapse) {
                Image(systemName: "sidebar.trailing")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("full-room-collapse")
            .accessibilityLabel("Collapse interview room")
            .accessibilityHint("Keeps the same room and board in compact controls")
        }
        .font(.system(.body, design: .rounded))
        .foregroundStyle(LivePalette.ink)
        .padding(.leading, FullRoomHeaderLayout.trafficLightClearance)
        .padding(.trailing, 22)
        .frame(minHeight: FullRoomHeaderLayout.height)
        .background(LivePalette.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(LivePalette.line)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var speechAttentionBadge: some View {
        let presentation = model.speechReadinessPresentation
        if let progress = presentation.progress {
            HStack(spacing: 5) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 42)
                Text("\(Int((progress * 100).rounded()))%")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(presentation.title)
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        } else {
            Label(
                presentation.canDownload ? "Add voice" : "Voice issue",
                systemImage: presentation.systemImage
            )
            .accessibilityLabel(presentation.title)
            .accessibilityHint("Open Mara’s menu for local voice controls")
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUESTION")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(LivePalette.muted)
            Text(model.question)
                .font(.system(size: 31, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34)
        .padding(.vertical, 22)
        .background(LivePalette.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
    }

    private var turnModeRawSelection: Binding<String> {
        Binding(
            get: { model.turnMode.rawValue },
            set: { rawValue in
                guard let mode = model.availableTurnModes.first(where: {
                    $0.rawValue == rawValue
                }) else {
                    return
                }
                Task { await model.selectTurnMode(mode) }
            }
        )
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let snapshot = model.snapshot {
                    ForEach(snapshot.turns.indices, id: \.self) { index in
                        turnlineEntry(
                            snapshot.turns[index],
                            isLast: index == snapshot.turns.count - 1
                                && snapshot.phase != .candidateFloor
                        )
                    }

                    if snapshot.phase == .candidateFloor {
                        candidateFloorEntry
                    } else if snapshot.turns.isEmpty {
                        preparingEmptyState
                    }
                } else {
                    preparingEmptyState
                }
            }
        }
        .background(LivePalette.paper)
    }

    private var preparingEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREPARING ROOM")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(LivePalette.interviewer)
            Text("Restoring the latest complete local session.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(LivePalette.muted)
        }
        .padding(28)
    }

    private var candidateFloorEntry: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 0) {
                Circle()
                    .fill(LivePalette.candidate)
                    .frame(width: 11, height: 11)
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 1)
                    .frame(minHeight: 82)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("YOUR ANSWER DRAFT")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(LivePalette.candidate)
                    Spacer()
                    Text(segmentCountLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(LivePalette.muted)
                }

                if model.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Record your first segment")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                        Text("Working pauses can become separate segments. Only Hand off commits them as one answer.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(LivePalette.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LivePalette.room.opacity(0.48),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(LivePalette.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
                    }
                } else {
                    ForEach(model.segments) { segment in
                        CandidateSegmentCard(
                            segment: segment,
                            isBusy: model.isWorking || model.canStopRecording,
                            onPlay: {
                                Task { await model.playSegment(id: segment.id) }
                            },
                            onTranscribe: {
                                Task { await model.transcribeSegment(id: segment.id) }
                            },
                            onExclude: {
                                Task { await model.excludeSegment(id: segment.id) }
                            }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
    }

    private func turnlineEntry(_ turn: InterviewTurn, isLast: Bool) -> some View {
        let role: String
        let body: String
        let color: Color
        let rendersMarkdown: Bool
        let interviewerTurnID: TurnID?
        let boardRevisionID: BoardRevisionID?

        switch turn {
        case .candidate(let candidate):
            role = "YOU"
            body = candidate.transcript.body
            color = LivePalette.candidate
            rendersMarkdown = false
            interviewerTurnID = nil
            if case .revision(let revisionID) = candidate.boardAttachment {
                boardRevisionID = revisionID
            } else {
                boardRevisionID = nil
            }
        case .interviewer(let interviewer):
            role = "MARA"
            body = interviewer.displayMarkdown
            color = LivePalette.interviewer
            rendersMarkdown = true
            interviewerTurnID = interviewer.id
            boardRevisionID = nil
        }

        return HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                Rectangle()
                    .fill(isLast ? Color.clear : LivePalette.line)
                    .frame(width: 1)
                    .frame(minHeight: 82)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(role)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(color)
                Group {
                    if rendersMarkdown {
                        Text(.init(body))
                    } else {
                        Text(body)
                    }
                }
                    .font(.system(.title3, design: .rounded))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let interviewerTurnID,
                   let utterance = model.utterance(for: interviewerTurnID) {
                    interviewerSpeechRow(utterance)
                }

                if let boardRevisionID {
                    Button {
                        Task { await model.inspectBoardRevision(boardRevisionID) }
                    } label: {
                        Label(
                            boardRevisionLabel(boardRevisionID),
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(LivePalette.violet)
                    .accessibilityHint(
                        "Opens the exact immutable board attached to this answer without changing the current draft"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .contain)
    }

    private func boardRevisionLabel(_ revisionID: BoardRevisionID) -> String {
        guard let revision = model.snapshot?.board.revisions.first(where: {
            $0.id == revisionID
        }) else {
            return "Attached board revision"
        }
        return "Board revision \(revision.ordinal + 1) attached"
    }

    private func interviewerSpeechRow(
        _ utterance: InterviewerUtterance
    ) -> some View {
        let presentation = model.speechPresentation(for: utterance)
        let isPlaying = model.isPlayingSpeech(for: utterance.id)
        let color = utteranceStatusColor(for: presentation.tone)

        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : presentation.systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(isPlaying ? "Playing saved voice" : presentation.title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(color)
                Text(
                    isPlaying
                        ? "Playback uses the exact validated local WAV."
                        : presentation.detail
                )
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPlaying || presentation.canStop {
                Button {
                    Task { await model.stopSpeech() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(LivePalette.handoff)
            } else {
                if presentation.canPlay {
                    Button {
                        Task {
                            await model.playSpeech(utteranceID: utterance.id)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSpeechControlActionInFlight)
                    .accessibilityHint("Plays the exact validated saved WAV without invoking the model")
                }
                if presentation.canRetry {
                    Button {
                        Task {
                            await model.retrySpeech(utteranceID: utterance.id)
                        }
                    } label: {
                        Label(
                            utterance.synthesisAttempts.isEmpty ? "Generate" : "Retry",
                            systemImage: utterance.synthesisAttempts.isEmpty
                                ? "waveform"
                                : "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !model.isSpeechReady
                            || model.isSpeechControlActionInFlight
                    )
                    .accessibilityHint(
                        model.isSpeechReady
                            ? "Creates a fresh synthesis attempt while preserving prior saved audio"
                            : "Install and verify Mara’s local model first"
                    )
                }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(LivePalette.line.opacity(0.8)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func utteranceStatusColor(
        for tone: InterviewerUtterancePresentation.Tone
    ) -> Color {
        switch tone {
        case .quiet: return LivePalette.muted
        case .working: return LivePalette.interviewer
        case .speaking: return LivePalette.interviewer
        case .ready: return LivePalette.candidate
        case .warning: return LivePalette.warning
        }
    }

    private var board: some View {
        SystemDesignBoardView(model: model)
    }

    private var floorRail: some View {
        HStack(spacing: 16) {
            Text(floorLabel.uppercased())
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(LivePalette.violet)

            LiveWaveform(isActive: model.canStopRecording)
                .frame(minWidth: 180, maxWidth: .infinity)
                .frame(height: 32)

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                Label(model.actionTitle, systemImage: model.actionIcon)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(LivePalette.violet)
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])

            headerDivider

            if model.canStopRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LivePalette.navy)
                .disabled(model.isWorking)
                .keyboardShortcut(.space, modifiers: [.command])
            } else if model.showsRecordControl {
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LivePalette.navy)
                .disabled(!model.canRecordSegment)
                .keyboardShortcut(.space, modifiers: [.command])
            }

            headerDivider

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                Label("End", systemImage: "stop.fill")
                    .font(.system(.body, design: .rounded, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LivePalette.orange)
        }
        .foregroundStyle(LivePalette.navy)
        .padding(.horizontal, 22)
        .frame(minHeight: 76)
        .background(LivePalette.paper)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LivePalette.line, lineWidth: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private var floorLabel: String {
        if model.isInterviewerRequestInFlight {
            return "Answer saved · Codex working"
        }
        switch model.snapshot?.phase {
        case .candidateFloor:
            return "Your floor"
        case .interviewerProcessing:
            return model.isCodexReady
                ? "Answer saved · interviewer retry required"
                : "Answer saved · check Codex to retry"
        case .interviewerTurn:
            return "Interviewer turn"
        case .completed:
            return "Session complete"
        default:
            return "Preparing room"
        }
    }

    private var segmentCountLabel: String {
        let count = model.segments.count
        return count == 1 ? "1 SEGMENT" : "\(count) SEGMENTS"
    }

    private func recoveryBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LivePalette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.needsGroqCredential {
                Button("Add Groq key") {
                    model.presentCredentialSetup()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.5)).frame(height: 1)
        }
    }

    private func codexReadinessBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.codexStatusIcon)
                .foregroundStyle(LivePalette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.codexStatusTitle)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Text(message)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Check Codex") {
                Task { await model.checkCodex() }
            }
            .disabled(model.isCheckingCodex)
            .accessibilityHint("Runs a private local compatibility and sign-in check")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

enum FullRoomHeaderLayout {
    /// The full-size-content window draws into the titlebar. This keeps the
    /// brand beyond the standard close/minimize/zoom group while the 62-point
    /// custom header occupies that same row instead of leaving a blank strip.
    static let trafficLightClearance: CGFloat = 84
    static let height: CGFloat = 62
}

enum LivePalette {
    static let room = Color(red: 250 / 255, green: 251 / 255, blue: 254 / 255)
    static let paper = Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
    static let ink = Color(red: 14 / 255, green: 17 / 255, blue: 30 / 255)
    static let navy = Color(red: 24 / 255, green: 35 / 255, blue: 89 / 255)
    static let violet = Color(red: 75 / 255, green: 58 / 255, blue: 191 / 255)
    static let orange = Color(red: 237 / 255, green: 78 / 255, blue: 47 / 255)
    static let muted = Color(red: 82 / 255, green: 98 / 255, blue: 139 / 255)
    static let line = Color(red: 224 / 255, green: 226 / 255, blue: 237 / 255)
    static let shell = paper
    static let candidate = orange
    static let interviewer = violet
    static let handoff = violet
    static let liveSignal = violet
    static let warning = orange
}

private struct LiveWaveform: View {
    let isActive: Bool

    private let levels: [Double] = [
        0.18, 0.42, 0.24, 0.66, 0.31, 0.52, 0.2, 0.76, 0.38, 0.24,
        0.58, 0.33, 0.7, 0.28, 0.45, 0.2, 0.62, 0.35, 0.22, 0.48,
        0.3, 0.68, 0.26, 0.5, 0.21, 0.4, 0.18, 0.34, 0.2, 0.28,
    ]

    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: center))
            baseline.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(
                baseline,
                with: .color(LivePalette.violet.opacity(0.7)),
                lineWidth: 1
            )

            let spacing = min(7.0, size.width / Double(levels.count + 2))
            for (index, level) in levels.enumerated() {
                let x = 10 + Double(index) * spacing
                let height = max(3, level * size.height * (isActive ? 0.88 : 0.55))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - height / 2))
                bar.addLine(to: CGPoint(x: x, y: center + height / 2))
                context.stroke(
                    bar,
                    with: .color(LivePalette.violet),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LiveMark: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.05, to: 0.43)
                .stroke(LivePalette.violet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-22))
            Circle()
                .trim(from: 0.55, to: 0.92)
                .stroke(LivePalette.navy, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-22))
            Circle()
                .fill(LivePalette.orange)
                .frame(width: 7, height: 7)
                .offset(x: 10, y: 8)
        }
        .padding(4)
        .accessibilityLabel("Interview Arc Live")
    }
}

private struct SystemDesignRoomViewPreview: PreviewProvider {
    static var previews: some View {
        SystemDesignRoomView(model: SystemDesignRoomModel())
            .frame(width: 1180, height: 760)
            .previewDisplayName("System design tracer")
    }
}
