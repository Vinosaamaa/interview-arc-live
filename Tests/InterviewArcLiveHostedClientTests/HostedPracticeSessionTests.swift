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
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].contains("/receipts/old-op"))
    }

    func testTimerUsesServerOffsetWithoutPersistingLocalTicks() async throws {
        let fixture = try HostedSessionFixture()
        let snapshot = await fixture.session.open()

        XCTAssertEqual(snapshot.elapsedSeconds(localNow: 1_005_000), 35)
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
                "/live/v1/activities/activity-1/lease/release",
                "/live/v1/activities/activity-2",
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
        session = HostedPracticeSession(
            client: LiveV1Client(tokenReader: token, transport: transport),
            tokenReader: token,
            identityStore: PrivateLiveIdentityStore(
                directoryURL: root.appendingPathComponent("identity")
            ),
            outbox: outbox,
            clipStore: PrivateLiveClipStore(
                directoryURL: root.appendingPathComponent("clips")
            ),
            clock: TestLiveClock(now: 1_000_000),
            holderSessionID: holderSessionID
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor TestTokenReader: LiveIntegrationTokenReading {
    func readIntegrationToken() -> String { "public-test-token" }
    func credentialFingerprint() -> String { String(repeating: "a", count: 64) }
}

private struct TestLiveClock: LiveClock {
    let now: LiveEpochMilliseconds
    func epochMilliseconds() -> LiveEpochMilliseconds { now }
}

private enum HostedFixtureTransportError: Error { case expectedFailure }

private actor HostedFixtureTransport: LiveV1Transport {
    private var recorded: [LiveV1Request] = []
    private var failCommand = false
    private var rejectLeaseAcquire = false
    private var useNextActivity = false

    func failNextCommandTransport() { failCommand = true }
    func rejectNextLeaseAcquire() { rejectLeaseAcquire = true }
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
            return response(HostedFixtures.activity)
        }
        if request.path == "/live/v1/activities/activity-2" {
            return response(HostedFixtures.nextActivity)
        }
        if request.path.contains("/receipts/") {
            return errorResponse(
                status: 404,
                code: "receipt_not_found",
                retryable: false
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
        } else if request.path.hasSuffix("/lease/release") {
            operation = "lease.release"
            lease = nil
        } else if request.path.hasSuffix("/commands") {
            operation = "command.\(object["command"] as? String ?? "")"
            lease = nil
        } else {
            operation = "fixture"
            lease = nil
        }
        let projectedActivity = request.path.contains("activity-2")
            ? HostedFixtures.nextActivity
            : HostedFixtures.activity
        let selectedNextActivityID = object["command"] as? String == "finish-next"
            ? "activity-2"
            : nil
        return response(
            LiveMutationResponse(
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
                clip: nil
            )
        )
    }

    private func response<Value: Encodable>(_ value: Value) -> LiveV1HTTPResponse {
        LiveV1HTTPResponse(
            statusCode: 200,
            body: try! JSONEncoder().encode(value)
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
