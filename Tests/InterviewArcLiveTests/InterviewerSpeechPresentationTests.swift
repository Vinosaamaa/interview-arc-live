import XCTest

@testable import InterviewArcLiveCore
@testable import InterviewArcLive

final class InterviewerSpeechPresentationTests: XCTestCase {
    func testFailedRetryKeepsPriorSelectedVoicePlayable() throws {
        let utterance = try utteranceWithPreservedAudio(
            latestRetryLifecycle: .failed
        )
        let presentation = InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: false
        )

        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertEqual(utterance.latestAttempt?.lifecycle, .failed)
        XCTAssertNotNil(utterance.selectedAudio)
        XCTAssertEqual(presentation.title, "Retry failed")
        XCTAssertTrue(presentation.detail.contains("prior saved voice"))
        XCTAssertTrue(presentation.canPlay)
        XCTAssertTrue(presentation.canRetry)
        XCTAssertEqual(presentation.primaryActionTitle, "Play")
    }

    func testStoppedRetryKeepsPriorSelectedVoicePlayable() throws {
        let utterance = try utteranceWithPreservedAudio(
            latestRetryLifecycle: .stopped
        )
        let presentation = InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: false
        )

        XCTAssertEqual(utterance.lifecycle, .ready)
        XCTAssertEqual(utterance.latestAttempt?.stopReason, .userStopped)
        XCTAssertNotNil(utterance.selectedAudio)
        XCTAssertEqual(presentation.title, "Retry stopped")
        XCTAssertTrue(presentation.detail.contains("prior saved voice"))
        XCTAssertTrue(presentation.canPlay)
        XCTAssertTrue(presentation.canRetry)
        XCTAssertEqual(presentation.primaryActionTitle, "Play")
    }

    func testPendingHistoricalTurnRequiresAnExplicitGenerateAction() {
        let utterance = InterviewerUtterance(
            id: InterviewerUtteranceID("utterance-pending"),
            turnID: TurnID("turn-pending"),
            spokenTextFingerprint: "spoken-text-fingerprint"
        )
        let presentation = InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: false
        )

        XCTAssertEqual(presentation.primaryActionTitle, "Generate")
        XCTAssertTrue(presentation.canRetry)
        XCTAssertFalse(presentation.canPlay)
        XCTAssertFalse(presentation.canStop)
    }

    func testMutedReadyVoiceKeepsTranscriptAndSavedAudioStateWithoutPlay() throws {
        let utterance = try utteranceWithReadyAudio()
        let presentation = InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: true
        )

        XCTAssertEqual(presentation.title, "Voice ready")
        XCTAssertTrue(presentation.detail.contains("Unmute"))
        XCTAssertFalse(presentation.canPlay)
        XCTAssertFalse(presentation.canRetry)
    }

    func testReadyVoiceOffersPlayAndExplicitReplacementRetrySeparately() throws {
        let utterance = try utteranceWithReadyAudio()
        let presentation = InterviewerUtterancePresentation.make(
            utterance: utterance,
            isMuted: false
        )

        XCTAssertTrue(presentation.canPlay)
        XCTAssertTrue(presentation.canRetry)
    }

    func testPreparationProgressIsClampedForDefensiveRendering() {
        let presentation = InterviewerSpeechReadinessPresentation.make(
            readiness: .preparing(
                InterviewerSpeechPreparationProgress(
                    stage: .downloading,
                    completedBytes: 250,
                    totalBytes: 100
                )
            )
        )

        XCTAssertEqual(presentation.progress, 1)
        XCTAssertTrue(presentation.canCancel)
        XCTAssertFalse(presentation.canDownload)
    }

    func testVerificationFailurePreservesExplicitRecoveryAndInterviewUse() {
        let presentation = InterviewerSpeechReadinessPresentation.make(
            readiness: .unavailable(.verificationFailed)
        )

        XCTAssertEqual(presentation.title, "Model verification failed")
        XCTAssertTrue(presentation.detail.contains("not promoted"))
        XCTAssertTrue(presentation.canDownload)
        XCTAssertTrue(presentation.showsInstallDisclosure)
    }

    func testCancelledDownloadCanBeExplicitlyRestarted() {
        let presentation = InterviewerSpeechReadinessPresentation.make(
            readiness: .unavailable(.cancelled)
        )

        XCTAssertTrue(presentation.canDownload)
        XCTAssertFalse(presentation.canCancel)
    }

    func testIncompatibleRuntimeDoesNotOfferARepeatDownload() {
        let presentation = InterviewerSpeechReadinessPresentation.make(
            readiness: .unavailable(.incompatibleRuntime)
        )

        XCTAssertFalse(presentation.canDownload)
        XCTAssertEqual(
            presentation.title,
            "Local voice unavailable on this Mac"
        )
    }

    private func utteranceWithReadyAudio() throws -> InterviewerUtterance {
        let attemptID = SynthesisAttemptID("attempt-ready")
        let attempt = try synthesisAttempt(
            id: attemptID,
            kind: .initial,
            lifecycle: .ready,
            hashCharacter: "a",
            audio: true
        )
        return InterviewerUtterance(
            id: InterviewerUtteranceID("utterance-ready"),
            turnID: TurnID("turn-ready"),
            spokenTextFingerprint: "spoken-text-fingerprint",
            lifecycle: .ready,
            synthesisAttempts: [attempt],
            selectedAttemptID: attemptID
        )
    }

    private func utteranceWithPreservedAudio(
        latestRetryLifecycle: SynthesisAttemptLifecycle
    ) throws -> InterviewerUtterance {
        precondition(
            latestRetryLifecycle == .failed || latestRetryLifecycle == .stopped
        )
        let selectedAttemptID = SynthesisAttemptID("attempt-selected")
        let selected = try synthesisAttempt(
            id: selectedAttemptID,
            kind: .initial,
            lifecycle: .ready,
            hashCharacter: "a",
            audio: true
        )
        let retry = try synthesisAttempt(
            id: SynthesisAttemptID("attempt-retry"),
            kind: .retry,
            lifecycle: latestRetryLifecycle,
            hashCharacter: "b",
            audio: false
        )
        return InterviewerUtterance(
            id: InterviewerUtteranceID("utterance-retried"),
            turnID: TurnID("turn-retried"),
            spokenTextFingerprint: "spoken-text-fingerprint",
            lifecycle: .ready,
            synthesisAttempts: [selected, retry],
            selectedAttemptID: selectedAttemptID
        )
    }

    private func synthesisAttempt(
        id: SynthesisAttemptID,
        kind: SynthesisAttemptKind,
        lifecycle: SynthesisAttemptLifecycle,
        hashCharacter: Character,
        audio includesAudio: Bool
    ) throws -> SynthesisAttempt {
        let digest = String(repeating: hashCharacter, count: 64)
        let finalIdentity = try InterviewerAudioIdentity(
            validating: "speech-\(digest).wav"
        )
        let artifact = includesAudio
            ? InterviewerSpeechAudioArtifact(
                audioIdentity: finalIdentity,
                sampleRate: 24_000,
                channelCount: 1,
                durationMilliseconds: 0,
                byteCount: 48,
                sha256: String(repeating: "c", count: 64)
            )
            : nil
        return SynthesisAttempt(
            id: id,
            authorizationCommandID: CommandID("authorize-\(id.rawValue)"),
            kind: kind,
            provenance: InterviewerSpeechProvenance(
                providerID: "local-test-provider",
                modelID: "local-test-model",
                modelRevision: "exact-test-revision",
                profile: .maraV1
            ),
            partialAudioIdentity: try InterviewerAudioIdentity(
                validating: "speech-\(digest).partial.wav"
            ),
            finalAudioIdentity: finalIdentity,
            lifecycle: lifecycle,
            audio: artifact,
            failure: lifecycle == .failed
                ? InterviewerSynthesisFailure(reason: .providerFailed)
                : nil,
            stopReason: lifecycle == .stopped ? .userStopped : nil
        )
    }
}
