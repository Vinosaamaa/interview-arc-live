import XCTest

import InterviewArcLiveCore
@testable import InterviewArcLive

final class CompactRoomPresentationTests: XCTestCase {
    func testRestoringAndCompletedExposeOnlyExpand() {
        let restoring = CompactRoomPresentation.make(input: .init())
        XCTAssertEqual(restoring.statusKind, .restoring)
        XCTAssertEqual(restoring.floorTitle, "Preparing room")
        XCTAssertEqual(restoring.controls.map(\.action), [.expand])
        XCTAssertEqual(
            restoring.expandControl.systemImage,
            "rectangle.expand.vertical"
        )

        let completed = CompactRoomPresentation.make(
            input: .init(
                phase: .completed,
                statusMessage: "Session complete",
                showsRecordControl: true,
                canRecordSegment: true,
                canPerformPhaseAction: true
            )
        )
        XCTAssertEqual(completed.statusKind, .completed)
        XCTAssertEqual(completed.floorTitle, "Interview complete")
        XCTAssertEqual(completed.controls.map(\.action), [.expand])
    }

    func testCandidateFloorUsesExactRecordAndHandOffEnablement() throws {
        let presentation = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                statusMessage: "Ready to record",
                showsRecordControl: true,
                canRecordSegment: true,
                recordTitle: "Add segment",
                phaseActionTitle: "Hand off",
                canPerformPhaseAction: false
            )
        )

        XCTAssertEqual(presentation.statusKind, .candidateFloor)
        XCTAssertEqual(
            presentation.controls.map(\.action),
            [.recordSegment, .primaryPhaseAction, .expand]
        )
        let record = try XCTUnwrap(presentation.candidateControl)
        XCTAssertEqual(record.title, "Add segment")
        XCTAssertTrue(record.isEnabled)
        let handOff = try XCTUnwrap(presentation.phaseControl)
        XCTAssertEqual(handOff.title, "Hand off")
        XCTAssertFalse(handOff.isEnabled)
    }

    func testAutomaticMicrophoneShowsPauseAndResumeInCompactRoom() throws {
        for paused in [false, true] {
            let presentation = CompactRoomPresentation.make(input: .init(
                phase: .candidateFloor, showsAutomaticMicrophoneControl: true,
                isMicrophonePaused: paused))
            let control = try XCTUnwrap(presentation.candidateControl)
            XCTAssertEqual(control.action, .toggleMicrophone)
            XCTAssertEqual(control.title, paused ? "Resume" : "Pause")
            XCTAssertTrue(control.isEnabled)
        }
    }

    func testContinuousConversationExposesHoldFloorWithoutRecordOrHandOff() throws {
        let presentation = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                statusMessage: "Listening",
                showsHoldFloor: true,
                canToggleFloorHold: true,
                holdFloorTitle: "Hold floor"
            ),
            floorState: FloorStatePresentation.make(
                input: .init(
                    phase: .candidateFloor,
                    turnMode: .continuousConversation
                )
            )
        )

        XCTAssertEqual(presentation.statusKind, .listening)
        XCTAssertEqual(
            presentation.controls.map(\.action),
            [.holdFloor, .expand]
        )
        let hold = try XCTUnwrap(presentation.holdFloorControl)
        XCTAssertEqual(hold.title, "Hold floor")
        XCTAssertTrue(hold.isEnabled)
        XCTAssertNil(presentation.phaseControl)
        XCTAssertNil(presentation.candidateControl)
    }

    func testPendingEndpointGraceAddsKeepFloorWithoutReplacingHandOff() throws {
        let presentation = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                statusMessage: "Handing off in 4 seconds · Keep my floor to cancel",
                showsRecordControl: true,
                canRecordSegment: true,
                showsKeepFloor: true,
                canKeepFloor: true,
                phaseActionTitle: "Hand off",
                canPerformPhaseAction: true
            )
        )

        XCTAssertEqual(
            presentation.controls.map(\.action),
            [.recordSegment, .keepFloor, .primaryPhaseAction, .expand]
        )
        let keepFloor = try XCTUnwrap(presentation.keepFloorControl)
        XCTAssertEqual(keepFloor.title, "Keep my floor")
        XCTAssertEqual(keepFloor.systemImage, "hand.raised.fill")
        XCTAssertTrue(keepFloor.isEnabled)
        XCTAssertEqual(presentation.phaseControl?.title, "Hand off")
    }

    func testCaptureSavingAndTranscribingRemainDistinct() throws {
        let recording = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.recording],
                statusMessage: "Recording segment",
                isWorking: false,
                canStopRecording: true,
                stopRecordingTitle: "Stop segment"
            )
        )
        XCTAssertEqual(recording.statusKind, .recording)
        XCTAssertEqual(recording.candidateControl?.action, .stopRecording)
        XCTAssertTrue(try XCTUnwrap(recording.candidateControl).isEnabled)

        let saving = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.recording],
                statusMessage: "Saving recording before Groq transcription…",
                isWorking: true,
                canStopRecording: true
            )
        )
        XCTAssertEqual(saving.statusKind, .saving)
        XCTAssertFalse(try XCTUnwrap(saving.candidateControl).isEnabled)

        let transcribing = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.transcribing],
                statusMessage: "Transcribing with Groq",
                isWorking: true,
                showsRecordControl: true,
                canRecordSegment: false
            )
        )
        XCTAssertEqual(transcribing.statusKind, .transcribing)
        XCTAssertEqual(transcribing.statusValue, "Transcribing with Groq")
        XCTAssertFalse(try XCTUnwrap(transcribing.candidateControl).isEnabled)
    }

    func testInterviewerWorkingRetryAndTurnUseOnePhaseAction() throws {
        let working = CompactRoomPresentation.make(
            input: .init(
                phase: .interviewerProcessing,
                statusMessage: "Answer saved · Codex is preparing the next question",
                isInterviewerRequestInFlight: true,
                phaseActionTitle: "Retry interviewer",
                canPerformPhaseAction: false
            )
        )
        XCTAssertEqual(working.statusKind, .interviewerWorking)
        XCTAssertFalse(try XCTUnwrap(working.phaseControl).isEnabled)

        let retry = CompactRoomPresentation.make(
            input: .init(
                phase: .interviewerProcessing,
                statusMessage: "Answer saved · interviewer retry available",
                phaseActionTitle: "Retry interviewer",
                phaseActionSystemImage: "arrow.clockwise.circle.fill",
                canPerformPhaseAction: true
            )
        )
        XCTAssertEqual(retry.statusKind, .retryRequired)
        XCTAssertEqual(retry.phaseControl?.title, "Retry interviewer")
        XCTAssertTrue(try XCTUnwrap(retry.phaseControl).isEnabled)

        let interviewerTurn = CompactRoomPresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                phaseActionTitle: "Give me the floor",
                canPerformPhaseAction: true
            )
        )
        XCTAssertEqual(interviewerTurn.statusKind, .interviewerTurn)
        XCTAssertEqual(interviewerTurn.phaseControl?.title, "Give me the floor")
    }

    func testSpeechGenerationPlaybackMuteAndExpandHaveLogicalOrder() {
        let generating = CompactRoomPresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                speechActivity: .generating,
                phaseActionTitle: "Give me the floor",
                canPerformPhaseAction: true,
                canStopSpeech: true,
                showsSpeechMuteControl: true,
                canToggleSpeechMute: true,
                isSpeechMuted: false
            )
        )
        XCTAssertEqual(generating.statusKind, .speechGenerating)
        XCTAssertEqual(
            generating.controls.map(\.action),
            [
                .primaryPhaseAction,
                .stopSpeech,
                .toggleSpeechMute,
                .expand,
            ]
        )
        XCTAssertEqual(generating.speechControls.last?.accessibilityValue, "Unmuted")
        XCTAssertEqual(
            generating.speechControls.last?.systemImage,
            "speaker.slash.fill"
        )

        let playing = CompactRoomPresentation.make(
            input: .init(
                phase: .interviewerTurn,
                statusMessage: "Interviewer response saved",
                attentionMessage: "An older recovery message",
                speechActivity: .playing,
                canStopSpeech: true,
                showsSpeechMuteControl: true,
                canToggleSpeechMute: true,
                isSpeechMuted: true
            )
        )
        XCTAssertEqual(playing.statusKind, .speechPlayback)
        XCTAssertEqual(playing.statusValue, "Mara is speaking")
        XCTAssertEqual(playing.speechControls.last?.title, "Unmute Mara")
        XCTAssertEqual(playing.speechControls.last?.accessibilityValue, "Muted")
        XCTAssertEqual(
            playing.speechControls.last?.systemImage,
            "speaker.wave.2.fill"
        )

        let recordingWhileSpeechStops = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.recording],
                statusMessage: "Recording segment",
                speechActivity: .playing,
                canStopRecording: true,
                canStopSpeech: true
            )
        )
        XCTAssertEqual(recordingWhileSpeechStops.statusKind, .recording)
        XCTAssertEqual(
            recordingWhileSpeechStops.controls.map(\.action),
            [.stopRecording, .primaryPhaseAction, .stopSpeech, .expand]
        )
    }

    func testRecoveryAttentionUsesCompleteTextAndClosedActionVocabulary() {
        let message = "A recording recovery needs attention. "
            + "Preserved evidence remains visible in the full room."
        let presentation = CompactRoomPresentation.make(
            input: .init(
                phase: .candidateFloor,
                candidateSegmentLifecycles: [.failed],
                statusMessage: "Recording preserved · recovery available",
                attentionMessage: message,
                showsRecordControl: true,
                canRecordSegment: true
            )
        )

        XCTAssertEqual(presentation.statusKind, .recoveryAttention)
        XCTAssertEqual(presentation.statusValue, message)
        XCTAssertEqual(
            Set(presentation.controls.map(\.action)),
            Set([.recordSegment, .primaryPhaseAction, .expand])
        )
        XCTAssertEqual(
            Set([
                CompactRoomAction.recordSegment,
                .stopRecording,
                .keepFloor,
                .holdFloor,
                .primaryPhaseAction,
                .stopSpeech,
                .toggleSpeechMute,
                .expand,
            ]),
            Set(CompactRoomAction.allCases)
        )
    }
}
