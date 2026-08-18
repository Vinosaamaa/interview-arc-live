import AppKit
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveHostedClient
import SwiftUI

struct SystemDesignRoomView: View {
    @ObservedObject var model: SystemDesignRoomModel
    let onCollapse: () -> Void
    @State private var isModelRemovalConfirmationPresented = false
    @State private var preferredTurnlineWidth: CGFloat?
    @State private var isWorkspaceDividerHovered = false
    @GestureState private var splitDragTranslation: CGFloat = 0

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
            GeometryReader { workspace in
                let baseTurnlineWidth = FullRoomLayout.turnlineBaseWidth(
                    for: workspace.size.width,
                    preferredTurnlineWidth: preferredTurnlineWidth
                )
                let widths = FullRoomLayout.workspaceWidths(
                    for: workspace.size.width,
                    preferredTurnlineWidth: preferredTurnlineWidth
                )
                let splitPreview = FullRoomLayout.splitDragPreview(
                    baseWidth: baseTurnlineWidth,
                    dragTranslation: splitDragTranslation,
                    workspaceWidth: workspace.size.width
                )

                HStack(spacing: 0) {
                    conversationPane
                        .frame(
                            width: widths.turnlineWidth,
                            height: workspace.size.height
                        )
                        .overlay(alignment: .trailing) {
                            workspaceDivider(
                                baseWidth: baseTurnlineWidth,
                                currentWidth: splitPreview.proposedTurnlineWidth,
                                totalWidth: widths.totalWidth
                            )
                            .offset(
                                x: FullRoomLayout.workspaceDividerHitWidth / 2
                                    + splitPreview.translation
                            )
                        }
                    board
                        .frame(
                            width: widths.boardWidth,
                            height: workspace.size.height
                        )
                        .accessibilityIdentifier(FullRoomAccessibility.board)
                }
                .frame(
                    width: widths.totalWidth,
                    height: workspace.size.height,
                    alignment: .leading
                )
                .coordinateSpace(
                    name: FullRoomLayout.workspaceCoordinateSpaceName
                )
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
        .sheet(isPresented: $model.isLiveIntegrationSetupPresented) {
            LiveIntegrationSetupView(
                isWorking: model.isWorking,
                errorMessage: model.errorMessage,
                onSave: model.saveLiveIntegrationToken
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
            let statusPresentation = FullRoomHeaderStatusLayout.presentation(
                headerPresentation: state.presentation,
                windowWidth: geometry.size.width,
                statusMessage: model.statusMessage
            )

            Group {
                if state.presentation == .compact {
                    compactHeaderContent(
                        statusPresentation: statusPresentation
                    )
                } else {
                    fullHeaderContent(
                        statusPresentation: statusPresentation
                    )
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

    private func fullHeaderContent(
        statusPresentation: FullRoomHeaderStatusPresentation
    ) -> some View {
        HStack(spacing: 16) {
            headerBrand
            Spacer(minLength: 22)
            roomStatusMenu(presentation: statusPresentation)
            headerDivider
            personaMenu(isCompact: false)
            Spacer(minLength: 22)
            privacyStatus(isCompact: false)
            collapseButton
        }
        .frame(maxWidth: .infinity)
    }

    private func compactHeaderContent(
        statusPresentation: FullRoomHeaderStatusPresentation
    ) -> some View {
        HStack(spacing: 12) {
            headerBrand
            Spacer(minLength: 12)
            roomStatusMenu(presentation: statusPresentation)
            headerDivider
            personaMenu(isCompact: true)
            Spacer(minLength: 12)
            privacyStatus(isCompact: true)
            collapseButton
        }
        .frame(maxWidth: .infinity)
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

    private func roomStatusMenu(
        presentation: FullRoomHeaderStatusPresentation
    ) -> some View {
        let endpointPresentation = model.endpointHandoffPresentation
        return Menu {
            Picker("Turn-taking", selection: turnModeRawSelection) {
                ForEach(model.availableTurnModes, id: \.rawValue) { mode in
                    Text(model.turnModeTitle(mode)).tag(mode.rawValue)
                }
            }
            Divider()
            Text(endpointPresentation.title)
            Text(endpointPresentation.detail)
            if model.usesHostedAuthority {
                Divider()
                Text(model.hostedConnectionTitle)
                if model.hostedSnapshot.connection == .signedOut {
                    Button("Connect Interview Arc") {
                        model.isLiveIntegrationSetupPresented = true
                    }
                } else {
                    Button("Refresh hosted activity") {
                        Task { await model.refreshHostedAuthority() }
                    }
                    Button("Disconnect Interview Arc", role: .destructive) {
                        Task { await model.disconnectLiveIntegration() }
                    }
                }
            }
            if model.needsGroqCredential {
                Button("Add Groq key") { model.presentCredentialSetup() }
            }
            Button("Check Codex") { Task { await model.checkCodex() } }
        } label: {
            switch presentation.style {
            case .compact:
                HStack(spacing: 7) {
                    Text(presentation.visibleText)
                        .fontWeight(.semibold)
                    Circle()
                        .fill(headerRoomStatusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            case .wideInline:
                Text(presentation.visibleText)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            case .wideWrapped:
                Text(presentation.visibleText)
                    .fontWeight(.semibold)
                    .lineLimit(presentation.lineLimit)
                    .multilineTextAlignment(.leading)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.92)
                    .frame(
                        width: presentation.frameWidth,
                        alignment: .leading
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .menuStyle(.borderlessButton)
        .help(presentation.helpText)
        .accessibilityLabel(FullRoomHeaderAccessibility.roomStatusLabel)
        .accessibilityValue(presentation.accessibilityValue)
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
                Text(
                    isCompact
                        ? FullRoomHeaderLabels.compactPersona
                        : FullRoomHeaderLabels.widePersona
                )
                    .fontWeight(.semibold)
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
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .frame(
                    width: FullRoomLayout.minimumActionHitTarget,
                    height: FullRoomLayout.minimumActionHitTarget
                )
        }
        .buttonStyle(RoomChromeButtonStyle())
        .accessibilityIdentifier(FullRoomAccessibility.collapse)
        .accessibilityLabel("Collapse to compact controls")
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

    private var conversationPane: some View {
        VStack(spacing: 0) {
            question
            if let errorMessage = model.errorMessage {
                recoveryBanner(errorMessage)
            }
            if let codexMessage = model.codexAttentionMessage {
                codexReadinessBanner(codexMessage)
            }
            transcript
        }
        .background(LivePalette.paper)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: FullRoomLayout.questionStackSpacing) {
            Text("QUESTION")
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(LivePalette.navy)
            Text(model.question)
                .font(
                    .system(
                        size: FullRoomLayout.questionTitleSize,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .tracking(-0.35)
                .lineLimit(FullRoomLayout.questionLineLimit)
                .minimumScaleFactor(FullRoomLayout.questionMinimumScaleFactor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, FullRoomLayout.questionHorizontalPadding)
        .padding(.top, FullRoomLayout.questionTopPadding)
        .padding(.bottom, FullRoomLayout.questionBottomPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: FullRoomLayout.questionBandMinimumHeight,
            alignment: .topLeading
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.usesHostedAuthority && !model.hostedPairs.isEmpty {
                        ForEach(Array(model.hostedPairs.enumerated()), id: \.element.id) {
                            index, pair in
                            hostedTurnlineEntry(
                                role: "YOU",
                                body: pair.candidate.text,
                                color: LivePalette.candidateText,
                                rendersMarkdown: false,
                                isLast: false,
                                pair: pair
                            )
                            hostedTurnlineEntry(
                                role: "MARA",
                                body: pair.interviewer.displayMarkdown,
                                color: LivePalette.interviewer,
                                rendersMarkdown: true,
                                isLast: index == model.hostedPairs.count - 1
                                    && model.snapshot?.phase != .candidateFloor,
                                pair: nil
                            )
                        }
                        if model.snapshot?.phase == .candidateFloor {
                            candidateFloorEntry
                        }
                    } else if let snapshot = model.snapshot {
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
                            emptyTurnlineState
                        }
                    } else {
                        emptyTurnlineState
                    }
                }
                .padding(.top, 26)
            }
        }
        .background(LivePalette.paper)
        .accessibilityIdentifier(FullRoomAccessibility.turnline)
    }

    private func workspaceDivider(
        baseWidth: CGFloat,
        currentWidth: CGFloat,
        totalWidth: CGFloat
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(LivePalette.line)
                .frame(width: FullRoomLayout.workspaceVisualDividerWidth)
            Capsule()
                .fill(LivePalette.violet.opacity(0.72))
                .frame(width: 3, height: 42)
                .opacity(isWorkspaceDividerHovered ? 1 : 0)
        }
        .frame(width: FullRoomLayout.workspaceDividerHitWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            isWorkspaceDividerHovered = hovering
            if hovering { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
        .onDisappear {
            guard isWorkspaceDividerHovered else { return }
            NSCursor.pop()
            isWorkspaceDividerHovered = false
        }
        .animation(.easeOut(duration: 0.14), value: isWorkspaceDividerHovered)
        .gesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: .named(
                    FullRoomLayout.workspaceCoordinateSpaceName
                )
            )
                .updating($splitDragTranslation) { value, state, _ in
                    state = value.translation.width
                }
                .onEnded { value in
                    preferredTurnlineWidth = FullRoomLayout.committedTurnlineWidth(
                        baseWidth: baseWidth,
                        dragTranslation: value.translation.width,
                        workspaceWidth: totalWidth
                    )
                }
        )
        .onTapGesture(count: 2) {
            preferredTurnlineWidth = nil
        }
        .help("Drag to resize the question and Turnline")
        .accessibilityElement()
        .accessibilityLabel("Resize question and Turnline pane")
        .accessibilityValue(
            "\(Int((currentWidth / max(totalWidth, 1) * 100).rounded())) percent, \(Int(currentWidth.rounded())) points wide"
        )
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 24 : -24
            preferredTurnlineWidth = FullRoomLayout.clampedTurnlineWidth(
                currentWidth + delta,
                for: totalWidth
            )
        }
    }

    private var emptyTurnlineState: some View {
        let presentation = model.floorStatePresentation

        return VStack(alignment: .leading, spacing: 10) {
            Text(presentation.full.label.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(
                    presentation.tone == .warning
                        ? LivePalette.warning
                        : LivePalette.interviewer
                )
            Text(presentation.full.detail)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(LivePalette.muted)
        }
        .padding(28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.full.accessibilityValue)
    }

    private var candidateFloorEntry: some View {
        HStack(alignment: .top, spacing: FullRoomLayout.turnlineEntryGap) {
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
                            .font(
                                .system(
                                    size: FullRoomLayout.turnlineBodyFontSize,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
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
        .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
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

        return turnlineRow(
            role: role,
            body: body,
            color: color,
            rendersMarkdown: rendersMarkdown,
            isLast: isLast
        ) {
            Group {
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
        }
    }

    private func hostedTurnlineEntry(
        role: String,
        body: String,
        color: Color,
        rendersMarkdown: Bool,
        isLast: Bool,
        pair: LivePair?
    ) -> some View {
        turnlineRow(
            role: role,
            body: body,
            color: color,
            rendersMarkdown: rendersMarkdown,
            isLast: isLast
        ) {
            if let pair,
               pair.candidate.evidenceStatus == .possibleContamination,
               !pair.candidate.evidenceSatisfied {
                Button("Confirm this transcript") {
                    Task {
                        await model.confirmHostedCandidateEvidence(
                            pairID: pair.pairId
                        )
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint(
                    "Explicitly accepts possible contamination so hosted Finish can proceed"
                )
            }
        }
    }

    private func turnlineRow<Accessory: View>(
        role: String,
        body: String,
        color: Color,
        rendersMarkdown: Bool,
        isLast: Bool,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: FullRoomLayout.turnlineEntryGap) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 11, height: 11)
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
                    if rendersMarkdown { Text(.init(body)) }
                    else { Text(body) }
                }
                .font(
                    .system(
                        size: FullRoomLayout.turnlineBodyFontSize,
                        weight: .medium,
                        design: .rounded
                    )
                )
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

                accessory()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 30)
        }
        .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
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
        ViewThatFits(in: .horizontal) {
            floorRailContent(compact: false)
                .fixedSize(horizontal: true, vertical: false)
            floorRailContent(compact: true)
        }
        .foregroundStyle(LivePalette.navy)
        .frame(minHeight: FullRoomLayout.floorRailHeight)
        .background(LivePalette.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(FullRoomAccessibility.floorRail)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LivePalette.line, lineWidth: 1)
                .padding(
                    .horizontal,
                    FullRoomLayout.floorOutlineHorizontalInset
                )
                .padding(.vertical, FullRoomLayout.floorOutlineVerticalInset)
        }
    }

    private func floorRailContent(compact: Bool) -> some View {
        let floorState = model.floorStatePresentation

        return HStack(
            spacing: compact ? FullRoomLayout.floorCompactSpacing : 14
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text(floorState.full.label.uppercased())
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(LivePalette.violet)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !compact {
                    Text(floorState.full.detail)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(LivePalette.muted)
                        .lineLimit(1)
                }
            }
            .frame(
                width: compact
                    ? FullRoomLayout.floorCompactStatusWidth
                    : FullRoomLayout.floorStatusWidth,
                alignment: .leading
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(floorState.full.label)
            .accessibilityValue(floorState.full.detail)

            LiveWaveform(
                isActive: model.canStopRecording,
                powerHistory: model.recordingPowerHistory,
                elapsedSeconds: model.recordingElapsedSeconds
            )
                .frame(
                    minWidth: compact
                        ? FullRoomLayout.floorCompactWaveformWidth
                        : 140,
                    maxWidth: .infinity
                )
                .frame(height: FullRoomLayout.minimumActionHitTarget)

            if model.usesHostedAuthority {
                Button {
                    Task { await model.toggleHostedTimer() }
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        floorActionLabel(
                            model.hostedElapsedText(at: context.date)
                                ?? (model.hostedTimerIsRunning ? "Pause" : "Start"),
                            systemImage: model.hostedTimerIsRunning
                                ? "pause.circle.fill"
                                : "play.circle.fill",
                            compact: compact,
                            wideMinimumWidth: 76
                        )
                        .monospacedDigit()
                        .accessibilityValue(
                            model.hostedElapsedText(at: context.date) ?? ""
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.isHostedWritable)
                .accessibilityLabel(
                    model.hostedTimerIsRunning
                        ? "Pause hosted activity timer"
                        : "Start hosted activity timer"
                )

                Menu {
                    Button("Solved") {
                        Task { await model.setHostedResult(.solved) }
                    }
                    Button("Solved after reviewing approach") {
                        Task {
                            await model.setHostedResult(
                                .solvedAfterReviewingApproach
                            )
                        }
                    }
                    Button("Failed") {
                        Task { await model.setHostedResult(.failed) }
                    }
                    if model.hostedResult != nil {
                        Divider()
                        Button("Clear result", role: .destructive) {
                            Task { await model.setHostedResult(nil) }
                        }
                    }
                } label: {
                    floorActionLabel(
                        hostedResultTitle,
                        systemImage: "checkmark.seal",
                        compact: compact,
                        wideMinimumWidth: 88
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(!model.isHostedWritable)
                .accessibilityLabel("Hosted result: \(hostedResultTitle)")
                .help("Set the hosted activity result")
            }

            if model.activeEndpointGrace != nil {
                Button {
                    Task { await model.keepMyFloor() }
                } label: {
                    floorActionLabel(
                        "Keep my floor",
                        systemImage: "hand.raised.fill",
                        compact: compact,
                        wideMinimumWidth: 112
                    )
                }
                .buttonStyle(RoomChromeButtonStyle())
                .foregroundStyle(LivePalette.violet)
                .disabled(!model.canKeepFloor)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityIdentifier(FullRoomAccessibility.keepFloorAction)
                .accessibilityLabel("Keep my floor")
                .accessibilityHint("Cancels the pending automatic Hand off without changing saved answer evidence")
                .help("Cancel automatic Hand off")
            }

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                floorActionLabel(
                    model.actionTitle,
                    systemImage: model.actionIcon,
                    compact: compact,
                    wideMinimumWidth: 132
                )
            }
            .buttonStyle(RoomChromeButtonStyle())
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier(FullRoomAccessibility.primaryAction)
            .accessibilityLabel(model.actionTitle)
            .accessibilityHint(floorState.primaryActionHint)
            .help(model.actionTitle)

            if model.canStopRecording {
                headerDivider
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    floorActionLabel(
                        "Pause",
                        systemImage: "pause.fill",
                        compact: compact,
                        wideMinimumWidth: 86
                    )
                }
                .buttonStyle(RoomChromeButtonStyle())
                .foregroundStyle(LivePalette.navy)
                .disabled(model.isWorking)
                .keyboardShortcut(.space, modifiers: [.command])
                .accessibilityIdentifier(FullRoomAccessibility.recordingAction)
                .accessibilityLabel("Pause recording")
                .help("Pause recording")
            } else if model.showsRecordControl {
                headerDivider
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    floorActionLabel(
                        "Record",
                        systemImage: "record.circle",
                        compact: compact,
                        wideMinimumWidth: 86
                    )
                }
                .buttonStyle(RoomChromeButtonStyle())
                .foregroundStyle(LivePalette.navy)
                .disabled(!model.canRecordSegment)
                .keyboardShortcut(.space, modifiers: [.command])
                .accessibilityIdentifier(FullRoomAccessibility.recordingAction)
                .accessibilityLabel("Record answer segment")
                .help("Record answer segment")
            }

            headerDivider

            if model.hostedNextSystemDesignActivityID != nil {
                Button {
                    Task { _ = await model.finishAndOpenNextInterview() }
                } label: {
                    floorActionLabel(
                        "Finish & next",
                        systemImage: "forward.end.fill",
                        compact: compact,
                        wideMinimumWidth: 112,
                        weight: .medium
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(LivePalette.violet)
                .disabled(model.isWorking || !model.isHostedWritable)
                .accessibilityIdentifier(FullRoomAccessibility.finishNextAction)
                .accessibilityLabel("Finish and open next interview")
                .help("Finish and open next interview")

                headerDivider
            }

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                floorActionLabel(
                    "End",
                    systemImage: "stop.fill",
                    compact: compact,
                    wideMinimumWidth: 70,
                    weight: .medium
                )
            }
            .buttonStyle(RoomChromeButtonStyle(tint: LivePalette.warning))
            .foregroundStyle(LivePalette.warning)
            .accessibilityIdentifier(FullRoomAccessibility.endAction)
            .accessibilityLabel("End interview")
            .help("End interview")
        }
        .padding(
            .horizontal,
            compact
                ? FullRoomLayout.floorCompactHorizontalPadding
                : FullRoomLayout.floorContentHorizontalPadding
        )
    }

    @ViewBuilder
    private func floorActionLabel(
        _ title: String,
        systemImage: String,
        compact: Bool,
        wideMinimumWidth: CGFloat,
        weight: Font.Weight = .semibold
    ) -> some View {
        if compact {
            Image(systemName: systemImage)
                .font(.system(.body, design: .rounded, weight: weight))
                .frame(
                    minWidth: FullRoomLayout.minimumActionHitTarget,
                    minHeight: FullRoomLayout.minimumActionHitTarget
                )
                .accessibilityHidden(true)
        } else {
            Label(title, systemImage: systemImage)
                .font(.system(.body, design: .rounded, weight: weight))
                .lineLimit(1)
                .frame(
                    minWidth: wideMinimumWidth,
                    minHeight: FullRoomLayout.minimumActionHitTarget
                )
        }
    }

    private var turnlineSummary: String {
        if model.usesHostedAuthority, !model.hostedPairs.isEmpty {
            let count = model.hostedPairs.count * 2
            return count == 1 ? "1 HOSTED TURN" : "\(count) HOSTED TURNS"
        }
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

    private var hostedResultTitle: String {
        switch model.hostedResult {
        case .solved: "Solved"
        case .solvedAfterReviewingApproach: "Solved with review"
        case .failed: "Failed"
        case .unknown: "Unsupported result"
        case nil: "Set result"
        }
    }

    private var segmentCountLabel: String {
        let count = model.segments.count
        return count == 1 ? "1 SEGMENT" : "\(count) SEGMENTS"
    }

    private func recoveryBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(LivePalette.warning)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsGroqCredential {
                Button("Add Groq key") {
                    model.presentCredentialSetup()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.5)).frame(height: 1)
        }
    }

    private func codexReadinessBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.codexStatusTitle, systemImage: model.codexStatusIcon)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(LivePalette.warning)
                Text(message)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Check Codex") {
                Task { await model.checkCodex() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isCheckingCodex)
            .accessibilityHint("Runs a private local compatibility and sign-in check")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.warning.opacity(0.45)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct FullRoomWorkspaceWidths: Equatable {
    let totalWidth: CGFloat
    let turnlineWidth: CGFloat
    let boardWidth: CGFloat
    let visualDividerWidth: CGFloat

    var composedWidth: CGFloat {
        turnlineWidth + boardWidth
    }
}

struct FullRoomSplitDragPreview: Equatable {
    let translation: CGFloat
    let proposedTurnlineWidth: CGFloat
}

private struct RoomChromeButtonStyle: ButtonStyle {
    var tint: Color = LivePalette.violet

    func makeBody(configuration: Configuration) -> some View {
        RoomChromeButtonBody(
            configuration: configuration,
            tint: tint
        )
    }

    private struct RoomChromeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            tint.opacity(
                                configuration.isPressed
                                    ? 0.16
                                    : (isHovering ? 0.09 : 0)
                            )
                        )
                }
                .scaleEffect(
                    reduceMotion
                        ? 1
                        : (configuration.isPressed ? 0.98 : (isHovering ? 1.01 : 1))
                )
                .onHover { isHovering = $0 }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.14),
                    value: isHovering
                )
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.08),
                    value: configuration.isPressed
                )
        }
    }
}

