import AppKit
import XCTest

@testable import InterviewArcLive

@MainActor
final class InterviewRoomPresentationCoordinatorTests: XCTestCase {
    func testCompactPanelUsesToolPaletteScale() {
        XCTAssertEqual(CompactPanelLayout.contentWidth, 580)
        XCTAssertEqual(CompactPanelLayout.minimumContentHeight, 82)
        XCTAssertEqual(CompactPanelLayout.maximumContentHeight, 180)
    }

    func testCoordinatorOwnsOneFullWindowAndOneNonactivatingPanelWithSharedModel() {
        let model = SystemDesignRoomModel()
        let coordinator = makeCoordinator(model: model)
        defer { coordinator.prepareForTermination() }

        XCTAssertEqual(coordinator.presentationState, .notStarted)
        XCTAssertFalse(coordinator.didRequestModelOpen)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertEqual(
            coordinator.fullHostedModelIdentity,
            ObjectIdentifier(model)
        )
        XCTAssertEqual(
            coordinator.compactHostedModelIdentity,
            ObjectIdentifier(model)
        )
        XCTAssertTrue(
            coordinator.compactPanel.styleMask.contains(.nonactivatingPanel)
        )
        XCTAssertTrue(coordinator.compactPanel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(coordinator.compactPanel.canBecomeKey)
        XCTAssertFalse(coordinator.compactPanel.canBecomeMain)
        XCTAssertFalse(
            coordinator.compactPanel.collectionBehavior.contains(.canJoinAllSpaces)
        )
        XCTAssertFalse(
            coordinator.compactPanel.collectionBehavior.contains(.fullScreenAuxiliary)
        )
        XCTAssertTrue(
            coordinator.compactPanel.collectionBehavior.contains(.fullScreenNone)
        )
        XCTAssertEqual(
            coordinator.compactPanel.contentMinSize,
            NSSize(
                width: CompactPanelLayout.contentWidth,
                height: CompactPanelLayout.minimumContentHeight
            )
        )
        XCTAssertEqual(
            coordinator.compactPanel.contentMaxSize,
            NSSize(
                width: CompactPanelLayout.contentWidth,
                height: CompactPanelLayout.maximumContentHeight
            )
        )
    }

    func testScreenChangeCallbackCannotReenterAnActiveFrameAdjustment() {
        let frameAdjustmentGuard = PresentationFrameAdjustmentGuard()
        var adjustmentCount = 0
        var screenChangeCallback: (() -> Void)!

        screenChangeCallback = {
            guard !frameAdjustmentGuard.isActive else { return }
            frameAdjustmentGuard.perform {
                adjustmentCount += 1
                // NSWindow frame restoration can synchronously send the same
                // screen-change callback before setFrame returns.
                screenChangeCallback()
            }
        }

        screenChangeCallback()

        XCTAssertEqual(adjustmentCount, 1)
        XCTAssertFalse(frameAdjustmentGuard.isActive)
    }

    func testCollapseAndExpandRetainWindowsHostingTreesFrameAndFocus() throws {
        let coordinator = makeCoordinator()
        defer { coordinator.prepareForTermination() }
        let fullWindowIdentity = ObjectIdentifier(coordinator.fullWindow)
        let panelIdentity = ObjectIdentifier(coordinator.compactPanel)
        let fullTreeIdentity = coordinator.fullHostingTreeIdentity
        let compactTreeIdentity = coordinator.compactHostingTreeIdentity

        coordinator.expand()
        let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let requestedFrame = NSRect(
            x: visibleFrame.minX + 30,
            y: visibleFrame.minY + 30,
            width: min(1_180, visibleFrame.width - 60),
            height: min(760, visibleFrame.height - 60)
        )
        coordinator.fullWindow.setFrame(requestedFrame, display: false)
        let retainedFrame = coordinator.fullWindow.frame
        XCTAssertTrue(
            coordinator.fullWindow.makeFirstResponder(
                coordinator.fallbackFirstResponder
            )
        )

        coordinator.collapse()
        coordinator.collapse()
        XCTAssertEqual(coordinator.presentationState, .compact)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertTrue(coordinator.compactPanel.isVisible)

        coordinator.expand()
        coordinator.expand()
        XCTAssertEqual(coordinator.presentationState, .full)
        XCTAssertTrue(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertEqual(ObjectIdentifier(coordinator.fullWindow), fullWindowIdentity)
        XCTAssertEqual(ObjectIdentifier(coordinator.compactPanel), panelIdentity)
        XCTAssertEqual(coordinator.fullHostingTreeIdentity, fullTreeIdentity)
        XCTAssertEqual(coordinator.compactHostingTreeIdentity, compactTreeIdentity)
        XCTAssertEqual(coordinator.fullWindow.frame, retainedFrame)
        XCTAssertTrue(
            coordinator.fullWindow.firstResponder
                === coordinator.fallbackFirstResponder
        )
    }

    func testContinueCompactAndCancelUseRetainedPresentation() async {
        let coordinator = makeCoordinator()
        defer { coordinator.prepareForTermination() }
        coordinator.expand()
        let fullIdentity = ObjectIdentifier(coordinator.fullWindow)

        await coordinator.resolveCloseChoice(.cancel)
        XCTAssertEqual(coordinator.presentationState, .full)
        XCTAssertTrue(coordinator.fullWindow.isVisible)

        await coordinator.resolveCloseChoice(.continueCompact)
        XCTAssertEqual(coordinator.presentationState, .compact)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertTrue(coordinator.compactPanel.isVisible)
        XCTAssertEqual(ObjectIdentifier(coordinator.fullWindow), fullIdentity)
    }

    func testFailedEndLeavesFullRoomVisibleAndFocusIntact() async {
        let coordinator = makeCoordinator()
        defer { coordinator.prepareForTermination() }
        coordinator.expand()
        XCTAssertTrue(
            coordinator.fullWindow.makeFirstResponder(
                coordinator.fallbackFirstResponder
            )
        )

        // This unopened model has no coordinator to finish. The presentation
        // must fail closed without creating production session dependencies.
        await coordinator.resolveCloseChoice(.endInterview)

        XCTAssertEqual(coordinator.presentationState, .full)
        XCTAssertTrue(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertTrue(
            coordinator.fullWindow.firstResponder
                === coordinator.fallbackFirstResponder
        )
    }

    func testEndSerializesCloseChoicesAndPresentationTransitions() async throws {
        let fixture = try await makeCompletionBlockingRoomModel()
        let coordinator = makeCoordinator(model: fixture.model)
        defer { coordinator.prepareForTermination() }
        coordinator.expand()
        XCTAssertTrue(
            coordinator.fullWindow.makeFirstResponder(
                coordinator.fallbackFirstResponder
            )
        )

        let endChoice = Task { @MainActor in
            await coordinator.resolveCloseChoice(.endInterview)
        }
        await fixture.store.waitUntilCompletionSaveStarts()
        XCTAssertTrue(coordinator.isResolvingCloseChoice)
        XCTAssertEqual(coordinator.presentationState, .full)

        await coordinator.resolveCloseChoice(.cancel)
        await coordinator.resolveCloseChoice(.continueCompact)
        coordinator.collapse()
        coordinator.reopen()
        coordinator.requestFullWindowClose()

        XCTAssertEqual(coordinator.presentationState, .full)
        XCTAssertTrue(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertFalse(coordinator.isCloseGuardPresented)
        let suspendedSaveCount = await fixture.store.completionSaveCount()
        XCTAssertEqual(suspendedSaveCount, 1)

        await fixture.store.releaseCompletionSave()
        await endChoice.value

        XCTAssertFalse(coordinator.isResolvingCloseChoice)
        XCTAssertEqual(coordinator.presentationState, .closed)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        let finalSaveCount = await fixture.store.completionSaveCount()
        XCTAssertEqual(finalSaveCount, 1)
    }

    func testTerminationWinsWhenSuspendedEndChoiceResumes() async throws {
        let fixture = try await makeCompletionBlockingRoomModel()
        let coordinator = makeCoordinator(model: fixture.model)
        coordinator.expand()

        let endChoice = Task { @MainActor in
            await coordinator.resolveCloseChoice(.endInterview)
        }
        await fixture.store.waitUntilCompletionSaveStarts()
        coordinator.prepareForTermination()
        await fixture.store.releaseCompletionSave()
        await endChoice.value

        XCTAssertEqual(coordinator.presentationState, .terminated)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertFalse(coordinator.isResolvingCloseChoice)
    }

    func testReopenRoutesToExistingWindowAndTerminationOnlyTearsDownPresentation() {
        let coordinator = makeCoordinator()
        let fullIdentity = ObjectIdentifier(coordinator.fullWindow)
        let panelIdentity = ObjectIdentifier(coordinator.compactPanel)

        coordinator.collapse()
        coordinator.reopen()
        XCTAssertEqual(coordinator.presentationState, .full)
        XCTAssertEqual(ObjectIdentifier(coordinator.fullWindow), fullIdentity)
        XCTAssertEqual(ObjectIdentifier(coordinator.compactPanel), panelIdentity)

        coordinator.prepareForTermination()
        coordinator.prepareForTermination()
        XCTAssertEqual(coordinator.presentationState, .terminated)
        XCTAssertFalse(coordinator.fullWindow.isVisible)
        XCTAssertFalse(coordinator.compactPanel.isVisible)
        XCTAssertFalse(coordinator.didRequestModelOpen)
    }

    func testClampedFrameKeepsMovedPanelInsideRemainingDisplay() {
        let removedDisplayFrame = NSRect(x: 2_000, y: 200, width: 640, height: 254)
        let remainingVisibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)

        let clamped = InterviewRoomPresentationCoordinator.clampedFrame(
            removedDisplayFrame,
            to: [remainingVisibleFrame]
        )

        XCTAssertGreaterThanOrEqual(clamped.minX, remainingVisibleFrame.minX + 12)
        XCTAssertGreaterThanOrEqual(clamped.minY, remainingVisibleFrame.minY + 12)
        XCTAssertLessThanOrEqual(clamped.maxX, remainingVisibleFrame.maxX - 12)
        XCTAssertLessThanOrEqual(clamped.maxY, remainingVisibleFrame.maxY - 12)
        XCTAssertEqual(clamped.size, removedDisplayFrame.size)
    }

    func testCompactPanelSizingIsBoundedAndPreservesTopEdge() {
        XCTAssertEqual(CompactPanelLayout.boundedContentHeight(50), 82)
        XCTAssertEqual(CompactPanelLayout.boundedContentHeight(120), 120)
        XCTAssertEqual(CompactPanelLayout.boundedContentHeight(600), 180)

        let original = NSRect(x: 100, y: 200, width: 700, height: 254)
        let resized = CompactPanelLayout.framePreservingTopEdge(
            original,
            measuredContentHeight: 120
        )

        XCTAssertEqual(resized.width, 580)
        XCTAssertEqual(resized.height, 120)
        XCTAssertEqual(resized.maxY, original.maxY)
    }

    func testGrowingCompactPanelRemainsInsideVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let panelNearBottom = NSRect(x: 780, y: 20, width: 580, height: 82)
        let resized = CompactPanelLayout.framePreservingTopEdge(
            panelNearBottom,
            measuredContentHeight: 600
        )

        let clamped = InterviewRoomPresentationCoordinator.clampedFrame(
            resized,
            to: [visibleFrame]
        )

        XCTAssertGreaterThanOrEqual(clamped.minX, visibleFrame.minX + 12)
        XCTAssertGreaterThanOrEqual(clamped.minY, visibleFrame.minY + 12)
        XCTAssertLessThanOrEqual(clamped.maxX, visibleFrame.maxX - 12)
        XCTAssertLessThanOrEqual(clamped.maxY, visibleFrame.maxY - 12)
        XCTAssertEqual(clamped.size, NSSize(width: 580, height: 180))
    }

    private func makeCoordinator(
        model: SystemDesignRoomModel = SystemDesignRoomModel()
    ) -> InterviewRoomPresentationCoordinator {
        _ = NSApplication.shared
        return InterviewRoomPresentationCoordinator(
            model: model,
            frameAutosaveName: "InterviewArcLiveTests.TransientFrame"
        )
    }
}
