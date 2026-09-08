import InterviewArcLiveCore

enum CompactRoomAction: String, CaseIterable, Hashable {
    case recordSegment
    case stopRecording
    case toggleMicrophone
    case keepFloor
    case holdFloor
    case primaryPhaseAction
    case stopSpeech
    case toggleSpeechMute
    case expand
}

struct CompactRoomControl: Equatable, Identifiable {
    let action: CompactRoomAction
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let accessibilityHint: String
    let accessibilityValue: String?

    var id: CompactRoomAction { action }
}

struct CompactRoomPresentation: Equatable {
    typealias StatusKind = FloorStatePresentation.StatusKind
    typealias Tone = FloorStatePresentation.Tone
    typealias SpeechActivity = FloorStatePresentation.SpeechActivity

    struct Input {
        var phase: InterviewRoomPhase?
        var candidateSegmentLifecycles: [CandidateSegmentLifecycle]
        var statusMessage: String
        var attentionMessage: String?
        var speechActivity: SpeechActivity?
        var isInterviewerRequestInFlight: Bool
        var isWorking: Bool
        var canStopRecording: Bool
        var stopRecordingTitle: String
        var stopRecordingSystemImage: String
        var showsRecordControl: Bool
        var showsAutomaticMicrophoneControl: Bool
        var isMicrophonePaused: Bool
        var canRecordSegment: Bool
        var recordTitle: String
        var showsKeepFloor: Bool
        var canKeepFloor: Bool
        var showsHoldFloor: Bool
        var canToggleFloorHold: Bool
        var holdFloorTitle: String
        var holdFloorSystemImage: String
        var phaseActionTitle: String
        var phaseActionSystemImage: String
        var canPerformPhaseAction: Bool
        var canStopSpeech: Bool
        var showsSpeechMuteControl: Bool
        var canToggleSpeechMute: Bool
        var isSpeechMuted: Bool

        init(
            phase: InterviewRoomPhase? = nil,
            candidateSegmentLifecycles: [CandidateSegmentLifecycle] = [],
            statusMessage: String = "Restoring local session…",
            attentionMessage: String? = nil,
            speechActivity: SpeechActivity? = nil,
            isInterviewerRequestInFlight: Bool = false,
            isWorking: Bool = false,
            canStopRecording: Bool = false,
            stopRecordingTitle: String = "Stop segment",
            stopRecordingSystemImage: String = "stop.fill",
            showsRecordControl: Bool = false,
            showsAutomaticMicrophoneControl: Bool = false,
            isMicrophonePaused: Bool = false,
            canRecordSegment: Bool = false,
            recordTitle: String = "Record segment",
            showsKeepFloor: Bool = false,
            canKeepFloor: Bool = false,
            showsHoldFloor: Bool = false,
            canToggleFloorHold: Bool = false,
            holdFloorTitle: String = "Hold floor",
            holdFloorSystemImage: String = "hand.raised.fill",
            phaseActionTitle: String = "Hand off",
            phaseActionSystemImage: String = "arrowshape.right.circle.fill",
            canPerformPhaseAction: Bool = false,
            canStopSpeech: Bool = false,
            showsSpeechMuteControl: Bool = false,
            canToggleSpeechMute: Bool = false,
            isSpeechMuted: Bool = false
        ) {
            self.phase = phase
            self.candidateSegmentLifecycles = candidateSegmentLifecycles
            self.statusMessage = statusMessage
            self.attentionMessage = attentionMessage
            self.speechActivity = speechActivity
            self.isInterviewerRequestInFlight = isInterviewerRequestInFlight
            self.isWorking = isWorking
            self.canStopRecording = canStopRecording
            self.stopRecordingTitle = stopRecordingTitle
            self.stopRecordingSystemImage = stopRecordingSystemImage
            self.showsRecordControl = showsRecordControl
            self.showsAutomaticMicrophoneControl = showsAutomaticMicrophoneControl
            self.isMicrophonePaused = isMicrophonePaused
            self.canRecordSegment = canRecordSegment
            self.recordTitle = recordTitle
            self.showsKeepFloor = showsKeepFloor
            self.canKeepFloor = canKeepFloor
            self.showsHoldFloor = showsHoldFloor
            self.canToggleFloorHold = canToggleFloorHold
            self.holdFloorTitle = holdFloorTitle
            self.holdFloorSystemImage = holdFloorSystemImage
            self.phaseActionTitle = phaseActionTitle
            self.phaseActionSystemImage = phaseActionSystemImage
            self.canPerformPhaseAction = canPerformPhaseAction
            self.canStopSpeech = canStopSpeech
            self.showsSpeechMuteControl = showsSpeechMuteControl
            self.canToggleSpeechMute = canToggleSpeechMute
            self.isSpeechMuted = isSpeechMuted
        }
    }