enum FullRoomLayout {
    static let minimumWindowWidth: CGFloat = 800
    static let defaultWindowWidth: CGFloat = 1_180
    static let headerHeight: CGFloat = 50
    static let questionTitleSize: CGFloat = 32
    static let questionHorizontalPadding: CGFloat = 32
    static let questionTopPadding: CGFloat = 28
    static let questionBottomPadding: CGFloat = 24
    static let questionStackSpacing: CGFloat = 14
    static let questionLineLimit = 2
    static let questionMinimumScaleFactor: CGFloat = 0.82
    static let questionBandOneLineHeight: CGFloat = 132
    static let questionAdditionalLineHeight: CGFloat = 38
    static let questionBandMinimumHeight = questionBandOneLineHeight
    static let turnlineWidthFraction: CGFloat = 0.34
    static let boardWidthFraction: CGFloat = 1 - turnlineWidthFraction
    static let workspaceVisualDividerWidth: CGFloat = 1
    static let workspaceDividerHitWidth: CGFloat = 13
    static let turnlineMinimumWidth: CGFloat = 260
    static let turnlineHorizontalPadding: CGFloat = 32
    static let turnlineEntryGap: CGFloat = 24
    static let turnlineBodyFontSize: CGFloat = 20
    static let boardMinimumWidth: CGFloat = 483
    static let floorRailHeight: CGFloat = 55
    static let floorStatusWidth: CGFloat = 144
    static let floorCompactStatusWidth: CGFloat = 112
    static let floorCompactWaveformWidth: CGFloat = 80
    static let floorCompactSpacing: CGFloat = 8
    static let floorCompactHorizontalPadding: CGFloat = 16
    static let floorContentHorizontalPadding: CGFloat = 24
    static let floorOutlineHorizontalInset: CGFloat = 16
    static let floorOutlineVerticalInset: CGFloat = 4
    static let minimumActionHitTarget: CGFloat = 44
    static let requiredWorkspaceHeight: CGFloat = 320
    static let requiredTurnlineHeight: CGFloat = 200
    static let minimumWindowHeight: CGFloat = 500

