import InterviewArcLiveCore

struct FloorStatePresentation: Equatable {
    enum StatusKind: Equatable, CaseIterable {
        case restoring
        case preparing
        case candidateFloor
        case listening
        case speechDetected
        case recording
        case saving
        case transcribing
        case checkingAnswer
        case holdingFloor
        case handingOff
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

    enum RoomAvailability: Equatable {
        case ready
        case restoring
        case hostedSignInRequired
        case hostedActivityRequired
        case hostedRecoveryRequired
    }

    struct Surface: Equatable {
        let label: String
        let detail: String

        var accessibilityValue: String {
            "\(label). \(detail)"
        }
    }

    struct Input {
        var phase: InterviewRoomPhase?
        var candidateSegmentLifecycles: [CandidateSegmentLifecycle]
        var candidateSegmentCount: Int
        var statusMessage: String
        var attentionMessage: String?
        var speechActivity: SpeechActivity?
        var isInterviewerRequestInFlight: Bool
        var isOpeningInterviewer: Bool
        var isInterviewerReady: Bool
        var canStopRecording: Bool
        var roomAvailability: RoomAvailability
        var turnMode: TurnMode
        var isFloorHeld: Bool
        var isCheckingAnswer: Bool

        init(
            phase: InterviewRoomPhase? = nil,
            candidateSegmentLifecycles: [CandidateSegmentLifecycle] = [],
            candidateSegmentCount: Int = 0,
            statusMessage: String = "Restoring local session…",
            attentionMessage: String? = nil,
            speechActivity: SpeechActivity? = nil,
            isInterviewerRequestInFlight: Bool = false,
            isOpeningInterviewer: Bool = false,
            isInterviewerReady: Bool = false,
            canStopRecording: Bool = false,
            roomAvailability: RoomAvailability = .ready,
            turnMode: TurnMode = .manual,
            isFloorHeld: Bool = false,
            isCheckingAnswer: Bool = false
        ) {
            self.phase = phase
            self.candidateSegmentLifecycles = candidateSegmentLifecycles
            self.candidateSegmentCount = candidateSegmentCount
            self.statusMessage = statusMessage
            self.attentionMessage = attentionMessage
            self.speechActivity = speechActivity
            self.isInterviewerRequestInFlight = isInterviewerRequestInFlight
            self.isOpeningInterviewer = isOpeningInterviewer
            self.isInterviewerReady = isInterviewerReady
            self.canStopRecording = canStopRecording
            self.roomAvailability = roomAvailability
            self.turnMode = turnMode
            self.isFloorHeld = isFloorHeld
            self.isCheckingAnswer = isCheckingAnswer
        }
    }

    let statusKind: StatusKind
    let tone: Tone
    let full: Surface
    let compact: Surface
    let systemImage: String
    let primaryActionHint: String

    static func make(input: Input) -> FloorStatePresentation {
        let status = status(for: input)
        return FloorStatePresentation(
            statusKind: status.kind,
            tone: status.tone,
            full: fullSurface(for: input),
            compact: Surface(
                label: compactLabel(for: input),
                detail: status.detail
            ),
            systemImage: status.systemImage,
            primaryActionHint: phaseActionHint(for: input.phase)
        )
    }

