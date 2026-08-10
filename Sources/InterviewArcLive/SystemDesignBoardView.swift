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
        HStack(spacing: 18) {
            HStack(spacing: 30) {
                tab("Board", isSelected: true)
                tab("Brief", isSelected: false)
                tab("Notes", isSelected: false)
            }

            Spacer(minLength: 12)

            if model.isInspectingBoardRevision {
                Button("Return to draft") {
                    Task { await model.returnToBoardDraft() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(BoardPalette.violet)
                .accessibilityHint("Closes the immutable revision without changing the editable draft")
            } else if model.isBoardDraftDirty {
                Button {
                    Task { await model.saveBoardRevision() }
                } label: {
                    Label("Save revision", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BoardPalette.violet)
                .disabled(!model.canSaveBoardRevision)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityHint("Creates one immutable board revision")
            } else {
                Label(model.boardRevisionStatus, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(BoardPalette.muted)
                    .accessibilityElement(children: .combine)
            }

            if let snapshot = model.snapshot, !snapshot.board.revisions.isEmpty {
                Menu {
                    ForEach(snapshot.board.revisions, id: \.id) { revision in
                        Button("Revision \(revision.ordinal + 1)") {
                            Task { await model.inspectBoardRevision(revision.id) }
                        }
                    }
                } label: {
                    Label("Revisions", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityHint("Opens an immutable saved board for inspection")
            }

            railDivider

            Button("Attach revision") {
                Task { await model.attachSelectedBoardRevision() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(BoardPalette.navy)
            .disabled(!model.canAttachBoardRevision)
            .accessibilityHint("Attaches the selected immutable revision to the latest unattached answer")

            Button {
                Task { await model.exportSelectedBoardRevision() }
            } label: {
                if model.isBoardExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting board revision")
                } else {
                    Text("Export")
                }
            }
            .buttonStyle(.bordered)
            .tint(BoardPalette.violet)
            .disabled(!model.canExportBoardRevision || model.isBoardExporting)
            .accessibilityHint("Exports Draw.io source, SVG, and PNG as one private bundle")
        }
        .font(.system(.callout, design: .rounded))
        .padding(.horizontal, 20)
        .frame(minHeight: BoardLayoutMetrics.revisionRailHeight)
        .background(BoardPalette.paper)
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
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                toolButton(.select, title: "Select", icon: "cursorarrow")
                toolButton(
                    .connector,
                    title: connectorSourceID == nil ? "Connector" : "Choose target",
                    icon: "point.3.connected.trianglepath.dotted"
                )
                boxToolMenu
                toolButton(.label, title: "Text", icon: "textformat")
                railDivider
                toolButton(.pen, title: "Pen", icon: "pencil.tip")
                toolButton(.eraser, title: "Eraser", icon: "eraser")
                railDivider
                Button {
                    model.applyBoardAction(.undo)
                    interactionFeedback = "Undid the last board edit"
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.boardEditor.canUndo || model.isInspectingBoardRevision)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityHint("Reverses the last board edit")

                Button {
                    model.applyBoardAction(.redo)
                    interactionFeedback = "Restored the last board edit"
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.boardEditor.canRedo || model.isInspectingBoardRevision)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .accessibilityHint("Restores the last undone board edit")

                railDivider

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
                    HStack(spacing: 5) {
                        Text("\(Int((model.boardEditor.zoom * 100).rounded()))%")
                        Image(systemName: "chevron.down")
                    }
                    .frame(minHeight: 32)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Board zoom")
                .accessibilityValue("\(Int((model.boardEditor.zoom * 100).rounded())) percent")
            }
            .buttonStyle(.plain)
            .font(.system(.callout, design: .rounded))
            .padding(.horizontal, 20)
            .frame(minHeight: BoardLayoutMetrics.toolRailHeight)
        }
        .scrollIndicators(.hidden)
        .background(BoardPalette.toolbar)
    }

    private var boxToolMenu: some View {
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
                    if newBoxKind == kind {
                        Label(kind.displayName, systemImage: "checkmark")
                    } else {
                        Text(kind.displayName)
                    }
                }
            }
        } label: {
            Label("Box", systemImage: "square")
                .padding(.horizontal, 10)
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
    }

    private func toolButton(
        _ tool: BoardEditorTool,
        title: String,
        icon: String
    ) -> some View {
        Button {
            connectorSourceID = nil
            model.applyBoardAction(.setTool(tool))
            interactionFeedback = "\(title) tool active"
            isCanvasFocused = true
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 10)
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
                keys: [.tab, .return, .leftArrow, .rightArrow, .upArrow, .downArrow, "b"],
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
        HStack(spacing: 7) {
            Image(
                systemName: model.boardErrorMessage == nil
                    ? "checkmark.circle"
                    : "exclamationmark.triangle"
            )
            Text(boardStatusText)
                .lineLimit(2)
            Spacer()
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(
            model.boardErrorMessage == nil ? BoardPalette.muted : BoardPalette.errorText
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(BoardPalette.paper.opacity(0.94))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board status")
        .accessibilityValue(boardStatusText)
    }

    private var boardStatusText: String {
        if let boardErrorMessage = model.boardErrorMessage {
            return boardErrorMessage
        }
        if let boardExportMessage = model.boardExportMessage {
            return boardExportMessage
        }
        if let interactionFeedback {
            return "\(interactionFeedback) · \(model.boardRevisionStatus)"
        }
        return model.boardRevisionStatus
    }

    private func boxLayer(_ document: BoardDocument) -> some View {
        ForEach(boxes(in: document), id: \.id) { box in
            let selected = model.boardEditor.selectedElementID == box.id
                && !model.isInspectingBoardRevision
            let visual = box.kind.visual
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

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if editingElementID == box.id {
                        TextField("Box label", text: $editingText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .focused($isLabelEditorFocused)
                            .onSubmit { commitEditing(id: box.id) }
                    } else {
                        Text(box.label.isEmpty ? "Box" : box.label)
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
                .frame(maxHeight: .infinity, alignment: .bottom)
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
                editable: "Select, edit, move, or resize this architecture node"
            )
            .accessibilityFocused($accessibilityFocusedElementID, equals: box.id)
            .boardSelectAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
            ) {
                select(box.id)
            }
            .boardEditAccessibilityAction(
                isReadOnly: model.isInspectingBoardRevision
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
        }
    }

    private func connectorLayer(_ document: BoardDocument) -> some View {
        ForEach(connectors(in: document), id: \.id) { connector in
            let selected = model.boardEditor.selectedElementID == connector.id
                && !model.isInspectingBoardRevision
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
                    editable: "Selects this connector so it can be labeled or deleted"
                )
                .accessibilityFocused($accessibilityFocusedElementID, equals: connector.id)
                .boardEditAccessibilityAction(
                    isReadOnly: model.isInspectingBoardRevision
                ) {
                    select(connector.id)
                    beginEditing(id: connector.id, text: connector.label)
                }
                .boardMoveAccessibilityActions(
                    isReadOnly: model.isInspectingBoardRevision,
                    left: { select(connector.id); moveSelection(.left) },
                    right: { select(connector.id); moveSelection(.right) },
                    up: { select(connector.id); moveSelection(.up) },
                    down: { select(connector.id); moveSelection(.down) }
                )
            }
        }
    }

    private func strokeLayer(_ document: BoardDocument) -> some View {
        ForEach(strokes(in: document), id: \.id) { stroke in
            let selected = model.boardEditor.selectedElementID == stroke.id
                && !model.isInspectingBoardRevision
            BoardStrokePath(
                points: stroke.points,
                color: selected
                    ? BoardPalette.violet
                    : boardColor(stroke.color),
                width: selected ? stroke.width + 1 : stroke.width
            )
            .accessibilityElement()
            .accessibilityLabel("Freehand board annotation")
            .accessibilityValue(selected ? "Selected" : "")
            .boardElementHint(
                isReadOnly: model.isInspectingBoardRevision,
                editable: "Select or move this freehand annotation"
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
            .frame(minWidth: 80, minHeight: 34, alignment: .leading)
            .position(x: label.origin.x + 80, y: label.origin.y + 17)
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
                editable: "Select, edit, or move this board text"
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
                    let origin = BoardPoint(
                        x: max(0, min(point.x - 80, model.boardEditor.document.canvas.size.width - 160)),
                        y: max(0, min(point.y - 45, model.boardEditor.document.canvas.size.height - 90))
                    )
                    model.applyBoardAction(
                        .createBox(
                            frame: BoardRect(
                                origin: origin,
                                size: BoardSize(width: 160, height: 90)
                            ),
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
                    model.applyBoardAction(.createLabel(origin: point, text: "Label"))
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
        if model.boardEditor.tool == .connector {
            if let sourceID = connectorSourceID, sourceID != box.id {
                model.applyBoardAction(
                    .connect(
                        sourceBoxID: sourceID,
                        targetBoxID: box.id,
                        label: ""
                    )
                )
                connectorSourceID = nil
                model.applyBoardAction(.setTool(.select))
                interactionFeedback = "Connector added and selected"
            } else {
                connectorSourceID = box.id
                select(box.id)
                interactionFeedback = "Source selected · choose a target node"
            }
        } else {
            select(box.id)
            interactionFeedback = "\(box.label.isEmpty ? box.kind.displayName : box.label) selected"
        }
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
        if press.key == .return {
            guard let editable = editableSelection else { return .ignored }
            beginEditing(id: editable.id, text: editable.text)
            return .handled
        }
        guard let direction = BoardKeyboardDirection(key: press.key) else {
            return .ignored
        }
        if press.modifiers.contains(.shift) {
            resizeSelection(by: direction.delta)
        } else {
            moveSelection(direction)
        }
        return .handled
    }

    private func addBoxFromKeyboard() {
        guard !model.isInspectingBoardRevision else { return }
        let frame = BoardKeyboardPlacement.nextBoxFrame(
            in: model.boardEditor.document
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

    private func moveSelection(_ direction: BoardKeyboardDirection) {
        guard !model.isInspectingBoardRevision else { return }
        model.applyBoardAction(.moveSelected(by: direction.delta))
        interactionFeedback = "Selection moved \(direction.displayName)"
        accessibilityFocusedElementID = model.boardEditor.selectedElementID
        isCanvasFocused = true
    }

    private func resizeSelection(by delta: BoardPoint) {
        guard !model.isInspectingBoardRevision else { return }
        model.applyBoardAction(
            .resizeSelected(handle: .bottomTrailing, by: delta)
        )
        interactionFeedback = "Selected node resized"
        accessibilityFocusedElementID = model.boardEditor.selectedElementID
        isCanvasFocused = true
    }

    private var editableSelection: (id: BoardElementID, text: String)? {
        guard let selectedID = model.boardEditor.selectedElementID,
              let element = model.boardEditor.document.elements.first(where: {
                  $0.boardID == selectedID
              }) else {
            return nil
        }
        switch element {
        case .box(let box): return (box.id, box.label)
        case .connector(let connector): return (connector.id, connector.label)
        case .label(let label): return (label.id, label.text)
        case .stroke: return nil
        }
    }

    private var boardAccessibilityValue: String {
        let count = model.boardDocumentForPresentation.elements.count
        let selection = model.boardEditor.selectedElementID?.rawValue ?? "none"
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
        document.elements.compactMap {
            guard case .box(let value) = $0 else { return nil }
            return value
        }
    }

    private func connectors(in document: BoardDocument) -> [BoardConnector] {
        document.elements.compactMap {
            guard case .connector(let value) = $0 else { return nil }
            return value
        }
    }

    private func labels(in document: BoardDocument) -> [BoardLabel] {
        document.elements.compactMap {
            guard case .label(let value) = $0 else { return nil }
            return value
        }
    }

    private func strokes(in document: BoardDocument) -> [BoardStroke] {
        document.elements.compactMap {
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
    static let toolControlHeight: CGFloat = 38
    static let emptyStateMaximumWidth: CGFloat = 360
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
            context.fill(outline, with: .color(fill))
            context.stroke(
                outline,
                with: .color(stroke),
                style: StrokeStyle(
                    lineWidth: isSelected ? 2 : 1.5,
                    lineJoin: .round
                )
            )
            for vector in visual.detailPaths(in: rect) + visual.pictogramPaths(in: rect) {
                context.stroke(
                    Path(vector.cgPath),
                    with: .color(stroke),
                    style: StrokeStyle(
                        lineWidth: 1.5,
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
            for x in stride(from: 10.0, through: size.width, by: 20) {
                for y in stride(from: 10.0, through: size.height, by: 20) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(BoardPalette.line.opacity(0.9))
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

enum BoardKeyboardPlacement {
    static func nextBoxFrame(in document: BoardDocument) -> BoardRect {
        let canvas = document.canvas.size
        let width = min(160, canvas.width)
        let height = min(90, canvas.height)
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