    static var floorCompactMaximumRequiredWidth: CGFloat {
        floorCompactStatusWidth
            + floorCompactWaveformWidth
            + 7 * minimumActionHitTarget
            + 3 * workspaceVisualDividerWidth
            + 11 * floorCompactSpacing
            + 2 * floorCompactHorizontalPadding
    }

    static var questionBandMaximumHeight: CGFloat {
        questionBandHeight(forLineCount: questionLineLimit)
    }

    /// The full-size-content window draws into the titlebar. This keeps the
    /// brand beyond the standard close/minimize/zoom group while the custom
    /// header occupies that same row instead of leaving a blank strip.
    static let trafficLightClearance: CGFloat = 92
    static let workspaceCoordinateSpaceName = "system-design-workspace"

    static func turnlineBaseWidth(
        for workspaceWidth: CGFloat,
        preferredTurnlineWidth: CGFloat? = nil
    ) -> CGFloat {
        let totalWidth = max(0, workspaceWidth)
        return clampedTurnlineWidth(
            preferredTurnlineWidth ?? totalWidth * turnlineWidthFraction,
            for: totalWidth
        )
    }

    static func workspaceWidths(
        for workspaceWidth: CGFloat,
        preferredTurnlineWidth: CGFloat? = nil
    ) -> FullRoomWorkspaceWidths {
        let totalWidth = max(0, workspaceWidth)
        let turnlineWidth = turnlineBaseWidth(
            for: totalWidth,
            preferredTurnlineWidth: preferredTurnlineWidth
        )
        return FullRoomWorkspaceWidths(
            totalWidth: totalWidth,
            turnlineWidth: turnlineWidth,
            boardWidth: totalWidth - turnlineWidth,
            visualDividerWidth: workspaceVisualDividerWidth
        )
    }

