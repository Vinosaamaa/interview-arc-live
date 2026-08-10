import AppKit
import InterviewArcLiveCore
import SwiftUI

enum InterviewRoomPresentationState: Equatable {
    case notStarted
    case full
    case compact
    case closed
    case terminated
}

enum InterviewRoomCloseChoice: Equatable {
    case continueCompact
    case endInterview
    case cancel
}

enum CompactPanelLayout {
    static let contentWidth: CGFloat = 640
    static let minimumContentHeight: CGFloat = 214
    static let maximumContentHeight: CGFloat = 420

    static func boundedContentHeight(_ measuredHeight: CGFloat) -> CGFloat {
        guard !measuredHeight.isNaN else { return minimumContentHeight }
        if !measuredHeight.isFinite {
            return measuredHeight > 0
                ? maximumContentHeight
                : minimumContentHeight
        }
        return min(
            max(ceil(measuredHeight), minimumContentHeight),
            maximumContentHeight
        )
    }

    static func framePreservingTopEdge(
        _ frame: NSRect,
        measuredContentHeight: CGFloat
    ) -> NSRect {
        let height = boundedContentHeight(measuredContentHeight)
        return NSRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: contentWidth,
            height: height
        )
    }
}

/// Owns the two process-level Presentations while the interview model remains
/// the single interaction writer. Hiding a Presentation never tears down its
/// hosting tree or creates session/provider state.
@MainActor
final class InterviewRoomPresentationCoordinator: NSObject, NSWindowDelegate {
    let model: SystemDesignRoomModel

    private(set) var presentationState: InterviewRoomPresentationState = .notStarted
    private(set) var didRequestModelOpen = false
    private(set) var fullWindow: NSWindow!
    private(set) var compactPanel: NSPanel!

    private var fullHostingController: NSHostingController<SystemDesignRoomView>!
    private var compactHostingController: CompactRoomHostingController!
    private var fullContainerController: FullRoomContainerController!
    private let frameAutosaveName: String

    private var didStart = false
    private var didRegisterObservers = false
    private var isAllowingFullWindowClose = false
    private(set) var isResolvingCloseChoice = false
    private var isAdjustingFrames = false
    private var closeAlert: NSAlert?
    private var modelOpenTask: Task<Void, Never>?
    private var compactSizeReconciliationTask: Task<Void, Never>?
    private var savedFullFrame: NSRect?
    private var savedCompactOrigin: NSPoint?
    private weak var savedFullFirstResponder: NSResponder?
    private weak var closeGuardFirstResponder: NSResponder?

    init(
        model: SystemDesignRoomModel,
        frameAutosaveName: String = "InterviewArcLive.SystemDesignRoom"
    ) {
        self.model = model
        self.frameAutosaveName = frameAutosaveName
        super.init()
        installPresentations()
        registerLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var fullHostingTreeIdentity: ObjectIdentifier {
        ObjectIdentifier(fullHostingController)
    }

    var compactHostingTreeIdentity: ObjectIdentifier {
        ObjectIdentifier(compactHostingController)
    }

    var fullHostedModelIdentity: ObjectIdentifier {
        ObjectIdentifier(fullHostingController.rootView.model)
    }

    var compactHostedModelIdentity: ObjectIdentifier {
        ObjectIdentifier(compactHostingController.rootView.model)
    }

    var fallbackFirstResponder: NSResponder {
        fullContainerController.fallbackFirstResponder
    }

    var isCloseGuardPresented: Bool {
        closeAlert != nil
    }

    func start() {
        guard presentationState != .terminated, !didStart else { return }
        didStart = true
        showFullPresentation(activating: true)

        guard !didRequestModelOpen else { return }
        didRequestModelOpen = true
        modelOpenTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await model.open()
        }
    }

    func collapse() {
        guard presentationState != .terminated,
              !isResolvingCloseChoice else {
            return
        }
        if presentationState == .compact {
            reconcileCompactPanelSize()
            clampCompactPanelToVisibleScreens()
            if !compactPanel.isVisible {
                compactPanel.orderFrontRegardless()
            }
            return
        }

        captureFullPresentationState()
        fullWindow.orderOut(nil)
        reconcileCompactPanelSize()
        clampCompactPanelToVisibleScreens()
        compactPanel.orderFrontRegardless()
        presentationState = .compact
    }

