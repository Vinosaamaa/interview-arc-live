import AppKit
import InterviewArcLiveCore
import SwiftUI

/// Copied Live visual tokens. Do not move `LivePalette` out of SystemDesignRoomView.
enum BehavioralRoomPalette {
    static let paperHex = "#FCFCFE"
    static let roomHex = "#FAFBFE"
    static let inkHex = "#0E111E"
    static let navyHex = "#182359"
    static let violetHex = "#4B3ABF"
    static let candidateTextHex = "#9F2E22"

    static let paper = Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
    static let room = Color(red: 250 / 255, green: 251 / 255, blue: 254 / 255)
    static let ink = Color(red: 14 / 255, green: 17 / 255, blue: 30 / 255)
    static let navy = Color(red: 24 / 255, green: 35 / 255, blue: 89 / 255)
    static let violet = Color(red: 75 / 255, green: 58 / 255, blue: 191 / 255)
    static let candidateText = Color(red: 159 / 255, green: 46 / 255, blue: 34 / 255)
    static let muted = Color(red: 82 / 255, green: 98 / 255, blue: 139 / 255)
    static let line = Color(red: 224 / 255, green: 226 / 255, blue: 237 / 255)
    static let interviewer = violet
    static let warning = candidateText
}

enum BehavioralRoomAccessibility {
    static let root = "behavioral-room-root"
    static let header = "behavioral-room-header"
    static let hostedChip = "behavioral-room-hosted-chip"
    static let question = "behavioral-room-question"
    static let familyPicker = "behavioral-room-family-picker"
    static let turnline = "behavioral-room-turnline"
    static let kit = "behavioral-room-kit"
    static let storyKit = "behavioral-room-story-kit"
    static let projectKit = "behavioral-room-project-kit"
    static let claimKit = "behavioral-room-claim-kit"
    static let starl = "behavioral-room-starl"
    static let notes = "behavioral-room-notes"
    static let gaps = "behavioral-room-gaps"
    static let coachedDiscovery = "behavioral-room-coached-discovery"
    static let returnToInterviewer = "behavioral-room-return-to-interviewer"
    static let floorRail = "behavioral-room-floor-rail"
    static let primaryAction = "behavioral-room-primary-action"
    static let recordingAction = "behavioral-room-recording-action"
    static let hostedPause = "behavioral-room-hosted-pause"
    static let endAction = "behavioral-room-end-action"
    static let compactRoot = "behavioral-room-compact-root"

    static let allIdentifiers = [
        root,
        header,
        hostedChip,
        question,
        familyPicker,
        turnline,
        kit,
        storyKit,
        projectKit,
        claimKit,
        starl,
        notes,
        gaps,
        coachedDiscovery,
        returnToInterviewer,
        floorRail,
        primaryAction,
        recordingAction,
        hostedPause,
        endAction,
        compactRoot,
    ]
}

struct BehavioralRoomView: View {
    @ObservedObject var model: BehavioralRoomModel
    let onCollapse: () -> Void
    @State private var preferredTurnlineWidth: CGFloat?
    @State private var isWorkspaceDividerHovered = false
    @GestureState private var splitDragTranslation: CGFloat = 0

    private static let workspaceCoordinateSpaceName = "behavioral-workspace"