    static func splitDragPreview(
        baseWidth: CGFloat,
        dragTranslation: CGFloat,
        workspaceWidth: CGFloat
    ) -> FullRoomSplitDragPreview {
        let proposedTurnlineWidth = clampedTurnlineWidth(
            baseWidth + dragTranslation,
            for: workspaceWidth
        )
        return FullRoomSplitDragPreview(
            translation: proposedTurnlineWidth - baseWidth,
            proposedTurnlineWidth: proposedTurnlineWidth
        )
    }

    static func committedTurnlineWidth(
        baseWidth: CGFloat,
        dragTranslation: CGFloat,
        workspaceWidth: CGFloat
    ) -> CGFloat {
        clampedTurnlineWidth(
            baseWidth + dragTranslation,
            for: workspaceWidth
        )
    }

    static func turnlineIdealWidth(for workspaceWidth: CGFloat) -> CGFloat {
        workspaceWidths(for: workspaceWidth).turnlineWidth
    }

    static func boardIdealWidth(for workspaceWidth: CGFloat) -> CGFloat {
        workspaceWidths(for: workspaceWidth).boardWidth
    }

    static func clampedTurnlineWidth(
        _ proposedWidth: CGFloat,
        for workspaceWidth: CGFloat
    ) -> CGFloat {
        let totalWidth = max(0, workspaceWidth)
        let maximum = max(0, totalWidth - boardMinimumWidth)
        let minimum = min(turnlineMinimumWidth, maximum)
        return min(max(proposedWidth, minimum), maximum)
    }