    private static func status(
        for input: Input
    ) -> (kind: StatusKind, tone: Tone, detail: String, systemImage: String) {
        if input.phase == .completed {
            return (
                .completed,
                .completed,
                input.statusMessage,
                "checkmark.circle.fill"
            )
        }

        if input.phase == nil {
            switch input.roomAvailability {
            case .hostedSignInRequired:
                return (
                    .recoveryAttention,
                    .warning,
                    input.statusMessage,
                    "link.circle.fill"
                )
            case .hostedActivityRequired, .hostedRecoveryRequired:
                return (
                    .recoveryAttention,
                    .warning,
                    input.statusMessage,
                    "exclamationmark.triangle.fill"
                )
            case .ready, .restoring:
                break
            }
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
        if input.turnMode == .continuousConversation,
           input.candidateSegmentLifecycles.contains(.recording)
            || input.canStopRecording {
            return (.speechDetected, .candidate, "Speech detected", "waveform")
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

        if input.turnMode == .continuousConversation, input.phase == .candidateFloor {
            if input.isFloorHeld {
                return (
                    .holdingFloor,
                    .candidate,
                    "Holding your floor",
                    "hand.raised.fill"
                )
            }
            if input.isCheckingAnswer
                || normalizedStatus.contains("checking") {
                return (
                    .checkingAnswer,
                    .working,
                    "Checking answer",
                    "text.magnifyingglass"
                )
            }
            if normalizedStatus.contains("handing off") {
                return (
                    .handingOff,
                    .working,
                    "Handing off",
                    "arrowshape.right.circle.fill"
                )
            }
            return (
                .listening,
                .candidate,
                "Listening",
                "ear"
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

    private static func fullSurface(for input: Input) -> Surface {
        if input.phase == nil {
            switch input.roomAvailability {
            case .hostedSignInRequired:
                return Surface(
                    label: "Connect Interview Arc",
                    detail: input.statusMessage
                )
            case .hostedActivityRequired:
                return Surface(
                    label: "Open a System Design activity",
                    detail: input.statusMessage
                )
            case .hostedRecoveryRequired:
                return Surface(
                    label: "Hosted recovery required",
                    detail: input.statusMessage
                )
            case .ready, .restoring:
                break
            }
        }

        if input.isInterviewerRequestInFlight {
            if input.isOpeningInterviewer {
                return Surface(
                    label: "Mara is opening",
                    detail: "The interviewer is preparing the greeting"
                )
            }
            return Surface(
                label: "Answer saved · interviewer working",
                detail: "The interviewer is preparing a response"
            )
        }

        switch input.phase {
        case .candidateFloor:
            if input.turnMode == .continuousConversation {
                if input.isFloorHeld {
                    return Surface(label: "Holding your floor", detail: candidateDetail(for: input))
                }
                if input.isCheckingAnswer {
                    return Surface(label: "Checking answer", detail: "Semantic endpoint is evaluating this answer")
                }
                return Surface(label: "Listening", detail: candidateDetail(for: input))
            }
            return Surface(
                label: "Your floor",
                detail: candidateDetail(for: input)
            )
        case .interviewerProcessing:
            if input.isOpeningInterviewer {
                return Surface(
                    label: input.isInterviewerReady
                        ? "Opening greeting needs retry"
                        : "Opening greeting needs the interviewer to retry",
                    detail: "No candidate answer yet"
                )
            }
            return Surface(
                label: input.isInterviewerReady
                    ? "Answer saved · interviewer retry required"
                    : "Answer saved · check the interviewer to retry",
                detail: "Candidate answer saved"
            )
        case .interviewerTurn:
            return Surface(
                label: "Interviewer turn",
                detail: "Mara has the floor"
            )
        case .completed:
            return Surface(
                label: "Session complete",
                detail: "Local session saved"
            )
        case .ready, nil:
            return Surface(
                label: "Preparing room",
                detail: "Restoring local session"
            )
        }
    }

    private static func candidateDetail(for input: Input) -> String {
        if input.canStopRecording {
            return "Recording segment"
        }
        let count = input.candidateSegmentCount
        if count == 0 {
            return "No segment yet"
        }
        return count == 1 ? "1 Segment" : "\(count) Segments"
    }

    private static func compactLabel(for input: Input) -> String {
        if input.phase == nil {
            switch input.roomAvailability {
            case .hostedSignInRequired: return "Connect Interview Arc"
            case .hostedActivityRequired: return "Open System Design activity"
            case .hostedRecoveryRequired: return "Hosted recovery required"
            case .ready, .restoring: break
            }
        }

        if input.isOpeningInterviewer {
            return input.isInterviewerRequestInFlight ? "Opening" : "Opening retry"
        }

        switch input.phase {
        case .candidateFloor:
            if input.turnMode == .continuousConversation {
                if input.isFloorHeld { return "Holding your floor" }
                if input.isCheckingAnswer { return "Checking answer" }
                return "Listening"
            }
            return "Your floor"
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
    var floorStatePresentation: FloorStatePresentation {
        let draftLifecycles = snapshot?.segments
            .filter { $0.committedTurnID == nil }
            .map(\.lifecycle) ?? []

        let speechActivity: FloorStatePresentation.SpeechActivity?
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

        return FloorStatePresentation.make(
            input: FloorStatePresentation.Input(
                phase: snapshot?.phase,
                candidateSegmentLifecycles: draftLifecycles,
                candidateSegmentCount: segments.count,
                statusMessage: statusMessage,
                attentionMessage: errorMessage
                    ?? speechErrorMessage
                    ?? interviewerAttentionMessage,
                speechActivity: speechActivity,
                isInterviewerRequestInFlight: isInterviewerRequestInFlight,
                isOpeningInterviewer: snapshot?.turns.isEmpty == true
                    && snapshot?.phase != .candidateFloor
                    && (snapshot?.phase == .interviewerProcessing
                        || isInterviewerRequestInFlight),
                isInterviewerReady: isInterviewerReady,
                canStopRecording: canStopRecording,
                roomAvailability: floorRoomAvailability,
                turnMode: snapshot?.turnMode ?? .continuousConversation,
                isFloorHeld: snapshot?.isFloorHeld == true,
                isCheckingAnswer: snapshot?.endpointEvaluations.last?.lifecycle == .authorized
                    || snapshot?.endpointGraces.contains(where: { $0.lifecycle == .pending }) == true
            )
        )
    }

    private var floorRoomAvailability: FloorStatePresentation.RoomAvailability {
        guard snapshot == nil else { return .ready }
        guard usesHostedAuthority else { return .restoring }
        switch hostedSnapshot.connection {
        case .signedOut:
            return .hostedSignInRequired
        case .noOpenSystemDesignActivity:
            return .hostedActivityRequired
        case .offline, .recoveryRequired:
            return .hostedRecoveryRequired
        case .loading, .readOnly, .writable:
            return .restoring
        }
    }
}
