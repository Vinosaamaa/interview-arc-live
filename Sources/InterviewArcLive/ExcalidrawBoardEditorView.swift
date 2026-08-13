import AppKit
import Foundation
import InterviewArcLiveCore
import SwiftUI
import WebKit

enum ExcalidrawBoardCommand: Equatable, Sendable {
    case undo
    case redo
    case saveRevision
    case zoomIn
    case zoomOut
    case zoomReset
    case showRevisions
    case returnToDraft
    case attachRevision
    case exportRevision
    case tool(BoardEditorTool)
}

enum ExcalidrawBoardWebSecurity {
    static let scheme = "interviewarc-board"
    static let contentRuleIdentifier = "InterviewArcBoardOfflineOnly-v3"
    static let contentRuleJSON = """
    [
      {
        "trigger": { "url-filter": "^https?://.*" },
        "action": { "type": "block" }
      }
    ]
    """

    static func permitsNavigation(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == Self.scheme || scheme == "about"
    }
}

enum ExcalidrawBoardStartupPolicy {
    static let readyTimeout: Duration = .seconds(8)
}

enum ExcalidrawBoardViewportPolicy {
    static func resolvedSize(
        current: NSSize,
        proposed: NSSize,
        isSettlingReparent: Bool = false
    ) -> NSSize {
        let hasUsableCurrentViewport = current.width > 0 && current.height > 0
        let proposedViewportIsEmpty = proposed.width <= 0 || proposed.height <= 0
        guard hasUsableCurrentViewport else { return proposed }
        if proposedViewportIsEmpty { return current }
        if isSettlingReparent,
           abs(proposed.width / current.width - 2) < 0.01,
           abs(proposed.height / current.height - 2) < 0.01 {
            return current
        }
        return proposed
    }
}

enum ExcalidrawBoardDiagnostics {
    static let environmentKey = "INTERVIEW_ARC_BOARD_DIAGNOSTICS_PATH"

    private static var logURL: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var isEnabled: Bool { logURL != nil }

    @MainActor
    static func record(
        kind: String,
        fields: [String: Any] = [:]
    ) {
        guard let logURL else { return }
        var payload = fields
        payload["kind"] = kind
        payload["uptimeNanoseconds"] = DispatchTime.now().uptimeNanoseconds
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let newline = "\n".data(using: .utf8) else { return }
        let data = json + newline
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            return
        }
    }
}

@MainActor
private final class ExcalidrawBoardWebView: WKWebView {
    override func setFrameSize(_ newSize: NSSize) {
        ExcalidrawBoardDiagnostics.record(
            kind: "native-frame",
            fields: [
                "currentWidth": frame.width,
                "currentHeight": frame.height,
                "proposedWidth": newSize.width,
                "proposedHeight": newSize.height,
                "resolvedWidth": newSize.width,
                "resolvedHeight": newSize.height,
                "hasSuperview": superview != nil,
                "hasWindow": window != nil,
            ]
        )
        super.setFrameSize(newSize)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        ExcalidrawBoardDiagnostics.record(
            kind: "native-superview",
            fields: [
                "width": frame.width,
                "height": frame.height,
                "hasSuperview": superview != nil,
                "superviewIdentity": superview.map {
                    String(describing: ObjectIdentifier($0))
                } ?? "none",
                "hasWindow": window != nil,
            ]
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ExcalidrawBoardDiagnostics.record(
            kind: "native-window",
            fields: [
                "width": frame.width,
                "height": frame.height,
                "hasSuperview": superview != nil,
                "hasWindow": window != nil,
            ]
        )
    }
}

@MainActor
final class ExcalidrawBoardHostView: NSView {
    let hostID = UUID()
    var onAttachToWindow: ((ExcalidrawBoardHostView) -> Void)?
    var onStableViewport: ((NSSize) -> Void)?

    private weak var hostedWebView: WKWebView?
    private var stableViewportSize = NSSize.zero
    private var isSettlingReparent = false

