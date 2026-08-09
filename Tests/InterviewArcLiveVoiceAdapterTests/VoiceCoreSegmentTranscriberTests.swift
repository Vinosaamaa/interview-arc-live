import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore
import XCTest
@testable import InterviewArcLiveVoiceAdapter

final class VoiceCoreSegmentTranscriberTests: XCTestCase {
    func testInitialAttemptMakesOneProviderInvocationAndPreservesBodyVerbatim() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let exactBody = "  Exact candidate with whitespace.\n"
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: exactBody))
        )
        let adapter = fixture.adapter(spy: spy)

        let result = try await adapter.transcribe(
            fixture.request(kind: .initial),
            credential: "public-test-key"
        )

        XCTAssertEqual(result.body, exactBody)
        XCTAssertEqual(result.quality, .verified)
        XCTAssertEqual(result.integrityReasons, [])
        let invocations = await spy.invocations()
        XCTAssertEqual(invocations, [.initial])
    }

    func testRetryAttemptUsesExactlyOneCoverageRecoveryCall() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: "Recovered candidate"))
        )
        let adapter = fixture.adapter(spy: spy)

        _ = try await adapter.transcribe(
            fixture.request(kind: .retry),
            credential: "public-test-key"
        )

        let invocations = await spy.invocations()
        XCTAssertEqual(invocations, [.coverageRecovery])
    }

    func testPromptLeakageCandidateIsPreservedAndMarkedPossibleContamination() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let body = "Thank you for watching"
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: body))
        )
        let adapter = fixture.adapter(spy: spy)

        let result = try await adapter.transcribe(
            fixture.request(kind: .initial),
            credential: "public-test-key"
        )

        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.quality, .possibleContamination)
        XCTAssertTrue(
            result.integrityReasons.contains(
                SegmentIntegrityReason("promptLeakage")
            )
        )
        let invocationCount = await spy.invocations().count
        XCTAssertEqual(invocationCount, 1)
    }

    func testOtherSuspiciousNonemptyCandidateIsPreservedAsBestAvailable() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let body = "short but nonempty"
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: body))
        )
        let adapter = fixture.adapter(spy: spy) { _, prompt, transcription in
            TranscriptionIntegrityEvaluator.evaluate(
                TranscriptionIntegrityEvidence(
                    audioDurationSeconds: 20,
                    providerDurationSeconds: 2,
                    expectedChunkCount: 2,
                    returnedChunkCount: 1,
                    transcript: transcription.text,
                    prompt: prompt,
                    hasSustainedSpeechAfterProviderCoverage: true
                )
            )
        }

        let result = try await adapter.transcribe(
            fixture.request(kind: .initial),
            credential: "public-test-key"
        )

        XCTAssertEqual(result.body, body)
        XCTAssertEqual(result.quality, .bestAvailable)
        XCTAssertTrue(
            result.integrityReasons.contains(
                SegmentIntegrityReason("missingSpeechCoverage")
            )
        )
        let invocationCount = await spy.invocations().count
        XCTAssertEqual(invocationCount, 1)
    }

    func testEmptyProviderResultFailsWithoutFabricatingCandidate() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: "  \n"))
        )
        let adapter = fixture.adapter(spy: spy)

        do {
            _ = try await adapter.transcribe(
                fixture.request(kind: .initial),
                credential: "public-test-key"
            )
            XCTFail("Expected an empty-provider-result failure")
        } catch let failure as SegmentTranscriptionAdapterFailure {
            XCTAssertEqual(failure.reason, .emptyProviderResult)
            XCTAssertNil(failure.providerCode)
        }
        let invocationCount = await spy.invocations().count
        XCTAssertEqual(invocationCount, 1)
    }

    func testUnauthorizedFailureIsDomainSafeAndDoesNotContainCredential() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let spy = SpeechTranscriberSpy(behavior: .invalidCredential)
        let adapter = fixture.adapter(spy: spy)

        do {
            _ = try await adapter.transcribe(
                fixture.request(kind: .initial),
                credential: "private-test-credential"
            )
            XCTFail("Expected a credential rejection")
        } catch let failure as SegmentTranscriptionAdapterFailure {
            XCTAssertEqual(failure.reason, .credentialRejected)
            XCTAssertEqual(failure.providerCode, .unauthorized)
            XCTAssertFalse(String(describing: failure).contains("private-test-credential"))
        }
        let invocationCount = await spy.invocations().count
        XCTAssertEqual(invocationCount, 1)
    }

    func testHTTP401VariantIsAlsoClassifiedAsCredentialRejected() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let spy = SpeechTranscriberSpy(behavior: .providerStatus(401))
        let adapter = fixture.adapter(spy: spy)

        do {
            _ = try await adapter.transcribe(
                fixture.request(kind: .initial),
                credential: "private-test-credential"
            )
            XCTFail("Expected a credential rejection")
        } catch let failure as SegmentTranscriptionAdapterFailure {
            XCTAssertEqual(failure.reason, .credentialRejected)
            XCTAssertEqual(failure.providerCode, .unauthorized)
        }
    }

    func testMissingAudioFailsBeforeProviderInvocation() async throws {
        let fixture = try TranscriptionFixture(createAudio: false)
        defer { fixture.remove() }
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: "must not be returned"))
        )
        let adapter = fixture.adapter(spy: spy)

        do {
            _ = try await adapter.transcribe(
                fixture.request(kind: .initial),
                credential: "public-test-key"
            )
            XCTFail("Expected invalid audio")
        } catch let failure as SegmentTranscriptionAdapterFailure {
            XCTAssertEqual(failure.reason, .invalidAudio)
        }
        let invocations = await spy.invocations()
        XCTAssertEqual(invocations, [])
    }

    func testFirstUseCleanupRemovesOnlyStalePrivateScratch() async throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let paths = LiveVoicePaths(applicationSupportRoot: fixture.root)
        let stale = try paths.transcriptionScratchDirectory(
            sessionID: fixture.sessionID,
            attemptID: TranscriptionAttemptID("stale-attempt")
        )
        let fresh = try paths.transcriptionScratchDirectory(
            sessionID: fixture.sessionID,
            attemptID: TranscriptionAttemptID("fresh-attempt")
        )
        try Data(repeating: 2, count: 128).write(
            to: stale.appendingPathComponent("provider-chunk.m4a")
        )
        try Data(repeating: 3, count: 128).write(
            to: fresh.appendingPathComponent("provider-chunk.m4a")
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fresh.path
        )

        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "provider-scratch-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        let outsideEvidence = outside.appendingPathComponent("must-remain.m4a")
        try Data(repeating: 4, count: 128).write(to: outsideEvidence)
        let linkedAttempt = try paths.transcriptionScratchDirectory(
            sessionID: fixture.sessionID,
            attemptID: TranscriptionAttemptID("linked-attempt")
        )
        try FileManager.default.removeItem(at: linkedAttempt)
        try FileManager.default.createSymbolicLink(
            at: linkedAttempt,
            withDestinationURL: outside
        )

        let sourceAudio = try paths.audioURL(
            sessionID: fixture.sessionID,
            identity: fixture.audioIdentity,
            createParentDirectory: false
        )
        let spy = SpeechTranscriberSpy(
            behavior: .result(Self.result(text: "Preserved transcript"))
        )
        let adapter = fixture.adapter(
            spy: spy,
            scratchCleanupPolicy: ProviderScratchCleanupPolicy(
                staleAge: 3_600,
                maximumSessionDirectories: 8,
                maximumAttemptDirectories: 32,
                maximumDeletions: 8
            ),
            now: { now }
        )

        _ = try await adapter.transcribe(
            fixture.request(kind: .initial),
            credential: "public-test-key"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedAttempt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideEvidence.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAudio.path))
    }

    func testScratchCleanupDeletionCountIsBounded() throws {
        let fixture = try TranscriptionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let paths = LiveVoicePaths(applicationSupportRoot: fixture.root)
        var staleDirectories: [URL] = []
        for index in 0..<3 {
            let directory = try paths.transcriptionScratchDirectory(
                sessionID: fixture.sessionID,
                attemptID: TranscriptionAttemptID("bounded-attempt-\(index)")
            )
            try Data(repeating: UInt8(index), count: 128).write(
                to: directory.appendingPathComponent("provider-chunk.m4a")
            )
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-7_200)],
                ofItemAtPath: directory.path
            )
            staleDirectories.append(directory)
        }

        let removed = try paths.cleanupStaleTranscriptionScratch(
            now: now,
            policy: ProviderScratchCleanupPolicy(
                staleAge: 3_600,
                maximumSessionDirectories: 8,
                maximumAttemptDirectories: 32,
                maximumDeletions: 1
            )
        )

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(
            staleDirectories.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            2
        )
    }

    private static func result(text: String) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            words: [],
            durationSeconds: 1,
            chunkCount: 1,
            engine: "test",
            model: "test"
        )
    }
}

