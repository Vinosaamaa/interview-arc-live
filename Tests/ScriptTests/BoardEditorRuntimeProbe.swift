import AppKit
import Foundation
import WebKit

private final class LocalAssetHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private let onFailure: (String) -> Void

    init(root: URL, onFailure: @escaping (String) -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.onFailure = onFailure
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let relative = url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let requested = root
            .appendingPathComponent(relative.isEmpty ? "index.html" : relative)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard requested.path.hasPrefix(root.path + "/") else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        do {
            let data = try Data(contentsOf: requested, options: .mappedIfSafe)
            let mimeType = Self.mimeType(for: requested.pathExtension)
            task.didReceive(
                URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: mimeType.hasPrefix("text/")
                        || mimeType == "application/javascript" ? "utf-8" : nil
                )
            )
            task.didReceive(data)
            task.didFinish()
        } catch {
            onFailure("missing local asset: \(relative)")
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "application/javascript"
        case "css": "text/css"
        case "woff2": "font/woff2"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }
}

private final class RuntimeProbe: NSObject,
    WKScriptMessageHandler,
    WKNavigationDelegate
{
    private let viewportWidths: [CGFloat]
    private var webView: WKWebView?
    private var didFinish = false
    private var failures: [String] = []
    private var viewportFailures: [String] = []
    private var isReady = false
    private var sceneEvents: [[String: Any]] = []
    private var flushedCommands: [String] = []
    private var directCommands: [String] = []
    private var loadedElementCount: Int?

    init(viewportWidths: [CGFloat]) {
        self.viewportWidths = viewportWidths
    }

    func recordFailure(_ message: String) {
        failures.append(message)
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "boardBridge",
              let object = message.body as? [String: Any],
              let event = object["event"] as? String else { return }
        switch event {
        case "ready":
            guard !isReady else { return }
            isReady = true
            loadNonEmptySceneFixture()
        case "failure":
            failures.append(
                object["message"] as? String ?? "editor reported failure"
            )
        case "scene":
            sceneEvents.append(object)
        case "flushedCommand":
            if let command = object["command"] as? String {
                flushedCommands.append(command)
            }
        case "command":
            if let command = object["command"] as? String {
                directCommands.append(command)
            }
        default:
            break
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failures.append("navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failures.append("navigation could not start: \(error.localizedDescription)")
    }

    func timeout() {
        guard !didFinish else { return }
        failures.append("local editor did not become ready")
        finish()
    }

    private func loadNonEmptySceneFixture() {
        guard let webView else {
            failures.append("WKWebView was released before scene loading")
            finish()
            return
        }
        let scene: [String: Any] = [
            "elements": [[
                "type": "box",
                "boardID": "runtime-probe-box",
                "x": 370.14453125,
                "y": 330.546875,
                "width": 170.0,
                "height": 100.0,
                "label": "API service",
                "nodeKind": "service",
                "fill": "#ffffff",
                "stroke": "#4b3abf",
            ], [
                "type": "box",
                "boardID": "runtime-probe-queue",
                "x": 136.2734375,
                "y": 173.84765625,
                "width": 160.0,
                "height": 90.0,
                "label": "Delivery queue",
                "nodeKind": "queue",
                "fill": "#ffffff",
                "stroke": "#4b3abf",
            ], [
                "type": "connector",
                "boardID": "runtime-probe-connector",
                "startX": 333.14453125,
                "startY": 299.546875,
                "endX": 333.2734375,
                "endY": 299.84765625,
                "points": [
                    ["x": 333.14453125, "y": 299.546875],
                    ["x": 333.208984375, "y": 299.546875],
                    ["x": 333.208984375, "y": 299.84765625],
                    ["x": 333.2734375, "y": 299.84765625],
                ],
                "sourceID": "runtime-probe-box",
                "targetID": "runtime-probe-queue",
                "startAnchorPolicy": "automatic",
                "endAnchorPolicy": "automatic",
                "label": "publishes",
                "stroke": "#1f2937",
            ]],
            "selectedID": "runtime-probe-box",
            "zoom": 1.0,
            "readOnly": false,
            "tool": "hand",
            "boxKind": "service",
            "controls": [
                "revisionStatus": "Unsaved changes · revision 1",
                "notice": NSNull(),
                "noticeIsError": false,
                "isInspecting": false,
                "canSave": true,
                "hasRevisions": true,
                "canAttach": true,
                "canExport": true,
                "isExporting": false,
            ],
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: scene,
                options: [.sortedKeys]
            )
            let json = String(decoding: data, as: UTF8.self)
            let quotedData = try JSONEncoder().encode(json)
            guard let quoted = String(data: quotedData, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            webView.evaluateJavaScript(
                """
                (() => {
                  const serialized = \(quoted);
                  const scene = JSON.parse(serialized);
                  const count = window.interviewArcLoad(serialized);
                  window.setTimeout(() => {
                    const reconciledScene = structuredClone(scene);
                    reconciledScene.elements[0].x = 450.14453125;
                    const currentState = JSON.stringify({
                      selectedID: "runtime-probe-box",
                      zoom: 1.25,
                      readOnly: false,
                      tool: "hand",
                      boxKind: "service",
                      controls: scene.controls
                    });
                    window.interviewArcSetState(currentState);
                    window.interviewArcReconcile(JSON.stringify(reconciledScene));
                    window.setTimeout(() => {
                      const controlsOnlyState = JSON.parse(currentState);
                      controlsOnlyState.controls = {
                        ...controlsOnlyState.controls,
                        revisionStatus: "Native sync confirmed"
                      };
                      window.interviewArcSetState(
                        JSON.stringify(controlsOnlyState)
                      );
                    }, 100);
                  }, 250);
                  return count;
                })()
                """
            ) {
                [weak self] result, error in
                guard let self else { return }
                loadedElementCount = (result as? NSNumber)?.intValue
                if let error {
                    failures.append(
                        "non-empty scene failed: \(error.localizedDescription)"
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    webView.evaluateJavaScript(
                        """
                        document.querySelector('button[aria-label="Save revision"]')?.click();
                        document.querySelector('button[aria-label="Export board"]')?.click();
                        """
                    ) { _, actionError in
                        if let actionError {
                            self.failures.append(
                                "Board chrome actions failed: \(actionError.localizedDescription)"
                            )
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                            self.finish()
                        }
                    }
                }
            }
        } catch {
            failures.append(
                "non-empty scene fixture failed: \(error.localizedDescription)"
            )
            finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        validateViewport(at: 0)
    }

    private func validateViewport(at index: Int) {
        guard let webView else {
            complete(success: false, detail: "WKWebView was released")
            return
        }
        guard index < viewportWidths.count else {
            let widths = viewportWidths
                .map { String(format: "%.0f", Double($0)) }
                .joined(separator: ", ")
            let succeeded = failures.isEmpty && viewportFailures.isEmpty
            complete(
                success: succeeded,
                detail: succeeded
                    ? "viewports \(widths) retained ready local chrome, native bridge state, and the canonical document"
                    : (failures + viewportFailures).joined(separator: "; ")
            )
            return
        }
        let width = viewportWidths[index]
        webView.setFrameSize(NSSize(width: width, height: 600))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            [weak self, weak webView] in
            guard let self, let webView else { return }
            evaluateViewport(at: index, width: width, webView: webView)
        }
    }

    private func evaluateViewport(
        at index: Int,
        width: CGFloat,
        webView: WKWebView
    ) {
        let probe = #"""
        JSON.stringify({
          ready: document.documentElement.dataset.interviewArcBoardReady ?? null,
          rootChildren: document.getElementById("root")?.children.length ?? 0,
          hasLoadBridge: typeof window.interviewArcLoad === "function",
          hasReconcileBridge: typeof window.interviewArcReconcile === "function",
          nativeToolbarControlCount: document.querySelectorAll(
            '.App-toolbar-container button, .App-toolbar-container label, .App-toolbar-container input'
          ).length,
          nativeToolbarVisible: (() => {
            const element = document.querySelector('.App-toolbar-container');
            return element ? getComputedStyle(element).display !== 'none' : false;
          })(),
          nativeFooterVisible: (() => {
            const element = document.querySelector('.layer-ui__wrapper__footer');
            return element ? getComputedStyle(element).display !== 'none' : false;
          })(),
          hasSave: Boolean(document.querySelector('button[aria-label="Save revision"]')),
          hasRevisions: Boolean(document.querySelector('button[aria-label="Browse revisions"]')),
          hasAttach: Boolean(document.querySelector('button[aria-label="Attach revision"]')),
          hasExport: Boolean(document.querySelector('button[aria-label="Export board"]')),
          chromeComputedVisible: (() => {
            const controls = document.querySelector('.interview-arc-board-controls');
            if (!controls) return false;
            const style = getComputedStyle(controls);
            return style.display !== 'none'
              && style.visibility === 'visible'
              && Number(style.opacity) > 0;
          })(),
          chromeComputedOpacity: (() => {
            const controls = document.querySelector('.interview-arc-board-controls');
            return controls ? Number(getComputedStyle(controls).opacity) : 0;
          })(),
          chromeActionableButtonCount: (() => {
            return Array.from(document.querySelectorAll(
              '.interview-arc-board-controls button:not(:disabled)'
            )).length;
          })(),
          chromeActionableButtonsInViewport: (() => {
            const buttons = Array.from(document.querySelectorAll(
              '.interview-arc-board-controls button:not(:disabled)'
            ));
            if (buttons.length === 0) return false;
            return buttons.every((button) => {
              const rect = button.getBoundingClientRect();
              const style = getComputedStyle(button);
              return rect.width > 0
                && rect.height > 0
                && rect.left >= 0
                && rect.top >= 0
                && rect.right <= document.documentElement.clientWidth
                && rect.bottom <= document.documentElement.clientHeight
                && style.display !== 'none'
                && style.visibility === 'visible'
                && Number(style.opacity) > 0
                && style.pointerEvents !== 'none';
            });
          })(),
          chromeFitsWithoutOverlap: (() => {
            const toolbar = document.querySelector('.App-toolbar-container')?.getBoundingClientRect();
            const controls = document.querySelector('.interview-arc-board-controls')?.getBoundingClientRect();
            if (!toolbar || !controls) return false;
            const placement = document.querySelector('.interview-arc-board-controls')
              ?.dataset.placement;
            const overlaps = toolbar.left < controls.right
              && toolbar.right > controls.left
              && toolbar.top < controls.bottom
              && toolbar.bottom > controls.top;
            return !overlaps
              && (placement === 'inline'
                ? Math.abs(toolbar.top - controls.top) <= 1
                : placement === 'stacked' && controls.top >= toolbar.bottom + 8)
              && controls.left >= 0
              && controls.right <= document.documentElement.clientWidth
              && controls.top >= 0
              && controls.bottom <= document.documentElement.clientHeight;
          })(),
          chromeMetrics: (() => {
            const toolbar = document.querySelector('.App-toolbar-container')?.getBoundingClientRect();
            const controls = document.querySelector('.interview-arc-board-controls')?.getBoundingClientRect();
            const pack = (rect) => rect ? {
              left: rect.left,
              right: rect.right,
              top: rect.top,
              bottom: rect.bottom
            } : null;
            return {
              toolbar: pack(toolbar),
              controls: pack(controls),
              viewportWidth: document.documentElement.clientWidth
            };
          })(),
          runtime: window.interviewArcRuntimeState?.() ?? null,
          snapshot: window.interviewArcSnapshot?.() ?? null
        })
        """#
        webView.evaluateJavaScript(probe) { [weak self] result, error in
            guard let self else { return }
            if let error {
                failures.append("readiness probe failed: \(error.localizedDescription)")
            }
            guard let data = (result as? String)?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                complete(success: false, detail: failures.joined(separator: "; "))
                return
            }
            let stable = failures.isEmpty
                && object["ready"] as? String == "true"
                && (object["rootChildren"] as? Int ?? 0) > 0
                && object["hasLoadBridge"] as? Bool == true
                && object["hasReconcileBridge"] as? Bool == true
                && (object["nativeToolbarControlCount"] as? Int ?? 0) >= 8
                && object["nativeToolbarVisible"] as? Bool == true
                && object["nativeFooterVisible"] as? Bool == true
                && object["hasSave"] as? Bool == true
                && object["hasRevisions"] as? Bool == true
                && object["hasAttach"] as? Bool == true
                && object["hasExport"] as? Bool == true
                && object["chromeComputedVisible"] as? Bool == true
                && (object["chromeComputedOpacity"] as? NSNumber)?.doubleValue == 1
                && (object["chromeActionableButtonCount"] as? Int ?? 0) == 4
                && object["chromeActionableButtonsInViewport"] as? Bool == true
                && object["chromeFitsWithoutOverlap"] as? Bool == true
                && loadedElementCount == 3
                && containsMovedRuntimeProbeBox(object["snapshot"])
                && containsBoundRuntimeProbeConnector(object["snapshot"])
                && containsActiveHandTool(object["runtime"])
                && containsZoom(object["runtime"], expected: 1.25)
                && containsNativeSceneMutationCount(
                    object["runtime"],
                    expected: 3
                )
                && flushedCommands.contains("saveRevision")
                && directCommands.contains("exportRevision")
                && sceneEventsPreserveNativeDocument()
            if !stable {
                viewportFailures.append(
                    (["viewport \(Int(width)) failed"] + failures + [
                        "scene updates: \(sceneEvents.count)",
                        "flushed commands: \(flushedCommands)",
                        "direct commands: \(directCommands)",
                        "probe: \(object)",
                    ])
                    .joined(separator: "; ")
                )
            }
            validateViewport(at: index + 1)
        }
    }

    private func containsMovedRuntimeProbeBox(_ rawSnapshot: Any?) -> Bool {
        guard let snapshot = rawSnapshot as? [String: Any],
              let elements = snapshot["elements"] as? [[String: Any]] else {
            return false
        }
        return elements.contains { element in
            element["type"] as? String == "box"
                && element["boardID"] as? String == "runtime-probe-box"
                && element["label"] as? String == "API service"
                && abs(((element["x"] as? NSNumber)?.doubleValue ?? 0) - 450.14453125) <= 0.000_1
        }
    }

    private func containsRuntimeProbeQueue(_ rawSnapshot: Any?) -> Bool {
        guard let snapshot = rawSnapshot as? [String: Any],
              let elements = snapshot["elements"] as? [[String: Any]] else {
            return false
        }
        return elements.contains { element in
            element["type"] as? String == "box"
                && element["boardID"] as? String == "runtime-probe-queue"
                && element["label"] as? String == "Delivery queue"
        }
    }

    private func containsBoundRuntimeProbeConnector(_ rawSnapshot: Any?) -> Bool {
        guard let snapshot = rawSnapshot as? [String: Any],
              let elements = snapshot["elements"] as? [[String: Any]] else {
            return false
        }
        return elements.contains { element in
            element["type"] as? String == "connector"
                && element["boardID"] as? String == "runtime-probe-connector"
                && element["sourceWebID"] as? String == "runtime-probe-box"
                && element["targetWebID"] as? String == "runtime-probe-queue"
        }
    }

    private func containsActiveHandTool(_ rawRuntime: Any?) -> Bool {
        guard let runtime = rawRuntime as? [String: Any] else { return false }
        return runtime["activeTool"] as? String == "hand"
    }

    private func containsZoom(_ rawRuntime: Any?, expected: Double) -> Bool {
        guard let runtime = rawRuntime as? [String: Any],
              let zoom = (runtime["zoom"] as? NSNumber)?.doubleValue else {
            return false
        }
        return abs(zoom - expected) <= 0.000_1
    }

    private func sceneEventsPreserveNativeDocument() -> Bool {
        sceneEvents.count < 10 && sceneEvents.allSatisfy { event in
            guard let elements = event["elements"] as? [[String: Any]],
                  elements.count == 3,
                  (event["unsupportedElementCount"] as? NSNumber)?.intValue == 0
            else {
                return false
            }
            return containsMovedRuntimeProbeBox(event)
                && containsRuntimeProbeQueue(event)
                && containsBoundRuntimeProbeConnector(event)
        }
    }

    private func containsNativeSceneMutationCount(
        _ rawRuntime: Any?,
        expected: Int
    ) -> Bool {
        guard let runtime = rawRuntime as? [String: Any],
              let count = (runtime["nativeSceneMutationCount"] as? NSNumber)?
                .intValue else {
            return false
        }
        return count == expected
    }

    private func complete(success: Bool, detail: String) {
        print(success
            ? "Board editor packaged WKWebView runtime passed: \(detail)."
            : "FAIL: Board editor packaged WKWebView runtime: \(detail)")
        fflush(stdout)
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

guard CommandLine.arguments.count >= 2 else {
    fputs(
        "usage: BoardEditorRuntimeProbe <BoardEditor resource root> [width ...]\n",
        stderr
    )
    exit(EXIT_FAILURE)
}

private let suppliedWidths = CommandLine.arguments.dropFirst(2)
private let viewportWidths: [CGFloat] = suppliedWidths.isEmpty
    ? [780]
    : suppliedWidths.compactMap { rawWidth in
        guard let width = Double(rawWidth), width >= 480 else { return nil }
        return CGFloat(width)
    }
guard viewportWidths.count == max(1, suppliedWidths.count) else {
    fputs("every viewport width must be a number of at least 480\n", stderr)
    exit(EXIT_FAILURE)
}

let resourceRoot = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
private let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
private let probe = RuntimeProbe(viewportWidths: viewportWidths)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
configuration.userContentController.add(probe, name: "boardBridge")
configuration.userContentController.addUserScript(
    WKUserScript(
        source: #"""
        window.addEventListener("error", (event) => {
          window.webkit?.messageHandlers?.boardBridge?.postMessage({
            event: "failure",
            message: `bootstrap error: ${event.message ?? "unknown"}`
          });
        }, true);
        window.addEventListener("unhandledrejection", (event) => {
          window.webkit?.messageHandlers?.boardBridge?.postMessage({
            event: "failure",
            message: `bootstrap rejection: ${String(event.reason ?? "unknown")}`
          });
        }, true);
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
)
private let assetHandler = LocalAssetHandler(
    root: resourceRoot,
    onFailure: probe.recordFailure
)
configuration.setURLSchemeHandler(assetHandler, forURLScheme: "interviewarc-board")

let webView = WKWebView(
    frame: NSRect(x: 0, y: 0, width: viewportWidths[0], height: 600),
    configuration: configuration
)
webView.navigationDelegate = probe
probe.attach(webView)

let window = NSWindow(
    contentRect: webView.frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.contentView = webView
window.orderBack(nil)

guard let page = URL(string: "interviewarc-board://editor/index.html") else {
    fatalError("invalid local editor URL")
}
webView.load(URLRequest(url: page))
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    probe.timeout()
}
application.run()
