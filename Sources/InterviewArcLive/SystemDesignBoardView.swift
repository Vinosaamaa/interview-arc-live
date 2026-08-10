import InterviewArcLiveCore
import SwiftUI

struct SystemDesignBoardView: View {
    @ObservedObject var model: SystemDesignRoomModel

    @State private var connectorSourceID: BoardElementID?
    @State private var activePenPoints: [BoardPoint] = []
    @State private var lastEraserPoint: BoardPoint?
    @State private var newBoxKind: BoardNodeKind = .service
    @State private var editingElementID: BoardElementID?
    @State private var editingText = ""
    @State private var interactionFeedback: String?
    @State private var isRevisionHistoryPresented = false
    @FocusState private var isCanvasFocused: Bool
    @FocusState private var isLabelEditorFocused: Bool
    @AccessibilityFocusState private var accessibilityFocusedElementID: BoardElementID?

    var body: some View {
        VStack(spacing: 0) {
            revisionRail
            Divider().overlay(BoardPalette.line)
            toolRail
            Divider().overlay(BoardPalette.line)
            canvas
        }
        .background(BoardPalette.canvas)
        .foregroundStyle(BoardPalette.navy)
        .sheet(isPresented: $isRevisionHistoryPresented) {
            revisionHistoryBrowser
        }
        .onDeleteCommand {
            guard !model.isInspectingBoardRevision else { return }
            model.applyBoardAction(.deleteSelection)
        }
        .onExitCommand {
            guard !model.isInspectingBoardRevision else { return }
            if editingElementID != nil {
                cancelEditing()
            } else {
                connectorSourceID = nil
                select(nil)
                model.applyBoardAction(.setTool(.select))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System design board")
        .accessibilityValue(boardAccessibilityValue)
        .boardRootAccessibilityActions(
            isReadOnly: model.isInspectingBoardRevision,
            addTitle: "Add \(newBoxKind.displayName) node",
            add: addBoxFromKeyboard,
            next: { selectRelativeElement(forward: true) },
            previous: { selectRelativeElement(forward: false) }
        )
        .task(id: interactionFeedback) {
            guard interactionFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            interactionFeedback = nil
        }
    }

    private var revisionRail: some View {
        ViewThatFits(in: .horizontal) {
            revisionRailContent(compact: false)
            revisionRailContent(compact: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: BoardLayoutMetrics.revisionRailHeight,
            alignment: .leading
        )
        .background(BoardPalette.paper)
    }

    private func revisionRailContent(compact: Bool) -> some View {
        let sizing = BoardRailWidthBudget.revisionSizing(
            compact: compact,
            actionCount: compactRevisionActionCount
        )

        return HStack(spacing: compact ? BoardRailWidthBudget.compactRevisionSpacing : 0) {
            if compact {
                tab("Board", isSelected: true)
                    .frame(width: BoardRailWidthBudget.compactTabWidth)
                    .accessibilityHint("Brief and Notes are not available in this version")
                revisionStatus(compact: true)
                Spacer(minLength: BoardRailWidthBudget.compactRevisionSpacerWidth)
                revisionPrimaryAction(compact: true)
                revisionMenu(compact: true)
                attachRevisionButton(compact: true)
                exportRevisionButton(compact: true)
            } else {
                HStack(spacing: 30) {
                    tab("Board", isSelected: true)
                    tab("Brief", isSelected: false)
                    tab("Notes", isSelected: false)
                }
                .fixedSize()

                Spacer(
                    minLength: BoardRailWidthBudget.wideRevisionGroupGapMinimum
                )

                HStack(spacing: 18) {
                    revisionStatus(compact: false)
                    revisionPrimaryAction(compact: false)
                    revisionMenu(compact: false)
                    railDivider
                    attachRevisionButton(compact: false)
                    exportRevisionButton(compact: false)
                }
                .fixedSize()
            }
        }
        .font(.system(.callout, design: .rounded))
        .padding(.horizontal, compact
            ? BoardRailWidthBudget.compactHorizontalPadding
            : 20
        )
        .frame(
            minWidth: sizing.requiredWidth,
            maxWidth: sizing.maximumWidth,
            minHeight: BoardLayoutMetrics.revisionRailHeight
        )
        .fixedSize(horizontal: sizing.fixesHorizontalSize, vertical: false)
    }

    private var compactRevisionActionCount: Int {
        var count = 2 // Attach and Export are always discoverable.
        if model.isInspectingBoardRevision || model.isBoardDraftDirty {
            count += 1
        }
        if model.snapshot?.board.revisions.isEmpty == false {
            count += 1
        }
        return count
    }

    private func revisionStatus(compact: Bool) -> some View {
        let status = model.boardRevisionStatusPresentation
        return Label {
            Text(
                compact
                    ? BoardRailPresentation.compactRevisionStatus(status)
                    : status.fullText
            )
            .lineLimit(1)
        } icon: {
            Image(systemName: revisionStatusIcon)
        }
        .foregroundStyle(model.boardErrorMessage == nil
            ? BoardPalette.muted
            : BoardPalette.errorText
        )
        .frame(
            width: compact ? BoardRailWidthBudget.compactStatusWidth : nil,
            alignment: .leading
        )
        .frame(minHeight: BoardLayoutMetrics.minimumHitTarget)
        .help(status.fullText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board revision status")
        .accessibilityValue(status.fullText)
    }

    private var revisionStatusIcon: String {
        if model.boardErrorMessage != nil { return "exclamationmark.triangle.fill" }
        if model.isBoardSaving { return "arrow.triangle.2.circlepath" }
        if model.isInspectingBoardRevision { return "lock.fill" }
        if model.isBoardDraftDirty { return "circle.dotted" }
        return "checkmark.circle.fill"
    }

    @ViewBuilder
    private func revisionPrimaryAction(compact: Bool) -> some View {
        if model.isInspectingBoardRevision {
            Button {
                Task { await model.returnToBoardDraft() }
            } label: {
                adaptiveRailLabel(
                    "Return to draft",
                    icon: "arrow.uturn.backward",
                    compact: compact
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(BoardPalette.violet)
            .help("Return to draft")
            .accessibilityHint("Closes the immutable revision without changing the editable draft")
        } else if model.isBoardDraftDirty {
            Button {
                Task { await model.saveBoardRevision() }
            } label: {
                adaptiveRailLabel(
                    "Save revision",
                    icon: "square.and.arrow.down",
                    compact: compact
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(BoardPalette.violet)
            .disabled(!model.canSaveBoardRevision)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save revision")
            .accessibilityHint("Creates one immutable board revision")
        }
    }

    @ViewBuilder
    private func revisionMenu(compact: Bool) -> some View {
        if let snapshot = model.snapshot, !snapshot.board.revisions.isEmpty {
            Menu {
                ForEach(
                    BoardRevisionHistoryPresentation.recent(
                        snapshot.board.revisions
                    ),
                    id: \.id
                ) { revision in
                    Button("Revision \(revision.ordinal + 1)") {
                        Task { await model.inspectBoardRevision(revision.id) }
                    }
                }
                if BoardRevisionHistoryPresentation.hasMore(
                    snapshot.board.revisions
                ) {
                    Divider()
                    Button("View all revisions…") {
                        isRevisionHistoryPresented = true
                    }
                }
            } label: {
                adaptiveRailLabel(
                    "Revisions",
                    icon: "clock.arrow.circlepath",
                    compact: compact
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Browse revisions")
            .accessibilityHint("Opens an immutable saved board for inspection")
        }
    }

    private var revisionHistoryBrowser: some View {
        NavigationStack {
            List(
                BoardRevisionHistoryPresentation.all(
                    model.snapshot?.board.revisions ?? []
                ),
                id: \.id
            ) { revision in
                Button {
                    isRevisionHistoryPresented = false
                    Task { await model.inspectBoardRevision(revision.id) }
                } label: {
                    HStack {
                        Label(
                            "Revision \(revision.ordinal + 1)",
                            systemImage: "doc.text"
                        )
                        Spacer()
                        if model.inspectedBoardRevisionID == revision.id {
                            Text("Viewing")
                                .foregroundStyle(BoardPalette.muted)
                        }
                    }
                    .frame(minHeight: BoardLayoutMetrics.minimumHitTarget)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Board revisions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isRevisionHistoryPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func attachRevisionButton(compact: Bool) -> some View {
        Button {
            Task { await model.attachSelectedBoardRevision() }
        } label: {
            adaptiveRailLabel(
                "Attach revision",
                icon: "paperclip",
                compact: compact
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(BoardPalette.navy)
        .disabled(!model.canAttachBoardRevision)
        .help("Attach revision")
        .accessibilityHint("Attaches the selected immutable revision to the latest unattached answer")
    }

    private func exportRevisionButton(compact: Bool) -> some View {
        Button {
            Task { await model.exportSelectedBoardRevision() }
        } label: {
            if model.isBoardExporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(
                        minWidth: BoardLayoutMetrics.minimumHitTarget,
                        minHeight: BoardLayoutMetrics.minimumHitTarget
                    )
                    .accessibilityLabel("Exporting board revision")
            } else {
                adaptiveRailLabel(
                    "Export",
                    icon: "square.and.arrow.up",
                    compact: compact
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(BoardPalette.violet)
        .background(
            BoardPalette.violet.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BoardPalette.violet.opacity(0.28), lineWidth: 1)
        }
        .disabled(!model.canExportBoardRevision || model.isBoardExporting)
        .help("Export board revision")
        .accessibilityHint("Exports Draw.io source, SVG, and PNG as one private bundle")
    }

    @ViewBuilder
    private func adaptiveRailLabel(
        _ title: String,
        icon: String,
        compact: Bool
    ) -> some View {
        if compact {
            Image(systemName: icon)
                .frame(
                    width: BoardLayoutMetrics.minimumHitTarget,
                    height: BoardLayoutMetrics.minimumHitTarget
                )
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: icon)
                .frame(minHeight: BoardLayoutMetrics.minimumHitTarget)
        }
    }

    private func tab(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.system(.body, design: .rounded, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? BoardPalette.ink : BoardPalette.muted)
            .frame(minHeight: BoardLayoutMetrics.sectionLabelHeight)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(BoardPalette.violet)
                        .frame(height: 3)
                }
            }
            .accessibilityLabel(
                isSelected
                    ? "Board, current section"
                    : "\(title), not available in this version"
            )
    }

    private var toolRail: some View {
        ViewThatFits(in: .horizontal) {
            toolRailContent(compact: false)
            toolRailContent(compact: true)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: BoardLayoutMetrics.toolRailHeight,
            alignment: .leading
        )
        .background(BoardPalette.toolbar)
    }

    private func toolRailContent(compact: Bool) -> some View {
        let sizing = BoardRailWidthBudget.toolbarSizing(compact: compact)

        return HStack(spacing: compact
            ? BoardRailWidthBudget.compactToolbarSpacing
            : 8
        ) {
            toolButton(
                .select,
                title: "Select",
                icon: "cursorarrow",
                compact: compact
            )
            toolButton(
                .connector,
                title: connectorSourceID == nil ? "Connector" : "Choose target",
                icon: "point.3.connected.trianglepath.dotted",
                compact: compact
            )
            boxToolMenu(compact: compact)
            toolButton(
                .label,
                title: "Text",
                icon: "textformat",
                compact: compact
            )
            toolRailSeparator(compact: compact)
            toolButton(
                .pen,
                title: "Pen",
                icon: "pencil.tip",
                compact: compact
            )
            toolButton(
                .eraser,
                title: "Eraser",
                icon: "eraser",
                compact: compact
            )
            toolRailSeparator(compact: compact)
            historyButton(isUndo: true, compact: compact)
            historyButton(isUndo: false, compact: compact)
            toolRailSeparator(compact: compact)
            zoomMenu(compact: compact)
        }
        .buttonStyle(.plain)
        .font(.system(.callout, design: .rounded))
        .padding(.horizontal, compact
            ? BoardRailWidthBudget.compactHorizontalPadding
            : 20
        )
        .frame(
            minWidth: sizing.requiredWidth,
            maxWidth: sizing.maximumWidth,
            minHeight: BoardLayoutMetrics.toolRailHeight
        )
        .fixedSize(horizontal: sizing.fixesHorizontalSize, vertical: false)
    }

    @ViewBuilder
    private func toolRailSeparator(compact: Bool) -> some View {
        if compact {
            railDivider
        } else {
            Spacer(minLength: BoardRailWidthBudget.wideToolbarGroupGapMinimum)
            railDivider
            Spacer(minLength: BoardRailWidthBudget.wideToolbarGroupGapMinimum)
        }
    }

    private func boxToolMenu(compact: Bool) -> some View {
        Menu {
            Button {
                addBoxFromKeyboard()
            } label: {
                Label(
                    "Add \(newBoxKind.displayName) node",
                    systemImage: "plus.square"
                )
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Divider()

            ForEach(BoardNodeKind.selectableKinds, id: \.rawValue) { kind in
                Button {
                    newBoxKind = kind
                    connectorSourceID = nil
                    model.applyBoardAction(.setTool(.box))
                    interactionFeedback = "\(kind.displayName) box tool active · click the canvas to place"
                    isCanvasFocused = true
                } label: {
                    boxKindMenuLabel(kind)
                }
            }
        } label: {
            Group {
                if compact {
                    Image(systemName: "square")
                        .accessibilityLabel("Box")
                } else {
                    Label("Box", systemImage: "square")
                        .padding(.horizontal, 10)
                }
            }
                .frame(
                    width: compact ? BoardLayoutMetrics.minimumHitTarget : nil
                )
                .frame(minHeight: BoardLayoutMetrics.toolControlHeight)
                .background(
                    model.boardEditor.tool == .box
                        ? BoardPalette.violet.opacity(0.14)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            model.boardEditor.tool == .box
                                ? BoardPalette.violet.opacity(0.72)
                                : .clear,
                            lineWidth: 1
                        )
                }
        } primaryAction: {
            connectorSourceID = nil
            model.applyBoardAction(.setTool(.box))
            interactionFeedback = "\(newBoxKind.displayName) box tool active · click the canvas to place"
            isCanvasFocused = true
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .keyboardShortcut("b", modifiers: .control)
        .disabled(model.isInspectingBoardRevision)
        .foregroundStyle(
            model.boardEditor.tool == .box
                ? BoardPalette.violet
                : BoardPalette.navy
        )
        .accessibilityLabel("Box")
        .accessibilityValue(
            "\(newBoxKind.displayName)\(model.boardEditor.tool == .box ? ", selected" : "")"
        )
        .accessibilityHint("Choose the architecture node kind, then click the canvas")
        .help("Box · \(newBoxKind.displayName)")
    }

    @ViewBuilder
    private func boxKindMenuLabel(_ kind: BoardNodeKind) -> some View {
        if newBoxKind == kind {
            Label(kind.displayName, systemImage: "checkmark")
        } else {
            Text(kind.displayName)
        }
    }

    private func toolButton(
        _ tool: BoardEditorTool,
        title: String,
        icon: String,
        compact: Bool
    ) -> some View {
        Button {
            connectorSourceID = nil
            model.applyBoardAction(.setTool(tool))
            interactionFeedback = "\(title) tool active"
            isCanvasFocused = true
        } label: {
            Group {
                if compact {
                    Image(systemName: icon)
                        .accessibilityLabel(title)
                } else {
                    Label(title, systemImage: icon)
                        .padding(.horizontal, 10)
                }
            }
                .frame(
                    width: compact ? BoardLayoutMetrics.minimumHitTarget : nil
                )
                .frame(minHeight: BoardLayoutMetrics.toolControlHeight)
                .background(
                    model.boardEditor.tool == tool
                        ? BoardPalette.violet.opacity(0.14)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            model.boardEditor.tool == tool
                                ? BoardPalette.violet.opacity(0.72)
                                : .clear,
                            lineWidth: 1
                        )
                }
        }
        .foregroundStyle(
            model.boardEditor.tool == tool
                ? BoardPalette.violet
                : BoardPalette.navy
        )
        .keyboardShortcut(shortcut(for: tool), modifiers: .control)
        .disabled(model.isInspectingBoardRevision)
        .accessibilityValue(model.boardEditor.tool == tool ? "Selected" : "")
        .accessibilityHint(hint(for: tool))
        .help(title)
    }

    private func historyButton(isUndo: Bool, compact: Bool) -> some View {
        let title = isUndo ? "Undo" : "Redo"
        let icon = isUndo ? "arrow.uturn.backward" : "arrow.uturn.forward"
        return Button {
            model.applyBoardAction(isUndo ? .undo : .redo)
            interactionFeedback = isUndo
                ? "Undid the last board edit"
                : "Restored the last board edit"
        } label: {
            Group {
                if compact {
                    Image(systemName: icon)
                        .accessibilityLabel(title)
                } else {
                    Label(title, systemImage: icon)
                }
            }
            .frame(
                width: compact ? BoardLayoutMetrics.minimumHitTarget : nil
            )
            .frame(minHeight: BoardLayoutMetrics.toolControlHeight)
        }
        .disabled(
            isUndo
                ? !model.boardEditor.canUndo || model.isInspectingBoardRevision
                : !model.boardEditor.canRedo || model.isInspectingBoardRevision
        )
        .keyboardShortcut(
            "z",
            modifiers: isUndo ? .command : [.command, .shift]
        )
        .accessibilityHint(
            isUndo
                ? "Reverses the last board edit"
                : "Restores the last undone board edit"
        )
        .help(title)
    }

    private func zoomMenu(compact: Bool) -> some View {
        Menu {
            Button("Zoom in") {
                model.applyBoardAction(
                    .setZoom(model.boardEditor.zoom * 1.25)
                )
            }
            .keyboardShortcut("+", modifiers: .command)
            Button("Zoom out") {
                model.applyBoardAction(
                    .setZoom(model.boardEditor.zoom / 1.25)
                )
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Reset zoom") {
                model.applyBoardAction(.resetZoom)
            }
            .keyboardShortcut("0", modifiers: .command)
        } label: {
            HStack(spacing: compact ? 3 : 5) {
                if compact { Image(systemName: "magnifyingglass") }
                Text("\(Int((model.boardEditor.zoom * 100).rounded()))%")
                if !compact { Image(systemName: "chevron.down") }
            }
            .font(compact ? .caption : .callout)
            .frame(
                width: compact ? BoardRailWidthBudget.compactZoomWidth : nil
            )
            .frame(minHeight: BoardLayoutMetrics.toolControlHeight)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Board zoom")
        .accessibilityLabel("Board zoom")
        .accessibilityValue("\(Int((model.boardEditor.zoom * 100).rounded())) percent")
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                let document = model.boardDocumentForPresentation
                let zoom = model.boardEditor.zoom
                ZStack(alignment: .topLeading) {
                    BoardDotGrid()
                        .frame(
                            width: document.canvas.size.width,
                            height: document.canvas.size.height
                        )
                        .contentShape(Rectangle())
                        .gesture(backgroundGesture)

                    connectorLayer(document)
                    strokeLayer(document)
                    labelLayer(document)
                    boxLayer(document)

                    if document.elements.isEmpty {
                        emptyState
                            .padding(.leading, 28)
                            .padding(.top, 26)
                    }

                    if activePenPoints.count > 1 {
                        BoardStrokePath(
                            points: activePenPoints,
                            color: BoardPalette.orange,
                            width: 3
                        )
                    }
                }
                .frame(
                    width: document.canvas.size.width,
                    height: document.canvas.size.height,
                    alignment: .topLeading
                )
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: max(proxy.size.width, document.canvas.size.width * zoom),
                    height: max(proxy.size.height, document.canvas.size.height * zoom),
                    alignment: .topLeading
                )
            }
            .scrollIndicators(.visible)
            .background(BoardPalette.canvas)
            .focusable()
            .focused($isCanvasFocused)
            .onKeyPress(
                keys: [
                    .tab,
                    .return,
                    .space,
                    .leftArrow,
                    .rightArrow,
                    .upArrow,
                    .downArrow,
                    "b",
                ],
                phases: .down,
                action: handleCanvasKeyPress
            )
            .overlay {
                Rectangle()
                    .stroke(
                        isCanvasFocused ? BoardPalette.violet.opacity(0.7) : .clear,
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                boardFooter
                    .padding(12)
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BoardPalette.violet)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Build the architecture here")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                Text("Choose Box, Text, Connector, or Pen. Save a revision before Hand off.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(BoardPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: BoardLayoutMetrics.emptyStateMaximumWidth, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var boardFooter: some View {
        let presentation = BoardFooterPresentation.make(
            errorMessage: model.boardErrorMessage,
            exportMessage: model.boardExportMessage,
            interactionFeedback: interactionFeedback
        )

        return HStack(spacing: 7) {
            Image(systemName: presentation.systemImage)
            Text(presentation.text)
                .lineLimit(2)
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(
            presentation.tone == .error
                ? BoardPalette.errorText
                : BoardPalette.muted
        )
        .frame(
            maxWidth: BoardCanvasVisualMetrics.footerMaximumWidth,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board status")
        .accessibilityValue(presentation.text)
    }

    private func boxLayer(_ document: BoardDocument) -> some View {
        ForEach(boxes(in: document), id: \.id) { box in
            let selected = model.boardEditor.selectedElementID == box.id
                && !model.isInspectingBoardRevision
            let visual = box.kind.visual
            let nodeRect = CGRect(
                origin: .zero,
                size: CGSize(
                    width: box.frame.size.width,
                    height: box.frame.size.height
                )
            )
            let labelLayout = BoardNodeLabelLayout(
                text: box.label,
                in: visual.labelRect(in: nodeRect)
            )
            ZStack {
                BoardNodeVisualLayer(
                    visual: visual,
                    fill: boardColor(box.fill),
                    stroke: selected
                        ? BoardPalette.violet
                        : boardColor(box.stroke),
                    isSelected: selected
                )
                .accessibilityHidden(true)

                if editingElementID == box.id {
                    TextField("Box label", text: $editingText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused($isLabelEditorFocused)
                        .onSubmit { commitEditing(id: box.id) }
                        .frame(
                            width: labelLayout.rect.width,
                            height: labelLayout.rect.height
                        )
                        .clipped()
                        .position(
                            x: labelLayout.rect.midX,
                            y: labelLayout.rect.midY
                        )
                } else {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(labelLayout.lines.enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                                .font(
                                    .system(
                                        size: labelLayout.resolvedFontSize,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .lineLimit(1)
                                .frame(
                                    height: labelLayout.resolvedLineHeight
                                )
                        }
                    }
                    .frame(
                        width: labelLayout.rect.width,
                        height: labelLayout.rect.height
                    )
                    .clipped()
                    .position(
                        x: labelLayout.rect.midX,
                        y: labelLayout.rect.midY
                    )
                }
            }
            .foregroundStyle(boardColor(box.stroke))
            .frame(width: box.frame.size.width, height: box.frame.size.height)
            .overlay { selectionHandles(for: box, isVisible: selected) }
            .position(
                x: box.frame.origin.x + box.frame.size.width / 2,
                y: box.frame.origin.y + box.frame.size.height / 2
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !model.isInspectingBoardRevision else { return }
                beginEditing(id: box.id, text: box.label)
            }
            .onTapGesture {
                handleBoxTap(box)
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onEnded { value in
                        guard model.boardEditor.tool == .select,
                              !model.isInspectingBoardRevision else { return }
                        select(box.id)
                        model.applyBoardAction(
                            .moveSelected(
                                by: BoardPoint(
                                    x: value.translation.width / model.boardEditor.zoom,
                                    y: value.translation.height / model.boardEditor.zoom
                                )
                            )
                        )
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Architecture box: \(box.label.isEmpty ? "Untitled" : box.label)")
            .accessibilityValue(
                "\(visual.accessibilityName), \(Int(box.frame.size.width.rounded())) by \(Int(box.frame.size.height.rounded())) points\(selected ? ", selected" : "")"
            )
            .boardElementHint(
                isReadOnly: model.isInspectingBoardRevision,
                editable: BoardConnectorBoxActivation.resolve(
                    sourceID: connectorSourceID,
                    activatedBoxID: box.id,
                    tool: model.boardEditor.tool
                ).accessibilityHint
            )
            .accessibilityFocused($accessibilityFocusedElementID, equals: box.id)
            .boardBoxAccessibilityActions(
                isReadOnly: model.isInspectingBoardRevision,
                connectorActionTitle: BoardConnectorBoxActivation.resolve(
                    sourceID: connectorSourceID,
                    activatedBoxID: box.id,
                    tool: model.boardEditor.tool
                ).accessibilityActionTitle
            ) {
                handleBoxTap(box)
            }
            .boardEditAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
                    || model.boardEditor.tool == .connector
            ) {
                select(box.id)
                beginEditing(id: box.id, text: box.label)
            }
            .boardMoveAccessibilityActions(
                isReadOnly: model.isInspectingBoardRevision,
                left: { select(box.id); moveSelection(.left) },
                right: { select(box.id); moveSelection(.right) },
                up: { select(box.id); moveSelection(.up) },
                down: { select(box.id); moveSelection(.down) }
            )
            .boardResizeAccessibilityActions(
                isReadOnly: model.isInspectingBoardRevision,
                increase: {
                    select(box.id)
                    resizeSelection(by: BoardPoint(x: 10, y: 10))
                },
                decrease: {
                    select(box.id)
                    resizeSelection(by: BoardPoint(x: -10, y: -10))
                }
            )
            .boardDeleteAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                deleteBoardElement(box.id, name: "Architecture node")
            }
        }
    }

    private func connectorLayer(_ document: BoardDocument) -> some View {
        ForEach(connectors(in: document), id: \.id) { connector in
            let selected = model.boardEditor.selectedElementID == connector.id
                && !model.isInspectingBoardRevision
            let capabilities = BoardSelectionCapabilities(
                element: .connector(connector)
            )
            ZStack(alignment: .topLeading) {
                BoardConnectorPath(
                    start: connector.start.point,
                    end: connector.end.point,
                    color: selected
                        ? BoardPalette.violet
                        : boardColor(connector.stroke)
                )
                Group {
                    if editingElementID == connector.id {
                        TextField("Connector label", text: $editingText)
                            .textFieldStyle(.roundedBorder)
                            .focused($isLabelEditorFocused)
                            .onSubmit { commitEditing(id: connector.id) }
                            .frame(width: 150)
                    } else {
                        Button {
                            select(connector.id)
                            isCanvasFocused = true
                        } label: {
                            Text(connector.label)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(BoardPalette.muted)
                                .padding(.horizontal, connector.label.isEmpty ? 13 : 5)
                                .frame(minWidth: 30, minHeight: 30)
                                .background(BoardPalette.canvas.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                        .onTapGesture(count: 2) {
                            guard !model.isInspectingBoardRevision else { return }
                            beginEditing(id: connector.id, text: connector.label)
                        }
                        .disabled(model.isInspectingBoardRevision)
                    }
                }
                .position(
                    x: (connector.start.point.x + connector.end.point.x) / 2,
                    y: (connector.start.point.y + connector.end.point.y) / 2
                )
                .accessibilityLabel(
                    connector.label.isEmpty
                        ? "Unlabeled connector"
                        : "Connector: \(connector.label)"
                )
                .accessibilityValue(selected ? "Selected" : "")
                .boardElementHint(
                    isReadOnly: model.isInspectingBoardRevision,
                    editable: capabilities.canMove
                        ? "Select, label, move, or delete this free connector"
                        : "Select, label, or delete this connector; its endpoints stay anchored to their nodes"
                )
                .accessibilityFocused($accessibilityFocusedElementID, equals: connector.id)
                .boardEditAccessibilityAction(
                    isReadOnly: model.isInspectingBoardRevision
                ) {
                    select(connector.id)
                    beginEditing(id: connector.id, text: connector.label)
                }
                .boardMoveAccessibilityActions(
                    isReadOnly: model.isInspectingBoardRevision
                        || !capabilities.canMove,
                    left: { select(connector.id); moveSelection(.left) },
                    right: { select(connector.id); moveSelection(.right) },
                    up: { select(connector.id); moveSelection(.up) },
                    down: { select(connector.id); moveSelection(.down) }
                )
                .boardDeleteAccessibilityAction(
                    isReadOnly: model.isInspectingBoardRevision
                ) {
                    deleteBoardElement(connector.id, name: "Connector")
                }
            }
        }
    }

    private func strokeLayer(_ document: BoardDocument) -> some View {
        ForEach(strokes(in: document), id: \.id) { stroke in
            let selected = model.boardEditor.selectedElementID == stroke.id
                && !model.isInspectingBoardRevision
            ZStack {
                BoardStrokePath(
                    points: stroke.points,
                    color: selected
                        ? BoardPalette.violet
                        : boardColor(stroke.color),
                    width: selected ? stroke.width + 1 : stroke.width
                )

                BoardStrokeHitTarget(
                    points: stroke.points,
                    width: BoardStrokePointerInteraction.hitWidth(
                        for: stroke.width
                    )
                )
                .allowsHitTesting(
                    BoardStrokePointerInteraction.isEnabled(
                        tool: model.boardEditor.tool,
                        isReadOnly: model.isInspectingBoardRevision
                    )
                )
                .onTapGesture {
                    select(stroke.id)
                    interactionFeedback = "Freehand annotation selected"
                    isCanvasFocused = true
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onEnded { value in
                            guard BoardStrokePointerInteraction.isEnabled(
                                tool: model.boardEditor.tool,
                                isReadOnly: model.isInspectingBoardRevision
                            ) else { return }
                            select(stroke.id)
                            let changed = model.applyBoardAction(
                                .moveSelected(
                                    by: BoardPoint(
                                        x: value.translation.width
                                            / model.boardEditor.zoom,
                                        y: value.translation.height
                                            / model.boardEditor.zoom
                                    )
                                )
                            )
                            if changed {
                                interactionFeedback = "Freehand annotation moved"
                            }
                            isCanvasFocused = true
                        }
                )
                .accessibilityHidden(true)
            }
            .accessibilityElement()
            .accessibilityLabel("Freehand board annotation")
            .accessibilityValue(selected ? "Selected" : "")
            .boardElementHint(
                isReadOnly: model.isInspectingBoardRevision,
                editable: "Select, move, or delete this freehand annotation"
            )
            .accessibilityFocused($accessibilityFocusedElementID, equals: stroke.id)
            .boardSelectAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                select(stroke.id)
            }
            .boardMoveAccessibilityActions(
                isReadOnly: model.isInspectingBoardRevision,
                left: { select(stroke.id); moveSelection(.left) },
                right: { select(stroke.id); moveSelection(.right) },
                up: { select(stroke.id); moveSelection(.up) },
                down: { select(stroke.id); moveSelection(.down) }
            )
            .boardDeleteAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                deleteBoardElement(stroke.id, name: "Freehand annotation")
            }
        }
    }

    private func labelLayer(_ document: BoardDocument) -> some View {
        ForEach(labels(in: document), id: \.id) { label in
            Group {
                if editingElementID == label.id {
                    TextField("Text label", text: $editingText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isLabelEditorFocused)
                        .onSubmit { commitEditing(id: label.id) }
                } else {
                    Text(label.text)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(boardColor(label.color))
                }
            }
            .frame(
                width: BoardElementLayout.labelSize.width,
                height: BoardElementLayout.labelSize.height,
                alignment: .leading
            )
            .position(
                x: label.origin.x + BoardElementLayout.labelSize.width / 2,
                y: label.origin.y + BoardElementLayout.labelSize.height / 2
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !model.isInspectingBoardRevision else { return }
                beginEditing(id: label.id, text: label.text)
            }
            .onTapGesture {
                guard !model.isInspectingBoardRevision else { return }
                select(label.id)
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onEnded { value in
                        guard model.boardEditor.tool == .select,
                              !model.isInspectingBoardRevision else { return }
                        select(label.id)
                        model.applyBoardAction(
                            .moveSelected(
                                by: BoardPoint(
                                    x: value.translation.width / model.boardEditor.zoom,
                                    y: value.translation.height / model.boardEditor.zoom
                                )
                            )
                        )
                    }
            )
            .accessibilityLabel("Board text: \(label.text)")
            .accessibilityValue(
                model.boardEditor.selectedElementID == label.id ? "Selected" : ""
            )
            .boardElementHint(
                isReadOnly: model.isInspectingBoardRevision,
                editable: "Select, edit, move, or delete this board text"
            )
            .accessibilityFocused($accessibilityFocusedElementID, equals: label.id)
            .boardEditAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                select(label.id)
                beginEditing(id: label.id, text: label.text)
            }
            .boardMoveAccessibilityActions(
                isReadOnly: model.isInspectingBoardRevision,
                left: { select(label.id); moveSelection(.left) },
                right: { select(label.id); moveSelection(.right) },
                up: { select(label.id); moveSelection(.up) },
                down: { select(label.id); moveSelection(.down) }
            )
            .boardDeleteAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                deleteBoardElement(label.id, name: "Board text")
            }
        }
    }

    private var backgroundGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !model.isInspectingBoardRevision else { return }
                let point = BoardPoint(
                    x: value.location.x,
                    y: value.location.y
                )
                switch model.boardEditor.tool {
                case .pen:
                    if activePenPoints.count < BoardDocument.maximumStrokePoints,
                       activePenPoints.isEmpty
                        || distance(activePenPoints.last!, point) >= 2 {
                        activePenPoints.append(point)
                    }
                case .eraser:
                    if BoardGestureSampling.shouldAcceptEraserPoint(
                        point,
                        after: lastEraserPoint
                    ) {
                        lastEraserPoint = point
                        model.applyBoardAction(.eraseStroke(at: point, radius: 12))
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                guard !model.isInspectingBoardRevision else { return }
                let point = BoardPoint(x: value.location.x, y: value.location.y)
                switch model.boardEditor.tool {
                case .select:
                    select(nil)
                    interactionFeedback = "Selection cleared"
                case .box:
                    let frame = BoardNodeCreationDefaults.frame(
                        centeredAt: point,
                        in: model.boardEditor.document.canvas.size
                    )
                    model.applyBoardAction(
                        .createBox(
                            frame: frame,
                            label: newBoxKind.displayName,
                            kind: newBoxKind
                        )
                    )
                    model.applyBoardAction(.setTool(.select))
                    interactionFeedback = "\(newBoxKind.displayName) node added and selected"
                    if let id = model.boardEditor.selectedElementID {
                        beginEditing(id: id, text: newBoxKind.displayName)
                    }
                case .label:
                    let origin = BoardElementLayout.clampedLabelOrigin(
                        point,
                        in: model.boardEditor.document.canvas.size
                    )
                    model.applyBoardAction(
                        .createLabel(origin: origin, text: "Label")
                    )
                    model.applyBoardAction(.setTool(.select))
                    interactionFeedback = "Text label added and selected"
                    if let id = model.boardEditor.selectedElementID {
                        beginEditing(id: id, text: "Label")
                    }
                case .pen:
                    if activePenPoints.count >= 2 {
                        model.applyBoardAction(.addStroke(points: activePenPoints))
                    }
                    activePenPoints = []
                case .eraser:
                    if BoardGestureSampling.shouldAcceptEraserPoint(
                        point,
                        after: lastEraserPoint
                    ) {
                        model.applyBoardAction(.eraseStroke(at: point, radius: 12))
                    }
                    lastEraserPoint = nil
                case .connector:
                    connectorSourceID = nil
                    interactionFeedback = "Connector source cleared"
                }
            }
    }

    private func handleBoxTap(_ box: BoardBox) {
        guard !model.isInspectingBoardRevision else { return }
        switch BoardConnectorBoxActivation.resolve(
            sourceID: connectorSourceID,
            activatedBoxID: box.id,
            tool: model.boardEditor.tool
        ) {
        case .selectNormally:
            select(box.id)
            interactionFeedback = "\(boxDisplayName(box)) selected"

        case .chooseSource:
            connectorSourceID = box.id
            select(box.id)
            interactionFeedback = "Source selected: \(boxDisplayName(box)) · choose a target node"

        case .chooseDifferentTarget:
            select(box.id)
            interactionFeedback = "\(boxDisplayName(box)) is already the source · choose a different target node"

        case .connect(let sourceID, let targetID):
            guard let source = boxes(
                in: model.boardEditor.document
            ).first(where: { $0.id == sourceID }) else {
                connectorSourceID = nil
                interactionFeedback = "Connector source is no longer available · choose a source node"
                break
            }
            model.applyBoardAction(
                .connect(
                    sourceBoxID: sourceID,
                    targetBoxID: targetID,
                    label: ""
                )
            )
            connectorSourceID = nil
            model.applyBoardAction(.setTool(.select))
            accessibilityFocusedElementID = model.boardEditor.selectedElementID
            interactionFeedback = "Connector added: \(boxDisplayName(source)) to \(boxDisplayName(box))"
        }
        isCanvasFocused = true
    }

    private func boxDisplayName(_ box: BoardBox) -> String {
        box.label.isEmpty ? box.kind.displayName : box.label
    }

    private func deleteBoardElement(
        _ id: BoardElementID,
        name: String
    ) {
        guard !model.isInspectingBoardRevision else { return }
        if connectorSourceID == id { connectorSourceID = nil }
        select(id)
        model.applyBoardAction(.deleteSelection)
        accessibilityFocusedElementID = nil
        interactionFeedback = "\(name) deleted"
        isCanvasFocused = true
    }

    @ViewBuilder
    private func selectionHandles(for box: BoardBox, isVisible: Bool) -> some View {
        if isVisible {
            ZStack {
                ForEach(BoardResizeHandle.allCases, id: \.rawValue) { handle in
                    ZStack {
                        Rectangle()
                            .fill(BoardPalette.paper)
                            .frame(width: 10, height: 10)
                        Rectangle()
                            .stroke(BoardPalette.violet, lineWidth: 2)
                            .frame(width: 10, height: 10)
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .onEnded { value in
                                guard !model.isInspectingBoardRevision else { return }
                                select(box.id)
                                model.applyBoardAction(
                                    .resizeSelected(
                                        handle: handle,
                                        by: BoardPoint(
                                            x: value.translation.width / model.boardEditor.zoom,
                                            y: value.translation.height / model.boardEditor.zoom
                                        )
                                    )
                                )
                                interactionFeedback = "Node resized"
                            }
                    )
                    .help("Resize from the \(handle.displayName) corner")
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: handle.alignment
                    )
                }
            }
            .padding(-14)
            .accessibilityHidden(true)
        }
    }

    private func handleCanvasKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isInspectingBoardRevision,
              editingElementID == nil else {
            return .ignored
        }

        if press.key == .tab {
            guard press.modifiers.contains(.control) else { return .ignored }
            selectRelativeElement(forward: !press.modifiers.contains(.shift))
            return .handled
        }
        if press.key == "b", press.modifiers.contains(.command) {
            addBoxFromKeyboard()
            return .handled
        }
        if let activationKey = BoardKeyboardActivationKey(key: press.key) {
            switch BoardKeyboardActivation.resolve(
                key: activationKey,
                tool: model.boardEditor.tool,
                selectedElement: selectedBoardElement
            ) {
            case .activateConnectorBox(let id):
                guard let box = boxes(
                    in: model.boardEditor.document
                ).first(where: { $0.id == id }) else {
                    return .ignored
                }
                handleBoxTap(box)
                return .handled
            case .editLabel(let id, let text):
                beginEditing(id: id, text: text)
                return .handled
            case .ignored:
                return .ignored
            }
        }
        guard let direction = BoardKeyboardDirection(key: press.key) else {
            return .ignored
        }
        if press.modifiers.contains(.shift) {
            guard selectedCapabilities?.canResize == true else {
                return .ignored
            }
            resizeSelection(by: direction.delta)
        } else {
            guard selectedCapabilities?.canMove == true else {
                return .ignored
            }
            moveSelection(direction)
        }
        return .handled
    }

    private func addBoxFromKeyboard() {
        guard !model.isInspectingBoardRevision else { return }
        let frame = BoardKeyboardPlacement.nextBoxFrame(
            in: model.boardEditor.document
        )
        let previousSelection = model.boardEditor.selectedElementID
        let changed = model.applyBoardAction(
            .createBox(
                frame: frame,
                label: newBoxKind.displayName,
                kind: newBoxKind
            )
        )
        guard BoardKeyboardCreationOutcome.didCreateElement(
            documentChanged: changed,
            previousSelection: previousSelection,
            currentSelection: model.boardEditor.selectedElementID
        ) else {
            return
        }
        model.applyBoardAction(.setTool(.select))
        interactionFeedback = "\(newBoxKind.displayName) node added and selected"
        if let id = model.boardEditor.selectedElementID {
            accessibilityFocusedElementID = id
        }
        isCanvasFocused = true
    }

    private func select(_ id: BoardElementID?) {
        model.applyBoardAction(.select(id))
        accessibilityFocusedElementID = id
    }

    private func selectRelativeElement(forward: Bool) {
        guard !model.isInspectingBoardRevision else { return }
        model.applyBoardAction(forward ? .selectNext : .selectPrevious)
        accessibilityFocusedElementID = model.boardEditor.selectedElementID
        isCanvasFocused = true
    }

    @discardableResult
    private func moveSelection(_ direction: BoardKeyboardDirection) -> Bool {
        guard !model.isInspectingBoardRevision,
              selectedCapabilities?.canMove == true else {
            return false
        }
        guard model.applyBoardAction(
            .moveSelected(by: direction.delta)
        ) else { return false }
        interactionFeedback = "Selection moved \(direction.displayName)"
        accessibilityFocusedElementID = model.boardEditor.selectedElementID
        isCanvasFocused = true
        return true
    }

    @discardableResult
    private func resizeSelection(by delta: BoardPoint) -> Bool {
        guard !model.isInspectingBoardRevision,
              selectedCapabilities?.canResize == true else {
            return false
        }
        guard model.applyBoardAction(
            .resizeSelected(handle: .bottomTrailing, by: delta)
        ) else { return false }
        interactionFeedback = "Selected node resized"
        accessibilityFocusedElementID = model.boardEditor.selectedElementID
        isCanvasFocused = true
        return true
    }

    private var selectedBoardElement: BoardElement? {
        guard let selectedID = model.boardEditor.selectedElementID else {
            return nil
        }
        return model.boardEditor.document.elements.first {
            $0.boardID == selectedID
        }
    }

    private var selectedCapabilities: BoardSelectionCapabilities? {
        selectedBoardElement.map(BoardSelectionCapabilities.init(element:))
    }

    private var boardAccessibilityValue: String {
        let document = model.boardDocumentForPresentation
        let count = document.elements.count
        let selection = model.boardSelectedElementIDForPresentation?.rawValue
            ?? "none"
        return "\(count) elements, \(model.boardEditor.tool.rawValue) tool, \(Int((model.boardEditor.zoom * 100).rounded())) percent zoom, selected \(selection)"
    }

    private func beginEditing(id: BoardElementID, text: String) {
        guard !model.isInspectingBoardRevision else { return }
        editingElementID = id
        editingText = text
        isLabelEditorFocused = true
    }

    private func commitEditing(id: BoardElementID) {
        model.applyBoardAction(.updateLabel(id: id, text: editingText))
        editingElementID = nil
        editingText = ""
        isCanvasFocused = true
    }

    private func cancelEditing() {
        editingElementID = nil
        editingText = ""
        isCanvasFocused = true
    }

    private func boxes(in document: BoardDocument) -> [BoardBox] {
        BoardRenderOrder.elements(in: document).compactMap {
            guard case .box(let value) = $0 else { return nil }
            return value
        }
    }

    private func connectors(in document: BoardDocument) -> [BoardConnector] {
        BoardRenderOrder.elements(in: document).compactMap {
            guard case .connector(let value) = $0 else { return nil }
            return value
        }
    }

    private func labels(in document: BoardDocument) -> [BoardLabel] {
        BoardRenderOrder.elements(in: document).compactMap {
            guard case .label(let value) = $0 else { return nil }
            return value
        }
    }

    private func strokes(in document: BoardDocument) -> [BoardStroke] {
        BoardRenderOrder.elements(in: document).compactMap {
            guard case .stroke(let value) = $0 else { return nil }
            return value
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(BoardPalette.line)
            .frame(width: 1, height: 28)
            .accessibilityHidden(true)
    }

    private func shortcut(for tool: BoardEditorTool) -> KeyEquivalent {
        switch tool {
        case .select: "v"
        case .connector: "c"
        case .box: "b"
        case .label: "t"
        case .pen: "p"
        case .eraser: "e"
        }
    }

    private func hint(for tool: BoardEditorTool) -> String {
        switch tool {
        case .select: "Select, move, relabel, or delete board elements"
        case .connector: "Choose a source box, then a target box"
        case .box: "Click the canvas to add an architecture box"
        case .label: "Click the canvas to add editable text"
        case .pen: "Drag on the canvas to draw a freehand annotation"
        case .eraser: "Drag across a freehand annotation to erase it"
        }
    }

    private func boardColor(_ color: BoardColor) -> Color {
        guard color.hexRGB.count == 6,
              let packed = UInt64(color.hexRGB, radix: 16) else {
            return BoardPalette.navy
        }
        return Color(
            red: Double((packed >> 16) & 0xff) / 255,
            green: Double((packed >> 8) & 0xff) / 255,
            blue: Double(packed & 0xff) / 255
        )
    }

    private func distance(_ first: BoardPoint, _ second: BoardPoint) -> Double {
        hypot(second.x - first.x, second.y - first.y)
    }
}

private extension View {
    @ViewBuilder
    func boardRootAccessibilityActions(
        isReadOnly: Bool,
        addTitle: String,
        add: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else {
            self
                .accessibilityAction(named: Text(addTitle)) { add() }
                .accessibilityAction(named: "Select next board element") {
                    next()
                }
                .accessibilityAction(named: "Select previous board element") {
                    previous()
                }
        }
    }

    func boardElementHint(
        isReadOnly: Bool,
        editable: String
    ) -> some View {
        accessibilityHint(
            isReadOnly ? "Read-only saved board revision" : editable
        )
    }

    @ViewBuilder
    func boardBoxAccessibilityActions(
        isReadOnly: Bool,
        connectorActionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else if let connectorActionTitle {
            self
                .accessibilityAction { action() }
                .accessibilityAction(named: "Select") { action() }
                .accessibilityAction(named: Text(connectorActionTitle)) {
                    action()
                }
        } else {
            self
                .accessibilityAction { action() }
                .accessibilityAction(named: "Select") { action() }
        }
    }

    @ViewBuilder
    func boardSelectAccessibilityAction(
        isReadOnly: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else {
            accessibilityAction(named: "Select") { action() }
        }
    }

    @ViewBuilder
    func boardEditAccessibilityAction(
        isReadOnly: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else {
            accessibilityAction(named: "Edit label") { action() }
        }
    }

    @ViewBuilder
    func boardMoveAccessibilityActions(
        isReadOnly: Bool,
        left: @escaping () -> Void,
        right: @escaping () -> Void,
        up: @escaping () -> Void,
        down: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else {
            self
                .accessibilityAction(named: "Move left") { left() }
                .accessibilityAction(named: "Move right") { right() }
                .accessibilityAction(named: "Move up") { up() }
                .accessibilityAction(named: "Move down") { down() }
        }
    }

    @ViewBuilder
    func boardResizeAccessibilityActions(
        isReadOnly: Bool,
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void
    ) -> some View {
        if isReadOnly {
            self
        } else {
            self
                .accessibilityAction(named: "Increase size") { increase() }
                .accessibilityAction(named: "Decrease size") { decrease() }
        }
    }

    @ViewBuilder
    func boardDeleteAccessibilityAction(
        isReadOnly: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if BoardAccessibilityActionPolicy.exposesDelete(
            isReadOnly: isReadOnly
        ) {
            accessibilityAction(named: "Delete") { action() }
        } else {
            self
        }
    }
}

enum BoardAccessibilityActionPolicy {
    static func exposesDelete(isReadOnly: Bool) -> Bool {
        !isReadOnly
    }
}

enum BoardConnectorBoxActivation: Equatable {
    case selectNormally
    case chooseSource
    case chooseDifferentTarget
    case connect(sourceID: BoardElementID, targetID: BoardElementID)

    static func resolve(
        sourceID: BoardElementID?,
        activatedBoxID: BoardElementID,
        tool: BoardEditorTool
    ) -> Self {
        guard tool == .connector else { return .selectNormally }
        guard let sourceID else { return .chooseSource }
        guard sourceID != activatedBoxID else {
            return .chooseDifferentTarget
        }
        return .connect(sourceID: sourceID, targetID: activatedBoxID)
    }

    var accessibilityActionTitle: String? {
        switch self {
        case .selectNormally:
            nil
        case .chooseSource:
            "Choose as connector source"
        case .chooseDifferentTarget:
            "Keep as connector source"
        case .connect:
            "Connect to this node"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .selectNormally:
            "Select, edit, move, resize, or delete this architecture node"
        case .chooseSource:
            "Choose this node as the connector source, or delete it"
        case .chooseDifferentTarget:
            "This is the connector source; choose a different target node, or delete it"
        case .connect:
            "Use this node as the connector target, or delete it"
        }
    }
}

enum BoardKeyboardActivationKey: Equatable {
    case returnKey
    case space

    init?(key: KeyEquivalent) {
        if key == .return {
            self = .returnKey
        } else if key == .space {
            self = .space
        } else {
            return nil
        }
    }
}

enum BoardKeyboardActivation: Equatable {
    case activateConnectorBox(BoardElementID)
    case editLabel(BoardElementID, String)
    case ignored

    static func resolve(
        key: BoardKeyboardActivationKey,
        tool: BoardEditorTool,
        selectedElement: BoardElement?
    ) -> Self {
        guard let selectedElement else { return .ignored }
        if tool == .connector {
            guard case .box(let box) = selectedElement else { return .ignored }
            return .activateConnectorBox(box.id)
        }
        guard key == .returnKey else { return .ignored }
        switch selectedElement {
        case .box(let box):
            return .editLabel(box.id, box.label)
        case .connector(let connector):
            return .editLabel(connector.id, connector.label)
        case .label(let label):
            return .editLabel(label.id, label.text)
        case .stroke:
            return .ignored
        }
    }
}

enum BoardStrokePointerInteraction {
    static let minimumHitWidth = 44.0

    static func isEnabled(
        tool: BoardEditorTool,
        isReadOnly: Bool
    ) -> Bool {
        tool == .select && !isReadOnly
    }

    static func hitWidth(for visibleWidth: Double) -> Double {
        max(minimumHitWidth, visibleWidth)
    }
}

enum BoardGestureSampling {
    static let minimumEraserDistance = 6.0

    static func shouldAcceptEraserPoint(
        _ point: BoardPoint,
        after previous: BoardPoint?
    ) -> Bool {
        guard let previous else { return true }
        return hypot(point.x - previous.x, point.y - previous.y)
            >= minimumEraserDistance
    }
}

enum BoardLayoutMetrics {
    static let revisionRailHeight: CGFloat = 54
    static let toolRailHeight: CGFloat = 58
    static let sectionLabelHeight: CGFloat = 44
    static let minimumHitTarget: CGFloat = 44
    static let toolControlHeight: CGFloat = minimumHitTarget
    static let emptyStateMaximumWidth: CGFloat = 360
}

enum BoardCanvasVisualMetrics {
    static let gridSpacing: CGFloat = 20
    static let gridDotDiameter: CGFloat = 1.6
    static let gridDotOpacity = 0.22
    static let footerMaximumWidth: CGFloat = 420
}

struct BoardFooterPresentation: Equatable {
    enum Tone: Equatable {
        case neutral
        case confirmation
        case feedback
        case error
    }

    let text: String
    let systemImage: String
    let tone: Tone

    static func make(
        errorMessage: String?,
        exportMessage: String?,
        interactionFeedback: String?
    ) -> Self {
        if let errorMessage {
            return Self(
                text: errorMessage,
                systemImage: "exclamationmark.triangle",
                tone: .error
            )
        }
        if let interactionFeedback {
            return Self(
                text: interactionFeedback,
                systemImage: "info.circle",
                tone: .feedback
            )
        }
        if let exportMessage {
            return Self(
                text: exportMessage,
                systemImage: "checkmark.circle",
                tone: .confirmation
            )
        }
        return Self(
            text: "Editable source autosaves locally",
            systemImage: "internaldrive",
            tone: .neutral
        )
    }
}

enum BoardRailVariant: Equatable {
    case wide
    case compact
}

struct BoardRailWidthResolution: Equatable {
    let variant: BoardRailVariant
    let renderedWidth: CGFloat
}

struct BoardRailSizing: Equatable {
    let requiredWidth: CGFloat
    let expandsToAvailableWidth: Bool

    var maximumWidth: CGFloat? {
        expandsToAvailableWidth ? .infinity : nil
    }

    var fixesHorizontalSize: Bool {
        !expandsToAvailableWidth
    }

    func renderedWidth(in availableWidth: CGFloat) -> CGFloat {
        expandsToAvailableWidth
            ? max(requiredWidth, availableWidth)
            : requiredWidth
    }
}

enum BoardRailWidthBudget {
    static let supportedBoardWidth: CGFloat = 680
    static let compactHorizontalPadding: CGFloat = 8
    static let compactRevisionSpacing: CGFloat = 6
    static let compactToolbarSpacing: CGFloat = 4
    static let compactTabWidth: CGFloat = 64
    static let compactStatusWidth: CGFloat = 132
    static let compactRevisionSpacerWidth: CGFloat = 4
    static let compactZoomWidth: CGFloat = 68
    static let dividerWidth: CGFloat = 1
    static let wideRevisionRequiredWidth: CGFloat = 820
    static let wideToolbarRequiredWidth: CGFloat = 780
    static let wideRevisionGroupGapMinimum: CGFloat = 32
    static let wideToolbarGroupGapMinimum: CGFloat = 12

    static func compactRevisionRequiredWidth(actionCount: Int) -> CGFloat {
        let actions = max(0, actionCount)
        let itemCount = 3 + actions // Board, status, spacer, then actions.
        return compactHorizontalPadding * 2
            + compactTabWidth
            + compactStatusWidth
            + compactRevisionSpacerWidth
            + CGFloat(actions) * BoardLayoutMetrics.minimumHitTarget
            + CGFloat(max(0, itemCount - 1)) * compactRevisionSpacing
    }

    static var compactToolbarRequiredWidth: CGFloat {
        let iconControlCount = 8
        let dividerCount = 3
        let itemCount = iconControlCount + dividerCount + 1 // Zoom.
        return compactHorizontalPadding * 2
            + CGFloat(iconControlCount) * BoardLayoutMetrics.minimumHitTarget
            + CGFloat(dividerCount) * dividerWidth
            + compactZoomWidth
            + CGFloat(itemCount - 1) * compactToolbarSpacing
    }

    static func revisionSizing(
        compact: Bool,
        actionCount: Int
    ) -> BoardRailSizing {
        BoardRailSizing(
            requiredWidth: compact
                ? compactRevisionRequiredWidth(actionCount: actionCount)
                : wideRevisionRequiredWidth,
            expandsToAvailableWidth: !compact
        )
    }

    static func toolbarSizing(compact: Bool) -> BoardRailSizing {
        BoardRailSizing(
            requiredWidth: compact
                ? compactToolbarRequiredWidth
                : wideToolbarRequiredWidth,
            expandsToAvailableWidth: !compact
        )
    }

    static func revisionResolution(
        availableWidth: CGFloat,
        actionCount: Int
    ) -> BoardRailWidthResolution {
        resolution(
            availableWidth: availableWidth,
            wide: revisionSizing(compact: false, actionCount: actionCount),
            compact: revisionSizing(compact: true, actionCount: actionCount)
        )
    }

    static func toolbarResolution(
        availableWidth: CGFloat
    ) -> BoardRailWidthResolution {
        resolution(
            availableWidth: availableWidth,
            wide: toolbarSizing(compact: false),
            compact: toolbarSizing(compact: true)
        )
    }

    private static func resolution(
        availableWidth: CGFloat,
        wide: BoardRailSizing,
        compact: BoardRailSizing
    ) -> BoardRailWidthResolution {
        if availableWidth >= wide.requiredWidth {
            return BoardRailWidthResolution(
                variant: .wide,
                renderedWidth: wide.renderedWidth(in: availableWidth)
            )
        }
        return BoardRailWidthResolution(
            variant: .compact,
            renderedWidth: compact.renderedWidth(in: availableWidth)
        )
    }
}

enum BoardRailPresentation {
    static func compactRevisionStatus(
        _ status: BoardRevisionStatusPresentation
    ) -> String {
        status.compactText
    }
}

enum BoardRevisionHistoryPresentation {
    static let recentLimit = 5

    static func recent(_ revisions: [BoardRevision]) -> [BoardRevision] {
        Array(revisions.suffix(recentLimit).reversed())
    }

    static func all(_ revisions: [BoardRevision]) -> [BoardRevision] {
        Array(revisions.reversed())
    }

    static func hasMore(_ revisions: [BoardRevision]) -> Bool {
        revisions.count > recentLimit
    }
}

enum BoardPalette {
    static let paper = Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
    static let toolbar = Color(red: 248 / 255, green: 248 / 255, blue: 252 / 255)
    static let canvas = Color(red: 250 / 255, green: 251 / 255, blue: 254 / 255)
    static let ink = Color(red: 14 / 255, green: 17 / 255, blue: 30 / 255)
    static let navy = Color(red: 24 / 255, green: 35 / 255, blue: 89 / 255)
    static let violet = Color(red: 75 / 255, green: 58 / 255, blue: 191 / 255)
    static let orange = Color(red: 237 / 255, green: 78 / 255, blue: 47 / 255)
    static let errorText = Color(red: 169 / 255, green: 54 / 255, blue: 30 / 255)
    static let muted = Color(red: 82 / 255, green: 98 / 255, blue: 139 / 255)
    static let line = Color(red: 224 / 255, green: 226 / 255, blue: 237 / 255)
}

private struct BoardNodeVisualLayer: View {
    let visual: BoardNodeVisual
    let fill: Color
    let stroke: Color
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let outline = Path(visual.outlinePath(in: rect).cgPath)
            let strokeWidth = visual.strokeWidth(in: rect)
            context.fill(outline, with: .color(fill))
            context.stroke(
                outline,
                with: .color(stroke),
                style: StrokeStyle(
                    lineWidth: visual.strokeWidth(
                        in: rect,
                        isSelected: isSelected
                    ),
                    lineJoin: .round
                )
            )
            for vector in visual.detailPaths(in: rect) + visual.pictogramPaths(in: rect) {
                context.stroke(
                    Path(vector.cgPath),
                    with: .color(stroke),
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }
}

private struct BoardDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let diameter = BoardCanvasVisualMetrics.gridDotDiameter
            let offset = diameter / 2
            for x in stride(
                from: BoardCanvasVisualMetrics.gridSpacing / 2,
                through: size.width,
                by: BoardCanvasVisualMetrics.gridSpacing
            ) {
                for y in stride(
                    from: BoardCanvasVisualMetrics.gridSpacing / 2,
                    through: size.height,
                    by: BoardCanvasVisualMetrics.gridSpacing
                ) {
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: x - offset,
                                y: y - offset,
                                width: diameter,
                                height: diameter
                            )
                        ),
                        with: .color(
                            BoardPalette.violet.opacity(
                                BoardCanvasVisualMetrics.gridDotOpacity
                            )
                        )
                    )
                }
            }
        }
        .background(BoardPalette.canvas)
        .accessibilityHidden(true)
    }
}

private struct BoardConnectorPath: View {
    let start: BoardPoint
    let end: BoardPoint
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let route = BoardOrthogonalConnectorRoute(start: start, end: end)
            guard let first = route.points.first,
                  let last = route.points.last else {
                return
            }
            var line = Path()
            line.move(to: CGPoint(x: first.x, y: first.y))
            for point in route.points.dropFirst() {
                line.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: 1.7,
                    lineCap: .round,
                    lineJoin: .round
                )
            )

            let arrowStart = route.points.dropLast().last ?? first
            let angle = atan2(last.y - arrowStart.y, last.x - arrowStart.x)
            let length = 10.0
            let wing = 0.5
            var arrow = Path()
            arrow.move(to: CGPoint(x: last.x, y: last.y))
            arrow.addLine(
                to: CGPoint(
                    x: last.x - length * cos(angle - wing),
                    y: last.y - length * sin(angle - wing)
                )
            )
            arrow.addLine(
                to: CGPoint(
                    x: last.x - length * cos(angle + wing),
                    y: last.y - length * sin(angle + wing)
                )
            )
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BoardStrokePath: View {
    let points: [BoardPoint]
    let color: Color
    let width: Double

    var body: some View {
        Canvas { context, _ in
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: width,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .allowsHitTesting(false)
    }
}

private struct BoardStrokeHitTarget: View {
    let points: [BoardPoint]
    let width: Double

    var body: some View {
        BoardStrokeHitShape(points: points, width: width)
            .fill(Color.clear)
            .contentShape(BoardStrokeHitShape(points: points, width: width))
    }
}

private struct BoardStrokeHitShape: Shape {
    let points: [BoardPoint]
    let width: Double

    func path(in rect: CGRect) -> Path {
        guard let first = points.first else { return Path() }
        guard points.count > 1 else {
            return Path(
                ellipseIn: CGRect(
                    x: first.x - width / 2,
                    y: first.y - width / 2,
                    width: width,
                    height: width
                )
            )
        }
        var line = Path()
        line.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() {
            line.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        return line.strokedPath(
            StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}

private extension BoardResizeHandle {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var displayName: String {
        switch self {
        case .topLeading: "top-left"
        case .topTrailing: "top-right"
        case .bottomLeading: "bottom-left"
        case .bottomTrailing: "bottom-right"
        }
    }
}

enum BoardKeyboardDirection: Equatable {
    case left
    case right
    case up
    case down

    init?(key: KeyEquivalent) {
        if key == .leftArrow {
            self = .left
        } else if key == .rightArrow {
            self = .right
        } else if key == .upArrow {
            self = .up
        } else if key == .downArrow {
            self = .down
        } else {
            return nil
        }
    }

    var delta: BoardPoint {
        switch self {
        case .left: BoardPoint(x: -10, y: 0)
        case .right: BoardPoint(x: 10, y: 0)
        case .up: BoardPoint(x: 0, y: -10)
        case .down: BoardPoint(x: 0, y: 10)
        }
    }

    var displayName: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }
}

enum BoardKeyboardCreationOutcome {
    static func didCreateElement(
        documentChanged: Bool,
        previousSelection: BoardElementID?,
        currentSelection: BoardElementID?
    ) -> Bool {
        documentChanged
            && currentSelection != nil
            && currentSelection != previousSelection
    }
}

enum BoardNodeCreationDefaults {
    static let defaultSize = BoardSize(width: 120, height: 112)

    static func fittedSize(in canvas: BoardSize) -> BoardSize {
        BoardSize(
            width: min(defaultSize.width, canvas.width),
            height: min(defaultSize.height, canvas.height)
        )
    }

    static func frame(
        centeredAt point: BoardPoint,
        in canvas: BoardSize
    ) -> BoardRect {
        let size = fittedSize(in: canvas)
        return BoardRect(
            origin: BoardPoint(
                x: max(
                    0,
                    min(point.x - size.width / 2, canvas.width - size.width)
                ),
                y: max(
                    0,
                    min(point.y - size.height / 2, canvas.height - size.height)
                )
            ),
            size: size
        )
    }
}

enum BoardKeyboardPlacement {
    static func nextBoxFrame(in document: BoardDocument) -> BoardRect {
        let canvas = document.canvas.size
        let size = BoardNodeCreationDefaults.fittedSize(in: canvas)
        let width = size.width
        let height = size.height
        let horizontalMargin = min(40, max(0, (canvas.width - width) / 2))
        let verticalMargin = min(40, max(0, (canvas.height - height) / 2))
        let horizontalStep = width + 24
        let verticalStep = height + 24
        let usableWidth = max(width, canvas.width - horizontalMargin * 2)
        let columns = max(1, Int((usableWidth + 24) / horizontalStep))
        let boxCount = document.elements.reduce(into: 0) { count, element in
            if case .box = element { count += 1 }
        }
        let column = boxCount % columns
        let row = boxCount / columns
        let x = min(
            max(0, canvas.width - width),
            horizontalMargin + Double(column) * horizontalStep
        )
        let y = min(
            max(0, canvas.height - height),
            verticalMargin + Double(row) * verticalStep
        )
        return BoardRect(
            origin: BoardPoint(x: x, y: y),
            size: BoardSize(width: width, height: height)
        )
    }
}
