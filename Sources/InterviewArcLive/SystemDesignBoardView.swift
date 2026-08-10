import InterviewArcLiveCore
import SwiftUI

struct SystemDesignBoardView: View {
    @ObservedObject var model: SystemDesignRoomModel

    @State private var connectorSourceID: BoardElementID?
    @State private var activePenPoints: [BoardPoint] = []
    @State private var newBoxKind: BoardNodeKind = .service
    @State private var editingElementID: BoardElementID?
    @State private var editingText = ""
    @FocusState private var isCanvasFocused: Bool
    @FocusState private var isLabelEditorFocused: Bool

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
                model.applyBoardAction(.select(nil))
                model.applyBoardAction(.setTool(.select))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System design board")
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
        .frame(minHeight: 54)
        .background(BoardPalette.paper)
    }

    private func tab(_ title: String, isSelected: Bool) -> some View {
        Button(title) {}
            .buttonStyle(.plain)
            .font(.system(.body, design: .rounded, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? BoardPalette.ink : BoardPalette.muted)
            .disabled(!isSelected)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(BoardPalette.violet)
                        .frame(height: 3)
                }
            }
            .accessibilityValue(isSelected ? "Selected" : "Unavailable in this slice")
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
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.boardEditor.canUndo || model.isInspectingBoardRevision)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityHint("Reverses the last board edit")

                Button {
                    model.applyBoardAction(.redo)
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
            .frame(minHeight: 58)
        }
        .scrollIndicators(.hidden)
        .background(BoardPalette.paper)
    }

    private var boxToolMenu: some View {
        Menu {
            ForEach(BoardNodeKind.selectableKinds, id: \.rawValue) { kind in
                Button {
                    newBoxKind = kind
                    connectorSourceID = nil
                    model.applyBoardAction(.setTool(.box))
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
                .frame(minHeight: 38)
                .background(
                    model.boardEditor.tool == .box
                        ? BoardPalette.violet.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .keyboardShortcut("b", modifiers: .control)
        .disabled(model.isInspectingBoardRevision)
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
            isCanvasFocused = true
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(
                    model.boardEditor.tool == tool
                        ? BoardPalette.violet.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
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
                            .position(
                                x: document.canvas.size.width / 2,
                                y: document.canvas.size.height / 2
                            )
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
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(BoardPalette.violet)
            Text("Build the architecture here")
                .font(.system(.headline, design: .rounded))
            Text("Choose Box, Text, Connector, or Pen. Save a revision before Hand off.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(BoardPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
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
            model.boardErrorMessage == nil ? BoardPalette.muted : BoardPalette.orange
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(BoardPalette.paper.opacity(0.94))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board status")
        .accessibilityValue(boardStatusText)
    }

    private var boardStatusText: String {
        model.boardErrorMessage
            ?? model.boardExportMessage
            ?? model.boardRevisionStatus
    }

    private func boxLayer(_ document: BoardDocument) -> some View {
        ForEach(boxes(in: document), id: \.id) { box in
            let selected = model.boardEditor.selectedElementID == box.id
                && !model.isInspectingBoardRevision
            VStack(spacing: 7) {
                Text(box.kind.glyphToken)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 40, height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(boardColor(box.stroke), lineWidth: 1.5)
                    }
                    .accessibilityLabel("\(box.kind.rawValue) node")
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
            .foregroundStyle(boardColor(box.stroke))
            .frame(width: box.frame.size.width, height: box.frame.size.height)
            .background(
                boardColor(box.fill),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        selected ? BoardPalette.violet : boardColor(box.stroke),
                        lineWidth: selected ? 2 : 1.5
                    )
            }
            .overlay { selectionHandles(isVisible: selected) }
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
                        model.applyBoardAction(.select(box.id))
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Architecture box: \(box.label.isEmpty ? "Untitled" : box.label)")
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityHint("Press to select. Double-click to edit the label. Drag to move in Select mode.")
            .accessibilityAction(named: "Select") {
                model.applyBoardAction(.select(box.id))
            }
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
                            model.applyBoardAction(.select(connector.id))
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
                .accessibilityHint("Selects this connector so it can be labeled or deleted")
            }
        }
    }

    private func strokeLayer(_ document: BoardDocument) -> some View {
        ForEach(strokes(in: document), id: \.id) { stroke in
            BoardStrokePath(
                points: stroke.points,
                color: boardColor(stroke.color),
                width: stroke.width
            )
            .accessibilityElement()
            .accessibilityLabel("Freehand board annotation")
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
                model.applyBoardAction(.select(label.id))
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onEnded { value in
                        guard model.boardEditor.tool == .select,
                              !model.isInspectingBoardRevision else { return }
                        model.applyBoardAction(.select(label.id))
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
            .accessibilityHint("Press to select. Double-click to edit. Drag to move in Select mode.")
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
                    model.applyBoardAction(.eraseStroke(at: point, radius: 12))
                default:
                    break
                }
            }
            .onEnded { value in
                guard !model.isInspectingBoardRevision else { return }
                let point = BoardPoint(x: value.location.x, y: value.location.y)
                switch model.boardEditor.tool {
                case .select:
                    model.applyBoardAction(.select(nil))
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
                    if let id = model.boardEditor.selectedElementID {
                        beginEditing(id: id, text: newBoxKind.displayName)
                    }
                case .label:
                    model.applyBoardAction(.createLabel(origin: point, text: "Label"))
                    if let id = model.boardEditor.selectedElementID {
                        beginEditing(id: id, text: "Label")
                    }
                case .pen:
                    if activePenPoints.count >= 2 {
                        model.applyBoardAction(.addStroke(points: activePenPoints))
                    }
                    activePenPoints = []
                case .eraser:
                    model.applyBoardAction(.eraseStroke(at: point, radius: 12))
                case .connector:
                    connectorSourceID = nil
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
            } else {
                connectorSourceID = box.id
                model.applyBoardAction(.select(box.id))
            }
        } else {
            model.applyBoardAction(.select(box.id))
        }
        isCanvasFocused = true
    }

    @ViewBuilder
    private func selectionHandles(isVisible: Bool) -> some View {
        if isVisible {
            ZStack {
                ForEach(SelectionCorner.allCases, id: \.self) { corner in
                    Rectangle()
                        .fill(BoardPalette.violet)
                        .frame(width: 7, height: 7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                }
            }
            .padding(-4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func beginEditing(id: BoardElementID, text: String) {
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

enum BoardPalette {
    static let paper = Color(red: 252 / 255, green: 252 / 255, blue: 254 / 255)
    static let canvas = Color(red: 250 / 255, green: 251 / 255, blue: 254 / 255)
    static let ink = Color(red: 14 / 255, green: 17 / 255, blue: 30 / 255)
    static let navy = Color(red: 24 / 255, green: 35 / 255, blue: 89 / 255)
    static let violet = Color(red: 75 / 255, green: 58 / 255, blue: 191 / 255)
    static let orange = Color(red: 237 / 255, green: 78 / 255, blue: 47 / 255)
    static let muted = Color(red: 82 / 255, green: 98 / 255, blue: 139 / 255)
    static let line = Color(red: 224 / 255, green: 226 / 255, blue: 237 / 255)
}

private struct BoardDotGrid: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: 10.0, through: size.width, by: 20) {
                for y in stride(from: 10.0, through: size.height, by: 20) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)),
                        with: .color(BoardPalette.line.opacity(0.78))
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
            var line = Path()
            line.move(to: CGPoint(x: start.x, y: start.y))
            line.addLine(to: CGPoint(x: end.x, y: end.y))
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )

            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = 10.0
            let wing = 0.5
            var arrow = Path()
            arrow.move(to: CGPoint(x: end.x, y: end.y))
            arrow.addLine(
                to: CGPoint(
                    x: end.x - length * cos(angle - wing),
                    y: end.y - length * sin(angle - wing)
                )
            )
            arrow.addLine(
                to: CGPoint(
                    x: end.x - length * cos(angle + wing),
                    y: end.y - length * sin(angle + wing)
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

private enum SelectionCorner: CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