    func expand() {
        guard presentationState != .terminated,
              !isResolvingCloseChoice else {
            return
        }
        showFullPresentation(activating: true)
    }

    func reopen() {
        guard presentationState != .terminated,
              !isResolvingCloseChoice else {
            return
        }
        expand()
    }

    func requestFullWindowClose() {
        guard presentationState != .terminated,
              !isResolvingCloseChoice else {
            return
        }
        if !fullWindow.isVisible {
            expand()
        }
        fullWindow.performClose(nil)
    }

    func resolveCloseChoice(_ choice: InterviewRoomCloseChoice) async {
        guard presentationState != .terminated,
              !isResolvingCloseChoice else {
            return
        }

        switch choice {
        case .continueCompact:
            collapse()
        case .cancel:
            presentationState = .full
            fullWindow.makeKeyAndOrderFront(nil)
            restoreFullFirstResponder(preferred: closeGuardFirstResponder)
        case .endInterview:
            isResolvingCloseChoice = true
            defer { isResolvingCloseChoice = false }
            let didFinish = await model.finishInterview()

            guard presentationState != .terminated else { return }

            guard didFinish else {
                compactPanel.orderOut(nil)
                presentationState = .full
                fullWindow.makeKeyAndOrderFront(nil)
                restoreFullFirstResponder(preferred: closeGuardFirstResponder)
                return
            }

            compactPanel.orderOut(nil)
            isAllowingFullWindowClose = true
            fullWindow.performClose(nil)
            isAllowingFullWindowClose = false
            presentationState = .closed
        }
    }

    func prepareForTermination() {
        guard presentationState != .terminated else { return }
        presentationState = .terminated
        if didRegisterObservers {
            NotificationCenter.default.removeObserver(self)
            didRegisterObservers = false
        }
        closeAlert = nil
        compactSizeReconciliationTask?.cancel()
        compactSizeReconciliationTask = nil
        compactPanel.orderOut(nil)
        fullWindow.orderOut(nil)
        // Do not finish the Session or cancel/replay durable provider work.
        // Process termination owns the remaining task lifetime.
        modelOpenTask = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === fullWindow else { return true }
        if presentationState == .terminated
            || isAllowingFullWindowClose
            || model.snapshot?.phase == .completed {
            return true
        }
        if isResolvingCloseChoice {
            return false
        }

        presentCloseGuardIfNeeded()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === fullWindow,
              presentationState != .terminated else {
            return
        }
        presentationState = .closed
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrames,
              let window = notification.object as? NSWindow else {
            return
        }
        if window === compactPanel {
            savedCompactOrigin = compactPanel.frame.origin
        } else if window === fullWindow, !fullWindow.isMiniaturized {
            savedFullFrame = fullWindow.frame
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAdjustingFrames,
              let window = notification.object as? NSWindow,
              window === fullWindow,
              !fullWindow.isMiniaturized else {
            return
        }
        savedFullFrame = fullWindow.frame
    }

    func windowDidChangeScreen(_ notification: Notification) {
        clampPresentationFramesToVisibleScreens()
    }

    static func clampedFrame(
        _ frame: NSRect,
        to visibleFrames: [NSRect],
        margin: CGFloat = 12
    ) -> NSRect {
        guard !visibleFrames.isEmpty else { return frame }

        let target = visibleFrames.max { lhs, rhs in
            let lhsIntersection = lhs.intersection(frame)
            let rhsIntersection = rhs.intersection(frame)
            let lhsArea = max(lhsIntersection.width, 0)
                * max(lhsIntersection.height, 0)
            let rhsArea = max(rhsIntersection.width, 0)
                * max(rhsIntersection.height, 0)
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            return squaredDistance(from: frame.center, to: lhs.center)
                > squaredDistance(from: frame.center, to: rhs.center)
        } ?? visibleFrames[0]

        let maximumWidth = max(target.width - margin * 2, 1)
        let maximumHeight = max(target.height - margin * 2, 1)
        let size = NSSize(
            width: min(frame.width, maximumWidth),
            height: min(frame.height, maximumHeight)
        )
        let minimumX = target.minX + margin
        let maximumX = max(minimumX, target.maxX - margin - size.width)
        let minimumY = target.minY + margin
        let maximumY = max(minimumY, target.maxY - margin - size.height)

        return NSRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: size.width,
            height: size.height
        )
    }

