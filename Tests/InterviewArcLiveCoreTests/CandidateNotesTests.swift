import Foundation
import XCTest
@testable import InterviewArcLiveCore

final class CandidateNotesTests: XCTestCase {
    func testNotesAreBoundedByUTF8Bytes() throws {
        let exact = String(repeating: "é", count: CandidateNotes.maximumBodyUTF8Bytes / 2)
        XCTAssertEqual(try CandidateNotes(body: exact).body, exact)

        XCTAssertThrowsError(try CandidateNotes(body: exact + "é")) { error in
            XCTAssertEqual(
                error as? CandidateNotesValidationError,
                .bodyTooLong(maximumUTF8Bytes: CandidateNotes.maximumBodyUTF8Bytes)
            )
        }
    }

    func testNotesUpdateIsIdempotentAndSurvivesInterviewerTransitions() async throws {
        let store = InMemorySessionManifestStore()
        let runtime = NotesRuntime()
        let session = try await InterviewRoomSession.start(
            sessionID: SessionID("notes-session"),
            activityID: "notes-activity",
            activityPrompt: try prompt(),
            manifestStore: store,
            interviewerRuntime: runtime
        )
        let notes = try CandidateNotes(body: "Verify regional failover.")
        let command = InterviewRoomCommand.updateCandidateNotes(
            commandID: CommandID("notes-update-1"),
            notes: notes
        )

        let first = try await session.apply(command)
        let replay = try await session.apply(command)
        XCTAssertEqual(first.disposition, .accepted)
        XCTAssertEqual(replay.disposition, .alreadyApplied)
        XCTAssertEqual(replay.snapshot.revision, first.snapshot.revision)
        XCTAssertEqual(replay.snapshot.candidateNotes, notes)

        _ = try await session.execute(
            .giveCandidateFloor(commandID: CommandID("notes-floor"))
        )
        let completed = try await session.execute(
            .handOff(
                commandID: CommandID("notes-hand-off"),
                transcript: CandidateTranscript(
                    body: "The queue absorbs the burst.",
                    quality: .verified
                )
            )
        )

        XCTAssertEqual(completed.phase, .interviewerTurn)
        XCTAssertEqual(completed.candidateNotes, notes)
        let requests = await runtime.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertNotEqual(request.candidateTurn?.transcript.body, notes.body)
        XCTAssertFalse(request.activityPrompt.question.contains(notes.body))
        XCTAssertTrue(request.priorVisibleTurns.isEmpty)
    }

    func testLegacyManifestWithoutNotesDecodesEmpty() throws {
        let manifest = SessionManifest(
            sessionID: SessionID("legacy-notes"),
            activityID: "legacy-notes-activity",
            activityPrompt: try prompt(),
            phase: .ready,
            turnMode: .manual,
            turns: [],
            revision: 0,
            appliedCommands: []
        )
        let encoded = try JSONEncoder().encode(manifest)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "candidateNotes")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        XCTAssertEqual(
            try JSONDecoder().decode(SessionManifest.self, from: legacy).candidateNotes,
            .empty
        )
    }

    private func prompt() throws -> ActivityPrompt {
        try ActivityPrompt(
            specialty: .systemDesign,
            stage: "Architecture",
            question: "Design a public notification service.",
            requestedParts: ["Explain delivery reliability."]
        )
    }
}

private actor NotesRuntime: InterviewerRuntime {
    private var recordedRequests: [InterviewerRequest] = []

    func respond(to request: InterviewerRequest) -> CanonicalInterviewerResponse {
        recordedRequests.append(request)
        return CanonicalInterviewerResponse(
            displayMarkdown: "What trade-off comes next?",
            spokenText: "What trade-off comes next?"
        )
    }

    func requests() -> [InterviewerRequest] { recordedRequests }
}
