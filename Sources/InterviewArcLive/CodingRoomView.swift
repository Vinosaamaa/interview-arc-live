import AppKit
import Foundation
import InterviewArcLiveCore
import InterviewArcLiveHostedClient
import SwiftUI

struct CodingRoomView: View {
    @ObservedObject var model: CodingRoomModel
    let onCollapse: () -> Void
    @State private var isModelRemovalConfirmationPresented = false
    @State private var preferredTurnlineWidth: CGFloat?
    @State private var isWorkspaceDividerHovered = false
    @State private var isOutputExpanded = true
    @GestureState private var splitDragTranslation: CGFloat = 0

    init(
        model: CodingRoomModel,
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
                    codingSurface
                        .frame(
                            width: widths.boardWidth,
                            height: workspace.size.height
                        )
                        .accessibilityIdentifier(CodingRoomAccessibility.editor)
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
            HStack(spacing: state.presentation == .compact ? 12 : 16) {
                headerBrand
                Spacer(minLength: 12)
                roomStatusMenu(compact: state.presentation == .compact)
                headerDivider
                personaMenu(isCompact: state.presentation == .compact)
                Spacer(minLength: 12)
                privacyStatus
                collapseButton
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

    private var headerBrand: some View {
        HStack(spacing: 14) {
            CodingLiveMark()
                .frame(width: 34, height: 34)
            Text("Interview Arc Live")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func roomStatusMenu(compact: Bool) -> some View {
        let endpointPresentation = model.endpointHandoffPresentation
        let visible = compact
            ? "Coding"
            : "Coding · \(model.statusMessage)"
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
            Text(visible)
                .fontWeight(.semibold)
                .lineLimit(compact ? 1 : 2)
        }
        .menuStyle(.borderlessButton)
        .help("Coding · \(model.statusMessage)")
        .accessibilityLabel("Coding room status")
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
            Text(isCompact ? "Mara" : "Mara · Staff Engineer")
                .fontWeight(.semibold)
                .foregroundStyle(LivePalette.navy)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Interviewer: Mara, Staff Engineer")
        .accessibilityValue(model.speechReadinessPresentation.title)
    }

    private var privacyStatus: some View {
        HStack(spacing: 7) {
            Label("Private", systemImage: "lock")
            Text("·")
                .foregroundStyle(LivePalette.muted)
            Text(model.sourceFileName)
                .foregroundStyle(LivePalette.muted)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help("Private · \(model.sourceFileName)")
        .accessibilityLabel("Private local session")
        .accessibilityValue(model.sourceFileName)
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .frame(
                    width: FullRoomLayout.minimumActionHitTarget,
                    height: FullRoomLayout.minimumActionHitTarget
                )
        }
        .buttonStyle(CodingRoomChromeButtonStyle())
        .accessibilityIdentifier(FullRoomAccessibility.collapse)
        .accessibilityLabel("Collapse to compact controls")
        .accessibilityHint("Keeps the same coding room in compact controls")
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(LivePalette.line)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
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
                }) else { return }
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
            Rectangle()
                .fill(LivePalette.violet.opacity(isWorkspaceDividerHovered ? 0.72 : 0))
        }
        .frame(width: FullRoomLayout.workspaceDividerHitWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            isWorkspaceDividerHovered = hovering
            if hovering { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: .named(FullRoomLayout.workspaceCoordinateSpaceName)
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
        .onTapGesture(count: 2) { preferredTurnlineWidth = nil }
        .accessibilityLabel("Resize question and Turnline pane")
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
            VStack(alignment: .leading, spacing: 16) {
                Text("YOU · CURRENT TURN")
                    .font(.system(.callout, design: .monospaced, weight: .bold))
                    .foregroundStyle(LivePalette.candidateText)
                if model.segments.isEmpty {
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
                } else {
                    ForEach(model.segments) { segment in
                        CandidateSegmentCard(
                            segment: segment,
                            isBusy: model.isWorking || model.canStopRecording,
                            onPlay: { Task { await model.playSegment(id: segment.id) } },
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
        switch turn {
        case .candidate(let candidate):
            return AnyView(
                turnlineRow(
                    role: "YOU",
                    body: candidate.transcript.body,
                    color: LivePalette.candidateText,
                    rendersMarkdown: false,
                    isLast: isLast
                ) { EmptyView() }
            )
        case .interviewer(let interviewer):
            return AnyView(
                turnlineRow(
                    role: "MARA",
                    body: interviewer.displayMarkdown,
                    color: LivePalette.interviewer,
                    rendersMarkdown: true,
                    isLast: isLast
                ) {
                    if let utterance = model.utterance(for: interviewer.id) {
                        interviewerSpeechRow(utterance)
                    }
                }
            )
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
                        await model.confirmHostedCandidateEvidence(pairID: pair.pairId)
                    }
                }
                .buttonStyle(.bordered)
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
    }

    private func interviewerSpeechRow(_ utterance: InterviewerUtterance) -> some View {
        let presentation = model.speechPresentation(for: utterance)
        let isPlaying = model.isPlayingSpeech(for: utterance.id)
        return HStack(spacing: 9) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : presentation.systemImage)
                .foregroundStyle(LivePalette.violet)
            VStack(alignment: .leading, spacing: 1) {
                Text(isPlaying ? "Playing saved voice" : presentation.title)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                Text(presentation.detail)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
            }
            Spacer()
            if isPlaying || presentation.canStop {
                Button("Stop") { Task { await model.stopSpeech() } }
            } else if presentation.canPlay {
                Button("Play") {
                    Task { await model.playSpeech(utteranceID: utterance.id) }
                }
                .disabled(model.isSpeechControlActionInFlight)
            }
        }
        .controlSize(.small)
        .padding(.vertical, 7)
    }

    private var codingSurface: some View {
        VStack(spacing: 0) {
            codingToolbar
            ZStack {
                JavaSourceEditorView(
                    text: sourceBinding,
                    isEditable: model.isJavaFileLoaded && !model.isCodingActivityMissing,
                    onEditingChanged: { model.updateSourceText($0) }
                )
                if model.isCodingActivityMissing {
                    codingGate
                }
            }
            if isOutputExpanded || model.latestRunReceipt != nil {
                outputDrawer
            }
        }
        .background(LivePalette.paper)
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { model.sourceText },
            set: { model.updateSourceText($0) }
        )
    }

    private var codingToolbar: some View {
        HStack(spacing: 10) {
            Text(model.sourceFileName)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(LivePalette.line.opacity(0.55), in: Capsule())
                .accessibilityIdentifier(CodingRoomAccessibility.filePill)

            languageControl

            Spacer()

            if let message = model.workSurfaceMessage {
                Text(message)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
                    .lineLimit(1)
            }

            Button {
                Task { await model.openLeetCode() }
            } label: {
                Label("Open LeetCode", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
            .disabled(model.isOpeningLeetCode || model.isCodingActivityMissing)
            .accessibilityIdentifier(CodingRoomAccessibility.openLeetCode)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
    }

    private var languageControl: some View {
        HStack(spacing: 0) {
            ForEach(CodingLanguage.allCases) { language in
                Text(language.rawValue)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        language == model.selectedLanguage
                            ? LivePalette.navy.opacity(0.12)
                            : Color.clear
                    )
                    .foregroundStyle(
                        language.isEnabled ? LivePalette.ink : LivePalette.muted.opacity(0.7)
                    )
            }
        }
        .background(LivePalette.line.opacity(0.4), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Language Java 21 enabled, Python disabled")
    }

    private var codingGate: some View {
        VStack(spacing: 14) {
            Text("CODING ROOM")
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(LivePalette.warning)
            Text("Open a LeetCode activity on Today")
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text("Live binds one evolving Java file to the focused coding activity. It will not invent a problem or start a timer.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(LivePalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(28)
        .background(LivePalette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LivePalette.line, lineWidth: 1)
        }
        .accessibilityIdentifier(CodingRoomAccessibility.gate)
    }

    private var outputDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.latestRunReceipt?.commandClass.rawValue ?? "Output")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Spacer()
                if let receipt = model.latestRunReceipt {
                    Text(receipt.summaryLine)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(
                            receipt.outcome.isSuccess
                                ? LivePalette.violet
                                : LivePalette.warning
                        )
                        .accessibilityIdentifier(CodingRoomAccessibility.runLabel)
                }
                Button {
                    isOutputExpanded.toggle()
                } label: {
                    Image(systemName: isOutputExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain)
            }
            if let receipt = model.latestRunReceipt, isOutputExpanded {
                Text("Run \(receipt.identity) · \(receipt.commandClass.rawValue) · exit \(receipt.exitCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(LivePalette.muted)
                ScrollView {
                    Text(receipt.diagnostics.isEmpty ? receipt.summaryLine : receipt.diagnostics)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                Text("Locally verified is not LeetCode Accepted.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(LivePalette.muted)
            }
            HStack {
                Spacer()
                Button {
                    Task { await model.quickRun() }
                } label: {
                    Label("Quick run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(LivePalette.violet)
                .disabled(model.isHarnessRunning || !model.isJavaFileLoaded)
                .accessibilityIdentifier(CodingRoomAccessibility.quickRun)

                Button {
                    Task { await model.fullRun() }
                } label: {
                    Label("Full run", systemImage: "play.square.stack")
                }
                .buttonStyle(.bordered)
                .disabled(model.isHarnessRunning || !model.isJavaFileLoaded)
                .accessibilityIdentifier(CodingRoomAccessibility.fullRun)
            }
        }
        .padding(14)
        .background(LivePalette.room)
        .overlay(alignment: .top) {
            Rectangle().fill(LivePalette.line).frame(height: 1)
        }
        .accessibilityIdentifier(CodingRoomAccessibility.output)
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
        .accessibilityIdentifier(FullRoomAccessibility.floorRail)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LivePalette.line, lineWidth: 1)
                .padding(.horizontal, FullRoomLayout.floorOutlineHorizontalInset)
                .padding(.vertical, FullRoomLayout.floorOutlineVerticalInset)
        }
    }

    private func floorRailContent(compact: Bool) -> some View {
        let floorState = model.floorStatePresentation
        return HStack(spacing: compact ? FullRoomLayout.floorCompactSpacing : 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(floorState.full.label.uppercased())
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(LivePalette.violet)
                    .lineLimit(1)
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

            CodingLiveWaveform(isActive: model.canStopRecording)
                .frame(
                    minWidth: compact ? FullRoomLayout.floorCompactWaveformWidth : 140,
                    maxWidth: .infinity
                )
                .frame(height: FullRoomLayout.minimumActionHitTarget)

            if model.usesHostedAuthority {
                Button {
                    Task { await model.toggleHostedTimer() }
                } label: {
                    floorActionLabel(
                        model.hostedElapsedText
                            ?? (model.hostedTimerIsRunning ? "Pause" : "Start"),
                        systemImage: model.hostedTimerIsRunning
                            ? "pause.circle.fill"
                            : "play.circle.fill",
                        compact: compact
                    )
                    .monospacedDigit()
                }
                .buttonStyle(.bordered)
                .disabled(!model.canToggleHostedTimer)
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
                            await model.setHostedResult(.solvedAfterReviewingApproach)
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
                        compact: compact
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(!model.canSetHostedResult)
                .accessibilityLabel("Hosted result: \(hostedResultTitle)")
            }

            if model.activeEndpointGrace != nil {
                Button {
                    Task { await model.keepMyFloor() }
                } label: {
                    floorActionLabel("Keep my floor", systemImage: "hand.raised.fill", compact: compact)
                }
                .disabled(!model.canKeepFloor)
            }

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                floorActionLabel(
                    model.actionTitle,
                    systemImage: model.actionIcon,
                    compact: compact
                )
            }
            .buttonStyle(CodingRoomPrimaryActionButtonStyle())
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier(FullRoomAccessibility.primaryAction)
            .accessibilityLabel(model.actionTitle)

            if model.canStopRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    floorActionLabel("Pause", systemImage: "pause.fill", compact: compact)
                }
                .disabled(model.isWorking)
            } else if model.showsRecordControl {
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    floorActionLabel("Record", systemImage: "record.circle", compact: compact)
                }
                .disabled(!model.canRecordSegment)
            }

            if model.hostedNextCodingActivityID != nil {
                Button {
                    Task { _ = await model.finishAndOpenNextInterview() }
                } label: {
                    floorActionLabel("Finish & next", systemImage: "forward.end.fill", compact: compact)
                }
                .disabled(model.isWorking || !model.isHostedWritable)
            }

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                floorActionLabel("End", systemImage: "stop.fill", compact: compact)
            }
            .buttonStyle(CodingRoomChromeButtonStyle(tint: LivePalette.warning))
            .foregroundStyle(LivePalette.warning)
            .accessibilityIdentifier(FullRoomAccessibility.endAction)
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
        compact: Bool
    ) -> some View {
        if compact {
            Image(systemName: systemImage)
                .frame(
                    minWidth: FullRoomLayout.minimumActionHitTarget,
                    minHeight: FullRoomLayout.minimumActionHitTarget
                )
        } else {
            Label(title, systemImage: systemImage)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .frame(minHeight: FullRoomLayout.minimumActionHitTarget)
        }
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

    private func recoveryBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(LivePalette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(LivePalette.warning.opacity(0.12))
    }

    private func codexReadinessBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.codexStatusTitle, systemImage: model.codexStatusIcon)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(LivePalette.warning)
            Text(message)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(LivePalette.muted)
            Button("Check Codex") { Task { await model.checkCodex() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isCheckingCodex)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LivePalette.warning.opacity(0.1))
    }
}

enum CodingRoomAccessibility {
    static let editor = "coding-room-editor"
    static let filePill = "coding-room-file-pill"
    static let openLeetCode = "coding-room-open-leetcode"
    static let quickRun = "coding-room-quick-run"
    static let fullRun = "coding-room-full-run"
    static let output = "coding-room-output"
    static let runLabel = "coding-room-run-label"
    static let gate = "coding-room-gate"
}

private struct CodingRoomChromeButtonStyle: ButtonStyle {
    var tint: Color = LivePalette.violet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.16 : 0.08))
            }
    }
}