    private func installPresentations() {
        let fullRoot = SystemDesignRoomView(
            model: model,
            onCollapse: { [weak self] in self?.collapse() }
        )
        fullHostingController = NSHostingController(rootView: fullRoot)
        fullContainerController = FullRoomContainerController(
            hostingController: fullHostingController
        )

        let full = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        full.title = "Interview Arc Live"
        full.titleVisibility = .hidden
        full.titlebarAppearsTransparent = true
        full.isReleasedWhenClosed = false
        full.contentMinSize = NSSize(width: 1_080, height: 700)
        full.animationBehavior = .none
        full.contentViewController = fullContainerController
        full.delegate = self
        full.identifier = NSUserInterfaceItemIdentifier("interview-room-full")
        full.setAccessibilityIdentifier("interview-room-full")
        full.setAccessibilityLabel("Interview Arc Live full interview room")
        let restoredFrame = full.setFrameUsingName(frameAutosaveName)
        _ = full.setFrameAutosaveName(frameAutosaveName)
        if !restoredFrame {
            full.center()
        }
        fullWindow = full
        savedFullFrame = full.frame

        let compactRoot = CompactSystemDesignRoomView(
            model: model,
            onExpand: { [weak self] in self?.expand() }
        )
        compactHostingController = CompactRoomHostingController(
            rootView: compactRoot
        )
        compactHostingController.sizingOptions = [.intrinsicContentSize]
        compactHostingController.onLayout = { [weak self] in
            self?.scheduleCompactPanelSizeReconciliation()
        }

        let panel = NonactivatingInterviewPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CompactPanelLayout.contentWidth,
                height: CompactPanelLayout.minimumContentHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Interview Arc Live compact interview controls"
        panel.contentViewController = compactHostingController
        panel.contentMinSize = NSSize(
            width: CompactPanelLayout.contentWidth,
            height: CompactPanelLayout.minimumContentHeight
        )
        panel.contentMaxSize = NSSize(
            width: CompactPanelLayout.contentWidth,
            height: CompactPanelLayout.maximumContentHeight
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenNone]
        panel.animationBehavior = .none
        panel.delegate = self
        panel.identifier = NSUserInterfaceItemIdentifier("interview-room-compact")
        panel.setAccessibilityIdentifier("interview-room-compact")
        panel.setAccessibilityLabel(
            "Interview Arc Live compact interview controls"
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 22
        panel.contentView?.layer?.masksToBounds = true
        compactPanel = panel
        reconcileCompactPanelSize()
        placeCompactPanelInitially()
    }

    private func registerLifecycleObservers() {
        guard !didRegisterObservers else { return }
        didRegisterObservers = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    private func showFullPresentation(activating: Bool) {
        let frameToRestore = savedFullFrame ?? fullWindow.frame
        compactPanel.orderOut(nil)
        if fullWindow.isMiniaturized {
            fullWindow.deminiaturize(nil)
        }
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
        fullWindow.makeKeyAndOrderFront(nil)
        fullWindow.makeMain()
        clampFullWindowToVisibleScreens(source: frameToRestore)
        restoreFullFirstResponder(preferred: savedFullFirstResponder)
        presentationState = .full
    }

    private func captureFullPresentationState() {
        guard fullWindow != nil else { return }
        if !fullWindow.isMiniaturized {
            savedFullFrame = fullWindow.frame
        }
        if let responder = fullWindow.firstResponder {
            savedFullFirstResponder = responder
        }
    }

    private func restoreFullFirstResponder(
        preferred: NSResponder?
    ) {
        if let preferred,
           fullWindow.makeFirstResponder(preferred) {
            savedFullFirstResponder = preferred
            return
        }
        _ = fullWindow.makeFirstResponder(
            fullContainerController.fallbackFirstResponder
        )
        savedFullFirstResponder = fullContainerController.fallbackFirstResponder
    }

    private func presentCloseGuardIfNeeded() {
        guard closeAlert == nil else { return }
        closeGuardFirstResponder = fullWindow.firstResponder

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "What should happen to this interview?"
        alert.informativeText = "Closing the full room does not silently end "
            + "an unfinished interview. Keep the same room available in "
            + "compact controls, end it safely, or cancel."
        alert.addButton(withTitle: "Continue compact")
        alert.addButton(withTitle: "End interview")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[2].keyEquivalent = "\u{1b}"
        closeAlert = alert

        alert.beginSheetModal(for: fullWindow) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                closeAlert = nil
                let choice: InterviewRoomCloseChoice
                switch response {
                case .alertFirstButtonReturn:
                    choice = .continueCompact
                case .alertSecondButtonReturn:
                    choice = .endInterview
                default:
                    choice = .cancel
                }
                await resolveCloseChoice(choice)
            }
        }
    }

