import XCTest

import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class SystemDesignRoomFinishTests: XCTestCase {
    func testFinishInterviewFailsClosedWithoutMutatingWhileWorkIsInFlight() async throws {
        let fixture = try await makeCompletionBlockingRoomModel()
        let model = fixture.model
        let store = fixture.store

        let firstFinish = Task { @MainActor in
            await model.finishInterview()
        }
        await store.waitUntilCompletionSaveStarts()

        let statusBeforeSecondAttempt = model.statusMessage
        let errorBeforeSecondAttempt = model.errorMessage
        let snapshotBeforeSecondAttempt = model.snapshot
        XCTAssertTrue(model.isWorking)

        let secondResult = await model.finishInterview()

        XCTAssertFalse(secondResult)
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.statusMessage, statusBeforeSecondAttempt)
        XCTAssertEqual(model.errorMessage, errorBeforeSecondAttempt)
        XCTAssertEqual(model.snapshot, snapshotBeforeSecondAttempt)
        let saveCountWhileSuspended = await store.completionSaveCount()
        XCTAssertEqual(saveCountWhileSuspended, 1)

        await store.releaseCompletionSave()
        let firstResult = await firstFinish.value
        XCTAssertTrue(firstResult)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.snapshot?.phase, .completed)
        let finalSaveCount = await store.completionSaveCount()
        XCTAssertEqual(finalSaveCount, 1)
    }
}