    init(
        model: BehavioralRoomModel,
        onCollapse: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onCollapse = onCollapse
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            questionBand
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
                    turnline
                        .frame(
                            width: widths.turnlineWidth,
                            height: workspace.size.height
                        )
                        .overlay(alignment: .trailing) {
                            workspaceDivider(
                                baseWidth: baseTurnlineWidth,
                                totalWidth: widths.totalWidth
                            )
                            .offset(
                                x: FullRoomLayout.workspaceDividerHitWidth / 2
                                    + splitPreview.translation
                            )
                        }
                    kitColumn
                        .frame(
                            width: widths.boardWidth,
                            height: workspace.size.height
                        )
                        .accessibilityIdentifier(BehavioralRoomAccessibility.kit)
                }
                .frame(
                    width: widths.totalWidth,
                    height: workspace.size.height,
                    alignment: .leading
                )
                .coordinateSpace(name: Self.workspaceCoordinateSpaceName)
            }
            floorRail
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(BehavioralRoomPalette.room)
        .foregroundStyle(BehavioralRoomPalette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(BehavioralRoomAccessibility.root)
        .sheet(isPresented: $model.isCredentialSetupPresented) {
            GroqCredentialSetupView(
                isSaving: model.isSavingCredential,
                errorMessage: model.credentialErrorMessage,
                onSaveToKeychain: model.saveGroqCredential,
                onUseUntilQuit: model.useGroqCredentialUntilQuit
            )
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                BehavioralLiveMark()
                    .frame(width: 34, height: 34)
                Text("Interview Arc Live")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .fixedSize()
            }
            Spacer(minLength: 12)
            Text("Behavioral")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(BehavioralRoomPalette.navy)
            Text(model.workSurface.questionFamily.title)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(BehavioralRoomPalette.muted)
            if model.workSurface.mode == .coachedDiscovery {
                Text("Coached discovery")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        BehavioralRoomPalette.violet.opacity(0.12),
                        in: Capsule()
                    )
            }
            Spacer(minLength: 12)
            Text(model.hostedAvailabilityChip)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(BehavioralRoomPalette.violet)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    BehavioralRoomPalette.violet.opacity(0.1),
                    in: Capsule()
                )
                .accessibilityIdentifier(BehavioralRoomAccessibility.hostedChip)
            Text("Mara · Staff Engineer")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(BehavioralRoomPalette.navy)
                .lineLimit(1)
            collapseButton
        }
        .padding(.leading, FullRoomLayout.trafficLightClearance)
        .padding(.trailing, 22)
        .frame(height: FullRoomLayout.headerHeight)
        .background(BehavioralRoomPalette.paper)
        .accessibilityIdentifier(BehavioralRoomAccessibility.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BehavioralRoomPalette.line).frame(height: 1)
        }
    }

    private var collapseButton: some View {
        Button(action: onCollapse) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .frame(
                    width: FullRoomLayout.minimumActionHitTarget,
                    height: FullRoomLayout.minimumActionHitTarget
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(FullRoomAccessibility.collapse)
        .accessibilityLabel("Collapse to compact controls")
        .accessibilityHint("Keeps the same Behavioral room in compact controls")
    }

    private var questionBand: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: FullRoomLayout.questionStackSpacing) {
                Text("QUESTION")
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(BehavioralRoomPalette.navy)
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
            Spacer(minLength: 12)
            Picker(
                "Question family",
                selection: familyBinding
            ) {
                ForEach(BehavioralQuestionFamily.allCases) { family in
                    Text(family.title).tag(family)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 160, minHeight: FullRoomLayout.minimumActionHitTarget)
            .accessibilityIdentifier(BehavioralRoomAccessibility.familyPicker)
        }
        .padding(.horizontal, FullRoomLayout.questionHorizontalPadding)
        .padding(.top, FullRoomLayout.questionTopPadding)
        .padding(.bottom, FullRoomLayout.questionBottomPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: FullRoomLayout.questionBandMinimumHeight,
            alignment: .topLeading
        )
        .background(BehavioralRoomPalette.paper)
        .accessibilityIdentifier(BehavioralRoomAccessibility.question)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BehavioralRoomPalette.line).frame(height: 1)
        }
    }

    private var familyBinding: Binding<BehavioralQuestionFamily> {
        Binding(
            get: { model.workSurface.questionFamily },
            set: { model.selectQuestionFamily($0) }
        )
    }

    private var turnline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TURNLINE")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(BehavioralRoomPalette.violet)
                .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
                .padding(.top, 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let snapshot = model.snapshot, !snapshot.turns.isEmpty {
                        ForEach(snapshot.turns.indices, id: \.self) { index in
                            turnlineEntry(
                                snapshot.turns[index],
                                isLast: index == snapshot.turns.count - 1
                                    && snapshot.phase != .candidateFloor
                            )
                        }
                        if snapshot.phase == .candidateFloor {
                            candidateFloorEntry
                        }
                    } else {
                        emptyTurnlineState
                        if model.snapshot?.phase == .candidateFloor {
                            candidateFloorEntry
                        }
                    }
                }
                .padding(.top, 18)
            }
        }
        .background(BehavioralRoomPalette.paper)
        .accessibilityIdentifier(BehavioralRoomAccessibility.turnline)
    }

    private var emptyTurnlineState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MARA")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(BehavioralRoomPalette.violet)
            Text("Ask this question cold. The sidecar shows evidence status and gaps, not a preferred answer.")
                .font(
                    .system(
                        size: FullRoomLayout.turnlineBodyFontSize,
                        weight: .regular,
                        design: .rounded
                    )
                )
                .foregroundStyle(BehavioralRoomPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
        .padding(.bottom, 24)
    }

    private var candidateFloorEntry: some View {
        HStack(alignment: .top, spacing: FullRoomLayout.turnlineEntryGap) {
            Circle()
                .fill(BehavioralRoomPalette.candidateText)
                .frame(width: 8, height: 8)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("YOU")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(BehavioralRoomPalette.candidateText)
                Text("Your floor")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(BehavioralRoomPalette.muted)
            }
        }
        .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
        .padding(.bottom, 24)
    }

    private func turnlineEntry(
        _ turn: InterviewTurn,
        isLast: Bool
    ) -> some View {
        let role: String
        let body: String
        let color: Color
        switch turn {
        case .candidate(let candidate):
            role = "YOU"
            body = candidate.transcript.body
            color = BehavioralRoomPalette.candidateText
        case .interviewer(let interviewer):
            role = model.workSurface.mode == .coachedDiscovery ? "MARA · COACH" : "MARA"
            body = interviewer.displayMarkdown
            color = BehavioralRoomPalette.violet
        }
        return HStack(alignment: .top, spacing: FullRoomLayout.turnlineEntryGap) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(role)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(color)
                Text(body)
                    .font(
                        .system(
                            size: FullRoomLayout.turnlineBodyFontSize,
                            weight: .regular,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(BehavioralRoomPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, FullRoomLayout.turnlineHorizontalPadding)
        .padding(.bottom, isLast ? 12 : 28)
    }

    private func workspaceDivider(
        baseWidth: CGFloat,
        totalWidth: CGFloat
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(BehavioralRoomPalette.line)
                .frame(width: FullRoomLayout.workspaceVisualDividerWidth)
            Capsule()
                .fill(BehavioralRoomPalette.violet.opacity(0.72))
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
        .gesture(
            DragGesture(
                minimumDistance: 1,
                coordinateSpace: .named(Self.workspaceCoordinateSpaceName)
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
        .accessibilityHidden(true)
    }

    private var kitColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Private context · not spoken")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(BehavioralRoomPalette.muted)
            .padding(.horizontal, 20)
            .padding(.top, 14)

            HStack(spacing: 4) {
                ForEach(BehavioralWorkSurfacePane.allCases) { pane in
                    Button {
                        model.selectWorkSurfacePane(pane)
                    } label: {
                        Text(pane.title(for: model.workSurface.questionFamily))
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: FullRoomLayout.minimumActionHitTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.workSurface.selectedPane == pane
                            ? BehavioralRoomPalette.violet
                            : BehavioralRoomPalette.muted
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                model.workSurface.selectedPane == pane
                                    ? BehavioralRoomPalette.violet
                                    : Color.clear
                            )
                            .frame(height: 2)
                    }
                    .accessibilityLabel(pane.title(for: model.workSurface.questionFamily))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(BehavioralRoomPalette.line).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.workSurface.selectedPane {
                    case .kit:
                        kitBody
                    case .starl:
                        starlCoverage
                    case .notes:
                        notesEditor
                    }
                    if model.workSurface.selectedPane != .starl {
                        starlCoverage
                    }
                    conspicuousGaps
                    coachedDiscoveryControls
                }
                .padding(20)
            }
        }
        .background(BehavioralRoomPalette.room)
    }

    @ViewBuilder
    private var kitBody: some View {
        switch model.workSurface.primaryKit {
        case .story:
            storyKit
        case .project:
            projectKit
        case .claim:
            claimKit
        }
    }

    private var storyKit: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.workSurface.storyKit.candidates) { story in
                Button {
                    model.selectStory(id: story.storyId)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: story.status.systemImage)
                            .foregroundStyle(statusColor(story.status))
                            .frame(
                                width: 22,
                                height: FullRoomLayout.minimumActionHitTarget / 2
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(story.displayLabel)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(BehavioralRoomPalette.ink)
                            Text(story.status.title)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(BehavioralRoomPalette.muted)
                            Text(
                                story.gapCount == 0
                                    ? "\(story.acceptedFactCount) accepted facts"
                                    : "\(story.acceptedFactCount) accepted facts · \(story.gapCount) gap"
                            )
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(BehavioralRoomPalette.muted)
                            if story.isHypothetical {
                                Text("Hypothetical · not personal evidence")
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                                    .foregroundStyle(BehavioralRoomPalette.candidateText)
                            }
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: FullRoomLayout.minimumActionHitTarget, alignment: .leading)
                    .background(
                        BehavioralRoomPalette.paper,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                model.workSurface.selectedStoryId == story.storyId
                                    ? BehavioralRoomPalette.violet
                                    : BehavioralRoomPalette.line,
                                lineWidth: model.workSurface.selectedStoryId == story.storyId ? 1.5 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(story.displayLabel), \(story.status.title)")
            }
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.storyKit)
    }

    private var projectKit: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Project kit · Private context")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Spacer()
                Text(model.workSurface.projectKit?.projectId ?? "")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        BehavioralRoomPalette.violet.opacity(0.1),
                        in: Capsule()
                    )
            }
            ForEach(model.workSurface.projectKit?.sections ?? []) { section in
                Button {
                    model.selectProjectSection(section.sectionKey)
                } label: {
                    HStack {
                        coverageDot(section.coverage)
                        Text(section.title)
                            .font(.system(.body, design: .rounded, weight: .medium))
                        Spacer()
                        Text(section.sectionKey)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(BehavioralRoomPalette.muted)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: FullRoomLayout.minimumActionHitTarget, alignment: .leading)
                    .background(
                        section.sectionKey == model.workSurface.projectKit?.selectedSectionKey
                            ? BehavioralRoomPalette.violet.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.title), \(section.sectionKey)")
            }
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.projectKit)
    }

    private var claimKit: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("sourceClaimId")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(BehavioralRoomPalette.muted)
                Text(model.workSurface.resumeClaimKit?.sourceClaimId ?? "")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
            }
            if let contrary = model.workSurface.resumeClaimKit?.contraryNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contrary")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(BehavioralRoomPalette.candidateText)
                    Text(contrary)
                        .font(.system(.callout, design: .rounded))
                }
                .padding(10)
                .background(
                    BehavioralRoomPalette.candidateText.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            ForEach(model.workSurface.resumeClaimKit?.sections ?? []) { section in
                Button {
                    model.selectResumeSection(section.sectionKey)
                } label: {
                    HStack {
                        coverageDot(section.coverage)
                        Text(section.title)
                            .font(.system(.body, design: .rounded, weight: .medium))
                        Spacer()
                        Text(section.sectionKey)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(BehavioralRoomPalette.muted)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: FullRoomLayout.minimumActionHitTarget, alignment: .leading)
                    .background(
                        section.sectionKey == model.workSurface.resumeClaimKit?.selectedSectionKey
                            ? BehavioralRoomPalette.violet.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.claimKit)
    }

    private var starlCoverage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STARL coverage")
                .font(.system(.callout, design: .rounded, weight: .semibold))
            Text("Coverage only · not a score")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(BehavioralRoomPalette.muted)
            HStack(spacing: 12) {
                ForEach(STARLLane.allCases) { lane in
                    VStack(spacing: 6) {
                        coverageDot(model.workSurface.starl.state(for: lane))
                        Text(lane.shortTitle)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(BehavioralRoomPalette.navy)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        "\(lane.title) \(model.workSurface.starl.state(for: lane).rawValue)"
                    )
                }
            }
            .frame(minHeight: FullRoomLayout.minimumActionHitTarget)
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.starl)
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.system(.callout, design: .rounded, weight: .semibold))
            TextEditor(
                text: Binding(
                    get: { model.workSurface.notes },
                    set: { model.updateNotes($0) }
                )
            )
            .font(.system(.body, design: .rounded))
            .frame(minHeight: 120)
            .disabled(!model.canEditNotes)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(
                BehavioralRoomPalette.paper,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(BehavioralRoomPalette.line, lineWidth: 1)
            }
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.notes)
    }

    private var conspicuousGaps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.workSurface.openGaps, id: \.self) { gap in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Conspicuous gap: \(gap)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(BehavioralRoomPalette.candidateText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    BehavioralRoomPalette.candidateText.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(BehavioralRoomPalette.candidateText.opacity(0.45), lineWidth: 1)
                }
            }
        }
        .accessibilityIdentifier(BehavioralRoomAccessibility.gaps)
    }

    private var coachedDiscoveryControls: some View {
        Group {
            if model.workSurface.mode == .coachedDiscovery {
                Button {
                    model.returnToInterviewer()
                } label: {
                    Label("Return to interviewer", systemImage: "person.fill.checkmark")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: FullRoomLayout.minimumActionHitTarget
                        )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(BehavioralRoomAccessibility.returnToInterviewer)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.beginCoachedDiscovery()
                    } label: {
                        Label("Begin coached discovery", systemImage: "lightbulb")
                            .frame(
                                maxWidth: .infinity,
                                minHeight: FullRoomLayout.minimumActionHitTarget
                            )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(BehavioralRoomAccessibility.coachedDiscovery)
                    Text("Only if you cannot answer cold.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(BehavioralRoomPalette.muted)
                }
            }
        }
    }

    private var floorRail: some View {
        let floorState = model.floorStatePresentation
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(floorState.full.label.uppercased())
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(BehavioralRoomPalette.violet)
                    .lineLimit(1)
                Text(floorState.full.detail)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(BehavioralRoomPalette.muted)
                    .lineLimit(1)
            }
            .frame(width: FullRoomLayout.floorStatusWidth, alignment: .leading)
            .accessibilityLabel(floorState.full.label)
            .accessibilityValue(floorState.full.detail)

            BehavioralWaveform(isActive: model.canStopRecording)
                .frame(minWidth: 140, maxWidth: .infinity)
                .frame(height: FullRoomLayout.minimumActionHitTarget)

            Button {
                Task { await model.performPrimaryAction() }
            } label: {
                floorLabel(model.actionTitle, systemImage: model.actionIcon, minWidth: 132)
            }
            .buttonStyle(BehavioralPrimaryButtonStyle())
            .disabled(!model.canAct)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier(BehavioralRoomAccessibility.primaryAction)
            .accessibilityLabel(model.actionTitle)
            .help(model.actionTitle)

            if model.canStopRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    floorLabel("Pause", systemImage: "pause.fill", minWidth: 86)
                }
                .buttonStyle(BehavioralChromeButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier(BehavioralRoomAccessibility.recordingAction)
                .accessibilityLabel("Pause recording")
            } else if model.showsRecordControl {
                Button {
                    Task { await model.recordSegment() }
                } label: {
                    floorLabel("Record", systemImage: "record.circle", minWidth: 86)
                }
                .buttonStyle(BehavioralChromeButtonStyle())
                .disabled(!model.canRecordSegment)
                .accessibilityIdentifier(BehavioralRoomAccessibility.recordingAction)
                .accessibilityLabel("Record answer segment")
            } else {
                Button {} label: {
                    floorLabel("Pause", systemImage: "pause.circle.fill", minWidth: 86)
                }
                .buttonStyle(BehavioralChromeButtonStyle())
                .disabled(true)
                .accessibilityIdentifier(BehavioralRoomAccessibility.hostedPause)
                .accessibilityLabel("Pause hosted activity timer")
                .help("Hosted activity timer is not enabled for behavioral. Local recording pause appears while a segment is open.")
            }

            Button {
                Task { _ = await model.finishInterview() }
            } label: {
                floorLabel("End", systemImage: "stop.fill", minWidth: 70)
            }
            .buttonStyle(BehavioralChromeButtonStyle(tint: BehavioralRoomPalette.warning))
            .foregroundStyle(BehavioralRoomPalette.warning)
            .disabled(!model.canFinishLocally)
            .accessibilityIdentifier(BehavioralRoomAccessibility.endAction)
            .accessibilityLabel("End local interview")
            .help("Ends the local session. Hosted finish waits on interview-arc#389.")
        }
        .padding(.horizontal, FullRoomLayout.floorContentHorizontalPadding)
        .frame(minHeight: FullRoomLayout.floorRailHeight)
        .background(BehavioralRoomPalette.paper)
        .accessibilityIdentifier(BehavioralRoomAccessibility.floorRail)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(BehavioralRoomPalette.line, lineWidth: 1)
                .padding(.horizontal, FullRoomLayout.floorOutlineHorizontalInset)
                .padding(.vertical, FullRoomLayout.floorOutlineVerticalInset)
        }
    }

    private func floorLabel(
        _ title: String,
        systemImage: String,
        minWidth: CGFloat
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(1)
            .frame(
                minWidth: minWidth,
                minHeight: FullRoomLayout.minimumActionHitTarget
            )
    }

    private func coverageDot(_ state: STARLCoverageState) -> some View {
        Group {
            switch state {
            case .filled:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 46 / 255, green: 125 / 255, blue: 50 / 255))
            case .current:
                ZStack {
                    Circle()
                        .stroke(BehavioralRoomPalette.violet, lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(BehavioralRoomPalette.navy)
                        .frame(width: 6, height: 6)
                }
            case .empty:
                Circle()
                    .stroke(BehavioralRoomPalette.muted, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityHidden(true)
    }

    private func statusColor(_ status: BehavioralEvidenceStatus) -> Color {
        switch status {
        case .ownerAttested, .corroborated:
            return Color(red: 46 / 255, green: 125 / 255, blue: 50 / 255)
        case .partial, .pending:
            return BehavioralRoomPalette.violet
        case .contradicted:
            return BehavioralRoomPalette.candidateText
        }
    }
}

private struct BehavioralLiveMark: View {
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.05, to: 0.43)
                .stroke(
                    BehavioralRoomPalette.violet,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-22))
            Circle()
                .trim(from: 0.55, to: 0.92)
                .stroke(
                    BehavioralRoomPalette.navy,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-22))
            Circle()
                .fill(Color(red: 237 / 255, green: 78 / 255, blue: 47 / 255))
                .frame(width: 7, height: 7)
                .offset(x: 10, y: 8)
        }
        .padding(4)
        .accessibilityLabel("Interview Arc Live")
    }
}

