import Foundation
import XCTest

@testable import InterviewArcLiveCore

@MainActor
final class SessionManifestStoreTests: XCTestCase {
    func testInMemoryAdapterComparesExpectedRevisionAndRestoresLatestManifest() async throws {
        let sessionID = SessionID("public-test-session")
        let store = InMemorySessionManifestStore()
        let initial = manifest(sessionID: sessionID, revision: 0)
        let next = manifest(sessionID: sessionID, revision: 1, phase: .candidateFloor)

        try await store.save(initial, expectedRevision: nil)
        try await store.save(next, expectedRevision: 0)

        let restored = try await store.load(sessionID: sessionID)
        XCTAssertEqual(restored, next)

        do {
            try await store.save(
                manifest(sessionID: sessionID, revision: 2, phase: .completed),
                expectedRevision: 0
            )
            XCTFail("Expected a stale revision to be rejected")
        } catch let error as SessionManifestStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(expected: 0, actual: 1)
            )
        }

        let retained = try await store.load(sessionID: sessionID)
        XCTAssertEqual(retained, next)
    }

    func testFileAdapterAtomicallySavesAndRestoresLatestCompleteManifest() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID("public-file-round-trip")
        let store = FileSessionManifestStore(directoryURL: directory)
        let initial = manifest(sessionID: sessionID, revision: 0)
        let next = manifest(sessionID: sessionID, revision: 1, phase: .candidateFloor)

        try await store.save(initial, expectedRevision: nil)
        try await store.save(next, expectedRevision: 0)

        let relaunchedStore = FileSessionManifestStore(directoryURL: directory)
        let restored = try await relaunchedStore.load(sessionID: sessionID)
        XCTAssertEqual(restored, next)
    }

    func testFileAdapterRejectsStaleWriterWithoutChangingReadableManifest() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID("public-stale-writer")
        let store = FileSessionManifestStore(directoryURL: directory)
        let initial = manifest(sessionID: sessionID, revision: 0)
        let durable = manifest(sessionID: sessionID, revision: 1, phase: .candidateFloor)

        try await store.save(initial, expectedRevision: nil)
        try await store.save(durable, expectedRevision: 0)

        do {
            try await store.save(
                manifest(sessionID: sessionID, revision: 2, phase: .completed),
                expectedRevision: 0
            )
            XCTFail("Expected a stale writer conflict")
        } catch let error as SessionManifestStoreError {
            XCTAssertEqual(
                error,
                .revisionConflict(expected: 0, actual: 1)
            )
        }

        let retained = try await store.load(sessionID: sessionID)
        XCTAssertEqual(retained, durable)
    }

    func testReplacementFailurePreservesPriorCompleteManifest() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID("public-failed-replacement")
        let initial = manifest(sessionID: sessionID, revision: 0)
        let durableStore = FileSessionManifestStore(directoryURL: directory)
        try await durableStore.save(initial, expectedRevision: nil)

        let failingStore = FileSessionManifestStore(
            directoryURL: directory,
            replace: { _, _ in throw ReplacementFixtureError.expectedFailure }
        )

        do {
            try await failingStore.save(
                manifest(sessionID: sessionID, revision: 1, phase: .completed),
                expectedRevision: 0
            )
            XCTFail("Expected replacement to fail")
        } catch ReplacementFixtureError.expectedFailure {
            // Expected: the prepared file never replaced the durable manifest.
        }

        let relaunchedStore = FileSessionManifestStore(directoryURL: directory)
        let restored = try await relaunchedStore.load(sessionID: sessionID)
        XCTAssertEqual(restored, initial)
    }

    func testDistinctFileAdaptersSerializeRevisionCheckAndReplacement() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID("public-concurrent-writers")
        let initial = manifest(sessionID: sessionID, revision: 0)
        let firstCandidate = manifest(
            sessionID: sessionID,
            revision: 1,
            phase: .interviewerProcessing,
            candidateBody: "Candidate A"
        )
        let secondCandidate = manifest(
            sessionID: sessionID,
            revision: 1,
            phase: .interviewerProcessing,
            candidateBody: "Candidate B"
        )
        let firstStore = FileSessionManifestStore(directoryURL: directory)
        let secondStore = FileSessionManifestStore(directoryURL: directory)
        try await firstStore.save(initial, expectedRevision: nil)

        let outcomes = await withTaskGroup(
            of: ConcurrentSaveOutcome.self,
            returning: [ConcurrentSaveOutcome].self
        ) { group in
            group.addTask {
                do {
                    try await firstStore.save(firstCandidate, expectedRevision: 0)
                    return .saved
                } catch let error as SessionManifestStoreError {
                    if error == .revisionConflict(expected: 0, actual: 1) {
                        return .conflict
                    }
                    return .unexpected
                } catch {
                    return .unexpected
                }
            }
            group.addTask {
                do {
                    try await secondStore.save(secondCandidate, expectedRevision: 0)
                    return .saved
                } catch let error as SessionManifestStoreError {
                    if error == .revisionConflict(expected: 0, actual: 1) {
                        return .conflict
                    }
                    return .unexpected
                } catch {
                    return .unexpected
                }
            }

            var collected: [ConcurrentSaveOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        XCTAssertEqual(outcomes.filter { $0 == .saved }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .conflict }.count, 1)
        XCTAssertFalse(outcomes.contains(.unexpected))

        let loaded = try await firstStore.load(sessionID: sessionID)
        let durable = try XCTUnwrap(loaded)
        XCTAssertEqual(durable.revision, 1)
        XCTAssertEqual(durable.turns.count, 1)
        guard case .candidate(let candidate) = durable.turns[0] else {
            return XCTFail("Expected exactly one winning Candidate Turn")
        }
        XCTAssertTrue(["Candidate A", "Candidate B"].contains(candidate.transcript.body))

        let lockFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lock" }
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: lockFile.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testReplacementMustAdvanceRevision() async throws {
        let store = InMemorySessionManifestStore()
        let sessionID = SessionID("public-monotonic-revision")
        let initial = manifest(sessionID: sessionID, revision: 0)
        try await store.save(initial, expectedRevision: nil)

        do {
            try await store.save(initial, expectedRevision: 0)
            XCTFail("Expected a non-monotonic replacement to fail")
        } catch let error as SessionManifestStoreError {
            XCTAssertEqual(
                error,
                .nonMonotonicRevision(previous: 0, proposed: 0)
            )
        }

        let retained = try await store.load(sessionID: sessionID)
        XCTAssertEqual(retained, initial)
    }

    private func manifest(
        sessionID: SessionID,
        revision: Int,
        phase: InterviewRoomPhase = .ready,
        candidateBody: String? = nil
    ) -> SessionManifest {
        let turns: [InterviewTurn]
        if let candidateBody {
            let commandID = CommandID("public-concurrent-candidate")
            turns = [
                .candidate(
                    CandidateTurn(
                        id: TurnID("public-concurrent-candidate-turn"),
                        commandID: commandID,
                        transcript: CandidateTranscript(
                            body: candidateBody,
                            quality: .verified
                        )
                    )
                ),
            ]
        } else {
            turns = []
        }

        return SessionManifest(
            sessionID: sessionID,
            activityID: "public-test-activity",
            phase: phase,
            turnMode: .manual,
            turns: turns,
            revision: revision,
            appliedCommands: []
        )
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewArcLiveTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private enum ReplacementFixtureError: Error {
    case expectedFailure
}

private enum ConcurrentSaveOutcome: Sendable, Equatable {
    case saved
    case conflict
    case unexpected
}
