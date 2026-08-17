import AppKit
import SwiftUI

@MainActor
final class BehavioralRoomWindowController: NSWindowController, NSWindowDelegate {
    let model: BehavioralRoomModel

    init(model: BehavioralRoomModel = BehavioralRoomModel()) {
        self.model = model
        let hosting = NSHostingController(
            rootView: BehavioralRoomView(model: model)
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: InterviewRoomWindowLayout.fullDefaultContentSize
            ),
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
        window.title = "Behavioral Room (local)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = InterviewRoomWindowLayout.fullMinimumContentSize
        window.contentViewController = hosting
        window.identifier = NSUserInterfaceItemIdentifier("behavioral-room-full")
        window.setAccessibilityIdentifier("behavioral-room-full")
        window.setAccessibilityLabel("Interview Arc Live Behavioral room")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeMain()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
