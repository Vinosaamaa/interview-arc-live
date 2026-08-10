import Foundation

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
func makeCompletionBlockingRoomModel() async throws -> (
    model: SystemDesignRoomModel,
    store: CompletionBlockingManifestStore
) {
    let store = CompletionBlockingManifestStore()
    let prompt = try ActivityPrompt(
        specialty: .systemDesign,
        stage: "High-level design",
        question: "Design a public-safe notification service.",
        requestedParts: ["Clarify requirements."]
    )
    let runtime = FinishRuntimeFixture()
    let coordinator = try await SegmentSpeechCoordinator.open(
        sessionID: SessionID("finish-fixture-\(UUID().uuidString)"),
        activityID: "finish-fixture",
        activityPrompt: prompt,
        manifestStore: store,
        interviewerRuntime: runtime,
        recording: UnusedFinishRecording(),
        transcriber: UnusedFinishTranscriber(),
        credentialReader: UnusedFinishCredentialReader()
    )
    return (
        SystemDesignRoomModel(
            codexRuntime: runtime,
            activityPrompt: prompt,
            initialCoordinator: coordinator
        ),
        store
    )
}

actor CompletionBlockingManifestStore: SessionManifestStore {
    private let backing = InMemorySessionManifestStore()
    private var completionSaveCountValue = 0
    private var completionSaveStarted = false
    private var holdsCompletionSave = true
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func load(sessionID: SessionID) async throws -> SessionManifest? {
        await backing.load(sessionID: sessionID)
    }

    func save(
        _ manifest: SessionManifest,
        expectedRevision: Int?
    ) async throws {
        if manifest.phase == .completed {
            completionSaveCountValue += 1
            completionSaveStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
            if holdsCompletionSave {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }
        try await backing.save(
            manifest,
            expectedRevision: expectedRevision
        )
    }

    func waitUntilCompletionSaveStarts() async {
        if completionSaveStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func releaseCompletionSave() {
        holdsCompletionSave = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func completionSaveCount() -> Int {
        completionSaveCountValue
    }
}

private struct FinishRuntimeFixture: LiveCodexInterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness {
        .ready
    }

    func respond(
        to request: InterviewerRequest
    ) async throws -> CanonicalInterviewerResponse {
        CanonicalInterviewerResponse(
            displayMarkdown: "What reliability tradeoff would you test next?",
            spokenText: "What reliability tradeoff would you test next?"
        )
    }
}

@MainActor
private final class UnusedFinishRecording: SegmentRecording {
    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {}

    func beginCapture(_ request: SegmentCaptureRequest) async throws {
        throw FinishFixtureError.unused
    }

    func finishCapture() async throws -> CapturedAudioSegment {
        throw FinishFixtureError.unused
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
        throw FinishFixtureError.unused
    }
}

private struct UnusedFinishTranscriber: SegmentTranscribing {
    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        throw FinishFixtureError.unused
    }
}

private struct UnusedFinishCredentialReader: GroqCredentialReading {
    func readGroqCredential() async throws -> String {
        throw FinishFixtureError.unused
    }
}

private enum FinishFixtureError: Error {
    case unused
}