    let statusKind: StatusKind
    let tone: Tone
    let floorTitle: String
    let statusValue: String
    let systemImage: String
    let controls: [CompactRoomControl]

    var candidateControl: CompactRoomControl? {
        controls.first {
            $0.action == .recordSegment || $0.action == .stopRecording || $0.action == .toggleMicrophone
        }
    }

    var phaseControl: CompactRoomControl? {
        controls.first { $0.action == .primaryPhaseAction }
    }

    var holdFloorControl: CompactRoomControl? {
        controls.first { $0.action == .holdFloor }
    }

    var keepFloorControl: CompactRoomControl? {
        controls.first { $0.action == .keepFloor }
    }

    var speechControls: [CompactRoomControl] {
        controls.filter {
            $0.action == .stopSpeech || $0.action == .toggleSpeechMute
        }
    }

    var expandControl: CompactRoomControl {
        controls.first { $0.action == .expand }!
    }

    static func make(
        input: Input,
        floorState: FloorStatePresentation? = nil
    ) -> CompactRoomPresentation {
        let floorState = floorState ?? FloorStatePresentation.make(
            input: FloorStatePresentation.Input(
                phase: input.phase,
                candidateSegmentLifecycles: input.candidateSegmentLifecycles,
                candidateSegmentCount: input.candidateSegmentLifecycles.count,
                statusMessage: input.statusMessage,
                attentionMessage: input.attentionMessage,
                speechActivity: input.speechActivity,
                isInterviewerRequestInFlight: input.isInterviewerRequestInFlight,
                canStopRecording: input.canStopRecording
            )
        )
        var controls: [CompactRoomControl] = []

        if input.phase == .candidateFloor {
            if input.canStopRecording && !input.showsAutomaticMicrophoneControl {
                controls.append(
                    CompactRoomControl(
                        action: .stopRecording,
                        title: input.stopRecordingTitle,
                        systemImage: input.stopRecordingSystemImage,
                        isEnabled: !input.isWorking,
                        accessibilityHint: "Stops the existing candidate capture path "
                            + "and preserves its source recording.",
                        accessibilityValue: nil
                    )
                )
            } else if input.showsAutomaticMicrophoneControl {
                controls.append(.init(action: .toggleMicrophone,
                    title: input.isMicrophonePaused ? "Resume" : "Pause",
                    systemImage: input.isMicrophonePaused ? "mic.fill" : "pause.fill",
                    isEnabled: !input.isWorking,
                    accessibilityHint: input.isMicrophonePaused ? "Resume microphone" : "Pause microphone",
                    accessibilityValue: nil))
            } else if input.showsRecordControl {
                controls.append(
                    CompactRoomControl(
                        action: .recordSegment,
                        title: input.recordTitle,
                        systemImage: "record.circle",
                        isEnabled: input.canRecordSegment,
                        accessibilityHint: "Starts the existing candidate Segment capture path.",
                        accessibilityValue: nil
                    )
                )
            }

            if input.showsKeepFloor {
                controls.append(
                    CompactRoomControl(
                        action: .keepFloor,
                        title: "Keep my floor",
                        systemImage: "hand.raised.fill",
                        isEnabled: input.canKeepFloor,
                        accessibilityHint: "Cancels the pending automatic Hand off without changing saved answer evidence.",
                        accessibilityValue: "Automatic Hand off pending"
                    )
                )
            }

            if input.showsHoldFloor {
                controls.append(
                    CompactRoomControl(
                        action: .holdFloor,
                        title: input.holdFloorTitle,
                        systemImage: input.holdFloorSystemImage,
                        isEnabled: input.canToggleFloorHold,
                        accessibilityHint: input.holdFloorTitle == "Send answer"
                            ? "Finalizes active speech, waits for durable transcripts, and Hands off once."
                            : "Keeps the Candidate Floor across pauses until Send answer.",
                        accessibilityValue: input.holdFloorTitle == "Send answer"
                            ? "Holding your floor"
                            : "Automatic completion allowed"
                    )
                )
            }
        }

        if (input.phase == .candidateFloor && !input.showsHoldFloor)
            || input.phase == .interviewerProcessing
            || input.phase == .interviewerTurn {
            controls.append(
                CompactRoomControl(
                    action: .primaryPhaseAction,
                    title: input.phaseActionTitle,
                    systemImage: input.phaseActionSystemImage,
                    isEnabled: input.canPerformPhaseAction,
                    accessibilityHint: floorState.primaryActionHint,
                    accessibilityValue: nil
                )
            )
        }

        if input.canStopSpeech {
            controls.append(
                CompactRoomControl(
                    action: .stopSpeech,
                    title: "Stop speech",
                    systemImage: "stop.fill",
                    isEnabled: true,
                    accessibilityHint: "Stops current local speech generation "
                        + "and playback without changing the written turn.",
                    accessibilityValue: nil
                )
            )
        }

        if input.showsSpeechMuteControl {
            controls.append(
                CompactRoomControl(
                    action: .toggleSpeechMute,
                    title: input.isSpeechMuted ? "Unmute Mara" : "Mute Mara",
                    systemImage: input.isSpeechMuted
                        ? "speaker.wave.2.fill"
                        : "speaker.slash.fill",
                    isEnabled: input.canToggleSpeechMute,
                    accessibilityHint: input.isSpeechMuted
                        ? "Allows future local interviewer speech without "
                            + "replaying historical turns."
                        : "Immediately stops current speech and suppresses "
                            + "future automatic speech.",
                    accessibilityValue: input.isSpeechMuted ? "Muted" : "Unmuted"
                )
            )
        }

        controls.append(
            CompactRoomControl(
                action: .expand,
                title: "Expand",
                systemImage: "rectangle.expand.vertical",
                isEnabled: true,
                accessibilityHint: "Returns to the retained full interview "
                    + "room and restores keyboard focus.",
                accessibilityValue: nil
            )
        )

        return CompactRoomPresentation(
            statusKind: floorState.statusKind,
            tone: floorState.tone,
            floorTitle: floorState.compact.label,
            statusValue: floorState.compact.detail,
            systemImage: floorState.systemImage,
            controls: controls
        )
    }
}

