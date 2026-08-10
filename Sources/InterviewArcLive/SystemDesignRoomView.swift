import Foundation
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

            GeometryReader { workspace in
                HSplitView {
                    transcript
                        .frame(
                            minWidth: FullRoomLayout.turnlineMinimumWidth,
                            idealWidth: FullRoomLayout.turnlineIdealWidth(
                                for: workspace.size.width
                            ),
                            maxWidth: FullRoomLayout.turnlineMaximumWidth
                        )
                    board
                        .frame(minWidth: FullRoomLayout.boardMinimumWidth)
                        .accessibilityIdentifier(FullRoomAccessibility.board)
                }
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
        GeometryReader { geometry in
            let state = FullRoomHeaderLayout.state(
                windowWidth: geometry.size.width,
                hasSpeechAttention: !model.isSpeechReady,
                hasRoomAttention: model.errorMessage != nil
                    || model.codexAttentionMessage != nil
            )

            Group {
                if state.usesAttentionCompactHeader {
                    compactHeaderContent
                } else {
                    ViewThatFits(in: .horizontal) {
                        fullHeaderContent
                            .fixedSize(horizontal: true, vertical: false)
                        compactHeaderContent
                    }
                }
            }
            .font(.system(.body, design: .rounded))
            .foregroundStyle(LivePalette.ink)
            .padding(.leading, FullRoomLayout.trafficLightClearance)
            .padding(.trailing, 22)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .leading
            )
        }
        .frame(height: FullRoomLayout.headerHeight)
        .background(LivePalette.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
    }

    private var fullHeaderContent: some View {
        HStack(spacing: 16) {
            headerBrand
            Spacer(minLength: 22)
            roomStatusMenu(isCompact: false)
            headerDivider
            personaMenu(isCompact: false)
            Spacer(minLength: 22)
            privacyStatus(isCompact: false)
            collapseButton
        }
    }

    private var compactHeaderContent: some View {
        HStack(spacing: 12) {
            headerBrand
            Spacer(minLength: 12)
            roomStatusMenu(isCompact: true)
            headerDivider
            personaMenu(isCompact: true)
            Spacer(minLength: 12)
            privacyStatus(isCompact: true)
            collapseButton
        }
    }

    private var headerBrand: some View {
        HStack(spacing: 14) {
            LiveMark()
                .frame(width: 34, height: 34)
            Text("Interview Arc Live")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func roomStatusMenu(isCompact: Bool) -> some View {
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
            if isCompact {
                HStack(spacing: 7) {
                    Text("System design")
                        .fontWeight(.semibold)
                    Circle()
                        .fill(headerRoomStatusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                .help("System design · \(model.statusMessage)")
            } else {
                HStack(spacing: 7) {
                    Text("System design")
                        .fontWeight(.semibold)
                    Text("·")
                        .foregroundStyle(LivePalette.muted)
                    Text(model.statusMessage)
                        .foregroundStyle(LivePalette.ink)
                        .lineLimit(1)
                        .frame(width: 86, alignment: .leading)
                        .help(model.statusMessage)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(FullRoomHeaderAccessibility.roomStatusLabel)
        .accessibilityValue(model.statusMessage)
    }

    private func personaMenu(isCompact: Bool) -> some View {
        Menu {
            Text("Mara · Staff Engineer")
            Divider()
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
                    .fontWeight(.semibold)
                if !isCompact {
                    Text("·")
                    Text("Staff Engineer")
                }
                if !model.isSpeechReady {
                    speechAttentionBadge
                }
            }
            .foregroundStyle(LivePalette.navy)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(FullRoomHeaderAccessibility.personaLabel)
        .accessibilityValue(model.speechReadinessPresentation.title)
    }

    private func privacyStatus(isCompact: Bool) -> some View {
        HStack(spacing: 7) {
            Label("Private", systemImage: "lock")
            if isCompact {
                Image(systemName: isBoardSaved ? "checkmark.circle.fill" : "internaldrive")
                    .foregroundStyle(LivePalette.muted)
                    .accessibilityHidden(true)
            } else {
                Text("·")
                    .foregroundStyle(LivePalette.muted)
                Text(boardSaveStatus)
                    .foregroundStyle(LivePalette.muted)
            }
        }
        .fixedSize()
        .help("Private · \(boardSaveStatus)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FullRoomHeaderAccessibility.privacyLabel)
        .accessibilityValue(boardSaveStatus)
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "sidebar.trailing")
                .frame(
                    width: FullRoomLayout.minimumActionHitTarget,
                    height: FullRoomLayout.minimumActionHitTarget
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(FullRoomAccessibility.collapse)
        .accessibilityLabel(FullRoomHeaderAccessibility.collapseLabel)
        .accessibilityHint("Keeps the same room and board in compact controls")
    }

    private var boardSaveStatus: String {
        isBoardSaved ? "Saved" : "Local"
    }

    private var isBoardSaved: Bool {
        model.latestBoardRevision != nil && !model.isBoardDraftDirty
    }

    private var headerRoomStatusColor: Color {
        model.errorMessage == nil && model.codexAttentionMessage == nil
            ? LivePalette.interviewer
            : LivePalette.warning
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
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(LivePalette.navy)
            Text(model.question)
                .font(.system(size: 35, weight: .semibold, design: .rounded))
                .tracking(-0.35)
                .lineLimit(FullRoomLayout.questionLineLimit)
                .minimumScaleFactor(FullRoomLayout.questionMinimumScaleFactor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .frame(
            maxWidth: .infinity,
            minHeight: FullRoomLayout.questionBandMinimumHeight,
            alignment: .leading
        )
        .background(LivePalette.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(FullRoomAccessibility.question)
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
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("TURNLINE")
                    .font(.system(.callout, design: .monospaced, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(LivePalette.navy)
                Spacer(minLength: 12)
                Text(turnlineSummary)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(LivePalette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 30)
            .frame(minHeight: FullRoomLayout.turnlineHeaderHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LivePalette.line).frame(height: 1)
            }

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
                .padding(.top, 26)
            }
        }
        .background(LivePalette.paper)
        .accessibilityIdentifier(FullRoomAccessibility.turnline)
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
                    .fill(LivePalette.candidateText)
                    .frame(width: 12, height: 12)
                Rectangle()
                    .fill(LivePalette.candidateText.opacity(0.22))
                    .frame(width: 1)
                    .frame(minHeight: 96)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("YOU · CURRENT TURN")
                        .font(.system(.callout, design: .monospaced, weight: .bold))
                        .foregroundStyle(LivePalette.candidateText)
                    Spacer()
                    Text(segmentCountLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(LivePalette.muted)
                }

                if model.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ready for your next answer.")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text("Record one or more segments here. Working pauses stay in this Candidate Turn until you choose Hand off.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(LivePalette.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 360, alignment: .leading)
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
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 30)
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
            color = LivePalette.candidateText
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
                    .font(.system(.callout, design: .monospaced, weight: .bold))
                    .foregroundStyle(color)
                Group {
                    if rendersMarkdown {
                        Text(.init(body))
                    } else {
                        Text(body)
                    }
                }
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .lineSpacing(4)
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
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 30)
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
        case .ready: return LivePalette.candidateText
        case .warning: return LivePalette.warning
        }
    }

    private var board: some View {
        SystemDesignBoardView(model: model)
    }

    private var floorRail: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(floorLabel.uppercased())
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(LivePalette.violet)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(floorStatusDetail)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(LivePalette.muted)
                    .lineLimit(1)
            }
            .frame(width: 164, alignment: .leading)

            LiveWaveform(isActive: model.canStopRecording)
                .frame(minWidth: 140, maxWidth: .infinity)
                .frame(height: FullRoomLayout.minimumActionHitTarget)

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                Label(model.actionTitle, systemImage: model.actionIcon)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(
                        minWidth: 132,
                        minHeight: FullRoomLayout.minimumActionHitTarget
                    )
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(LivePalette.violet)
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier(FullRoomAccessibility.primaryAction)

            if model.canStopRecording {
                headerDivider
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(minWidth: 86, minHeight: FullRoomLayout.minimumActionHitTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LivePalette.navy)
                .disabled(model.isWorking)
                .keyboardShortcut(.space, modifiers: [.command])
                .accessibilityIdentifier(FullRoomAccessibility.recordingAction)
            } else if model.showsRecordControl {
                headerDivider
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(minWidth: 86, minHeight: FullRoomLayout.minimumActionHitTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LivePalette.navy)
                .disabled(!model.canRecordSegment)
                .keyboardShortcut(.space, modifiers: [.command])
                .accessibilityIdentifier(FullRoomAccessibility.recordingAction)
            }

            headerDivider

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                Label("End", systemImage: "stop.fill")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .frame(minWidth: 70, minHeight: FullRoomLayout.minimumActionHitTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LivePalette.warning)
            .accessibilityIdentifier(FullRoomAccessibility.endAction)
        }
        .foregroundStyle(LivePalette.navy)
        .padding(.horizontal, 24)
        .frame(minHeight: FullRoomLayout.floorRailHeight)
        .background(LivePalette.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(FullRoomAccessibility.floorRail)
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

    private var floorStatusDetail: String {
        if model.canStopRecording {
            return "Recording segment"
        }
        if model.isInterviewerRequestInFlight {
            return "Codex is preparing Mara"
        }
        switch model.snapshot?.phase {
        case .candidateFloor:
            return model.segments.isEmpty ? "No segment yet" : segmentCountLabel.capitalized
        case .interviewerProcessing:
            return "Candidate answer saved"
        case .interviewerTurn:
            return "Mara has the floor"
        case .completed:
            return "Local session saved"
        default:
            return "Restoring local session"
        }
    }

    private var turnlineSummary: String {
        guard let snapshot = model.snapshot else {
            return "RESTORING SESSION"
        }
        if snapshot.phase == .candidateFloor {
            return model.segments.isEmpty
                ? "CANDIDATE FLOOR"
                : "CURRENT TURN · \(segmentCountLabel)"
        }
        let count = snapshot.turns.count
        return count == 1 ? "1 SAVED TURN" : "\(count) SAVED TURNS"
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

enum FullRoomLayout {
    static let minimumWindowWidth: CGFloat = 1_080
    static let defaultWindowWidth: CGFloat = 1_180
    static let minimumWindowHeight: CGFloat = 700
    static let headerHeight: CGFloat = 70
    static let questionBandMinimumHeight: CGFloat = 120
    static let questionLineLimit = 2
    static let questionMinimumScaleFactor: CGFloat = 0.82
    static let turnlineHeaderHeight: CGFloat = 58
    static let turnlineWidthFraction: CGFloat = 0.37
    static let turnlineMinimumWidth: CGFloat = 380
    static let turnlineMaximumWidth: CGFloat = 480
    static let boardMinimumWidth: CGFloat = 620
    static let floorRailHeight: CGFloat = 88
    static let minimumActionHitTarget: CGFloat = 44

    /// The full-size-content window draws into the titlebar. This keeps the
    /// brand beyond the standard close/minimize/zoom group while the custom
    /// header occupies that same row instead of leaving a blank strip.
    static let trafficLightClearance: CGFloat = 84

    static func turnlineIdealWidth(for workspaceWidth: CGFloat) -> CGFloat {
        min(
            max(workspaceWidth * turnlineWidthFraction, turnlineMinimumWidth),
            turnlineMaximumWidth
        )
    }

    static func boardIdealWidth(for workspaceWidth: CGFloat) -> CGFloat {
        max(boardMinimumWidth, workspaceWidth - turnlineIdealWidth(for: workspaceWidth))
    }

    static func minimumWorkspaceHeight(for windowHeight: CGFloat) -> CGFloat {
        max(0, windowHeight - headerHeight - questionBandMinimumHeight - floorRailHeight)
    }
}

enum FullRoomHeaderAttention: Equatable {
    case none
    case speech
    case room
    case speechAndRoom
}

struct FullRoomHeaderLayoutState: Equatable {
    let windowWidth: CGFloat
    let attention: FullRoomHeaderAttention

    var usesAttentionCompactHeader: Bool {
        attention != .none
            && windowWidth <= FullRoomHeaderLayout.attentionCompactMaximumWidth
    }
}

enum FullRoomHeaderLayout {
    static let attentionCompactMaximumWidth: CGFloat = 1_100

    static func state(
        windowWidth: CGFloat,
        hasSpeechAttention: Bool,
        hasRoomAttention: Bool
    ) -> FullRoomHeaderLayoutState {
        let attention: FullRoomHeaderAttention
        switch (hasSpeechAttention, hasRoomAttention) {
        case (false, false): attention = .none
        case (true, false): attention = .speech
        case (false, true): attention = .room
        case (true, true): attention = .speechAndRoom
        }
        return FullRoomHeaderLayoutState(
            windowWidth: windowWidth,
            attention: attention
        )
    }
}

enum FullRoomHeaderAccessibility {
    static let roomStatusLabel = "System design room status"
    static let personaLabel = "Interviewer: Mara, Staff Engineer"
    static let privacyLabel = "Private local session"
    static let collapseLabel = "Collapse interview room"
}

enum FullRoomAccessibility {
    static let question = "full-room-question"
    static let turnline = "full-room-turnline"
    static let board = "full-room-board"
    static let floorRail = "full-room-floor-rail"
    static let primaryAction = "full-room-primary-action"
    static let recordingAction = "full-room-recording-action"
    static let endAction = "full-room-end-action"
    static let collapse = "full-room-collapse"

    static let allIdentifiers = [
        question,
        turnline,
        board,
        floorRail,
        primaryAction,
        recordingAction,
        endAction,
        collapse,
    ]
}

struct LiveRGB: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    func contrastRatio(against other: LiveRGB) -> Double {
        let light = max(relativeLuminance, other.relativeLuminance)
        let dark = min(relativeLuminance, other.relativeLuminance)
        return (light + 0.05) / (dark + 0.05)
    }

    private var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    private static func linearized(_ component: Int) -> Double {
        let value = Double(component) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

enum LivePalette {
    static let roomToken = LiveRGB(red: 250, green: 251, blue: 254)
    static let paperToken = LiveRGB(red: 252, green: 252, blue: 254)
    static let candidateTextToken = LiveRGB(red: 159, green: 46, blue: 34)

    static let room = roomToken.color
    static let paper = paperToken.color
    static let ink = Color(red: 14 / 255, green: 17 / 255, blue: 30 / 255)
    static let navy = Color(red: 24 / 255, green: 35 / 255, blue: 89 / 255)
    static let violet = Color(red: 75 / 255, green: 58 / 255, blue: 191 / 255)
    static let signalOrange = Color(red: 237 / 255, green: 78 / 255, blue: 47 / 255)
    static let candidateText = candidateTextToken.color
    static let muted = Color(red: 82 / 255, green: 98 / 255, blue: 139 / 255)
    static let line = Color(red: 224 / 255, green: 226 / 255, blue: 237 / 255)
    static let shell = paper
    static let interviewer = violet
    static let handoff = violet
    static let liveSignal = violet
    static let warning = candidateText
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
                .fill(LivePalette.signalOrange)
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
