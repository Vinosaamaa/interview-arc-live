import Foundation
import XCTest

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class SystemDesignRoomModelTests: XCTestCase {
    func testReadyCodexEnablesAQuietReadyStatus() async {
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready)
        )

        await model.checkCodex()

        XCTAssertTrue(model.isCodexReady)
        XCTAssertEqual(model.codexStatusTitle, "Codex ready")
        XCTAssertNil(model.codexAttentionMessage)
    }

    func testMissingCodexKeepsRecordingRecoveryCopyActionable() async {
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .missing)
        )

        await model.checkCodex()

        XCTAssertFalse(model.isCodexReady)
        XCTAssertEqual(model.codexStatusTitle, "Codex not found")
        XCTAssertEqual(
            model.codexAttentionMessage,
            "Install or update ChatGPT or Codex, then check again. Your recorded segments remain saved."
        )
    }

    func testIncompatibleCodexShowsRequiredVersionWithoutActualDetails() async {
        let actual = "codex-cli unsupported-private-detail"
        let required = CodexAppServerInterviewerRuntime.testedCLIVersion
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(
                readiness: .incompatible(
                    actualVersion: actual,
                    requiredVersion: required
                )
            )
        )

        await model.checkCodex()

        let message = try? XCTUnwrap(model.codexAttentionMessage)
        XCTAssertEqual(model.codexStatusTitle, "Codex update required")
        XCTAssertTrue(message?.contains(required) == true)
        XCTAssertFalse(message?.contains(actual) == true)
    }

    func testInjectedActivityPromptOwnsQuestionCopy() throws {
        let prompt = try ActivityPrompt(
            specialty: .systemDesign,
            stage: "Requirements",
            question: "Design a public-safe test service.",
            requestedParts: ["Clarify scope."]
        )
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready),
            activityPrompt: prompt
        )

        XCTAssertEqual(model.question, prompt.question)
    }

    func testRuntimeFailuresUseSafeDurabilityCopy() {
        let privateActualVersion = "private-actual-version-detail"
        let privateServerCode = 9_999
        let failures: [CodexAppServerRuntimeError] = [
            .missing,
            .incompatible(
                actualVersion: privateActualVersion,
                requiredVersion: CodexAppServerInterviewerRuntime.testedCLIVersion
            ),
            .unauthenticated,
            .transportFailure,
            .protocolFailure,
            .serverFailure(code: privateServerCode),
            .malformedFinalResponse,
            .cancelled,
        ]

        for failure in failures {
            let message = SystemDesignRoomModel.safeCodexFailureMessage(for: failure)
            XCTAssertTrue(message.contains("saved"))
            XCTAssertFalse(message.contains(privateActualVersion))
            XCTAssertFalse(message.contains(String(privateServerCode)))
        }
    }

    func testTurnModeSurfaceOffersFunctionalPatientAuto() {
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready)
        )

        XCTAssertEqual(model.availableTurnModes, [.manual, .patientAuto])
        XCTAssertFalse(model.availableTurnModes.contains(.cueOnly))
        XCTAssertEqual(model.turnMode, .manual)
        XCTAssertEqual(model.turnModeTitle(.manual), "Manual")
        XCTAssertEqual(model.turnModeTitle(.patientAuto), "Patient Auto")
        XCTAssertEqual(
            model.endpointHandoffPresentation.detail,
            "Semantic endpoint calls are off. Hand off remains explicit."
        )
    }

    func testHostedRefreshOpensTheLocalCoordinatorOnlyOnceActivityExists() {
        XCTAssertFalse(
            SystemDesignRoomModel.shouldOpenLocalCoordinator(
                hasHostedActivity: false,
                hasCoordinator: false
            )
        )
        XCTAssertFalse(
            SystemDesignRoomModel.shouldOpenLocalCoordinator(
                hasHostedActivity: false,
                hasCoordinator: true
            )
        )
        XCTAssertFalse(
            SystemDesignRoomModel.shouldOpenLocalCoordinator(
                hasHostedActivity: true,
                hasCoordinator: true
            )
        )
        XCTAssertTrue(
            SystemDesignRoomModel.shouldOpenLocalCoordinator(
                hasHostedActivity: true,
                hasCoordinator: false
            )
        )
    }

    func testMuteStateAndPreferenceFollowControllerWhenDurableStopFails() async throws {
        let suiteName = "InterviewArcLiveTests.mute.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let controller = MutingThenFailingSpeechController()
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready),
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