    static func questionBandHeight(forLineCount lineCount: Int) -> CGFloat {
        let boundedLineCount = min(max(lineCount, 1), questionLineLimit)
        return questionBandOneLineHeight
            + CGFloat(boundedLineCount - 1) * questionAdditionalLineHeight
    }

    static func minimumWorkspaceHeight(
        for windowHeight: CGFloat,
        questionLineCount: Int = questionLineLimit
    ) -> CGFloat {
        _ = questionLineCount
        return max(
            0,
            windowHeight
                - headerHeight
                - floorRailHeight
        )
    }

    static func minimumTurnlineHeight(
        for windowHeight: CGFloat,
        questionLineCount: Int = questionLineLimit
    ) -> CGFloat {
        max(
            0,
            minimumWorkspaceHeight(for: windowHeight)
                - questionBandHeight(forLineCount: questionLineCount)
        )
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

    var presentation: FullRoomHeaderPresentation {
        if windowWidth < FullRoomHeaderStatusLayout.minimumWideHeaderWidth {
            return .compact
        }
        if attention != .none,
           windowWidth <= FullRoomHeaderLayout.attentionCompactMaximumWidth {
            return .compact
        }
        return .wide
    }

    var usesAttentionCompactHeader: Bool {
        presentation == .compact
    }
}

enum FullRoomHeaderPresentation: Equatable {
    case wide
    case compact
}

enum FullRoomHeaderLayout {
    static let attentionCompactMaximumWidth =
        FullRoomHeaderStatusLayout.minimumWideHeaderWidth

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

enum FullRoomHeaderStatusStyle: Equatable {
    case compact
    case wideInline
    case wideWrapped
}

struct FullRoomHeaderStatusPresentation: Equatable {
    let style: FullRoomHeaderStatusStyle
    let visibleText: String
    let accessibilityValue: String
    let helpText: String
    let frameWidth: CGFloat?
    let lineLimit: Int
}

enum FullRoomHeaderStatusLayout {
    /// Brand, the worst-case local-voice attention badge, persona, privacy,
    /// collapse, padding, gaps, and both flexible spacers keep this much of a
    /// wide header before status text is added.
    static let wideReservedWidth: CGFloat = 940
    static let minimumWrappedWidth: CGFloat = 220
    static let minimumWideHeaderWidth = wideReservedWidth + minimumWrappedWidth
    static let wrappedLineLimit = 2
    static let maximumWrappedTextHeight: CGFloat = 40
    static let inlineMeasurementSafetyMargin: CGFloat = 8

