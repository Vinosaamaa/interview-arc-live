import InterviewArcLiveCore

enum CompactRoomAction: String, CaseIterable, Hashable {
    case recordSegment
    case stopRecording
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
    enum StatusKind: Equatable {
        case restoring
        case preparing
        case candidateFloor
        case recording
        case saving
        case transcribing
        case interviewerWorking
        case retryRequired
        case interviewerTurn
        case speechGenerating
        case speechPlayback
        case recoveryAttention
        case completed
    }

    enum Tone: Equatable {
        case quiet
        case candidate
        case working
        case interviewer
        case warning
        case completed
    }

    enum SpeechActivity: Equatable {
        case generating
        case playing
    }

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
        var canRecordSegment: Bool
        var recordTitle: String
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
            canRecordSegment: Bool = false,
            recordTitle: String = "Record segment",
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
            self.canRecordSegment = canRecordSegment
            self.recordTitle = recordTitle
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
            $0.action == .recordSegment || $0.action == .stopRecording
        }
    }

    var phaseControl: CompactRoomControl? {
        controls.first { $0.action == .primaryPhaseAction }
    }

    var speechControls: [CompactRoomControl] {
        controls.filter {
            $0.action == .stopSpeech || $0.action == .toggleSpeechMute
        }
    }

    var expandControl: CompactRoomControl {
        controls.first { $0.action == .expand }!
    }

    static func make(input: Input) -> CompactRoomPresentation {
        let status = status(for: input)
        var controls: [CompactRoomControl] = []

        if input.phase == .candidateFloor {
            if input.canStopRecording {
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
        }

        if input.phase == .candidateFloor
            || input.phase == .interviewerProcessing
            || input.phase == .interviewerTurn {
            controls.append(
                CompactRoomControl(
                    action: .primaryPhaseAction,
                    title: input.phaseActionTitle,
                    systemImage: input.phaseActionSystemImage,
                    isEnabled: input.canPerformPhaseAction,
                    accessibilityHint: phaseActionHint(for: input.phase),
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
            statusKind: status.kind,
            tone: status.tone,
            floorTitle: floorTitle(for: input.phase),
            statusValue: status.value,
            systemImage: status.systemImage,
            controls: controls
        )
    }

    private static func status(
        for input: Input
    ) -> (kind: StatusKind, tone: Tone, value: String, systemImage: String) {
        if input.phase == .completed {
            return (
                .completed,
                .completed,
                input.statusMessage,
                "checkmark.circle.fill"
            )
        }

        let normalizedStatus = input.statusMessage.lowercased()
        if input.candidateSegmentLifecycles.contains(.finalizationAuthorized)
            || normalizedStatus.contains("saving recording")
            || normalizedStatus.contains("saving source")
            || normalizedStatus.contains("recovering the source") {
            return (.saving, .working, input.statusMessage, "square.and.arrow.down")
        }
        if input.candidateSegmentLifecycles.contains(.transcribing)
            || normalizedStatus.contains("transcrib") {
            return (.transcribing, .working, input.statusMessage, "waveform")
        }
        if input.candidateSegmentLifecycles.contains(.recording) {
            return (.recording, .candidate, input.statusMessage, "record.circle.fill")
        }
        if input.candidateSegmentLifecycles.contains(.captureAuthorized)
            || normalizedStatus.contains("preparing microphone") {
            return (.preparing, .working, input.statusMessage, "mic.badge.plus")
        }

        switch input.speechActivity {
        case .generating:
            return (
                .speechGenerating,
                .working,
                "Generating Mara’s response locally",
                "waveform"
            )
        case .playing:
            return (
                .speechPlayback,
                .interviewer,
                "Mara is speaking",
                "speaker.wave.2.fill"
            )
        case nil:
            break
        }

        if input.isInterviewerRequestInFlight {
            return (
                .interviewerWorking,
                .working,
                input.statusMessage,
                "ellipsis.bubble.fill"
            )
        }

        if let attentionMessage = input.attentionMessage {
            return (
                .recoveryAttention,
                .warning,
                attentionMessage,
                "exclamationmark.triangle.fill"
            )
        }
        if input.candidateSegmentLifecycles.contains(.audioReady)
            || input.candidateSegmentLifecycles.contains(.failed)
            || normalizedStatus.contains("recovery")
            || normalizedStatus.contains("required") {
            return (
                .recoveryAttention,
                .warning,
                input.statusMessage,
                "exclamationmark.triangle.fill"
            )
        }

        switch input.phase {
        case .candidateFloor:
            return (
                .candidateFloor,
                .candidate,
                input.statusMessage,
                "person.wave.2.fill"
            )
        case .interviewerProcessing:
            return (
                .retryRequired,
                .warning,
                input.statusMessage,
                "arrow.clockwise.circle.fill"
            )
        case .interviewerTurn:
            return (
                .interviewerTurn,
                .interviewer,
                input.statusMessage,
                "bubble.left.and.bubble.right.fill"
            )
        case .ready:
            return (
                .preparing,
                .quiet,
                input.statusMessage,
                "hourglass"
            )
        case .completed:
            preconditionFailure("Completed status is handled above")
        case nil:
            return (
                .restoring,
                .quiet,
                input.statusMessage,
                "clock.arrow.circlepath"
            )
        }
    }

    private static func floorTitle(
        for phase: InterviewRoomPhase?
    ) -> String {
        switch phase {
        case .candidateFloor: return "Your floor"
        case .interviewerProcessing: return "Answer saved"
        case .interviewerTurn: return "Interviewer turn"
        case .completed: return "Interview complete"
        case .ready, nil: return "Preparing room"
        }
    }

    private static func phaseActionHint(
        for phase: InterviewRoomPhase?
    ) -> String {
        switch phase {
        case .candidateFloor:
            return "Commits the ready Segment transcripts as one candidate answer."
        case .interviewerProcessing:
            return "Starts one explicit retry of the saved interviewer request."
        case .interviewerTurn:
            return "Returns the existing room to the candidate floor."
        case .ready, .completed, nil:
            return "Uses the current room phase action."
        }
    }
}

extension SystemDesignRoomModel {
    var compactPresentation: CompactRoomPresentation {
        let draftLifecycles = snapshot?.segments
            .filter { $0.committedTurnID == nil }
            .map(\.lifecycle) ?? []

        let speechActivity: CompactRoomPresentation.SpeechActivity?
        if playingUtteranceID != nil
            || snapshot?.interviewerUtterances.contains(where: {
                $0.lifecycle == .speaking
            }) == true {
            speechActivity = .playing
        } else if snapshot?.interviewerUtterances.contains(where: {
            $0.lifecycle == .generating
        }) == true {
            speechActivity = .generating
        } else {
            speechActivity = nil
        }

        let canStopSpeech = playingUtteranceID != nil
            || snapshot?.interviewerUtterances.contains(where: {
                speechPresentation(for: $0).canStop
            }) == true

        return CompactRoomPresentation.make(
            input: CompactRoomPresentation.Input(
                phase: snapshot?.phase,
                candidateSegmentLifecycles: draftLifecycles,
                statusMessage: statusMessage,
                attentionMessage: errorMessage
                    ?? speechErrorMessage
                    ?? codexAttentionMessage,
                speechActivity: speechActivity,
                isInterviewerRequestInFlight: isInterviewerRequestInFlight,
                isWorking: isWorking,
                canStopRecording: canStopRecording,
                stopRecordingTitle: stopActionTitle,
                stopRecordingSystemImage: stopActionIcon,
                showsRecordControl: showsRecordControl,
                canRecordSegment: canRecordSegment,
                recordTitle: recordActionTitle,
                phaseActionTitle: actionTitle,
                phaseActionSystemImage: actionIcon,
                canPerformPhaseAction: canAct,
                canStopSpeech: canStopSpeech,
                showsSpeechMuteControl: showsSpeechMuteControl,
                canToggleSpeechMute: canToggleSpeechMute,
                isSpeechMuted: isSpeechMuted
            )
        )
    }
}
