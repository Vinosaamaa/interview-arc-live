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
    private let application: NSApplication
    private var webView: WKWebView?
    private var didFinish = false
    private var failures: [String] = []
    private var isReady = false
    private var sceneEventCount = 0
    private var loadedElementCount: Int?

    init(application: NSApplication) {
        self.application = application
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
            sceneEventCount += 1
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
                "x": 120.0,
                "y": 140.0,
                "width": 180.0,
                "height": 112.0,
                "label": "API service",
                "nodeKind": "service",
                "fill": "#ffffff",
                "stroke": "#4b3abf",
            ]],
            "selectedID": "runtime-probe-box",
            "zoom": 1.0,
            "readOnly": false,
            "tool": "select",
            "boxKind": "service",
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
            webView.evaluateJavaScript("window.interviewArcLoad(\(quoted))") {
                [weak self] result, error in
                guard let self else { return }
                loadedElementCount = (result as? NSNumber)?.intValue
                if let error {
                    failures.append(
                        "non-empty scene failed: \(error.localizedDescription)"
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.finish()
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
        guard let webView else {
            complete(success: false, detail: "WKWebView was released")
            return
        }
        let probe = #"""
        JSON.stringify({
          ready: document.documentElement.dataset.interviewArcBoardReady ?? null,
          rootChildren: document.getElementById("root")?.children.length ?? 0,
          hasLoadBridge: typeof window.interviewArcLoad === "function",
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
                && loadedElementCount == 1
                && containsRuntimeProbeBox(object["snapshot"])
                && sceneEventCount > 0
                && sceneEventCount < 10
            complete(
                success: stable,
                detail: stable
                    ? "ready, stable React root, native bridge present, and \(sceneEventCount) initial scene updates"
                    : (failures + ["scene updates: \(sceneEventCount)"])
                        .joined(separator: "; ")
            )
        }
    }

    private func containsRuntimeProbeBox(_ rawSnapshot: Any?) -> Bool {
        guard let snapshot = rawSnapshot as? [String: Any],
              let elements = snapshot["elements"] as? [[String: Any]] else {
            return false
        }
        return elements.contains { element in
            element["type"] as? String == "box"
                && element["boardID"] as? String == "runtime-probe-box"
                && element["label"] as? String == "API service"
        }
    }

    private func complete(success: Bool, detail: String) {
        print(success
            ? "Board editor packaged WKWebView runtime passed: \(detail)."
            : "FAIL: Board editor packaged WKWebView runtime: \(detail)")
        fflush(stdout)
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: BoardEditorRuntimeProbe <BoardEditor resource root>\n", stderr)
    exit(EXIT_FAILURE)
}

let resourceRoot = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
private let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
private let probe = RuntimeProbe(application: application)
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
configuration.userContentController.add(probe, name: "boardBridge")
private let assetHandler = LocalAssetHandler(
    root: resourceRoot,
    onFailure: probe.recordFailure
)
configuration.setURLSchemeHandler(assetHandler, forURLScheme: "interviewarc-board")

let webView = WKWebView(
    frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
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
