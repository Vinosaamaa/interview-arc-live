import Foundation
import XCTest

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
import InterviewArcLiveLocalSpeechAdapter
@testable import InterviewArcLive

@MainActor
final class SystemDesignRoomModelTests: XCTestCase {
    func testVoiceChoiceSurvivesRelaunchAndUnknownPreferenceFallsBackToQwen() async throws {
        let name = "live-voice-choice-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("removed-provider", forKey: "live.interviewer-speech.engine")
        let first = SystemDesignRoomModel(preferences: preferences)
        XCTAssertEqual(first.selectedSpeechEngine, .qwen)
        await first.selectSpeechEngine(.kokoro)
        XCTAssertEqual(first.selectedSpeechEngine, .kokoro)
        XCTAssertTrue(first.speechReadinessPresentation.detail.contains("321.2 MiB"))
        let restored = SystemDesignRoomModel(preferences: preferences)
        XCTAssertEqual(restored.selectedSpeechEngine, .kokoro)
        await restored.selectSpeechEngine(.qwen)
        XCTAssertEqual(SystemDesignRoomModel(preferences: preferences).selectedSpeechEngine, .qwen)
    }

    func testReadyCodexEnablesAQuietReadyStatus() async {
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .ready)
        )

        await model.checkInterviewer()

        XCTAssertTrue(model.isInterviewerReady)
        XCTAssertEqual(model.interviewerStatusTitle, "Fixture ready")
        XCTAssertNil(model.interviewerAttentionMessage)
    }

    func testMissingCodexKeepsRecordingRecoveryCopyActionable() async {
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .missing)
        )

        await model.checkInterviewer()

        XCTAssertFalse(model.isInterviewerReady)
        XCTAssertEqual(model.interviewerStatusTitle, "Fixture not found")
        XCTAssertEqual(
            model.interviewerAttentionMessage,
            "Install or configure Fixture, then check again. Your recorded segments remain saved."
        )
    }

    func testFailedCodexReadinessOffersRetryWithoutRequiringAVersion() async {
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .transportFailure)
        )

        await model.checkInterviewer()

        XCTAssertFalse(model.isInterviewerReady)
        XCTAssertEqual(model.interviewerStatusTitle, "Fixture unavailable")
        XCTAssertEqual(
            model.interviewerAttentionMessage,
            "Fixture could not complete its readiness check. Check again; your interview draft is unchanged."
        )
    }

    func testInjectedActivityPromptOwnsQuestionCopy() throws {
        let prompt = try ActivityPrompt(
            specialty: .systemDesign,
            stage: "Requirements",
            question: "Design a public-safe test service.",
            requestedParts: ["Clarify scope."]
        )
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .ready),
            activityPrompt: prompt
        )

        XCTAssertEqual(model.question, prompt.question)
    }

    func testRuntimeFailuresUseSafeDurabilityCopy() {
        let privateServerCode = 9_999
        let failures: [InterviewerRuntimeError] = [
            .missing,
            .unauthenticated,
            .transportFailure,
            .protocolFailure,
            .serverFailure(code: privateServerCode),
            .malformedFinalResponse,
            .cancelled,
        ]

        for failure in failures {
            let message = SystemDesignRoomModel.safeInterviewerFailureMessage(for: failure)
            XCTAssertTrue(message.contains("saved"))
            XCTAssertFalse(message.contains(String(privateServerCode)))
        }
    }

    func testTurnModeSurfaceOffersFunctionalPatientAuto() {
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .ready)
        )

        XCTAssertEqual(
            model.availableTurnModes,
            [.continuousConversation, .patientAuto, .manual]
        )
        XCTAssertFalse(model.availableTurnModes.contains(.cueOnly))
        XCTAssertEqual(model.turnMode, .continuousConversation)
        XCTAssertEqual(model.turnModeTitle(.continuousConversation), "Automatic")
        XCTAssertEqual(model.turnModeTitle(.manual), "Manual")
        XCTAssertEqual(model.turnModeTitle(.patientAuto), "Patient Auto")
        XCTAssertEqual(
            model.endpointHandoffPresentation.title,
            "Automatic waits for your floor"
        )
    }

    func testMuteStateAndPreferenceFollowControllerWhenDurableStopFails() async throws {
        let suiteName = "InterviewArcLiveTests.mute.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = MutingThenFailingSpeechController()
        let model = SystemDesignRoomModel(
            interviewerRuntime: CodexRuntimeFixture(readiness: .ready),
            preferences: preferences
        )

        await model.toggleSpeechMute(using: controller)

        XCTAssertTrue(controller.isMuted)
        XCTAssertTrue(model.isSpeechMuted)
        XCTAssertTrue(
            preferences.bool(
                forKey: "interviewArcLive.interviewerSpeechMuted"
            )
        )
        XCTAssertNotNil(model.speechErrorMessage)
    }

    func testLikelyEndCopyPreparesAutomaticHandOff() {
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: evaluation,
                endpointGrace: nil,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(presentation.title, "Preparing automatic Hand off")
        XCTAssertTrue(presentation.detail.contains("completion signal is saved"))
        XCTAssertEqual(presentation.tone, .advisory)
    }

    func testLikelyEndRequiresAnAttachableBoardBeforeGrace() {
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: evaluation,
                endpointGrace: nil,
                canAutomaticallyHandOff: false,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(
            presentation.title,
            "Save the Board before automatic Hand off"
        )
        XCTAssertTrue(presentation.detail.contains("Save this Board draft"))
        XCTAssertEqual(presentation.tone, .warning)
    }

    func testPatientAutoFailureCopyDoesNotExposeProviderStatus() {
        let privateProviderStatus = 599
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .failed,
            failure: EndpointEvaluationFailure(
                reason: .providerRejected,
                providerStatusCode: privateProviderStatus
            )
        )

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: evaluation,
                endpointGrace: nil,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(presentation.title, "Patient Auto request rejected")
        XCTAssertTrue(presentation.detail.contains("transcript is saved"))
        XCTAssertFalse(presentation.detail.contains(String(privateProviderStatus)))
        XCTAssertEqual(presentation.tone, .warning)
    }

    func testOnlyLatestExactEvidenceEvaluationCanBeCurrent() {
        let candidateA = TranscriptCandidateID("candidate-a")
        let candidateB = TranscriptCandidateID("candidate-b")
        let olderMatching = endpointEvaluation(
            id: "older-evaluation",
            selectedCandidateIDs: [candidateA],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )
        let latestChanged = endpointEvaluation(
            id: "latest-evaluation",
            selectedCandidateIDs: [candidateA, candidateB],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyContinue,
                reasonCode: .unfinishedThought
            )
        )

        let stale = EndpointHandoffPresentation.currentEvaluation(
            in: [olderMatching, latestChanged],
            selectedCandidateIDs: [candidateA],
            questionTurnID: nil,
            hasUnresolvedDraft: false
        )
        XCTAssertNil(stale)

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: stale,
                endpointGrace: nil,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: true
            )
        )
        XCTAssertEqual(presentation.title, "Evidence changed · Patient Auto waiting")
        XCTAssertFalse(presentation.detail.contains("likely complete"))

        let current = EndpointHandoffPresentation.currentEvaluation(
            in: [olderMatching, latestChanged],
            selectedCandidateIDs: [candidateA, candidateB],
            questionTurnID: nil,
            hasUnresolvedDraft: false
        )
        XCTAssertEqual(current?.id, latestChanged.id)
    }

    func testFreshFloorWithHistoryWaitsForFirstNewTranscript() {
        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: nil,
                endpointGrace: nil,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: false,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(presentation.title, "Patient Auto waiting for a transcript")
        XCTAssertEqual(
            presentation.detail,
            "It checks after a new selected transcript is saved."
        )
    }

    func testRemovingAllSelectedEvidenceKeepsLatestEvaluationVisiblyStale() {
        let latestEvaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )
        let evaluations = [latestEvaluation]
        let currentEvaluation = EndpointHandoffPresentation.currentEvaluation(
            in: evaluations,
            selectedCandidateIDs: [],
            questionTurnID: nil,
            hasUnresolvedDraft: false
        )

        XCTAssertNil(currentEvaluation)
        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: currentEvaluation,
                endpointGrace: nil,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: false,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: evaluations.last != nil
                    && currentEvaluation == nil
            )
        )

        XCTAssertEqual(presentation.title, "Evidence changed · Patient Auto waiting")
        XCTAssertFalse(presentation.detail.contains("likely complete"))
    }

    func testPendingGraceExposesBoundedCancellationCopy() {
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )
        let grace = EndpointGrace.pending(
            id: EndpointGraceID("grace-a"),
            activationCommandID: CommandID("activate-grace-a"),
            evaluationID: evaluation.id,
            selectedCandidateIDs: evaluation.selectedCandidateIDs
        )

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: evaluation,
                endpointGrace: grace,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(presentation.title, "Handing off in 4 seconds")
        XCTAssertTrue(presentation.detail.contains("Keep my floor"))
        XCTAssertEqual(presentation.tone, .working)
    }

    func testKeptFloorGraceDoesNotPretendAutomaticHandOffIsStillPending() {
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )
        let grace = EndpointGrace.pending(
            id: EndpointGraceID("grace-kept"),
            activationCommandID: CommandID("activate-grace-kept"),
            evaluationID: evaluation.id,
            selectedCandidateIDs: evaluation.selectedCandidateIDs
        ).cancelling(reason: .keptFloor)

        let presentation = EndpointHandoffPresentation.make(
            input: .init(
                turnMode: .patientAuto,
                phase: .candidateFloor,
                currentEvaluation: evaluation,
                endpointGrace: grace,
                canAutomaticallyHandOff: true,
                hasSelectedDraft: true,
                hasUnresolvedDraft: false,
                hasStaleEvaluation: false
            )
        )

        XCTAssertEqual(presentation.title, "Your floor is staying open")
        XCTAssertTrue(presentation.detail.contains("new completed Segment"))
        XCTAssertFalse(presentation.title.contains("4 seconds"))
    }

    private func endpointEvaluation(
        id: String = "endpoint-evaluation",
        selectedCandidateIDs: [TranscriptCandidateID],
        questionTurnID: TurnID? = nil,
        lifecycle: EndpointEvaluationLifecycle,
        proposal: SemanticEndpointProposal? = nil,
        failure: EndpointEvaluationFailure? = nil
    ) -> EndpointEvaluation {
        let endpointID = EndpointEvaluationID(id)
        let commandID = CommandID("authorization-\(id)")
        let triggerSegmentID = SegmentID("trigger-segment")
        let fingerprint = "sha256:v1:\(String(repeating: "a", count: 64))"
        switch lifecycle {
        case .authorized:
            return .authorized(
                id: endpointID,
                authorizationCommandID: commandID,
                triggerSegmentID: triggerSegmentID,
                selectedCandidateIDs: selectedCandidateIDs,
                questionTurnID: questionTurnID,
                contextFingerprint: fingerprint
            )
        case .proposalStored:
            guard let proposal else {
                preconditionFailure("A stored proposal fixture requires a proposal")
            }
            return .proposalStored(
                id: endpointID,
                authorizationCommandID: commandID,
                triggerSegmentID: triggerSegmentID,
                selectedCandidateIDs: selectedCandidateIDs,
                questionTurnID: questionTurnID,
                contextFingerprint: fingerprint,
                proposal: proposal
            )
        case .failed:
            guard let failure else {
                preconditionFailure("A failed evaluation fixture requires a failure")
            }
            return .failed(
                id: endpointID,
                authorizationCommandID: commandID,
                triggerSegmentID: triggerSegmentID,
                selectedCandidateIDs: selectedCandidateIDs,
                questionTurnID: questionTurnID,
                contextFingerprint: fingerprint,
                failure: failure
            )
        }
    }
}

private actor CodexRuntimeFixture: InterviewerProvider {
    let providerName = "Fixture"
    private let readiness: InterviewerReadiness

    init(readiness: InterviewerReadiness) {
        self.readiness = readiness
    }

    func preflight() async -> InterviewerReadiness {
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
private final class MutingThenFailingSpeechController:
    LiveInterviewerSpeechMuteControlling
{
    enum Failure: Error {
        case manifestPersistenceFailed
    }

    private(set) var isMuted = false

    func setMuted(_ muted: Bool, commandID: CommandID) async throws {
        isMuted = muted
        throw Failure.manifestPersistenceFailed
    }
}