private struct CodingRoomPrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodingRoomPrimaryActionButtonBody(configuration: configuration)
    }

    private struct CodingRoomPrimaryActionButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(height: FullRoomLayout.minimumActionHitTarget)
                .foregroundStyle(isEnabled ? Color.white : LivePalette.violet.opacity(0.42))
                .background {
                    Capsule().fill(
                        isEnabled
                            ? LivePalette.violet.opacity(configuration.isPressed ? 0.82 : 1)
                            : LivePalette.violet.opacity(0.12)
                    )
                }
                .contentShape(Capsule())
        }
    }
}

private struct CodingLiveWaveform: View {
    let isActive: Bool
    private let levels: [Double] = [
        0.18, 0.42, 0.24, 0.66, 0.31, 0.52, 0.2, 0.76, 0.38, 0.24,
        0.58, 0.33, 0.7, 0.28, 0.45, 0.2, 0.62, 0.35, 0.22, 0.48,
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
            let positions = FullRoomWaveformLayout.barXPositions(
                width: size.width,
                levelCount: levels.count
            )
            for (level, x) in zip(levels, positions) {
                let height = max(3, level * size.height * (isActive ? 0.88 : 0.55))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - height / 2))
                bar.addLine(to: CGPoint(x: x, y: center + height / 2))
                context.stroke(
                    bar,
                    with: .color(LivePalette.violet),
                    lineWidth: 2
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CodingLiveMark: View {
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