private enum TranscriberInvocation: Equatable, Sendable {
    case initial
    case coverageRecovery
}

private actor SpeechTranscriberSpy: SpeechTranscribing {
    enum Behavior: Sendable {
        case result(TranscriptionResult)
        case invalidCredential
        case providerStatus(Int)
    }

    nonisolated let diagnosticEngine = "test"
    nonisolated let diagnosticModel: String? = "test"
    private let behavior: Behavior
    private var recordedInvocations: [TranscriberInvocation] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(
        fileURL: URL,
        prompt: String,
        temporaryDirectory: URL
    ) async throws -> TranscriptionResult {
        recordedInvocations.append(.initial)
        return try response()
    }

    func transcribeCoverageRecovery(
        fileURL: URL,
        temporaryDirectory: URL
    ) async throws -> TranscriptionResult {
        recordedInvocations.append(.coverageRecovery)
        return try response()
    }

    func invocations() -> [TranscriberInvocation] {
        recordedInvocations
    }

    private func response() throws -> TranscriptionResult {
        switch behavior {
        case .result(let result):
            result
        case .invalidCredential:
            throw VoiceBridgeError.invalidProviderCredential
        case .providerStatus(let status):
            throw VoiceBridgeError.providerResponseFailure(status, nil)
        }
    }
}

