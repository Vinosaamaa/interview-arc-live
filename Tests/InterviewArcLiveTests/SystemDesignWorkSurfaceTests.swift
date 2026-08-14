import Foundation
import XCTest

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class SystemDesignWorkSurfaceTests: XCTestCase {
    func testPaneSelectionPersistsAndBriefUsesExactPrompt() async throws {
        let suiteName = "InterviewArcLiveTests.work-surface.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let (model, _) = try await makeCompletionBlockingRoomModel(
            preferences: preferences
        )

        model.selectWorkSurface(.notes)

        XCTAssertEqual(model.selectedWorkSurface, .notes)
        XCTAssertEqual(model.activityPromptForPresentation.specialty, .systemDesign)
        XCTAssertEqual(
            model.activityPromptForPresentation.stage,
            "High-level design"
        )
        XCTAssertEqual(
            model.activityPromptForPresentation.question,
            "Design a public-safe notification service."
        )
        XCTAssertEqual(
            model.activityPromptForPresentation.requestedParts,
            ["Clarify requirements."]
        )
        let restoredPreference = SystemDesignRoomModel(
            codexRuntime: WorkSurfaceCodexRuntime(),
            preferences: preferences,
            boardArtifactStore: nil
        )
        XCTAssertEqual(restoredPreference.selectedWorkSurface, .notes)
        XCTAssertFalse(restoredPreference.canEditCandidateNotes)
        restoredPreference.updateCandidateNotesDraft("Must not edit while restoring")
        XCTAssertTrue(restoredPreference.candidateNotesDraft.isEmpty)
    }

    func testLatestNotesAreDurableBeforeSavedStatus() async throws {
        let (model, store) = try await makeCompletionBlockingRoomModel()

        model.updateCandidateNotesDraft("First assumption")
        model.updateCandidateNotesDraft("Latest assumption · multi-region")
        await model.waitForCandidateNotesPersistence()

        XCTAssertEqual(
            model.snapshot?.candidateNotes.body,
            "Latest assumption · multi-region"
        )
        XCTAssertEqual(model.candidateNotesSavePresentation, .saved)
        let sessionID = try XCTUnwrap(model.snapshot?.sessionID)
        let durable = try await store.load(sessionID: sessionID)
        XCTAssertEqual(
            durable?.candidateNotes.body,
            "Latest assumption · multi-region"
        )
    }

    func testBoardAndNotesWritesSerializeAndTerminationWaitsForBoth() async throws {
        let (model, store) = try await makeCompletionBlockingRoomModel()
        await store.holdNextBoardRevisionSave()

        XCTAssertTrue(
            model.applyBoardAction(
                .createLabel(
                    origin: BoardPoint(x: 80, y: 80),
                    text: "Durable boundary"
                )
            )
        )
        await store.waitUntilBoardRevisionSaveStarts()
        model.updateCandidateNotesDraft("Keep the queue idempotent.")

        let termination = Task { @MainActor in
            await model.prepareLocalPersistenceForTermination()
        }
        await Task.yield()
        XCTAssertTrue(model.isBoardSaving)
        XCTAssertEqual(model.candidateNotesSavePresentation, .saving)

        await store.releaseBoardRevisionSave()
        let shouldTerminate = await termination.value
        XCTAssertTrue(shouldTerminate)
        XCTAssertEqual(model.snapshot?.board.draft, model.boardEditor.document)
        XCTAssertEqual(
            model.snapshot?.candidateNotes.body,
            "Keep the queue idempotent."
        )
        XCTAssertEqual(model.candidateNotesSavePresentation, .saved)

        let sessionID = try XCTUnwrap(model.snapshot?.sessionID)
        let durable = try await store.load(sessionID: sessionID)
        XCTAssertEqual(durable?.board.draft, model.boardEditor.document)
        XCTAssertEqual(
            durable?.candidateNotes.body,
            "Keep the queue idempotent."
        )
    }

    func testNotesCannotAcceptUnretryableTextDuringCompletion() async throws {
        let (model, store) = try await makeCompletionBlockingRoomModel()
        model.updateCandidateNotesDraft("Persist before completion")
        await model.waitForCandidateNotesPersistence()

        let finishing = Task { @MainActor in
            await model.finishInterview()
        }
        await store.waitUntilCompletionSaveStarts()

        XCTAssertTrue(model.isFinishingInterview)
        XCTAssertFalse(model.canEditCandidateNotes)
        model.updateCandidateNotesDraft("Must not be accepted")
        XCTAssertEqual(model.candidateNotesDraft, "Persist before completion")

        await store.releaseCompletionSave()
        let didFinish = await finishing.value
        XCTAssertTrue(didFinish)
        XCTAssertEqual(model.snapshot?.phase, .completed)
        XCTAssertEqual(
            model.snapshot?.candidateNotes.body,
            "Persist before completion"
        )
    }

    func testOversizedNotesPreserveTheLastAcceptedDraft() async throws {
        let (model, _) = try await makeCompletionBlockingRoomModel()
        model.updateCandidateNotesDraft("Keep this")
        await model.waitForCandidateNotesPersistence()

        model.updateCandidateNotesDraft(
            String(repeating: "a", count: CandidateNotes.maximumBodyUTF8Bytes + 1)
        )

        XCTAssertEqual(model.candidateNotesDraft, "Keep this")
        guard case .error(let message) = model.candidateNotesSavePresentation else {
            return XCTFail("Expected a bounded Notes error")
        }
        XCTAssertTrue(message.contains("16 KB"))
    }
}

private struct WorkSurfaceCodexRuntime: LiveCodexInterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness { .ready }

    func respond(
        to request: InterviewerRequest
    ) -> CanonicalInterviewerResponse {
        CanonicalInterviewerResponse(
            displayMarkdown: "What trade-off comes next?",
            spokenText: "What trade-off comes next?"
        )
    }
}
