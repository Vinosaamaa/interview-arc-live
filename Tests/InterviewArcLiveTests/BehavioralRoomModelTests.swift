import AppKit
import Foundation
import XCTest

import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore
@testable import InterviewArcLive

@MainActor
final class BehavioralRoomModelTests: XCTestCase {
    func testQuestionFamilyRoutesToTheMatchingKit() {
        let model = BehavioralRoomModel()

        model.selectQuestionFamily(.starBank)
        XCTAssertEqual(model.workSurface.primaryKit, .story)
        XCTAssertEqual(model.workSurface.questionFamily.title, "STAR bank")

        model.selectQuestionFamily(.projectOverview)
        XCTAssertEqual(model.workSurface.primaryKit, .project)
        XCTAssertEqual(model.workSurface.projectKit?.projectId, "payments-migration")

        model.selectQuestionFamily(.resumeClaim)
        XCTAssertEqual(model.workSurface.primaryKit, .claim)
        XCTAssertEqual(
            model.workSurface.resumeClaimKit?.sourceClaimId,
            "claim-checkout-cache"
        )

        model.selectQuestionFamily(.focusedDeepDive)
        XCTAssertEqual(model.workSurface.primaryKit, .story)

        model.selectQuestionFamily(.practiceScenario)
        XCTAssertEqual(model.workSurface.primaryKit, .story)
        XCTAssertTrue(model.workSurface.questionFamily.isHypothetical)
        XCTAssertTrue(
            model.workSurface.storyKit.candidates.allSatisfy(\.isHypothetical)
        )
    }

    func testCoachedDiscoveryIsAnExplicitModeSwitch() {
        let model = BehavioralRoomModel()
        XCTAssertEqual(model.workSurface.mode, .interviewer)

        model.beginCoachedDiscovery()
        XCTAssertEqual(model.workSurface.mode, .coachedDiscovery)
        XCTAssertEqual(
            model.floorStatePresentation.statusKind,
            model.snapshot == nil
                ? FloorStatePresentation.StatusKind.restoring
                : model.floorStatePresentation.statusKind
        )
        XCTAssertTrue(model.statusMessage.contains("Coached discovery"))

        model.returnToInterviewer()
        XCTAssertEqual(model.workSurface.mode, .interviewer)
    }

    func testPreferredAnswerIsAbsentFromTheLiveSidecar() {
        let model = BehavioralRoomModel()
        let sidecar = model.workSurface.liveSidecarText.lowercased()
        XCTAssertFalse(sidecar.contains("preferred"))
        XCTAssertFalse(sidecar.contains("model answer"))
        XCTAssertFalse(sidecar.contains("baseline answer"))
        XCTAssertFalse(sidecar.contains("polished"))
        let mirror = Mirror(reflecting: model.workSurface)
        XCTAssertFalse(
            mirror.children.contains {
                $0.label?.lowercased().contains("preferred") == true
                    || $0.label?.lowercased().contains("modelanswer") == true
            }
        )
    }

    func testStarlTracksCoverageWithoutAScore() {
        let coverage = BehavioralWorkSurface.preflightFixture().starl
        XCTAssertEqual(coverage.state(for: .situation), .filled)
        XCTAssertEqual(coverage.state(for: .task), .filled)
        XCTAssertEqual(coverage.state(for: .action), .current)
        XCTAssertEqual(coverage.state(for: .result), .empty)
        XCTAssertEqual(coverage.state(for: .learning), .empty)
        let labels = Mirror(reflecting: coverage).children.compactMap(\.label)
        XCTAssertFalse(labels.contains { $0.lowercased().contains("score") })
        XCTAssertFalse(
            BehavioralWorkSurface.preflightFixture().liveSidecarText
                .lowercased()
                .contains("score")
        )
    }

    func testHostedWritesStayDisabledAndChipIsHonest() throws {
        let model = BehavioralRoomModel()
        XCTAssertFalse(model.hostedWritesEnabled)
        XCTAssertFalse(model.hostedPauseIsEnabled)
        XCTAssertFalse(model.hostedFinishIsEnabled)
        XCTAssertEqual(
            model.hostedAvailabilityChip,
            "Local behavioral room · hosted writes not enabled"
        )
        XCTAssertEqual(
            model.activityPromptForPresentation.specialty,
            .behavioral
        )
        XCTAssertEqual(
            BehavioralRoomPalette.paperHex,
            "#FCFCFE"
        )
        XCTAssertEqual(BehavioralRoomPalette.roomHex, "#FAFBFE")
        XCTAssertEqual(BehavioralRoomPalette.inkHex, "#0E111E")
        XCTAssertEqual(BehavioralRoomPalette.navyHex, "#182359")
        XCTAssertEqual(BehavioralRoomPalette.violetHex, "#4B3ABF")
        XCTAssertEqual(BehavioralRoomPalette.candidateTextHex, "#9F2E22")
        XCTAssertEqual(
            Set(BehavioralRoomAccessibility.allIdentifiers).count,
            BehavioralRoomAccessibility.allIdentifiers.count
        )
        XCTAssertTrue(
            BehavioralRoomAccessibility.allIdentifiers.allSatisfy {
                $0.hasPrefix("behavioral-room-")
            }
        )
    }

