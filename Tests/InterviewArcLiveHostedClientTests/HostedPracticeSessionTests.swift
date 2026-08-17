import Foundation
import XCTest

@testable import InterviewArcLiveHostedClient

final class HostedPracticeSessionTests: XCTestCase {
    func testOpenReadsAuthorityThenAcquiresActivityLease() async throws {
        let fixture = try HostedSessionFixture()

        let snapshot = await fixture.session.open()

        XCTAssertEqual(snapshot.connection, .writable)
        XCTAssertEqual(snapshot.question, "Design a public notification service.")
        XCTAssertEqual(snapshot.lease?.fencingToken, 7)
        XCTAssertEqual(snapshot.pendingOperationCount, 0)
        let paths = await fixture.transport.paths()
        XCTAssertEqual(
            paths,
            [
                "/live/v1/today",
                "/live/v1/activities/activity-1",
                "/live/v1/activities/activity-1/lease/acquire",
            ]
        )
    }

    func testAmbiguousCommandUsesReceiptFirstThenExactReplay() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.failNextCommandTransport()

        do {
            try await fixture.session.start()
            XCTFail("Expected ambiguous transport failure")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }
        let ambiguous = await fixture.session.snapshot()
        XCTAssertEqual(ambiguous.connection, .offline)
        XCTAssertEqual(ambiguous.pendingOperationCount, 1)

        await fixture.session.recoverPendingOperations()

