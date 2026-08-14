import Foundation
import XCTest
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class SystemDesignBoardModelTests: XCTestCase {
    func testTerminationFlushesEnhancedSceneAndAwaitsDurableBoardTail() async throws {
        let (model, store) = try await makeCompletionBlockingRoomModel()
        await store.holdNextBoardRevisionSave()
        let flusher = TerminationBoardFlusher { completion in
            XCTAssertTrue(
                model.applyBoardAction(
                    .createLabel(
                        origin: BoardPoint(x: 80, y: 80),
                        text: "Termination-safe edit"
                    )
                )
            )
            completion(true)
        }
        model.enhancedBoardBridgeController.attach(flusher)

        let preparation = Task { @MainActor in
            await model.prepareLocalPersistenceForTermination()
        }
        await store.waitUntilBoardRevisionSaveStarts()

        XCTAssertTrue(model.isBoardSaving)
        XCTAssertFalse(model.snapshot?.board.draft == model.boardEditor.document)

        await store.releaseBoardRevisionSave()
        let shouldTerminate = await preparation.value
        XCTAssertTrue(shouldTerminate)
        XCTAssertEqual(model.snapshot?.board.draft, model.boardEditor.document)
        XCTAssertEqual(model.snapshot?.phase, .ready)
    }

    func testTerminationCancelsWhenEnhancedSceneCannotBeAccepted() async throws {
        let (model, _) = try await makeCompletionBlockingRoomModel()
        let flusher = TerminationBoardFlusher { completion in
            completion(false)
        }
        model.enhancedBoardBridgeController.attach(flusher)

        let shouldTerminate = await model.prepareLocalPersistenceForTermination()
        XCTAssertFalse(shouldTerminate)
        XCTAssertEqual(model.snapshot?.phase, .ready)
        XCTAssertTrue(model.boardErrorMessage?.contains("Quit was cancelled") == true)
    }

    func testBoardRevisionSaveAvailabilityRequiresPublishedNonworkingRoom() {
        XCTAssertFalse(
            SystemDesignRoomModel.boardRevisionSaveIsAvailable(
                coordinatorIsAvailable: true,
                phase: nil,
                isWorking: false,
                isInspectingRevision: false,
                isSaving: false,
                isExporting: false
            )
        )
        XCTAssertFalse(
            SystemDesignRoomModel.boardRevisionSaveIsAvailable(
                coordinatorIsAvailable: true,
                phase: .candidateFloor,
                isWorking: true,
                isInspectingRevision: false,
                isSaving: false,
                isExporting: false
            )
        )
        XCTAssertTrue(
            SystemDesignRoomModel.boardRevisionSaveIsAvailable(
                coordinatorIsAvailable: true,
                phase: .candidateFloor,
                isWorking: false,
                isInspectingRevision: false,
                isSaving: false,
                isExporting: false
            )
        )
    }

    func testSaveRevisionFailsClosedAgainstConcurrentReentry() async throws {
        let (model, store) = try await makeCompletionBlockingRoomModel()
        model.applyBoardAction(
            .createLabel(
                origin: BoardPoint(x: 80, y: 80),
                text: "Capacity"
            )
        )
        await model.waitForBoardPersistence()
        await store.holdNextBoardRevisionSave()

        let firstSave = Task { @MainActor in
            await model.saveBoardRevision()
        }
        await store.waitUntilBoardRevisionSaveStarts()
        XCTAssertTrue(model.isBoardSaving)
        XCTAssertFalse(model.canSaveBoardRevision)

        await model.saveBoardRevision()
        let countWhileSuspended = await store.boardRevisionSaveCount()
        XCTAssertEqual(countWhileSuspended, 1)

        await store.releaseBoardRevisionSave()
        await firstSave.value
        XCTAssertFalse(model.isBoardSaving)
        XCTAssertEqual(model.snapshot?.board.revisions.count, 1)
        let finalCount = await store.boardRevisionSaveCount()
        XCTAssertEqual(finalCount, 1)
    }

    func testEditorDraftSaveAndHistoricalInspectionStayIndependent() async throws {
        let (model, _) = try await makeCompletionBlockingRoomModel()
        model.applyBoardAction(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 100, y: 120),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "Gateway",
                kind: .service
            )
        )
        await model.waitForBoardPersistence()
        XCTAssertEqual(model.snapshot?.board.draft, model.boardEditor.document)

        await model.saveBoardRevision()
        let revision = try XCTUnwrap(model.snapshot?.board.revisions.first)
        XCTAssertEqual(revision.document, model.boardEditor.document)

        let boxID = try XCTUnwrap(model.boardEditor.selectedElementID)
        model.applyBoardAction(.updateLabel(id: boxID, text: "Updated gateway"))
        await model.waitForBoardPersistence()
        let updatedDraft = model.boardEditor.document
        XCTAssertNotEqual(updatedDraft, revision.document)
        XCTAssertNil(model.boardAttachmentForHandOff)

        await model.saveBoardRevision()
        let second = try XCTUnwrap(model.snapshot?.board.revisions.last)
        XCTAssertNotEqual(second.id, revision.id)
        model.applyBoardAction(.updateLabel(id: boxID, text: "Latest gateway"))
        await model.waitForBoardPersistence()
        let latestDraft = model.boardEditor.document
        await model.saveBoardRevision()
        let latest = try XCTUnwrap(model.snapshot?.board.revisions.last)
        XCTAssertEqual(model.snapshot?.board.revisions.count, 3)
        XCTAssertEqual(latest.ordinal, 2)
        XCTAssertEqual(model.boardAttachmentForHandOff, .revision(latest.id))

        await model.inspectBoardRevision(revision.id)
        XCTAssertTrue(model.isInspectingBoardRevision)
        XCTAssertEqual(model.boardDocumentForPresentation, revision.document)
        XCTAssertEqual(model.boardEditor.document, latestDraft)
        XCTAssertEqual(model.boardRevisionStatus, "Viewing revision 1 · read-only")
        XCTAssertNil(model.boardSelectedElementIDForPresentation)
        XCTAssertEqual(model.boardAttachmentForHandOff, .revision(revision.id))
        XCTAssertEqual(
            model.currentBoardDraftAttachmentForHandOff,
            .revision(latest.id)
        )

        await model.returnToBoardDraft()
        XCTAssertFalse(model.isInspectingBoardRevision)
        XCTAssertEqual(model.boardDocumentForPresentation, latestDraft)
        XCTAssertEqual(model.boardSelectedElementIDForPresentation, boxID)
        XCTAssertEqual(model.boardAttachmentForHandOff, .revision(latest.id))

        model.applyBoardAction(.updateLabel(id: boxID, text: "Dirty gateway"))
        await model.waitForBoardPersistence()
        XCTAssertNil(model.boardAttachmentForHandOff)

        await model.inspectBoardRevision(revision.id)
        XCTAssertEqual(model.boardAttachmentForHandOff, .revision(revision.id))
        XCTAssertNil(model.currentBoardDraftAttachmentForHandOff)
    }

    func testExplicitExportRecordsOnlyACompletePrivateBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-board-model-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PrivateBoardArtifactStore(root: root)
        let (model, _) = try await makeCompletionBlockingRoomModel(
            boardArtifactStore: store
        )
        model.applyBoardAction(
            .createBox(
                frame: BoardRect(
                    origin: BoardPoint(x: 100, y: 120),
                    size: BoardSize(width: 180, height: 90)
                ),
                label: "Public service",
                kind: .service
            )
        )
        await model.waitForBoardPersistence()
        await model.saveBoardRevision()

        await model.exportSelectedBoardRevision()

        let operation = try XCTUnwrap(model.snapshot?.board.exports.last)
        let bundle = try XCTUnwrap(operation.bundle)
        let recovery = try await store.recover(
            identities: operation.artifactIdentities
        )
        XCTAssertEqual(operation.lifecycle, .ready)
        XCTAssertEqual(recovery, .complete(bundle))
        XCTAssertEqual(model.snapshot?.board.revisions.count, 1)

        await model.exportSelectedBoardRevision()

        let exports = try XCTUnwrap(model.snapshot?.board.exports)
        XCTAssertEqual(exports.count, 2)
        XCTAssertEqual(exports.map(\.lifecycle), [.ready, .ready])
        XCTAssertNotEqual(exports[0].id, exports[1].id)
        XCTAssertNotEqual(
            exports[0].artifactIdentities.source,
            exports[1].artifactIdentities.source
        )
        let secondRecovery = try await store.recover(
            identities: exports[1].artifactIdentities
        )
        XCTAssertEqual(secondRecovery, .complete(try XCTUnwrap(exports[1].bundle)))
    }

    func testFailedExportRetryCreatesFreshAuthorizationAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-board-retry-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FailFirstPromotionValidation()
        let store = PrivateBoardArtifactStore(
            root: root,
            postPromotionValidation: { url in try gate.validate(url) }
        )
        let (model, _) = try await makeCompletionBlockingRoomModel(
            boardArtifactStore: store
        )
        model.applyBoardAction(
            .createLabel(
                origin: BoardPoint(x: 80, y: 80),
                text: "Retry fixture"
            )
        )
        await model.waitForBoardPersistence()
        await model.saveBoardRevision()

        await model.exportSelectedBoardRevision()

        let failed = try XCTUnwrap(model.snapshot?.board.exports.last)
        XCTAssertEqual(failed.lifecycle, .failed)
        XCTAssertEqual(failed.failure?.reason, .storageFailed)

        await model.exportSelectedBoardRevision()

        let exports = try XCTUnwrap(model.snapshot?.board.exports)
        XCTAssertEqual(exports.count, 2)
        XCTAssertEqual(exports[0].lifecycle, .failed)
        XCTAssertEqual(exports[1].lifecycle, .ready)
        XCTAssertNotEqual(exports[0].id, exports[1].id)
        let recovery = try await store.recover(
            identities: exports[1].artifactIdentities
        )
        XCTAssertEqual(recovery, .complete(try XCTUnwrap(exports[1].bundle)))
    }

    func testRestoreAuditSurfacesDerivativeAndMissingBundleAttentionWithoutExporting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-board-restore-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PrivateBoardArtifactStore(root: root)
        let (model, _) = try await makeCompletionBlockingRoomModel(
            boardArtifactStore: store
        )
        model.applyBoardAction(
            .createLabel(
                origin: BoardPoint(x: 80, y: 80),
                text: "Recovery fixture"
            )
        )
        await model.waitForBoardPersistence()
        await model.saveBoardRevision()
        await model.exportSelectedBoardRevision()

        let workspace = try XCTUnwrap(model.snapshot?.board)
        let operation = try XCTUnwrap(workspace.exports.last)
        let exportCount = workspace.exports.count
        let svg = root.appendingPathComponent(operation.artifactIdentities.svg.rawValue)
        try Data("corrupt derivative".utf8).write(to: svg)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: svg.path
        )

        await model.recoverBoardArtifacts(in: workspace)

        XCTAssertTrue(model.boardErrorMessage?.contains("regeneration") == true)
        XCTAssertEqual(model.snapshot?.board.exports.count, exportCount)
        XCTAssertEqual(model.snapshot?.board.exports.last?.lifecycle, .ready)

        let directory = root
            .appendingPathComponent(operation.artifactIdentities.source.rawValue)
            .deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)

        await model.recoverBoardArtifacts(in: workspace)

        XCTAssertTrue(model.boardErrorMessage?.contains("missing") == true)
        XCTAssertEqual(model.snapshot?.board.exports.count, exportCount)
    }
}

@MainActor
private final class TerminationBoardFlusher: ExcalidrawBoardSceneFlushing {
    private let flush: (@escaping @MainActor (Bool) -> Void) -> Void

    init(flush: @escaping (@escaping @MainActor (Bool) -> Void) -> Void) {
        self.flush = flush
    }

    func flushPendingScene(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        flush(completion)
    }
}
