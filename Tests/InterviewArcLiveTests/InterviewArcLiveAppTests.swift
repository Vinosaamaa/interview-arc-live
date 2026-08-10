import AppKit
import XCTest

@testable import InterviewArcLive

@MainActor
final class InterviewArcLiveAppTests: XCTestCase {
    func testHandledDockReopenSuppressesDefaultAppKitReopen() {
        let delegate = InterviewArcLiveApp()
        let application = NSApplication.shared

        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(
                application,
                hasVisibleWindows: false
            )
        )
        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(
                application,
                hasVisibleWindows: true
            )
        )
    }

    func testMainMenuRestoresStandardEditResponderActions() throws {
        let delegate = InterviewArcLiveApp()
        let application = NSApplication.shared
        let previousServicesMenu = application.servicesMenu
        let previousWindowsMenu = application.windowsMenu
        defer {
            application.servicesMenu = previousServicesMenu
            application.windowsMenu = previousWindowsMenu
        }

        let mainMenu = delegate.makeMainMenu()

        XCTAssertEqual(
            mainMenu.items.compactMap { $0.submenu?.title },
            ["Interview Arc Live", "File", "Edit", "Window"]
        )
        let editMenu = try XCTUnwrap(
            mainMenu.items.first { $0.submenu?.title == "Edit" }?.submenu
        )
        let actions = editMenu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(
            actions.map(\.title),
            [
                "Undo",
                "Redo",
                "Cut",
                "Copy",
                "Paste",
                "Paste and Match Style",
                "Delete",
                "Select All",
            ]
        )
        XCTAssertEqual(
            actions.map { $0.action.map(NSStringFromSelector) },
            [
                "undo:",
                "redo:",
                "cut:",
                "copy:",
                "paste:",
                "pasteAsPlainText:",
                "delete:",
                "selectAll:",
            ]
        )
        XCTAssertTrue(actions.allSatisfy { $0.target == nil })
        XCTAssertEqual(actions[0].keyEquivalent, "z")
        XCTAssertEqual(actions[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(actions[1].keyEquivalent, "z")
        XCTAssertEqual(
            actions[1].keyEquivalentModifierMask,
            [.command, .shift]
        )
        XCTAssertEqual(actions[2].keyEquivalent, "x")
        XCTAssertEqual(actions[3].keyEquivalent, "c")
        XCTAssertEqual(actions[4].keyEquivalent, "v")
        XCTAssertEqual(
            actions[5].keyEquivalentModifierMask,
            [.command, .option, .shift]
        )
        XCTAssertEqual(actions[6].keyEquivalentModifierMask, [])
        XCTAssertEqual(actions[7].keyEquivalent, "a")
    }
}