extension SystemDesignRoomModel {
    var compactPresentation: CompactRoomPresentation {
        let canStopSpeech = playingUtteranceID != nil
            || snapshot?.interviewerUtterances.contains(where: {
                speechPresentation(for: $0).canStop
            }) == true
        let pendingGrace = activeEndpointGrace
        let keepFloorIsEnabled = canKeepFloor(pendingGrace: pendingGrace)

        return CompactRoomPresentation.make(
            input: CompactRoomPresentation.Input(
                phase: snapshot?.phase,
                isWorking: isWorking,
                canStopRecording: canStopRecording,
                stopRecordingTitle: stopActionTitle,
                stopRecordingSystemImage: stopActionIcon,
                showsRecordControl: showsRecordControl,
                showsAutomaticMicrophoneControl: showsAutomaticMicrophoneControl,
                isMicrophonePaused: isMicrophonePaused,
                canRecordSegment: canRecordSegment,
                recordTitle: recordActionTitle,
                showsKeepFloor: pendingGrace != nil && snapshot?.turnMode != .continuousConversation,
                canKeepFloor: keepFloorIsEnabled,
                showsHoldFloor: showsHoldFloorControl,
                canToggleFloorHold: canToggleFloorHold,
                holdFloorTitle: holdFloorTitle,
                holdFloorSystemImage: holdFloorSystemImage,
                phaseActionTitle: actionTitle,
                phaseActionSystemImage: actionIcon,
                canPerformPhaseAction: canAct,
                canStopSpeech: canStopSpeech,
                showsSpeechMuteControl: showsSpeechMuteControl,
                canToggleSpeechMute: canToggleSpeechMute,
                isSpeechMuted: isSpeechMuted
            ),
            floorState: floorStatePresentation
        )
    }
}