    func host(webView: WKWebView, stableViewportSize: NSSize) {
        if webView.superview !== self {
            webView.removeFromSuperview()
            addSubview(webView)
        }
        hostedWebView = webView
        self.stableViewportSize = stableViewportSize
        isSettlingReparent = stableViewportSize.width > 0
            && stableViewportSize.height > 0
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSettlingReparent = false
            self.needsLayout = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ExcalidrawBoardDiagnostics.record(
            kind: "native-host-window",
            fields: [
                "hostID": hostID.uuidString,
                "hasWindow": window != nil,
                "width": bounds.width,
                "height": bounds.height,
            ]
        )
        if window != nil { onAttachToWindow?(self) }
    }

    override func layout() {
        super.layout()
        guard let hostedWebView else { return }
        let proposed = bounds.size
        let current = stableViewportSize.width > 0
            && stableViewportSize.height > 0
            ? stableViewportSize
            : hostedWebView.frame.size
        let resolved = ExcalidrawBoardViewportPolicy.resolvedSize(
            current: current,
            proposed: proposed,
            isSettlingReparent: isSettlingReparent
        )
        hostedWebView.frame = NSRect(origin: .zero, size: resolved)
        ExcalidrawBoardDiagnostics.record(
            kind: "native-host-layout",
            fields: [
                "hostID": hostID.uuidString,
                "proposedWidth": proposed.width,
                "proposedHeight": proposed.height,
                "resolvedWidth": resolved.width,
                "resolvedHeight": resolved.height,
                "isSettlingReparent": isSettlingReparent,
            ]
        )
        if proposed.width > 0,
           proposed.height > 0,
           resolved == proposed {
            stableViewportSize = proposed
            onStableViewport?(proposed)
        }
    }
}

@MainActor
protocol ExcalidrawBoardSceneFlushing: AnyObject {
    func flushPendingScene(
        completion: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
final class ExcalidrawBoardBridgeController: ObservableObject {
    private weak var flusher: (any ExcalidrawBoardSceneFlushing)?
    private var editorCoordinator: ExcalidrawBoardEditorView.Coordinator?

    func attach(_ flusher: any ExcalidrawBoardSceneFlushing) {
        self.flusher = flusher
    }

    func detach(_ flusher: any ExcalidrawBoardSceneFlushing) {
        guard self.flusher === flusher else { return }
        self.flusher = nil
    }

    func flushPendingScene() async -> Bool {
        guard let flusher else { return true }
        return await withCheckedContinuation { continuation in
            flusher.flushPendingScene { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }

    func performAfterFlushing(_ operation: @escaping @MainActor () -> Void) {
        guard let flusher else {
            operation()
            return
        }
        flusher.flushPendingScene { accepted in
            guard accepted else { return }
            operation()
        }
    }

    func retainedEditorCoordinator(
        create: () -> ExcalidrawBoardEditorView.Coordinator
    ) -> ExcalidrawBoardEditorView.Coordinator {
        if let editorCoordinator { return editorCoordinator }
        let coordinator = create()
        editorCoordinator = coordinator
        return coordinator
    }

    func resetEditorSession() {
        editorCoordinator?.invalidate()
        editorCoordinator = nil
    }
}

struct ExcalidrawBoardEditorView: NSViewRepresentable {
    private static var assetBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    let document: BoardDocument
    let selectedElementID: BoardElementID?
    let zoom: Double
    let tool: BoardEditorTool
    let boxKind: BoardNodeKind
    let controls: ExcalidrawBoardControls
    let isReadOnly: Bool
    let bridgeController: ExcalidrawBoardBridgeController
    let onSceneChange: @MainActor (ExcalidrawBoardDecodeResult) -> Bool
    let onCommand: @MainActor (ExcalidrawBoardCommand) -> Void
    let onReady: @MainActor () -> Void
    let onIssue: @MainActor (String) -> Void
    let onFailure: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        bridgeController.retainedEditorCoordinator {
            Coordinator(
                onSceneChange: onSceneChange,
                onCommand: onCommand,
                onReady: onReady,
                onIssue: onIssue,
                onFailure: onFailure,
                bridgeController: bridgeController
            )
        }
    }

    func makeNSView(context: Context) -> ExcalidrawBoardHostView {
        let hostView = ExcalidrawBoardHostView()
        context.coordinator.prepare(hostView: hostView)

        if let retainedWebView = context.coordinator.retainedWebView {
            ExcalidrawBoardDiagnostics.record(
                kind: "representable-reused-webview",
                fields: [
                    "webViewIdentity": String(
                        describing: ObjectIdentifier(retainedWebView)
                    ),
                    "hostID": hostView.hostID.uuidString,
                ]
            )
            return hostView
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            name: "boardBridge"
        )

        if let assetRoot = Self.assetBundle.url(
            forResource: "BoardEditor",
            withExtension: nil
        ) {
            let assetHandler = ExcalidrawBoardAssetHandler(assetRoot: assetRoot)
            context.coordinator.retain(assetHandler: assetHandler)
            configuration.setURLSchemeHandler(
                assetHandler,
                forURLScheme: ExcalidrawBoardWebSecurity.scheme
            )
        }

        let webView = ExcalidrawBoardWebView(
            frame: .zero,
            configuration: configuration
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setAccessibilityElement(false)
        context.coordinator.attach(webView: webView)
        context.coordinator.update(
            document: document,
            selectedElementID: selectedElementID,
            zoom: zoom,
            tool: tool,
            boxKind: boxKind,
            controls: controls,
            isReadOnly: isReadOnly
        )
        context.coordinator.loadEditor()
        ExcalidrawBoardDiagnostics.record(
            kind: "representable-created-webview",
            fields: [
                "webViewIdentity": String(describing: ObjectIdentifier(webView)),
                "hostID": hostView.hostID.uuidString,
            ]
        )
        return hostView
    }

    func updateNSView(
        _ hostView: ExcalidrawBoardHostView,
        context: Context
    ) {
        context.coordinator.prepare(hostView: hostView)
        context.coordinator.updateCallbacks(
            onSceneChange: onSceneChange,
            onCommand: onCommand,
            onReady: onReady,
            onIssue: onIssue,
            onFailure: onFailure
        )
        context.coordinator.update(
            document: document,
            selectedElementID: selectedElementID,
            zoom: zoom,
            tool: tool,
            boxKind: boxKind,
            controls: controls,
            isReadOnly: isReadOnly
        )
    }

    static func dismantleNSView(
        _ hostView: ExcalidrawBoardHostView,
        coordinator: Coordinator
    ) {
        ExcalidrawBoardDiagnostics.record(
            kind: "representable-dismantle",
            fields: [
                "hostID": hostView.hostID.uuidString,
                "webViewIdentity": coordinator.retainedWebView.map {
                    String(describing: ObjectIdentifier($0))
                } ?? "none",
            ]
        )
        // SwiftUI may transiently dismantle an NSViewRepresentable when an
        // observed room value changes. The room-owned bridge retains this
        // local editor session so ordinary Board edits do not reload the page.
        // Intentional retry/surface transitions call resetEditorSession().
    }

    @MainActor
    final class Coordinator: NSObject,
        WKNavigationDelegate,
        WKScriptMessageHandler,
        WKUIDelegate,
        ExcalidrawBoardSceneFlushing
    {
        private struct Snapshot: Equatable {
            let document: BoardDocument
            let selectedElementID: BoardElementID?
            let zoom: Double
            let tool: BoardEditorTool
            let boxKind: BoardNodeKind
            let controls: ExcalidrawBoardControls
            let isReadOnly: Bool

            var state: ExcalidrawBoardState {
                ExcalidrawBoardState(
                    selectedID: selectedElementID?.rawValue,
                    zoom: zoom,
                    readOnly: isReadOnly,
                    tool: tool.rawValue,
                    boxKind: boxKind.rawValue,
                    controls: controls
                )
            }
        }

        private var webView: WKWebView?
        private weak var activeHostView: ExcalidrawBoardHostView?
        private var stableViewportSize = NSSize.zero
        private var assetHandler: ExcalidrawBoardAssetHandler?
        private var snapshot: Snapshot?
        private var lastLoadedDocument: BoardDocument?
        private var isReady = false
        private var didStartLoading = false
        private var readyDeadlineTask: Task<Void, Never>?
        private var pendingReloadTask: Task<Void, Never>?
        private var pendingReconcileTask: Task<Void, Never>?
        private weak var bridgeController: ExcalidrawBoardBridgeController?
        private var onSceneChange: @MainActor (ExcalidrawBoardDecodeResult) -> Bool
        private var onCommand: @MainActor (ExcalidrawBoardCommand) -> Void
        private var onReady: @MainActor () -> Void
        private var onIssue: @MainActor (String) -> Void
        private var onFailure: @MainActor (String) -> Void

        var retainedWebView: WKWebView? { webView }

        init(
            onSceneChange: @escaping @MainActor (ExcalidrawBoardDecodeResult) -> Bool,
            onCommand: @escaping @MainActor (ExcalidrawBoardCommand) -> Void,
            onReady: @escaping @MainActor () -> Void,
            onIssue: @escaping @MainActor (String) -> Void,
            onFailure: @escaping @MainActor (String) -> Void,
            bridgeController: ExcalidrawBoardBridgeController
        ) {
            self.onSceneChange = onSceneChange
            self.onCommand = onCommand
            self.onReady = onReady
            self.onIssue = onIssue
            self.onFailure = onFailure
            self.bridgeController = bridgeController
            super.init()
            bridgeController.attach(self)
        }

        func updateCallbacks(
            onSceneChange: @escaping @MainActor (ExcalidrawBoardDecodeResult) -> Bool,
            onCommand: @escaping @MainActor (ExcalidrawBoardCommand) -> Void,
            onReady: @escaping @MainActor () -> Void,
            onIssue: @escaping @MainActor (String) -> Void,
            onFailure: @escaping @MainActor (String) -> Void
        ) {
            self.onSceneChange = onSceneChange
            self.onCommand = onCommand
            self.onReady = onReady
            self.onIssue = onIssue
            self.onFailure = onFailure
        }

        func retain(assetHandler: ExcalidrawBoardAssetHandler) {
            self.assetHandler = assetHandler
        }

        func prepare(hostView: ExcalidrawBoardHostView) {
            hostView.onAttachToWindow = { [weak self] hostView in
                self?.activate(hostView: hostView)
            }
            hostView.onStableViewport = { [weak self] size in
                self?.stableViewportSize = size
            }
            if hostView.window != nil { activate(hostView: hostView) }
        }

        private func activate(hostView: ExcalidrawBoardHostView) {
            guard let webView else { return }
            guard activeHostView !== hostView
                    || webView.superview !== hostView else { return }
            activeHostView = hostView
            ExcalidrawBoardDiagnostics.record(
                kind: "native-host-activate",
                fields: [
                    "hostID": hostView.hostID.uuidString,
                    "stableWidth": stableViewportSize.width,
                    "stableHeight": stableViewportSize.height,
                ]
            )
            hostView.host(
                webView: webView,
                stableViewportSize: stableViewportSize
            )
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            if let activeHostView {
                activeHostView.host(
                    webView: webView,
                    stableViewportSize: stableViewportSize
                )
            }
        }

        func invalidate() {
            readyDeadlineTask?.cancel()
            readyDeadlineTask = nil
            pendingReloadTask?.cancel()
            pendingReloadTask = nil
            pendingReconcileTask?.cancel()
            pendingReconcileTask = nil
            bridgeController?.detach(self)
            webView?.stopLoading()
            webView?.configuration.userContentController
                .removeScriptMessageHandler(forName: "boardBridge")
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
            activeHostView = nil
            stableViewportSize = .zero
            assetHandler = nil
            snapshot = nil
            isReady = false
        }

        func update(
            document: BoardDocument,
            selectedElementID: BoardElementID?,
            zoom: Double,
            tool: BoardEditorTool,
            boxKind: BoardNodeKind,
            controls: ExcalidrawBoardControls,
            isReadOnly: Bool
        ) {
            let next = Snapshot(
                document: document,
                selectedElementID: selectedElementID,
                zoom: zoom,
                tool: tool,
                boxKind: boxKind,
                controls: controls,
                isReadOnly: isReadOnly
            )
            let previous = snapshot
            snapshot = next
            guard isReady else { return }
            if lastLoadedDocument != document {
                if lastLoadedDocument == nil {
                    scheduleLoad(next)
                } else {
                    scheduleReconcile(next)
                }
            } else {
                // A Board edit publishes from @Published.willSet before its
                // new value is readable. The next observation contains the
                // accepted document; cancel the stale reconcile queued by the
                // pre-assignment observation before it can reset the canvas.
                pendingReconcileTask?.cancel()
                pendingReconcileTask = nil
                pendingReloadTask?.cancel()
                pendingReloadTask = nil
                if ExcalidrawBoardUpdatePolicy.requiresStateUpdate(
                    previous: previous?.state,
                    next: next.state
                ) {
                    sendState(next)
                }
            }
        }

        func loadEditor() {
            guard !didStartLoading else { return }
            didStartLoading = true
            guard assetHandler != nil else {
                onFailure("The enhanced canvas resources are missing. The native Board is still available.")
                return
            }

            readyDeadlineTask?.cancel()
            readyDeadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: ExcalidrawBoardStartupPolicy.readyTimeout
                )
                guard !Task.isCancelled,
                      let self,
                      !self.isReady else { return }
                self.onFailure(
                    "The enhanced canvas did not become ready. Using the native canvas."
                )
            }

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: ExcalidrawBoardWebSecurity.contentRuleIdentifier,
                encodedContentRuleList: ExcalidrawBoardWebSecurity.contentRuleJSON
            ) { [weak self, weak webView] ruleList, error in
                Task { @MainActor in
                    guard let self, let webView else { return }
                    guard let ruleList else {
                        self.onFailure(
                            "The enhanced canvas security policy could not load: \(error?.localizedDescription ?? "unknown error")."
                        )
                        return
                    }
                    webView.configuration.userContentController.add(ruleList)
                    var components = URLComponents()
                    components.scheme = ExcalidrawBoardWebSecurity.scheme
                    components.host = "editor"
                    components.path = "/index.html"
                    if ExcalidrawBoardDiagnostics.isEnabled {
                        components.queryItems = [
                            URLQueryItem(name: "diagnostics", value: "1"),
                        ]
                    }
                    guard let url = components.url else {
                        self.onFailure("The enhanced canvas address is invalid.")
                        return
                    }
                    webView.load(URLRequest(url: url))
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let object = message.body as? [String: Any],
                  let event = object["event"] as? String else {
                onIssue("The enhanced canvas sent an unreadable update. Your saved Board was not changed.")
                return
            }
            switch event {
            case "ready":
                isReady = true
                readyDeadlineTask?.cancel()
                readyDeadlineTask = nil
                onReady()
                if let snapshot { scheduleLoad(snapshot) }

            case "scene":
                _ = receiveScene(object)

            case ExcalidrawBoardBridgePolicy.flushedCommandEvent:
                var sceneObject = object
                sceneObject["event"] = "scene"
                let accepted = receiveScene(sceneObject)
                guard ExcalidrawBoardBridgePolicy.permitsCommand(
                    afterSceneAccepted: accepted
                ) else { return }
                receiveCommand(object)

            case "command":
                receiveCommand(object)

            case "failure":
                let message = object["message"] as? String
                    ?? "The enhanced canvas stopped responding."
                onFailure(message)

            case "diagnostic":
                ExcalidrawBoardDiagnostics.record(
                    kind: "web-frame",
                    fields: object
                )

            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                ExcalidrawBoardWebSecurity.permitsNavigation(
                    to: navigationAction.request.url
                ) ? .allow : .cancel
            )
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure("The enhanced canvas could not load: \(error.localizedDescription).")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure("The enhanced canvas could not start: \(error.localizedDescription).")
        }

        func flushPendingScene(
            completion: @escaping @MainActor (Bool) -> Void
        ) {
            guard isReady, let webView else {
                completion(true)
                return
            }
            webView.evaluateJavaScript("window.interviewArcFlush()") {
                [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    guard error == nil,
                          let object = result as? [String: Any] else {
                        self.onIssue(
                            "The canvas could not confirm its latest edit. Save and history were not changed."
                        )
                        completion(false)
                        return
                    }
                    completion(self.receiveScene(object))
                }
            }
        }

        @discardableResult
        private func receiveScene(_ object: [String: Any]) -> Bool {
            guard let snapshot,
                  ExcalidrawBoardBridgePolicy.permitsScene(
                    afterNativeBaselineWasSent: lastLoadedDocument != nil
                  ) else { return false }
            do {
                let decoded = try ExcalidrawBoardCodec.decodeChange(
                    from: object,
                    currentDocument: snapshot.document
                )
                // Advance the bridge baseline before mutating the observed room
                // model. SwiftUI may synchronously re-enter `update` from the
                // callback; leaving the old baseline in place there schedules a
                // disruptive full scene load for every accepted drag or edit.
                let previousLoadedDocument = lastLoadedDocument
                lastLoadedDocument = decoded.document
                let previousSnapshot = self.snapshot
                self.snapshot = Snapshot(
                    document: decoded.document,
                    selectedElementID: decoded.selectedElementID,
                    zoom: decoded.zoom ?? snapshot.zoom,
                    tool: decoded.tool ?? snapshot.tool,
                    boxKind: decoded.boxKind ?? snapshot.boxKind,
                    controls: snapshot.controls,
                    isReadOnly: snapshot.isReadOnly
                )
                guard onSceneChange(decoded) else {
                    lastLoadedDocument = previousLoadedDocument
                    self.snapshot = previousSnapshot
                    onIssue("That canvas change could not be saved. The last valid Board remains available.")
                    scheduleLoad(snapshot)
                    return false
                }
                if decoded.requiresReload {
                    // `onSceneChange` can synchronously re-enter `update`.
                    // Pair the canonical document with the newest SwiftUI
                    // metadata rather than the stale pre-callback snapshot.
                    let current = self.snapshot ?? snapshot
                    scheduleReconcile(
                        Snapshot(
                            document: decoded.document,
                            selectedElementID: decoded.selectedElementID,
                            zoom: current.zoom,
                            tool: current.tool,
                            boxKind: current.boxKind,
                            controls: current.controls,
                            isReadOnly: current.isReadOnly
                        )
                    )
                }
                return true
            } catch ExcalidrawBoardCodecError.unsupportedElements {
                onIssue("That item is not supported by the local interview Board. Use Excalidraw's shape, arrow, line, draw, text, or eraser tools.")
                scheduleLoad(snapshot)
                return false
            } catch {
                onIssue("That canvas change is outside the supported Board bounds. The last valid Board remains available.")
                scheduleLoad(snapshot)
                return false
            }
        }

        private func scheduleLoad(_ snapshot: Snapshot) {
            pendingReconcileTask?.cancel()
            pendingReconcileTask = nil
            pendingReloadTask?.cancel()
            pendingReloadTask = Task { @MainActor [weak self] in
                // WKScriptMessageHandler and evaluateJavaScript callbacks must
                // return before native code calls back into the same WKWebView.
                // One executor yield provides that boundary without a timing
                // guess, while cancellation makes the latest snapshot win.
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.pendingReloadTask = nil
                self.load(snapshot)
            }
        }

        private func scheduleReconcile(_ snapshot: Snapshot) {
            // A canonical reconcile supersedes any full load that may have been
            // queued by an earlier observation pass. Running both is the source
            // of the visible white flash and viewport reset.
            pendingReloadTask?.cancel()
            pendingReloadTask = nil
            pendingReconcileTask?.cancel()
            pendingReconcileTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.pendingReconcileTask = nil
                self.reconcile(snapshot)
            }
        }

        private func receiveCommand(_ object: [String: Any]) {
            guard let rawCommand = object["command"] as? String else { return }
            switch rawCommand {
            case "undo": onCommand(.undo)
            case "redo": onCommand(.redo)
            case "saveRevision": onCommand(.saveRevision)
            case "zoomIn": onCommand(.zoomIn)
            case "zoomOut": onCommand(.zoomOut)
            case "zoomReset": onCommand(.zoomReset)
            case "showRevisions": onCommand(.showRevisions)
            case "returnToDraft": onCommand(.returnToDraft)
            case "attachRevision": onCommand(.attachRevision)
            case "exportRevision": onCommand(.exportRevision)
            case "tool":
                guard let rawTool = object["tool"] as? String,
                      let tool = BoardEditorTool(rawValue: rawTool) else { return }
                onCommand(.tool(tool))
            default:
                break
            }
        }

        private func load(_ snapshot: Snapshot) {
            guard isReady,
                  let json = try? ExcalidrawBoardCodec.encodeScene(
                    ExcalidrawBoardScene(
                        document: snapshot.document,
                        selectedElementID: snapshot.selectedElementID,
                        zoom: snapshot.zoom,
                        readOnly: snapshot.isReadOnly,
                        tool: snapshot.tool,
                        boxKind: snapshot.boxKind,
                        controls: snapshot.controls
                    )
                  ) else {
                return
            }
            lastLoadedDocument = snapshot.document
            evaluate(function: "interviewArcLoad", json: json)
        }

        private func reconcile(_ snapshot: Snapshot) {
            guard isReady,
                  let json = try? ExcalidrawBoardCodec.encodeScene(
                    ExcalidrawBoardScene(
                        document: snapshot.document,
                        selectedElementID: snapshot.selectedElementID,
                        zoom: snapshot.zoom,
                        readOnly: snapshot.isReadOnly,
                        tool: snapshot.tool,
                        boxKind: snapshot.boxKind,
                        controls: snapshot.controls
                    )
                  ) else {
                return
            }
            lastLoadedDocument = snapshot.document
            evaluate(function: "interviewArcReconcile", json: json)
        }

        private func sendState(_ snapshot: Snapshot) {
            guard let json = try? ExcalidrawBoardCodec.encodeState(
                ExcalidrawBoardState(
                    selectedID: snapshot.selectedElementID?.rawValue,
                    zoom: snapshot.zoom,
                    readOnly: snapshot.isReadOnly,
                    tool: snapshot.tool.rawValue,
                    boxKind: snapshot.boxKind.rawValue,
                    controls: snapshot.controls
                )
            ) else {
                return
            }
            evaluate(function: "interviewArcSetState", json: json)
        }

        private func evaluate(function: String, json: String) {
            guard let webView,
                  let quotedData = try? JSONEncoder().encode(json),
                  let quoted = String(data: quotedData, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript("window.\(function)(\(quoted))") {
                [weak self] _, error in
                guard let error else { return }
                Task { @MainActor in
                    self?.onFailure(
                        "The enhanced canvas bridge failed: \(error.localizedDescription)."
                    )
                }
            }
        }
    }
}

final class ExcalidrawBoardAssetHandler: NSObject, WKURLSchemeHandler {
    let assetRoot: URL

    init(assetRoot: URL) {
        self.assetRoot = assetRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    func webView(
        _ webView: WKWebView,
        start urlSchemeTask: WKURLSchemeTask
    ) {
        guard let url = urlSchemeTask.request.url,
              url.scheme?.lowercased() == ExcalidrawBoardWebSecurity.scheme else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let relativePath = url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let requested = assetRoot
            .appendingPathComponent(relativePath.isEmpty ? "index.html" : relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard requested.path.hasPrefix(assetRoot.path + "/"),
              let data = try? Data(contentsOf: requested),
              data.count <= ExcalidrawBoardCodec.maximumBridgeBytes else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = Self.mimeType(for: requested.pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/")
                || mimeType == "application/javascript" ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(
        _ webView: WKWebView,
        stop urlSchemeTask: WKURLSchemeTask
    ) {}

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "application/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}
