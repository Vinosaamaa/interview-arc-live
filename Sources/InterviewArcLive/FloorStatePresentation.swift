import InterviewArcLiveCore

struct FloorStatePresentation: Equatable {
    enum StatusKind: Equatable, CaseIterable {
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
        var isCodexReady: Bool
        var canStopRecording: Bool

        init(
            phase: InterviewRoomPhase? = nil,
            candidateSegmentLifecycles: [CandidateSegmentLifecycle] = [],
            candidateSegmentCount: Int = 0,
            statusMessage: String = "Restoring local session…",
            attentionMessage: String? = nil,
            speechActivity: SpeechActivity? = nil,
            isInterviewerRequestInFlight: Bool = false,
            isCodexReady: Bool = false,
            canStopRecording: Bool = false
        ) {
            self.phase = phase
            self.candidateSegmentLifecycles = candidateSegmentLifecycles
            self.candidateSegmentCount = candidateSegmentCount
            self.statusMessage = statusMessage
            self.attentionMessage = attentionMessage
            self.speechActivity = speechActivity
            self.isInterviewerRequestInFlight = isInterviewerRequestInFlight
            self.isCodexReady = isCodexReady
            self.canStopRecording = canStopRecording
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
                label: compactLabel(for: input.phase),
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

    private static func fullSurface(for input: Input) -> Surface {
        if input.isInterviewerRequestInFlight {
            return Surface(
                label: "Answer saved · Codex working",
                detail: "Codex is preparing Mara"
            )
        }

        switch input.phase {
        case .candidateFloor:
            return Surface(
                label: "Your floor",
                detail: candidateDetail(for: input)
            )
        case .interviewerProcessing:
            return Surface(
                label: input.isCodexReady
                    ? "Answer saved · interviewer retry required"
                    : "Answer saved · check Codex to retry",
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

    private static func compactLabel(
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
                    ?? codexAttentionMessage,
                speechActivity: speechActivity,
                isInterviewerRequestInFlight: isInterviewerRequestInFlight,
                isCodexReady: isCodexReady,
                canStopRecording: canStopRecording
            )
        )
    }
}