private struct BehavioralWaveform: View {
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
                with: .color(BehavioralRoomPalette.violet.opacity(0.7)),
                lineWidth: 1
            )
            let count = levels.count
            let spacing = size.width / CGFloat(count + 1)
            for (index, level) in levels.enumerated() {
                let x = spacing * CGFloat(index + 1)
                let height = max(3, level * size.height * (isActive ? 0.88 : 0.55))
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - height / 2))
                bar.addLine(to: CGPoint(x: x, y: center + height / 2))
                context.stroke(
                    bar,
                    with: .color(BehavioralRoomPalette.violet),
                    lineWidth: 2
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BehavioralChromeButtonStyle: ButtonStyle {
    var tint: Color = BehavioralRoomPalette.violet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.16 : 0.06))
            }
    }
}

private struct BehavioralPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BehavioralPrimaryButtonBody(configuration: configuration)
    }

    private struct BehavioralPrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(height: FullRoomLayout.minimumActionHitTarget)
                .foregroundStyle(
                    isEnabled ? Color.white : BehavioralRoomPalette.violet.opacity(0.42)
                )
                .background {
                    Capsule()
                        .fill(
                            isEnabled
                                ? BehavioralRoomPalette.violet.opacity(
                                    configuration.isPressed ? 0.82 : 1
                                )
                                : BehavioralRoomPalette.violet.opacity(0.12)
                        )
                }
                .contentShape(Capsule())
        }
    }
}
