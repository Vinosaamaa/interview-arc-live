import Foundation
import XCTest

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
import InterviewArcLiveHostedClient
@testable import InterviewArcLive

@MainActor
final class SystemDesignRoomHostedRefreshTests: XCTestCase {
    func testRefreshOpensTheRoomAfterASystemDesignActivityAppears() async throws {
        let fixture = try await HostedRefreshFixture(hasSystemDesignActivity: false)
        let boardRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hosted-refresh-board-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: boardRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: boardRoot) }
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready),
            speechDependencies: unusedSpeechDependencies(),
            boardArtifactStore: PrivateBoardArtifactStore(root: boardRoot),
            hostedController: fixture.controller,
            recording: UnusedRefreshRecording(),
            transcriber: UnusedRefreshTranscriber(),
            manifestStore: InMemorySessionManifestStore()
        )

        await model.open()

        XCTAssertNil(model.coordinator)
        XCTAssertEqual(
            model.statusMessage,
            "No System Design activity is open in Interview Arc Today"
        )

        await fixture.transport.exposeSystemDesignActivity()
        await model.refreshHostedAuthority()

        XCTAssertNotNil(model.coordinator)
        XCTAssertNotEqual(
            model.statusMessage,
            "No System Design activity is open in Interview Arc Today"
        )
        XCTAssertNotNil(model.hostedSnapshot.activity)
    }

    func testRefreshDoesNotReplaceAnExistingCoordinator() async throws {
        let fixture = try await HostedRefreshFixture(hasSystemDesignActivity: true)
        _ = await fixture.controller.open()
        let (model, _) = try await makeCompletionBlockingRoomModel(
            hostedController: fixture.controller
        )
        let existing = try XCTUnwrap(model.coordinator)

        await model.refreshHostedAuthority()

        XCTAssertTrue(model.coordinator === existing)
    }
}

@MainActor
private final class HostedRefreshFixture {
    let transport: HostedRefreshTransport
    let controller: HostedPracticeController
    private let root: URL

    init(hasSystemDesignActivity: Bool) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hosted-refresh-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let tokenStore = LiveIntegrationTokenStore()
        try await tokenStore.useUntilQuit("public-test-integration-token")
        transport = HostedRefreshTransport(
            hasSystemDesignActivity: hasSystemDesignActivity
        )
        controller = HostedPracticeController(
            tokenStore: tokenStore,
            session: HostedPracticeSession(
                client: LiveV1Client(
                    tokenReader: tokenStore,
                    transport: transport
                ),
                tokenReader: tokenStore,
                identityStore: PrivateLiveIdentityStore(
                    directoryURL: root.appendingPathComponent("identity")
                ),
                outbox: PrivateLiveOutboxStore(
                    directoryURL: root.appendingPathComponent("outbox")
                ),
                clipStore: PrivateLiveClipStore(
                    directoryURL: root.appendingPathComponent("clips")
                ),
                holderSessionID: "room-session-1"
            ),
            eventStream: try LiveEventStream(
                origin: URL(string: "https://127.0.0.1")!,
                tokenReader: tokenStore
            ),
            tokenValidator: { _ in }
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor HostedRefreshTransport: LiveV1Transport {
    private var hasSystemDesignActivity: Bool
    private var heldLease: LiveLeaseGrant?

    init(hasSystemDesignActivity: Bool) {
        self.hasSystemDesignActivity = hasSystemDesignActivity
    }

    func exposeSystemDesignActivity() {
        hasSystemDesignActivity = true
    }

    func send(_ request: LiveV1Request) async throws -> LiveV1HTTPResponse {
        if request.path == "/live/v1/today" {
            return json(
                hasSystemDesignActivity
                    ? HostedRefreshFixtures.today
                    : HostedRefreshFixtures.emptyToday
            )
        }
        if request.path == "/live/v1/activities/activity-1" {
            return json(activityProjection())
        }
        guard request.path.hasSuffix("/lease/acquire"),
              let body = request.body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationID = object["operationId"] as? String else {
            return json(
                LiveErrorBody(
                    error: "Fixture rejection",
                    code: "invalid_request",
                    retryable: false,
                    holderPresent: nil,
                    expiresAt: nil
                ),
                status: 400
            )
        }
        let lease = LiveLeaseGrant(
            fencingToken: 7,
            expiresAt: 1_090_000,
            holderSessionId: object["holderSessionId"] as? String ?? ""
        )
        heldLease = lease
        return json(
            LiveMutationResponse(
                protocolVersion: 1,
                duplicate: false,
                receipt: LiveMutationReceipt(
                    protocolVersion: 1,
                    operationId: operationID,
                    activityId: HostedRefreshFixtures.activity.activity.id,
                    operation: "lease.acquire",
                    committedAt: 1_000_000,
                    result: [:]
                ),
                activity: activityProjection(),
                lease: lease,
                selectedNextActivityId: nil,
                confirmation: nil,
                today: HostedRefreshFixtures.today,
                clip: nil
            )
        )
    }

    private func activityProjection() -> LiveActivityProjection {
        let base = HostedRefreshFixtures.activity
        return LiveActivityProjection(
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
            pairs: base.pairs,
            clips: base.clips
        )
    }

    private func json<Value: Encodable>(
        _ value: Value,
        status: Int = 200
    ) -> LiveV1HTTPResponse {
        LiveV1HTTPResponse(
            statusCode: status,
            body: try! JSONEncoder().encode(value)
        )
    }
}

private enum HostedRefreshFixtures {
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
                activityIds: ["activity-1"],
                allocatedSeconds: 2_700,
                revision: 1,
                timer: nil
            ),
        ],
        activities: [summary]
    )
    static let emptyToday = LiveTodayProjection(
        protocolVersion: 1,
        serverTime: 1_000_000,
        ownerRevision: 8,
        workbench: workbench,
        focus: LiveFocus(
            activityId: nil,
            sessionId: nil,
            focusedAt: nil
        ),
        sessions: [],
        activities: []
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
}

