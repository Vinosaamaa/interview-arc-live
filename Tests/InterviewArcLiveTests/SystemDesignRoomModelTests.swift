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

    func testTurnModeSurfaceOffersOnlyManualAndPatientAutoShadow() {
        let model = SystemDesignRoomModel(
            codexRuntime: CodexRuntimeFixture(readiness: .ready)
        )

        XCTAssertEqual(model.availableTurnModes, [.manual, .patientAuto])
        XCTAssertFalse(model.availableTurnModes.contains(.cueOnly))
        XCTAssertEqual(model.turnMode, .manual)
        XCTAssertEqual(model.turnModeTitle(.manual), "Manual")
        XCTAssertEqual(model.turnModeTitle(.patientAuto), "Patient Auto · Shadow")
        XCTAssertEqual(
            model.endpointShadowPresentation.detail,
            "Semantic endpoint calls are off. Hand off remains explicit."
        )
    }

    func testLikelyEndShadowCopyRemainsExplicitlyAdvisory() {
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .proposalStored,
            proposal: SemanticEndpointProposal(
                decision: .likelyEnd,
                reasonCode: .answerResolvesQuestion
            )
        )

        let presentation = EndpointShadowPresentation.make(
            turnMode: .patientAuto,
            phase: .candidateFloor,
            currentEvaluation: evaluation,
            hasSelectedDraft: true,
            hasUnresolvedDraft: false,
            hasStaleEvaluation: false
        )

        XCTAssertEqual(presentation.title, "Shadow: likely complete")
        XCTAssertTrue(presentation.detail.contains("advisory only"))
        XCTAssertTrue(presentation.detail.contains("choose Hand off"))
        XCTAssertEqual(presentation.tone, .advisory)
    }

    func testShadowFailureCopyDoesNotExposeProviderStatus() {
        let privateProviderStatus = 599
        let evaluation = endpointEvaluation(
            selectedCandidateIDs: [TranscriptCandidateID("candidate-a")],
            lifecycle: .failed,
            failure: EndpointEvaluationFailure(
                reason: .providerRejected,
                providerStatusCode: privateProviderStatus
            )
        )

        let presentation = EndpointShadowPresentation.make(
            turnMode: .patientAuto,
            phase: .candidateFloor,
            currentEvaluation: evaluation,
            hasSelectedDraft: true,
            hasUnresolvedDraft: false,
            hasStaleEvaluation: false
        )

        XCTAssertEqual(presentation.title, "Shadow request rejected")
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

        let stale = EndpointShadowPresentation.currentEvaluation(
            in: [olderMatching, latestChanged],
            selectedCandidateIDs: [candidateA],
            questionTurnID: nil,
            hasUnresolvedDraft: false
        )
        XCTAssertNil(stale)

        let presentation = EndpointShadowPresentation.make(
            turnMode: .patientAuto,
            phase: .candidateFloor,
            currentEvaluation: stale,
            hasSelectedDraft: true,
            hasUnresolvedDraft: false,
            hasStaleEvaluation: true
        )
        XCTAssertEqual(presentation.title, "Evidence changed · Shadow waiting")
        XCTAssertFalse(presentation.detail.contains("likely complete"))

        let current = EndpointShadowPresentation.currentEvaluation(
            in: [olderMatching, latestChanged],
            selectedCandidateIDs: [candidateA, candidateB],
            questionTurnID: nil,
            hasUnresolvedDraft: false
        )
        XCTAssertEqual(current?.id, latestChanged.id)
    }

    func testFreshFloorWithHistoryWaitsForFirstNewTranscript() {
        let presentation = EndpointShadowPresentation.make(
            turnMode: .patientAuto,
            phase: .candidateFloor,
            currentEvaluation: nil,
            hasSelectedDraft: false,
            hasUnresolvedDraft: false,
            hasStaleEvaluation: false
        )

        XCTAssertEqual(presentation.title, "Shadow waiting for a transcript")
        XCTAssertEqual(
            presentation.detail,
            "It checks only after a new selected transcript is saved."
        )
    }

    private func endpointEvaluation(
        id: String = "endpoint-evaluation",
        selectedCandidateIDs: [TranscriptCandidateID],
        questionTurnID: TurnID? = nil,
        lifecycle: EndpointEvaluationLifecycle,
        proposal: SemanticEndpointProposal? = nil,
        failure: EndpointEvaluationFailure? = nil
    ) -> EndpointEvaluation {
        EndpointEvaluation(
            id: EndpointEvaluationID(id),
            authorizationCommandID: CommandID("authorization-\(id)"),
            triggerSegmentID: SegmentID("trigger-segment"),
            selectedCandidateIDs: selectedCandidateIDs,
            questionTurnID: questionTurnID,
            contextFingerprint: "sha256:v1:\(String(repeating: "a", count: 64))",
            lifecycle: lifecycle,
            proposal: proposal,
            failure: failure
        )
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