        let recovered = await fixture.session.snapshot()
        XCTAssertEqual(recovered.connection, .loading)
        XCTAssertEqual(recovered.pendingOperationCount, 0)
        let paths = await fixture.transport.paths()
        let recoveryPaths = Array(paths.suffix(2))
        XCTAssertEqual(recoveryPaths.count, 2)
        XCTAssertTrue(recoveryPaths.first?.contains("/receipts/") == true)
        XCTAssertEqual(
            recoveryPaths.last,
            "/live/v1/activities/activity-1/commands"
        )
        let commandBodies = await fixture.transport.commandBodies()
        XCTAssertEqual(commandBodies.count, 2)
        XCTAssertEqual(commandBodies[0], commandBodies[1])
    }

    func testResponseLossAfterServerCommitUsesReceiptWithoutReplayingMutation() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.commitNextCommandThenLoseResponse()

        do {
            try await fixture.session.start()
            XCTFail("Expected response loss after the server commit")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }
        let ambiguous = await fixture.session.snapshot()
        XCTAssertEqual(ambiguous.pendingOperationCount, 1)

        await fixture.session.recoverPendingOperations()

        let recovered = await fixture.session.snapshot()
        XCTAssertEqual(recovered.pendingOperationCount, 0)
        let commandBodies = await fixture.transport.commandBodies()
        let paths = await fixture.transport.paths()
        XCTAssertEqual(commandBodies.count, 1)
        XCTAssertTrue(paths.last?.contains("/receipts/") == true)
    }

    func testRefreshCannotBecomeWritableBeforeAmbiguousReceiptRecovery() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.failNextCommandTransport()

        do {
            try await fixture.session.start()
            XCTFail("Expected ambiguous transport failure")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }
        await fixture.transport.rejectNextReceiptLookup()

        do {
            _ = try await fixture.session.refresh()
            XCTFail("Refresh must stay fail-closed while receipt recovery is unresolved")
        } catch let error as HostedPracticeSessionError {
            XCTAssertEqual(error, .operationAlreadyPending)
        }

        let snapshot = await fixture.session.snapshot()
        XCTAssertEqual(
            snapshot.connection,
            .recoveryRequired(code: "upstream_unavailable")
        )
        XCTAssertEqual(snapshot.pendingOperationCount, 1)
        let paths = await fixture.transport.paths()
        XCTAssertTrue(paths.last?.contains("/receipts/") == true)
    }

    func testReleaseLeaseRefusesToAbandonPendingOperation() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.failNextCommandTransport()

        do {
            try await fixture.session.start()
            XCTFail("Expected ambiguous transport failure")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }
        let pathsBeforeRelease = await fixture.transport.paths()

        do {
            try await fixture.session.releaseLease()
            XCTFail("Lease release must wait for the durable outbox")
        } catch let error as HostedPracticeSessionError {
            XCTAssertEqual(error, .operationAlreadyPending)
        }

        let snapshot = await fixture.session.snapshot()
        XCTAssertNotNil(snapshot.lease)
        XCTAssertEqual(snapshot.pendingOperationCount, 1)
        XCTAssertEqual(
            snapshot.connection,
            .recoveryRequired(code: "pending_operation")
        )
        let pathsAfterRelease = await fixture.transport.paths()
        XCTAssertEqual(pathsAfterRelease, pathsBeforeRelease)
    }

    func testRelaunchDoesNotRewriteOldSessionFenceWhenReceiptIsAbsent() async throws {
        let fixture = try HostedSessionFixture(holderSessionID: "fresh-room")
        let body = Data(
            #"{"command":"start","fencingToken":3,"holderId":"00000000-0000-4000-8000-000000000001","holderSessionId":"old-room","operationId":"old-op"}"#.utf8
        )
        try await fixture.outbox.prepare(
            LiveOutboxRecord(
                operationId: "old-op",
                operation: "command.start",
                pathSuffix: "commands",
                activityId: "activity-1",
                workbenchId: "workbench-1",
                holderId: "00000000-0000-4000-8000-000000000001",
                holderSessionId: "old-room",
                fencingToken: 3,
                dependencyOperationId: nil,
                canonicalBody: body,
                credentialFingerprint: await fixture.token.credentialFingerprint(),
                createdAt: 1
            )
        )

        let snapshot = await fixture.session.open()

        XCTAssertEqual(
            snapshot.connection,
            .recoveryRequired(code: "receipt_not_found")
        )
        XCTAssertEqual(snapshot.pendingOperationCount, 1)
        let paths = await fixture.transport.paths()
        XCTAssertEqual(
            paths,
            [
                "/live/v1/today",
                "/live/v1/activities/activity-1",
                "/live/v1/activities/activity-1/receipts/old-op",
            ]
        )
    }

    func testCredentialChangeQuarantineNeverAcquiresWritableLease() async throws {
        let fixture = try HostedSessionFixture()
        try await fixture.outbox.prepare(
            LiveOutboxRecord(
                operationId: "foreign-credential-op",
                operation: "command.start",
                pathSuffix: "commands",
                activityId: "activity-1",
                workbenchId: "workbench-1",
                holderId: "00000000-0000-4000-8000-000000000001",
                holderSessionId: "room-session-1",
                fencingToken: 3,
                dependencyOperationId: nil,
                canonicalBody: Data("foreign credential record".utf8),
                credentialFingerprint: String(repeating: "b", count: 64),
                createdAt: 1
            )
        )

        let snapshot = await fixture.session.open()

        XCTAssertEqual(
            snapshot.connection,
            .recoveryRequired(code: "credential_changed")
        )
        XCTAssertTrue(snapshot.hasQuarantinedOperations)
        XCTAssertNil(snapshot.lease)
        let paths = await fixture.transport.paths()
        XCTAssertEqual(
            paths,
            [
                "/live/v1/today",
                "/live/v1/activities/activity-1",
            ]
        )
    }

    func testTickRenewsAtThirtySecondsAndExpiresWithoutNetworkAtNinety() async throws {
        let renewalFixture = try HostedSessionFixture()
        _ = await renewalFixture.session.open()
        renewalFixture.clock.set(1_031_000)

        await renewalFixture.session.tick()

        let renewed = await renewalFixture.session.snapshot()
        XCTAssertEqual(renewed.connection, .writable)
        XCTAssertEqual(renewed.lease?.expiresAt, 1_150_000)
        let renewalPaths = await renewalFixture.transport.paths()
        XCTAssertEqual(
            renewalPaths.last,
            "/live/v1/activities/activity-1/lease/renew"
        )

        let expiryFixture = try HostedSessionFixture()
        _ = await expiryFixture.session.open()
        let pathsBeforeExpiry = await expiryFixture.transport.paths()
        expiryFixture.clock.set(1_090_000)

        await expiryFixture.session.tick()

        let expired = await expiryFixture.session.snapshot()
        XCTAssertEqual(
            expired.connection,
            .recoveryRequired(code: "lease_expired")
        )
        XCTAssertNil(expired.lease)
        let pathsAfterExpiry = await expiryFixture.transport.paths()
        XCTAssertEqual(pathsAfterExpiry, pathsBeforeExpiry)
    }

    func testStaleFenceAndRevokedTokenRetainOutboxAndStopWrites() async throws {
        let staleFixture = try HostedSessionFixture()
        _ = await staleFixture.session.open()
        await staleFixture.transport.rejectNextCommand(
            code: "stale_fence",
            retryable: false
        )

        do {
            try await staleFixture.session.start()
            XCTFail("Expected stale fence rejection")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error.code, "stale_fence")
        }
        let stale = await staleFixture.session.snapshot()
        XCTAssertEqual(
            stale.connection,
            .recoveryRequired(code: "stale_fence")
        )
        XCTAssertEqual(stale.pendingOperationCount, 1)

        let revokedFixture = try HostedSessionFixture()
        _ = await revokedFixture.session.open()
        await revokedFixture.transport.rejectNextCommand(
            code: "unauthorized",
            retryable: false
        )

        do {
            try await revokedFixture.session.start()
            XCTFail("Expected revoked credential rejection")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error.code, "unauthorized")
        }
        let revoked = await revokedFixture.session.snapshot()
        XCTAssertEqual(revoked.connection, .signedOut)
        XCTAssertEqual(revoked.pendingOperationCount, 1)
    }

    func testDefinitiveFinishGatesKeepCurrentActivityWithoutRecoveryDebt() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.rejectNextCommand(
            code: "candidate_evidence_required",
            retryable: false
        )

        do {
            try await fixture.session.finish()
            XCTFail("Expected hosted evidence gate")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error.code, "candidate_evidence_required")
        }
        var snapshot = await fixture.session.snapshot()
        XCTAssertEqual(snapshot.activityID, "activity-1")
        XCTAssertEqual(snapshot.connection, .writable)
        XCTAssertEqual(snapshot.pendingOperationCount, 0)

        await fixture.transport.rejectNextCommand(
            code: "no_next_activity",
            retryable: false
        )
        do {
            try await fixture.session.finishNext(nextActivityID: "activity-2")
            XCTFail("Expected no-next gate")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error.code, "no_next_activity")
        }
        snapshot = await fixture.session.snapshot()
        XCTAssertEqual(snapshot.activityID, "activity-1")
        XCTAssertEqual(snapshot.connection, .writable)
        XCTAssertEqual(snapshot.pendingOperationCount, 0)
    }

    func testCommittedPairKeepsOneStableIdentityAndCanonicalSequenceAfterRefresh() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()

        try await fixture.session.commitPair(
            pairID: "pair-1",
            candidate: LiveCandidatePairInput(
                turnId: "candidate-1",
                text: "Use regional queues with idempotent delivery.",
                evidenceStatus: .verified,
                occurredAt: 1_000_010
            ),
            interviewer: LiveInterviewerPairInput(
                turnId: "interviewer-1",
                displayMarkdown: "How do you recover a failed region?",
                spokenText: "How do you recover a failed region?",
                occurredAt: 1_000_020
            )
        )

        let committed = await fixture.session.snapshot()
        XCTAssertEqual(committed.activity?.pairs.map(\.pairId), ["pair-1"])
        XCTAssertEqual(committed.activity?.pairs.first?.candidate.turnId, "candidate-1")
        XCTAssertEqual(committed.activity?.pairs.first?.candidate.sequence, 1)
        XCTAssertEqual(committed.activity?.pairs.first?.interviewer.turnId, "interviewer-1")
        XCTAssertEqual(committed.activity?.pairs.first?.interviewer.sequence, 2)

        let refreshed = try await fixture.session.refresh()
        XCTAssertEqual(refreshed.activity?.pairs, committed.activity?.pairs)
        XCTAssertEqual(refreshed.pendingOperationCount, 0)
    }

    func testFailedClipUploadRetainsAcceptedPairAndRecoversExactPrivateIntent() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        try await fixture.session.commitPair(
            pairID: "pair-clip",
            candidate: LiveCandidatePairInput(
                turnId: "candidate-clip",
                text: "The clip is optional evidence.",
                evidenceStatus: .verified,
                occurredAt: 1_000_010
            ),
            interviewer: LiveInterviewerPairInput(
                turnId: "interviewer-clip",
                displayMarkdown: "Continue.",
                spokenText: "Continue.",
                occurredAt: 1_000_020
            ),
            clipID: "clip-1"
        )
        await fixture.transport.failNextClipUploadTransport()

        do {
            try await fixture.session.stageAndUploadClip(
                clipID: "clip-1",
                candidateTurnID: "candidate-clip",
                mimeType: "audio/m4a",
                data: Data("private fixture audio".utf8)
            )
            XCTFail("Expected ambiguous clip upload failure")
        } catch let error as LiveV1ClientError {
            XCTAssertEqual(error, .transportUnavailable)
        }

        var snapshot = await fixture.session.snapshot()
        XCTAssertEqual(snapshot.connection, .offline)
        XCTAssertEqual(snapshot.pendingOperationCount, 1)
        XCTAssertEqual(snapshot.activity?.pairs.map(\.pairId), ["pair-clip"])
        XCTAssertEqual(snapshot.activity?.clips.first?.status, .staged)
        let retainedIntent = try await fixture.clipStore.loadIntent(clipID: "clip-1")
        XCTAssertNotNil(retainedIntent)

        await fixture.session.recoverPendingOperations()

        snapshot = await fixture.session.snapshot()
        XCTAssertEqual(snapshot.pendingOperationCount, 0)
        XCTAssertEqual(snapshot.activity?.pairs.map(\.pairId), ["pair-clip"])
        XCTAssertEqual(snapshot.activity?.clips.first?.status, .available)
        let recoveredIntent = try await fixture.clipStore.loadIntent(clipID: "clip-1")
        XCTAssertNil(recoveredIntent)
        let paths = await fixture.transport.paths()
        XCTAssertTrue(paths.suffix(2).first?.contains("/receipts/") == true)
        XCTAssertEqual(
            paths.last,
            "/live/v1/activities/activity-1/clips/clip-1/content"
        )
    }

    func testTimerUsesServerOffsetWithoutPersistingLocalTicks() async throws {
        let fixture = try HostedSessionFixture()
        let snapshot = await fixture.session.open()

        XCTAssertEqual(snapshot.elapsedSeconds(localNow: 1_005_000), 35)
        XCTAssertEqual(snapshot.elapsedSeconds(localNow: 1_006_000), 36)
        XCTAssertEqual(snapshot.activity?.activity.timer?.accumulatedSeconds, 10)
    }

    func testLeaseHeldIsTruthfulReadOnlyWithoutRecoveryOutbox() async throws {
        let fixture = try HostedSessionFixture()
        await fixture.transport.rejectNextLeaseAcquire()

        let snapshot = await fixture.session.open()

        XCTAssertEqual(
            snapshot.connection,
            .readOnly(reason: "Another writer holds this activity")
        )
        XCTAssertNil(snapshot.lease)
        XCTAssertEqual(snapshot.pendingOperationCount, 0)
        let fingerprint = await fixture.token.credentialFingerprint()
        let records = try await fixture.outbox.records(
            credentialFingerprint: fingerprint
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testFinishNextRereadsSelectedActivityAndAcquiresFreshLease() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()

        try await fixture.session.finishNext(nextActivityID: "activity-2")

        let snapshot = await fixture.session.snapshot()
        XCTAssertEqual(snapshot.activityID, "activity-2")
        XCTAssertEqual(snapshot.connection, .writable)
        XCTAssertEqual(snapshot.lease?.holderSessionId, "room-session-1")
        let paths = await fixture.transport.paths()
        XCTAssertEqual(
            Array(paths.suffix(4)),
            [
                "/live/v1/activities/activity-1/commands",
                "/live/v1/today",
                "/live/v1/activities/activity-2",
                "/live/v1/activities/activity-2/lease/acquire",
            ]
        )
    }

    func testFocusedCompletedActivityFallsBackToNextOpenSystemDesignActivity() {
        XCTAssertEqual(
            HostedFixtures.todayWithCompletedFocus.selectedSystemDesignActivity?.id,
            "activity-2"
        )
    }

    func testRefreshSwitchesAuthorityAndAcquiresFreshSelectedLease() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        await fixture.transport.selectNextActivity()

        let refreshed = try await fixture.session.refresh()

        XCTAssertEqual(refreshed.activityID, "activity-2")
        XCTAssertEqual(refreshed.connection, .writable)
        let paths = await fixture.transport.paths()
        XCTAssertEqual(
            Array(paths.suffix(4)),
            [
                "/live/v1/today",
                "/live/v1/activities/activity-2",
                "/live/v1/activities/activity-1/lease/release",
                "/live/v1/activities/activity-2/lease/acquire",
            ]
        )
    }

    func testInvalidationRereadsOnlyNewLiveRevisions() async throws {
        let fixture = try HostedSessionFixture()
        _ = await fixture.session.open()
        let initialPaths = await fixture.transport.paths()
        let initialCount = initialPaths.count

        await fixture.session.receive(
            LiveInvalidation(
                type: "practice_changed",
                revision: 4,
                scope: "live",
                occurredAt: 1_000_000
            )
        )
        await fixture.session.receive(
            LiveInvalidation(
                type: "practice_changed",
                revision: 4,
                scope: "live",
                occurredAt: 1_000_001
            )
        )

        let finalPaths = await fixture.transport.paths()
        let finalSnapshot = await fixture.session.snapshot()
        XCTAssertEqual(finalPaths.count, initialCount + 2)
        XCTAssertEqual(
            finalSnapshot.lastLiveInvalidationRevision,
            4
        )
    }

    func testFallbackBackoffIsBoundedAtOneHundredTwentySeconds() {
        XCTAssertEqual(LiveEventStream.fallbackDelaySeconds(afterFailure: 0), 15)
        XCTAssertEqual(LiveEventStream.fallbackDelaySeconds(afterFailure: 1), 30)
        XCTAssertEqual(LiveEventStream.fallbackDelaySeconds(afterFailure: 2), 60)
        XCTAssertEqual(LiveEventStream.fallbackDelaySeconds(afterFailure: 3), 120)
        XCTAssertEqual(LiveEventStream.fallbackDelaySeconds(afterFailure: 99), 120)
    }

    func testAdditiveResponseEnumsDecodeWithoutInventingSupportedState() throws {
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(LiveActivityType.self, from: Data(#""future_type""#.utf8)),
            .unknown
        )
        XCTAssertEqual(
            try decoder.decode(
                LiveActivityLifecycle.self,
                from: Data(#""future_lifecycle""#.utf8)
            ),
            .unknown
        )
        XCTAssertEqual(
            try decoder.decode(LiveResult.self, from: Data(#""future_result""#.utf8)),
            .unknown
        )
        XCTAssertEqual(
            try decoder.decode(
                LiveCandidateEvidenceStatus.self,
                from: Data(#""future_evidence""#.utf8)
            ),
            .unknown
        )
        XCTAssertEqual(
            try decoder.decode(LiveClipStatus.self, from: Data(#""future_clip""#.utf8)),
            .unknown
        )
    }
}

private final class HostedSessionFixture {
    let token: TestTokenReader
    let transport: HostedFixtureTransport
    let outbox: PrivateLiveOutboxStore
    let clipStore: PrivateLiveClipStore
    let clock: TestLiveClock
    let session: HostedPracticeSession
    private let root: URL

    init(holderSessionID: String = "room-session-1") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hosted-session-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        token = TestTokenReader()
        transport = HostedFixtureTransport()
        outbox = PrivateLiveOutboxStore(
            directoryURL: root.appendingPathComponent("outbox")
        )
        clipStore = PrivateLiveClipStore(
            directoryURL: root.appendingPathComponent("clips")
        )
        clock = TestLiveClock(now: 1_000_000)
        session = HostedPracticeSession(
            client: LiveV1Client(tokenReader: token, transport: transport),
            tokenReader: token,
            identityStore: PrivateLiveIdentityStore(
                directoryURL: root.appendingPathComponent("identity")
            ),
            outbox: outbox,
            clipStore: clipStore,
            clock: clock,
            holderSessionID: holderSessionID
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor TestTokenReader: LiveIntegrationTokenReading {
    func readIntegrationToken() -> String { "public-test-token" }
    func credentialFingerprint() -> String { String(repeating: "a", count: 64) }
}

private final class TestLiveClock: LiveClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: LiveEpochMilliseconds

    init(now: LiveEpochMilliseconds) { self.now = now }

    func epochMilliseconds() -> LiveEpochMilliseconds {
        lock.withLock { now }
    }

    func set(_ value: LiveEpochMilliseconds) {
        lock.withLock { now = value }
    }
}

private enum HostedFixtureTransportError: Error { case expectedFailure }

private actor HostedFixtureTransport: LiveV1Transport {
    private var recorded: [LiveV1Request] = []
    private var failCommand = false
    private var commitCommandThenLoseResponse = false
    private var failClipUpload = false
    private var rejectLeaseAcquire = false
    private var rejectReceiptLookup = false
    private var commandRejection: (code: String, retryable: Bool)?
    private var useNextActivity = false
    private var heldLease: LiveLeaseGrant?
    private var committedPairs: [LivePair] = []
    private var clips: [LiveClip] = []
    private var receipts: [String: LiveMutationReceipt] = [:]

    func failNextCommandTransport() { failCommand = true }
    func commitNextCommandThenLoseResponse() { commitCommandThenLoseResponse = true }
    func failNextClipUploadTransport() { failClipUpload = true }
    func rejectNextLeaseAcquire() { rejectLeaseAcquire = true }
    func rejectNextReceiptLookup() { rejectReceiptLookup = true }
    func rejectNextCommand(code: String, retryable: Bool) {
        commandRejection = (code, retryable)
    }
    func selectNextActivity() { useNextActivity = true }
    func paths() -> [String] { recorded.map(\.path) }
    func commandBodies() -> [Data] {
        recorded.filter { $0.path.hasSuffix("/commands") }.compactMap(\.body)
    }

    func send(_ request: LiveV1Request) async throws -> LiveV1HTTPResponse {
        recorded.append(request)
        if request.path == "/live/v1/today" {
            return response(
                useNextActivity
                    ? HostedFixtures.todayWithNextFocus
                    : HostedFixtures.today
            )
        }
        if request.path == "/live/v1/activities/activity-1" {
            return response(activityProjection(HostedFixtures.activity))
        }
        if request.path == "/live/v1/activities/activity-2" {
            return response(activityProjection(HostedFixtures.nextActivity))
        }
        if request.path.contains("/receipts/") {
            if rejectReceiptLookup {
                rejectReceiptLookup = false
                return errorResponse(
                    status: 503,
                    code: "upstream_unavailable",
                    retryable: true
                )
            }
            let operationID = request.path.split(separator: "/").last.map(String.init) ?? ""
            if let receipt = receipts[operationID] {
                return response(
                    LiveReceiptResponse(protocolVersion: 1, receipt: receipt)
                )
            }
            return errorResponse(status: 404, code: "receipt_not_found", retryable: false)
        }
        if request.method == .put, request.path.hasSuffix("/content") {
            if failClipUpload {
                failClipUpload = false
                throw HostedFixtureTransportError.expectedFailure
            }
            guard let operationID = request.headers["X-Live-Operation-Id"],
                  let clipID = request.path.split(separator: "/").dropLast().last.map(String.init),
                  let staged = clips.first(where: { $0.clipId == clipID }) else {
                return errorResponse(status: 400, code: "invalid_request", retryable: false)
            }
            let available = LiveClip(
                clipId: staged.clipId,
                candidateTurnId: staged.candidateTurnId,
                pairId: staged.pairId,
                mimeType: staged.mimeType,
                byteSize: staged.byteSize,
                sha256: staged.sha256,
                status: .available,
                failureCode: nil,
                createdAt: staged.createdAt,
                updatedAt: 1_000_040
            )
            clips = clips.map { $0.clipId == clipID ? available : $0 }
            return response(
                mutationResponse(
                    operationID: operationID,
                    operation: "clip.upload",
                    clip: available
                )
            )
        }
        guard let body = request.body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationID = object["operationId"] as? String else {
            return errorResponse(status: 400, code: "invalid_request", retryable: false)
        }
        if request.path.hasSuffix("/commands"), failCommand {
            failCommand = false
            throw HostedFixtureTransportError.expectedFailure
        }
        if request.path.hasSuffix("/commands"), commitCommandThenLoseResponse {
            commitCommandThenLoseResponse = false
            receipts[operationID] = LiveMutationReceipt(
                protocolVersion: 1,
                operationId: operationID,
                activityId: "activity-1",
                operation: "command.\(object["command"] as? String ?? "")",
                committedAt: 1_000_000,
                result: [:]
            )
            throw HostedFixtureTransportError.expectedFailure
        }
        if request.path.hasSuffix("/commands"), let rejection = commandRejection {
            commandRejection = nil
            return errorResponse(
                status: rejection.code == "unauthorized" ? 401 : 409,
                code: rejection.code,
                retryable: rejection.retryable
            )
        }
        if request.path.hasSuffix("/lease/acquire"), rejectLeaseAcquire {
            rejectLeaseAcquire = false
            return errorResponse(status: 409, code: "lease_held", retryable: false)
        }
        let operation: String
        let lease: LiveLeaseGrant?
        if request.path.hasSuffix("/lease/acquire") {
            operation = "lease.acquire"
            lease = LiveLeaseGrant(
                fencingToken: 7,
                expiresAt: 1_090_000,
                holderSessionId: object["holderSessionId"] as? String ?? ""
            )
            heldLease = lease
        } else if request.path.hasSuffix("/lease/renew") {
            operation = "lease.renew"
            lease = LiveLeaseGrant(
                fencingToken: 7,
                expiresAt: 1_150_000,
                holderSessionId: object["holderSessionId"] as? String ?? ""
            )
            heldLease = lease
        } else if request.path.hasSuffix("/lease/release") {
            operation = "lease.release"
            lease = nil
            heldLease = nil
        } else if request.path.hasSuffix("/commands") {
            operation = "command.\(object["command"] as? String ?? "")"
            lease = nil
            if object["command"] as? String == "finish"
                || object["command"] as? String == "finish-next" {
                heldLease = nil
            }
        } else if request.path.hasSuffix("/turn-pairs") {
            operation = "turn_pair.commit"
            lease = nil
            guard let pairID = object["pairId"] as? String,
                  let candidate = object["candidate"] as? [String: Any],
                  let interviewer = object["interviewer"] as? [String: Any],
                  let candidateTurnID = candidate["turnId"] as? String,
                  let candidateText = candidate["text"] as? String,
                  let candidateEvidenceRaw = candidate["evidenceStatus"] as? String,
                  let candidateEvidence = LiveCandidateEvidenceStatus(rawValue: candidateEvidenceRaw),
                  let candidateOccurredAt = candidate["occurredAt"] as? NSNumber,
                  let interviewerTurnID = interviewer["turnId"] as? String,
                  let displayMarkdown = interviewer["displayMarkdown"] as? String,
                  let spokenText = interviewer["spokenText"] as? String,
                  let interviewerOccurredAt = interviewer["occurredAt"] as? NSNumber else {
                return errorResponse(status: 400, code: "invalid_pair", retryable: false)
            }
            let nextSequence = committedPairs.count * 2 + 1
            committedPairs.append(
                LivePair(
                    pairId: pairID,
                    candidate: LiveCandidateTurn(
                        turnId: candidateTurnID,
                        text: candidateText,
                        evidenceStatus: candidateEvidence,
                        evidenceConfirmedAt: nil,
                        evidenceSatisfied: candidateEvidence == .verified,
                        occurredAt: candidateOccurredAt.int64Value,
                        sequence: nextSequence
                    ),
                    interviewer: LiveInterviewerTurn(
                        turnId: interviewerTurnID,
                        displayMarkdown: displayMarkdown,
                        spokenText: spokenText,
                        occurredAt: interviewerOccurredAt.int64Value,
                        sequence: nextSequence + 1
                    ),
                    clipId: object["clipId"] as? String,
                    committedAt: 1_000_030
                )
            )
        } else if request.path.hasSuffix("/clips/stage") {
            operation = "clip.stage"
            lease = nil
            guard let clipID = object["clipId"] as? String,
                  let candidateTurnID = object["candidateTurnId"] as? String,
                  let mimeType = object["mimeType"] as? String,
                  let byteSize = object["byteSize"] as? Int,
                  let sha256 = object["sha256"] as? String else {
                return errorResponse(status: 400, code: "invalid_clip", retryable: false)
            }
            clips.append(
                LiveClip(
                    clipId: clipID,
                    candidateTurnId: candidateTurnID,
                    pairId: committedPairs.first(where: {
                        $0.candidate.turnId == candidateTurnID
                    })?.pairId,
                    mimeType: mimeType,
                    byteSize: byteSize,
                    sha256: sha256,
                    status: .staged,
                    failureCode: nil,
                    createdAt: 1_000_030,
                    updatedAt: 1_000_030
                )
            )
        } else {
            operation = "fixture"
            lease = nil
        }
        let selectedNextActivityID = object["command"] as? String == "finish-next"
            ? "activity-2"
            : nil
        return response(
            mutationResponse(
                operationID: operationID,
                operation: operation,
                base: request.path.contains("activity-2")
                    ? HostedFixtures.nextActivity
                    : HostedFixtures.activity,
                lease: lease,
                selectedNextActivityID: selectedNextActivityID,
                clip: clips.last
            )
        )
    }

    private func mutationResponse(
        operationID: String,
        operation: String,
        base: LiveActivityProjection = HostedFixtures.activity,
        lease: LiveLeaseGrant? = nil,
        selectedNextActivityID: String? = nil,
        clip: LiveClip? = nil
    ) -> LiveMutationResponse {
        let projectedActivity = activityProjection(base)
        return LiveMutationResponse(
            protocolVersion: 1,
            duplicate: false,
            receipt: LiveMutationReceipt(
                protocolVersion: 1,
                operationId: operationID,
                activityId: projectedActivity.activity.id,
                operation: operation,
                committedAt: 1_000_000,
                result: [:]
            ),
            activity: projectedActivity,
            lease: lease,
            selectedNextActivityId: selectedNextActivityID,
            confirmation: nil,
            today: HostedFixtures.today,
            clip: clip
        )
    }

    private func response<Value: Encodable>(_ value: Value) -> LiveV1HTTPResponse {
        LiveV1HTTPResponse(
            statusCode: 200,
            body: try! JSONEncoder().encode(value)
        )
    }

    private func activityProjection(
        _ base: LiveActivityProjection
    ) -> LiveActivityProjection {
        LiveActivityProjection(
            protocolVersion: base.protocolVersion,
            serverTime: base.serverTime,
            ownerRevision: base.ownerRevision,
            workbench: base.workbench,
            focus: base.focus,
            session: base.session,
            activity: base.activity,
            lease: LiveLeaseSummary(
                active: heldLease != nil,
                holderPresent: heldLease != nil,
                expiresAt: heldLease?.expiresAt
            ),
            pairs: base.activity.id == HostedFixtures.activity.activity.id
                ? committedPairs
                : base.pairs,
            clips: base.activity.id == HostedFixtures.activity.activity.id
                ? clips
                : base.clips
        )
    }

    private func errorResponse(
        status: Int,
        code: String,
        retryable: Bool
    ) -> LiveV1HTTPResponse {
        response(
            LiveErrorBody(
                error: "Fixture rejection",
                code: code,
                retryable: retryable,
                holderPresent: nil,
                expiresAt: nil
            ),
            status: status
        )
    }

    private func response<Value: Encodable>(
        _ value: Value,
        status: Int
    ) -> LiveV1HTTPResponse {
        LiveV1HTTPResponse(
            statusCode: status,
            body: try! JSONEncoder().encode(value)
        )
    }
}

private enum HostedFixtures {
    static let timer = LiveTimer(
        accumulatedSeconds: 10,
        startedAt: 970_000,
        runningSince: 980_000,
        completed: false,
        completedAt: nil,
        revision: 2
    )
    static let summary = LiveActivitySummary(
        id: "activity-1",
        questionId: "question-1",
        date: "2026-08-11",
        source: "fixture",
        type: .systemDesign,
        title: "Notification service",
        prompt: "Design a public notification service.",
        allocatedSeconds: 2_700,
        sessionId: "session-1",
        lifecycle: .running,
        revision: 3,
        timer: timer,
        result: LiveResultProjection(value: nil, revision: 0)
    )
    static let workbench = LiveWorkbench(
        id: "workbench-1",
        revision: 5,
        openedPacificDate: "2026-08-11",
        openedAt: 900_000
    )
    static let focus = LiveFocus(
        activityId: "activity-1",
        sessionId: "session-1",
        focusedAt: 990_000
    )
    static let today = LiveTodayProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 8,
        workbench: workbench,
        focus: focus,
        sessions: [
            LiveSessionSummary(
                id: "session-1",
                label: "System Design practice",
                activityIds: ["activity-1", "activity-2"],
                allocatedSeconds: 5_400,
                revision: 1,
                timer: nil
            ),
        ],
        activities: [summary, nextSummary]
    )
    static let detail = LiveActivityDetail(
        id: summary.id,
        questionId: summary.questionId,
        date: summary.date,
        source: summary.source,
        type: summary.type,
        title: summary.title,
        prompt: summary.prompt,
        allocatedSeconds: summary.allocatedSeconds,
        sessionId: summary.sessionId,
        lifecycle: summary.lifecycle,
        revision: summary.revision,
        timer: summary.timer,
        result: summary.result,
        textEvidenceSatisfied: false
    )
    static let activity = LiveActivityProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 8,
        workbench: workbench,
        focus: focus,
        session: nil,
        activity: detail,
        lease: LiveLeaseSummary(
            active: false,
            holderPresent: false,
            expiresAt: nil
        ),
        pairs: [],
        clips: []
    )
    static let nextSummary = LiveActivitySummary(
        id: "activity-2",
        questionId: "question-2",
        date: "2026-08-11",
        source: "fixture",
        type: .systemDesign,
        title: "Rate limiter",
        prompt: "Design a distributed rate limiter.",
        allocatedSeconds: 2_700,
        sessionId: "session-1",
        lifecycle: .planned,
        revision: 1,
        timer: LiveTimer(
            accumulatedSeconds: 0,
            startedAt: nil,
            runningSince: nil,
            completed: false,
            completedAt: nil,
            revision: 0
        ),
        result: LiveResultProjection(value: nil, revision: 0)
    )
    static let nextDetail = LiveActivityDetail(
        id: nextSummary.id,
        questionId: nextSummary.questionId,
        date: nextSummary.date,
        source: nextSummary.source,
        type: nextSummary.type,
        title: nextSummary.title,
        prompt: nextSummary.prompt,
        allocatedSeconds: nextSummary.allocatedSeconds,
        sessionId: nextSummary.sessionId,
        lifecycle: nextSummary.lifecycle,
        revision: nextSummary.revision,
        timer: nextSummary.timer,
        result: nextSummary.result,
        textEvidenceSatisfied: false
    )
    static let nextActivity = LiveActivityProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 9,
        workbench: workbench,
        focus: LiveFocus(
            activityId: "activity-2",
            sessionId: "session-1",
            focusedAt: 1_000_000
        ),
        session: today.sessions[0],
        activity: nextDetail,
        lease: LiveLeaseSummary(
            active: false,
            holderPresent: false,
            expiresAt: nil
        ),
        pairs: [],
        clips: []
    )
    static let completedSummary = LiveActivitySummary(
        id: "activity-completed",
        questionId: "question-completed",
        date: "2026-08-11",
        source: "fixture",
        type: .systemDesign,
        title: "Completed activity",
        prompt: "A completed activity.",
        allocatedSeconds: 2_700,
        sessionId: "session-1",
        lifecycle: .completed,
        revision: 2,
        timer: nil,
        result: LiveResultProjection(value: .solved, revision: 1)
    )
    static let todayWithCompletedFocus = LiveTodayProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 9,
        workbench: workbench,
        focus: LiveFocus(
            activityId: completedSummary.id,
            sessionId: "session-1",
            focusedAt: 1_000_000
        ),
        sessions: today.sessions,
        activities: [completedSummary, nextSummary]
    )
    static let todayWithNextFocus = LiveTodayProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 9,
        workbench: workbench,
        focus: LiveFocus(
            activityId: nextSummary.id,
            sessionId: "session-1",
            focusedAt: 1_000_000
        ),
        sessions: today.sessions,
        activities: [nextSummary]
    )
}
