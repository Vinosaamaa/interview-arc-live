import AppKit

@MainActor
final class InterviewArcLiveTerminationGate {
    typealias Preparation = @MainActor () async -> Bool

    private let preparation: Preparation
    private var preparationTask: Task<Void, Never>?

    init(preparation: @escaping Preparation) {
        self.preparation = preparation
    }

    func requestTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard preparationTask == nil else { return .terminateLater }
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let shouldTerminate = await preparation()
            preparationTask = nil
            reply(shouldTerminate)
        }
        return .terminateLater
    }
}

@main
@MainActor
final class InterviewArcLiveApp: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: InterviewArcLiveApp?

    private let model = SystemDesignRoomModel()
    private var presentationCoordinator: InterviewRoomPresentationCoordinator?
    private var terminationGate: InterviewArcLiveTerminationGate?

    static func main() {
        let application = NSApplication.shared
        let delegate = InterviewArcLiveApp()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        retainedDelegate = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        terminationGate = InterviewArcLiveTerminationGate { [weak model] in
            await model?.prepareBoardForTermination() ?? true
        }
        let coordinator = InterviewRoomPresentationCoordinator(model: model)
        presentationCoordinator = coordinator
        coordinator.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentationCoordinator?.reopen()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let terminationGate else { return .terminateNow }
        return terminationGate.requestTermination { [weak sender] shouldTerminate in
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        presentationCoordinator?.prepareForTermination()
    }

    @objc
    private func showInterviewRoom(_ sender: Any?) {
        presentationCoordinator?.reopen()
    }

    @objc
    private func closeInterviewRoom(_ sender: Any?) {
        presentationCoordinator?.requestFullWindowClose()
    }

    private func installMainMenu() {
        NSApp.mainMenu = makeMainMenu()
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    private func applicationMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Interview Arc Live")
        root.submenu = menu

        menu.addItem(
            NSMenuItem(
                title: "About Interview Arc Live",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Hide Interview Arc Live",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"
            )
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Interview Arc Live",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        return root
    }

    private func fileMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "File")
        root.submenu = menu

        let close = NSMenuItem(
            title: "Close Interview Room",
            action: #selector(closeInterviewRoom(_:)),
            keyEquivalent: "w"
        )
        close.target = self
        menu.addItem(close)
        return root
    }

    private func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        root.submenu = menu

        menu.addItem(
            responderMenuItem(
                title: "Undo",
                action: Selector(("undo:")),
                keyEquivalent: "z"
            )
        )
        menu.addItem(
            responderMenuItem(
                title: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            responderMenuItem(
                title: "Cut",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x"
            )
        )
        menu.addItem(
            responderMenuItem(
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c"
            )
        )
        menu.addItem(
            responderMenuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v"
            )
        )
        menu.addItem(
            responderMenuItem(
                title: "Paste and Match Style",
                action: #selector(NSTextView.pasteAsPlainText(_:)),
                keyEquivalent: "v",
                modifiers: [.command, .option, .shift]
            )
        )
        menu.addItem(
            responderMenuItem(
                title: "Delete",
                action: #selector(NSText.delete(_:)),
                keyEquivalent: "\u{8}",
                modifiers: []
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            responderMenuItem(
                title: "Select All",
                action: #selector(NSResponder.selectAll(_:)),
                keyEquivalent: "a"
            )
        )
        return root
    }

    private func responderMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Window")
        root.submenu = menu

        menu.addItem(
            NSMenuItem(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""
            )
        )
        menu.addItem(.separator())
        let show = NSMenuItem(
            title: "Show Interview Room",
            action: #selector(showInterviewRoom(_:)),
            keyEquivalent: "0"
        )
        show.target = self
        menu.addItem(show)
        NSApp.windowsMenu = menu
        return root
    }
}