    static func presentation(
        headerPresentation: FullRoomHeaderPresentation,
        windowWidth: CGFloat,
        statusMessage: String
    ) -> FullRoomHeaderStatusPresentation {
        let fullText = FullRoomHeaderLabels.roomStatus(
            statusMessage: statusMessage
        )
        if headerPresentation == .compact {
            return FullRoomHeaderStatusPresentation(
                style: .compact,
                visibleText: FullRoomHeaderLabels.compactRoom,
                accessibilityValue: statusMessage,
                helpText: fullText,
                frameWidth: nil,
                lineLimit: 1
            )
        }

        let availableWidth = wideStatusWidth(for: windowWidth)
        if measuredWidth(of: fullText)
            + inlineMeasurementSafetyMargin <= availableWidth {
            return FullRoomHeaderStatusPresentation(
                style: .wideInline,
                visibleText: fullText,
                accessibilityValue: statusMessage,
                helpText: fullText,
                frameWidth: nil,
                lineLimit: 1
            )
        }
        return FullRoomHeaderStatusPresentation(
            style: .wideWrapped,
            visibleText: statusMessage,
            accessibilityValue: statusMessage,
            helpText: fullText,
            frameWidth: availableWidth,
            lineLimit: wrappedLineLimit
        )
    }

    static func wideStatusWidth(for windowWidth: CGFloat) -> CGFloat {
        max(minimumWrappedWidth, windowWidth - wideReservedWidth)
    }