    private func placeCompactPanelInitially() {
        let visibleFrame = fullWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        var frame = compactPanel.frame
        frame.origin = NSPoint(
            x: visibleFrame.maxX - frame.width - 24,
            y: visibleFrame.maxY - frame.height - 24
        )
        setCompactPanelFrame(
            Self.clampedFrame(frame, to: NSScreen.screens.map(\.visibleFrame))
        )
    }

    private func clampPresentationFramesToVisibleScreens() {
        clampFullWindowToVisibleScreens()
        clampCompactPanelToVisibleScreens()
    }

    private func clampFullWindowToVisibleScreens(source: NSRect? = nil) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }
        let frame = source ?? savedFullFrame ?? fullWindow.frame
        let clamped = Self.clampedFrame(frame, to: visibleFrames)
        isAdjustingFrames = true
        fullWindow.setFrame(clamped, display: fullWindow.isVisible)
        isAdjustingFrames = false
        savedFullFrame = fullWindow.frame
    }

    private func clampCompactPanelToVisibleScreens() {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }
        var source = compactPanel.frame
        if let savedCompactOrigin {
            source.origin = savedCompactOrigin
        }
        setCompactPanelFrame(Self.clampedFrame(source, to: visibleFrames))
    }

    private func scheduleCompactPanelSizeReconciliation() {
        guard compactPanel != nil,
              presentationState != .terminated else {
            return
        }
        compactSizeReconciliationTask?.cancel()
        compactSizeReconciliationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.reconcileCompactPanelSize()
        }
    }

    private func reconcileCompactPanelSize() {
        guard compactPanel != nil,
              presentationState != .terminated else {
            return
        }
        let measuredSize = compactHostingController.sizeThatFits(
            in: NSSize(
                width: CompactPanelLayout.contentWidth,
                height: CompactPanelLayout.maximumContentHeight
            )
        )
        let resized = CompactPanelLayout.framePreservingTopEdge(
            compactPanel.frame,
            measuredContentHeight: measuredSize.height
        )
        let clamped = Self.clampedFrame(
            resized,
            to: NSScreen.screens.map(\.visibleFrame)
        )
        guard abs(compactPanel.frame.height - clamped.height) > 0.5
                || abs(compactPanel.frame.minX - clamped.minX) > 0.5
                || abs(compactPanel.frame.minY - clamped.minY) > 0.5 else {
            return
        }
        setCompactPanelFrame(clamped)
    }

    private func setCompactPanelFrame(_ frame: NSRect) {
        isAdjustingFrames = true
        compactPanel.setFrame(frame, display: compactPanel.isVisible)
        isAdjustingFrames = false
        savedCompactOrigin = compactPanel.frame.origin
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        clampPresentationFramesToVisibleScreens()
    }

    @objc
    private func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination()
    }

    private static func squaredDistance(
        from lhs: NSPoint,
        to rhs: NSPoint
    ) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private final class NonactivatingInterviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CompactRoomHostingController:
    NSHostingController<CompactSystemDesignRoomView>
{
    var onLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
    }
}

private final class FullRoomContainerController: NSViewController {
    let hostingController: NSHostingController<SystemDesignRoomView>
    let fallbackFirstResponder = StableFallbackFirstResponderView()

    init(hostingController: NSHostingController<SystemDesignRoomView>) {
        self.hostingController = hostingController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        addChild(hostingController)
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        fallbackFirstResponder.translatesAutoresizingMaskIntoConstraints = false
        fallbackFirstResponder.setAccessibilityElement(false)

        container.addSubview(fallbackFirstResponder)
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fallbackFirstResponder.leadingAnchor.constraint(
                equalTo: container.leadingAnchor
            ),
            fallbackFirstResponder.topAnchor.constraint(equalTo: container.topAnchor),
            fallbackFirstResponder.widthAnchor.constraint(equalToConstant: 1),
            fallbackFirstResponder.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
}

private final class StableFallbackFirstResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
