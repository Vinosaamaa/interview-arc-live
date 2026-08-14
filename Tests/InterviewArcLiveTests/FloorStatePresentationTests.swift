import XCTest

import InterviewArcLiveCore
@testable import InterviewArcLive

final class FloorStatePresentationTests: XCTestCase {
    func testEveryStatusKindHasAReachableTruthfulInput() {
        let inputs: [FloorStatePresentation.Input] = [
            .init(phase: nil, statusMessage: "Restoring local session"),
            .init(phase: .ready, statusMessage: "Preparing room"),
            .init(phase: .candidateFloor, statusMessage: "Ready to record"),
            .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.recording],
                statusMessage: "Recording segment"
            ),
            .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.finalizationAuthorized],
                statusMessage: "Saving recording"
            ),
            .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.transcribing],
                statusMessage: "Transcribing locally"
            ),
            .init(
                phase: .interviewerProcessing,
                statusMessage: "Codex is preparing the next question",
                isInterviewerRequestInFlight: true
            ),
            .init(
                phase: .interviewerProcessing,
                statusMessage: "Candidate answer saved"
            ),
            .init(phase: .interviewerTurn, statusMessage: "Mara has the floor"),
            .init(
                phase: .interviewerTurn,
                statusMessage: "Preparing speech",
                speechActivity: .generating
            ),
            .init(
                phase: .interviewerTurn,
                statusMessage: "Speaking",
                speechActivity: .playing
            ),
            .init(
                phase: .interviewerTurn,
                statusMessage: "Written turn preserved",
                attentionMessage: "Local speech needs attention"
            ),
            .init(phase: .completed, statusMessage: "Session complete"),
        ]
        let reached = inputs.map { FloorStatePresentation.make(input: $0).statusKind }

        XCTAssertEqual(reached.count, FloorStatePresentation.StatusKind.allCases.count)
        for statusKind in FloorStatePresentation.StatusKind.allCases {
            XCTAssertTrue(reached.contains(statusKind), "Missing \(statusKind)")
        }
    }

    func testEveryPhaseHasTruthfulFullAndCompactCopy() {
        let cases: [(
            phase: InterviewRoomPhase?,
            fullLabel: String,
            fullDetail: String,
            compactLabel: String,
            kind: FloorStatePresentation.StatusKind
        )] = [
            (nil, "Preparing room", "Restoring local session", "Preparing room", .restoring),
            (.ready, "Preparing room", "Restoring local session", "Preparing room", .preparing),
            (.candidateFloor, "Your floor", "No segment yet", "Your floor", .candidateFloor),
            (
                .interviewerProcessing,
                "Answer saved · check Codex to retry",
                "Candidate answer saved",
                "Answer saved",
                .retryRequired
            ),
            (
                .interviewerTurn,
                "Interviewer turn",
                "Mara has the floor",
                "Interviewer turn",
                .interviewerTurn
            ),
            (
                .completed,
                "Session complete",
                "Local session saved",
                "Interview complete",
                .completed
            ),
        ]

        for item in cases {
            let presentation = FloorStatePresentation.make(
                input: .init(
                    phase: item.phase,
                    statusMessage: item.phase == .completed
                        ? "Session complete"
                        : "Current local status"
                )
            )
            XCTAssertEqual(presentation.full.label, item.fullLabel)
            XCTAssertEqual(presentation.full.detail, item.fullDetail)
            XCTAssertEqual(presentation.compact.label, item.compactLabel)
            XCTAssertEqual(presentation.statusKind, item.kind)
            XCTAssertEqual(
                presentation.compact.accessibilityValue,
                "\(presentation.compact.label). \(presentation.compact.detail)"
            )
        }
    }

    func testCandidateSegmentCountRecordingAndCodexReadinessStayConsistent() {
        let oneSegment = FloorStatePresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentCount: 1,
                statusMessage: "Ready to record"
            )
        )
        XCTAssertEqual(oneSegment.full.detail, "1 Segment")

        let multipleSegments = FloorStatePresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentCount: 3,
                statusMessage: "Ready to record"
            )
        )
        XCTAssertEqual(multipleSegments.full.detail, "3 Segments")

        let recording = FloorStatePresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.recording],
                candidateSegmentCount: 1,
                statusMessage: "Recording segment",
                canStopRecording: true
            )
        )
        XCTAssertEqual(recording.full.detail, "Recording segment")
        XCTAssertEqual(recording.statusKind, .recording)

        let codexReady = FloorStatePresentation.make(
            input: .init(
                phase: .interviewerProcessing,
                statusMessage: "Retry available",
                isCodexReady: true
            )
        )
        XCTAssertEqual(
            codexReady.full.label,
            "Answer saved · interviewer retry required"
        )
    }

    func testHostedUnavailableStatesNeverClaimTheLocalRoomIsRestoring() {
        let cases: [(
            availability: FloorStatePresentation.RoomAvailability,
            status: String,
            fullLabel: String,
            compactLabel: String
        )] = [
            (
                .hostedSignInRequired,
                "Connect Interview Arc to open Today’s System Design activity",
                "Connect Interview Arc",
                "Connect Interview Arc"
            ),
            (
                .hostedActivityRequired,
                "No System Design activity is open in Interview Arc Today",
                "Open a System Design activity",
                "Open System Design activity"
            ),
            (
                .hostedRecoveryRequired,
                "Hosted recovery needs attention",
                "Hosted recovery required",
                "Hosted recovery required"
            ),
        ]

        for item in cases {
            let presentation = FloorStatePresentation.make(
                input: .init(
                    phase: nil,
                    statusMessage: item.status,
                    roomAvailability: item.availability
                )
            )

            XCTAssertEqual(presentation.statusKind, .recoveryAttention)
            XCTAssertEqual(presentation.tone, .warning)
            XCTAssertEqual(presentation.full.label, item.fullLabel)
            XCTAssertEqual(presentation.full.detail, item.status)
            XCTAssertEqual(
                presentation.full.accessibilityValue,
                "\(item.fullLabel). \(item.status)"
            )
            XCTAssertEqual(presentation.compact.label, item.compactLabel)
            XCTAssertEqual(presentation.compact.detail, item.status)
            XCTAssertFalse(presentation.full.accessibilityValue.contains("Restoring"))
            XCTAssertFalse(presentation.compact.accessibilityValue.contains("Restoring"))
        }
    }

    func testSavingTranscribingRecordingAndPreparingHaveStablePriority() {
        let cases: [(
            lifecycles: [CandidateSegmentLifecycle],
            message: String,
            expected: FloorStatePresentation.StatusKind
        )] = [
            ([.finalizationAuthorized], "Saving recording", .saving),
            ([.transcribing], "Transcribing with Groq", .transcribing),
            ([.recording], "Recording segment", .recording),
            ([.captureAuthorized], "Preparing microphone", .preparing),
        ]

        for item in cases {
            let presentation = FloorStatePresentation.make(
                input: .init(
                    phase: .candidateFloor,
                    candidateSegmentLifecycles: item.lifecycles,
                    statusMessage: item.message
                )
            )
            XCTAssertEqual(presentation.statusKind, item.expected)
            XCTAssertEqual(presentation.compact.detail, item.message)
        }
    }

    func testSpeechActivityAndAttentionNeverInventStatusCopy() {
        let generating = FloorStatePresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                attentionMessage: "Older speech recovery warning",
                speechActivity: .generating
            )
        )
        XCTAssertEqual(generating.statusKind, .speechGenerating)
        XCTAssertEqual(
            generating.compact.detail,
            "Generating Mara’s response locally"
        )

        let playing = FloorStatePresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                speechActivity: .playing
            )
        )
        XCTAssertEqual(playing.statusKind, .speechPlayback)
        XCTAssertEqual(playing.compact.detail, "Mara is speaking")

        let speechError = "Local speech stopped; the written turn is preserved."
        let attention = FloorStatePresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                attentionMessage: speechError
            )
        )
        XCTAssertEqual(attention.statusKind, .recoveryAttention)
        XCTAssertEqual(attention.compact.detail, speechError)
        XCTAssertEqual(attention.full.label, "Interviewer turn")
        XCTAssertEqual(attention.full.detail, "Mara has the floor")
    }

    func testInterviewerRequestOutranksAttentionWithoutHidingExactCompactStatus() {
        let status = "Answer saved · Codex is preparing the next question"
        let presentation = FloorStatePresentation.make(
            input: .init(
                phase: .interviewerProcessing,
                statusMessage: status,
                attentionMessage: "Older recoverable issue",
                isInterviewerRequestInFlight: true
            )
        )

        XCTAssertEqual(presentation.statusKind, .interviewerWorking)
        XCTAssertEqual(presentation.full.label, "Answer saved · Codex working")
        XCTAssertEqual(presentation.full.detail, "Codex is preparing Mara")
        XCTAssertEqual(presentation.compact.label, "Answer saved")
        XCTAssertEqual(presentation.compact.detail, status)
    }

    func testEveryPhaseActionHintIsExplicitAndTimerFree() {
        let phases: [InterviewRoomPhase?] = [
            nil,
            .ready,
            .candidateFloor,
            .interviewerProcessing,
            .interviewerTurn,
            .completed,
        ]
        let hints = phases.map {
            FloorStatePresentation.make(input: .init(phase: $0)).primaryActionHint
        }

        XCTAssertEqual(Set(hints).count, 4)
        for hint in hints {
            XCTAssertFalse(hint.isEmpty)
            XCTAssertFalse(hint.lowercased().contains("timer"))
            XCTAssertFalse(hint.contains(":"))
        }
    }
}