    static func measuredWidth(of text: String) -> CGFloat {
        ceil(
            (text as NSString).size(
                withAttributes: [.font: statusFont]
            ).width
        )
    }

    static func wrappedTextHeight(
        of text: String,
        width: CGFloat
    ) -> CGFloat {
        ceil(
            (text as NSString).boundingRect(
                with: NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: statusFont]
            ).height
        )
    }

    private static var statusFont: NSFont {
        NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )
    }
}

enum FullRoomHeaderLabels {
    static let compactRoom = "System design"
    static let compactPersona = "Mara"
    static let widePersona = "Mara · Staff Engineer"

    static func roomStatus(statusMessage: String) -> String {
        "\(compactRoom) · \(statusMessage)"
    }
}

enum FullRoomAccessibility {
    static let question = "full-room-question"
    static let turnline = "full-room-turnline"
    static let board = "full-room-board"
    static let floorRail = "full-room-floor-rail"
    static let primaryAction = "full-room-primary-action"
    static let keepFloorAction = "full-room-keep-floor-action"
    static let recordingAction = "full-room-recording-action"
    static let endAction = "full-room-end-action"
    static let finishNextAction = "full-room-finish-next-action"
    static let collapse = "full-room-collapse"

    static let allIdentifiers = [
        question,
        turnline,
        board,
        floorRail,
        primaryAction,
        recordingAction,
        endAction,
        finishNextAction,
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
    let powerHistory: [Float]
    let elapsedSeconds: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            let levels = FullRoomWaveformLayout.displayedLevels(
                powerHistory: powerHistory
            )
            let barPositions = FullRoomWaveformLayout.barXPositions(
                width: size.width,
                levelCount: levels.count
            )
            for (index, (level, x)) in zip(levels, barPositions).enumerated() {
                let height = FullRoomWaveformLayout.barHeight(
                    decibel: level,
                    canvasHeight: size.height,
                    isActive: isActive,
                    elapsedSeconds: elapsedSeconds,
                    index: index,
                    reduceMotion: reduceMotion
                )
                guard height > 0 else { continue }
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
        .accessibilityHidden(!isActive)
        .accessibilityLabel("Live microphone level")
        .animation(.linear(duration: 0.09), value: powerHistory)
        .animation(.linear(duration: 0.09), value: elapsedSeconds)
    }
}

enum FullRoomHostedTimerLayout {
    static func elapsedText(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum FullRoomWaveformLayout {
    static let traceCoverageFraction: CGFloat = 0.58
    static let horizontalInset: CGFloat = 10
    static let activeHeightFraction: CGFloat = 0.88
    static let sampleCount = 30
    static let pulseAmplitude = 0.18

    static func displayedLevels(powerHistory: [Float]) -> [Float] {
        Array(
            (
                Array(repeating: Float(-60), count: sampleCount)
                    + powerHistory
            )
            .suffix(sampleCount)
        )
    }

    static func normalizedLevel(_ decibel: Float) -> Double {
        Double(max(0.08, min(1, (decibel + 55) / 45)))
    }

    static func barHeight(
        level: Double,
        canvasHeight: CGFloat,
        isActive: Bool
    ) -> CGFloat {
        guard isActive else { return 0 }
        return max(3, CGFloat(level) * canvasHeight * activeHeightFraction)
    }

    static func barHeight(
        decibel: Float,
        canvasHeight: CGFloat,
        isActive: Bool,
        elapsedSeconds: TimeInterval,
        index: Int,
        reduceMotion: Bool
    ) -> CGFloat {
        guard isActive else { return 0 }
        let normalized = normalizedLevel(decibel)
        let pulse: Double
        if reduceMotion {
            pulse = 1
        } else {
            pulse = 0.82
                + pulseAmplitude
                * sin(elapsedSeconds * 11 + Double(index) * 0.72)
        }
        return max(
            3,
            canvasHeight * activeHeightFraction * CGFloat(normalized * pulse)
        )
    }

    static func barXPositions(
        width: CGFloat,
        levelCount: Int
    ) -> [CGFloat] {
        guard width > 0, levelCount > 0 else { return [] }
        guard levelCount > 1 else {
            return [min(width, horizontalInset)]
        }

        let first = min(width, horizontalInset)
        let last = max(
            first,
            min(
                width,
                width * traceCoverageFraction - horizontalInset
            )
        )
        let spacing = (last - first) / CGFloat(levelCount - 1)
        return (0..<levelCount).map { index in
            first + CGFloat(index) * spacing
        }
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