private actor CodexRuntimeFixture: LiveCodexInterviewerRuntime {
    private let readiness: CodexAppServerReadiness

    init(readiness: CodexAppServerReadiness) {
        self.readiness = readiness
    }

    func preflight() async -> CodexAppServerReadiness {
        readiness
    }

    func respond(
        to request: InterviewerRequest
    ) async throws -> CanonicalInterviewerResponse {
        CanonicalInterviewerResponse(
            displayMarkdown: "What tradeoff would you test next?",
            spokenText: "What tradeoff would you test next?"
        )
    }
}

@MainActor
private func unusedSpeechDependencies() -> LiveInterviewerSpeechDependencies {
    LiveInterviewerSpeechDependencies(
        provider: UnusedRefreshSpeechProvider(),
        player: UnusedRefreshSpeechPlayer(),
        audioStore: UnusedRefreshSpeechAudioStore()
    )
}

private actor UnusedRefreshSpeechProvider: InterviewerSpeechProvider {
    nonisolated let provenance = InterviewerSpeechProvenance(
        providerID: "fixture-provider",
        modelID: "fixture-model",
        modelRevision: "0",
        profile: .maraV1
    )

    func readiness() -> InterviewerSpeechReadiness { .notInstalled }

    func prepare(
        _ policy: InterviewerSpeechPreparationPolicy,
        progress: @escaping @Sendable (InterviewerSpeechPreparationProgress) -> Void
    ) -> InterviewerSpeechReadiness {
        .notInstalled
    }

    func synthesize(
        _ request: InterviewerSpeechSynthesisRequest
    ) async throws -> AsyncThrowingStream<InterviewerSpeechEvent, Error> {
        throw RefreshFixtureError.unused
    }

    func cancelSynthesis() {}
    func unload() {}
    func removePreparedModel() -> InterviewerSpeechReadiness { .notInstalled }
}

@MainActor
private final class UnusedRefreshSpeechPlayer: InterviewerSpeechPlaying {
    func beginStreaming(sampleRate: Int, channelCount: Int) async throws {}
    func enqueue(_ chunk: InterviewerSpeechPCMChunk) async throws {}
    func finishStreaming() async throws {}
    func stop() async {}
    func play(_ request: InterviewerSpeechPlaybackRequest) async throws {}
}

private actor UnusedRefreshSpeechAudioStore: InterviewerSpeechAudioStoring {
    func beginWrite(_ request: InterviewerSpeechAudioWriteRequest) async throws {}
    func append(
        _ chunk: InterviewerSpeechPCMChunk,
        attemptID: SynthesisAttemptID
    ) async throws {}
    func finalizeWrite(
        attemptID: SynthesisAttemptID
    ) async throws -> InterviewerSpeechAudioArtifact {
        throw RefreshFixtureError.unused
    }
    func discardPartial(attemptID: SynthesisAttemptID) async {}
    func recoverFinalizedAudio(
        _ request: InterviewerSpeechAudioRecoveryRequest
    ) async throws -> InterviewerSpeechAudioArtifact? {
        nil
    }
    func validateAudio(
        sessionID: SessionID,
        artifact: InterviewerSpeechAudioArtifact
    ) async -> Bool {
        false
    }
}

@MainActor
private final class UnusedRefreshRecording: SegmentRecording {
    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {}

    func beginCapture(_ request: SegmentCaptureRequest) async throws {
        throw RefreshFixtureError.unused
    }

    func finishCapture() async throws -> CapturedAudioSegment {
        throw RefreshFixtureError.unused
    }

    func recoverCapture(
        _ request: SegmentCaptureRequest
    ) async throws -> CapturedAudioSegment? {
        nil
    }

    func playbackURL(
        sessionID: SessionID,
        audioIdentity: SegmentAudioIdentity
    ) async throws -> URL {
        throw RefreshFixtureError.unused
    }
}

private struct UnusedRefreshTranscriber: SegmentTranscribing {
    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        throw RefreshFixtureError.unused
    }
}

private enum RefreshFixtureError: Error {
    case unused
}