    func testWindowMenuOpensALocalBehavioralRoomItem() throws {
        let delegate = InterviewArcLiveApp()
        let application = NSApplication.shared
        let previousWindowsMenu = application.windowsMenu
        defer { application.windowsMenu = previousWindowsMenu }

        let windowMenu = try XCTUnwrap(
            delegate.makeMainMenu().items.first {
                $0.submenu?.title == "Window"
            }?.submenu
        )
        let titles = windowMenu.items.map(\.title)
        XCTAssertTrue(titles.contains("Show Interview Room"))
        XCTAssertTrue(titles.contains("Behavioral Room (local)"))
        let item = try XCTUnwrap(
            windowMenu.items.first { $0.title == "Behavioral Room (local)" }
        )
        XCTAssertEqual(
            item.action.map(NSStringFromSelector),
            "showBehavioralRoom:"
        )
    }

    func testLocalSessionUsesBehavioralSpecialtyWithoutHostedWrites() async throws {
        let (model, _) = try await makeBehavioralRoomModel()

        XCTAssertEqual(model.snapshot?.activityPrompt.specialty, .behavioral)
        XCTAssertEqual(model.snapshot?.activityID, "local-behavioral-tracer")
        XCTAssertEqual(model.snapshot?.phase, .candidateFloor)
        XCTAssertFalse(model.hostedWritesEnabled)
        XCTAssertEqual(
            model.floorStatePresentation.full.label,
            "Your floor"
        )
    }
}

@MainActor
private func makeBehavioralRoomModel() async throws -> (
    model: BehavioralRoomModel,
    store: InMemorySessionManifestStore
) {
    let store = InMemorySessionManifestStore()
    let prompt = try ActivityPrompt(
        specialty: .behavioral,
        stage: "Behavioral interview",
        question: BehavioralWorkSurface.question(for: .starBank),
        requestedParts: ["Ask the primary question cold."]
    )
    let runtime = BehavioralCodexRuntimeFixture()
    let coordinator = try await SegmentSpeechCoordinator.open(
        sessionID: SessionID("behavioral-fixture-\(UUID().uuidString)"),
        activityID: "local-behavioral-tracer",
        activityPrompt: prompt,
        manifestStore: store,
        interviewerRuntime: runtime,
        recording: BehavioralUnusedRecording(),
        transcriber: BehavioralUnusedTranscriber(),
        credentialReader: BehavioralUnusedCredentialReader()
    )
    if coordinator.snapshot.phase == .ready {
        _ = try await coordinator.giveCandidateFloor(
            commandID: CommandID("behavioral-fixture-give-floor")
        )
    }
    return (
        BehavioralRoomModel(
            codexRuntime: runtime,
            activityPrompt: prompt,
            initialCoordinator: coordinator,
            recording: BehavioralUnusedRecording(),
            transcriber: BehavioralUnusedTranscriber(),
            manifestStore: store
        ),
        store
    )
}

private actor BehavioralCodexRuntimeFixture: LiveCodexInterviewerRuntime {
    func preflight() async -> CodexAppServerReadiness { .ready }

    func respond(
        to request: InterviewerRequest
    ) async throws -> CanonicalInterviewerResponse {
        CanonicalInterviewerResponse(
            displayMarkdown: "What did you personally own?",
            spokenText: "What did you personally own?"
        )
    }
}

@MainActor
private final class BehavioralUnusedRecording: SegmentRecording {
    func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {}

    func beginCapture(_ request: SegmentCaptureRequest) async throws {
        throw BehavioralFixtureError.unused
    }

    func finishCapture() async throws -> CapturedAudioSegment {
        throw BehavioralFixtureError.unused
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
        throw BehavioralFixtureError.unused
    }
}

private struct BehavioralUnusedTranscriber: SegmentTranscribing {
    func transcribe(
        _ request: SegmentTranscriptionRequest,
        credential: String
    ) async throws -> SegmentTranscriptionResult {
        throw BehavioralFixtureError.unused
    }
}

private struct BehavioralUnusedCredentialReader: GroqCredentialReading {
    func readGroqCredential() async throws -> String {
        throw BehavioralFixtureError.unused
    }
}

private enum BehavioralFixtureError: Error {
    case unused
}