private struct TranscriptionFixture {
    let root: URL
    let sessionID = SessionID("public-test-session")
    let audioIdentity: SegmentAudioIdentity

    init(createAudio: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "interview-arc-live-transcriber-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        audioIdentity = try SegmentAudioIdentity(validating: "segment.m4a")
        if createAudio {
            let paths = LiveVoicePaths(applicationSupportRoot: root)
            let url = try paths.audioURL(
                sessionID: sessionID,
                identity: audioIdentity,
                createParentDirectory: true
            )
            try Data(repeating: 1, count: 2_048).write(to: url, options: .atomic)
        }
    }

    func request(kind: SegmentTranscriptionKind) -> SegmentTranscriptionRequest {
        SegmentTranscriptionRequest(
            sessionID: sessionID,
            segmentID: SegmentID("segment-test"),
            attemptID: TranscriptionAttemptID("attempt-\(kind.rawValue)"),
            kind: kind,
            audioIdentity: audioIdentity
        )
    }

    func adapter(
        spy: SpeechTranscriberSpy,
        evaluateIntegrity: @escaping VoiceCoreIntegrityEvaluator = {
            audioURL,
            prompt,
            transcription in
            TranscriptionIntegrityEvaluator.evaluate(
                TranscriptionIntegrityEvidence(
                    audioDurationSeconds: transcription.durationSeconds,
                    providerDurationSeconds: transcription.durationSeconds,
                    expectedChunkCount: transcription.chunkCount,
                    returnedChunkCount: transcription.chunkCount,
                    transcript: transcription.text,
                    prompt: prompt
                )
            )
        },
        scratchCleanupPolicy: ProviderScratchCleanupPolicy = .production,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> VoiceCoreSegmentTranscriber {
        VoiceCoreSegmentTranscriber(
            applicationSupportRoot: root,
            makeTranscriber: { _ in spy },
            evaluateIntegrity: evaluateIntegrity,
            scratchCleanupPolicy: scratchCleanupPolicy,
            now: now
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
