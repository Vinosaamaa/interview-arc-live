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

@MainActor
protocol ExcalidrawBoardSceneFlushing: AnyObject {
    func flushPendingScene(
        completion: @escaping @MainActor (Bool) -> Void
    )
}

@MainActor
final class ExcalidrawBoardBridgeController: ObservableObject {
    private weak var flusher: (any ExcalidrawBoardSceneFlushing)?

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
        Coordinator(
            onSceneChange: onSceneChange,
            onCommand: onCommand,
            onReady: onReady,
            onIssue: onIssue,
            onFailure: onFailure,
            bridgeController: bridgeController
        )
    }

    func makeNSView(context: Context) -> WKWebView {
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
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
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
        _ webView: WKWebView,
        coordinator: Coordinator
    ) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "boardBridge"
        )
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.detach()
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

        private weak var webView: WKWebView?
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

        func attach(webView: WKWebView) {
            self.webView = webView
        }

        func detach() {
            readyDeadlineTask?.cancel()
            readyDeadlineTask = nil
            pendingReloadTask?.cancel()
            pendingReloadTask = nil
            pendingReconcileTask?.cancel()
            pendingReconcileTask = nil
            bridgeController?.detach(self)
            webView = nil
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
            } else if ExcalidrawBoardUpdatePolicy.requiresStateUpdate(
                previous: previous?.state,
                next: next.state
            ) {
                if pendingReloadTask != nil {
                    scheduleLoad(next)
                } else if pendingReconcileTask != nil {
                    scheduleReconcile(next)
                } else {
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
                    guard let url = URL(
                        string: "\(ExcalidrawBoardWebSecurity.scheme)://editor/index.html"
                    ) else {
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
