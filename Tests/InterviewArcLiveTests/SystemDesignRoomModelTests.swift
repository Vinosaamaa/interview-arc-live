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
