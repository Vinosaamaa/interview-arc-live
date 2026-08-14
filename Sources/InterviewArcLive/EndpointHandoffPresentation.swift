import InterviewArcLiveCore

/// Pure presentation policy for functional Patient Auto. The app model
/// supplies canonical evidence identities; this Module maps durable
/// Evaluation and Endpoint Grace state to bounded, truthful UI copy.
struct EndpointHandoffPresentation: Equatable {
    struct Input {
        let turnMode: TurnMode
        let phase: InterviewRoomPhase?
        let currentEvaluation: EndpointEvaluation?
        let endpointGrace: EndpointGrace?
        let canAutomaticallyHandOff: Bool
        let hasSelectedDraft: Bool
        let hasUnresolvedDraft: Bool
        let hasStaleEvaluation: Bool
    }

    enum Tone: Equatable {
        case neutral
        case working
        case advisory
        case warning
    }

    let title: String
    let detail: String
    let systemImage: String
    let tone: Tone

    static func currentEvaluation(
        in evaluations: [EndpointEvaluation],
        selectedCandidateIDs: [TranscriptCandidateID],
        questionTurnID: TurnID?,
        hasUnresolvedDraft: Bool
    ) -> EndpointEvaluation? {
        guard !hasUnresolvedDraft,
              let latestEvaluation = evaluations.last,
              latestEvaluation.selectedCandidateIDs == selectedCandidateIDs,
              latestEvaluation.questionTurnID == questionTurnID else {
            return nil
        }
        return latestEvaluation
    }

    static func make(input: Input) -> EndpointHandoffPresentation {
        guard input.turnMode == .patientAuto else {
            return EndpointHandoffPresentation(
                title: "Manual turn-taking",
                detail: "Semantic endpoint calls are off. Hand off remains explicit.",
                systemImage: "hand.raised.fill",
                tone: .neutral
            )
        }
        guard input.phase == .candidateFloor else {
            return EndpointHandoffPresentation(
                title: "Patient Auto waits for your floor",
                detail: "Automatic Hand off only runs during the Candidate Floor.",
                systemImage: "hourglass",
                tone: .neutral
            )
        }
        if input.hasUnresolvedDraft {
            return EndpointHandoffPresentation(
                title: "Patient Auto waiting for complete transcripts",
                detail: "Resolve or exclude every draft Segment before another endpoint check.",
                systemImage: "ellipsis.bubble",
                tone: .neutral
            )
        }
        if input.hasStaleEvaluation {
            return EndpointHandoffPresentation(
                title: "Evidence changed · Patient Auto waiting",
                detail: "The prior result is no longer current. A new Segment can start another check.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .neutral
            )
        }
        if let endpointGrace = input.endpointGrace {
            switch endpointGrace.lifecycle {
            case .pending:
                return EndpointHandoffPresentation(
                    title: "Handing off in 4 seconds",
                    detail: "Choose Keep my floor or begin recording to cancel automatic Hand off.",
                    systemImage: "timer",
                    tone: .working
                )
            case .cancelled:
                return cancelledPresentation(reason: endpointGrace.cancellationReason)
            case .completed:
                break
            }
        }
        guard let currentEvaluation = input.currentEvaluation else {
            return EndpointHandoffPresentation(
                title: input.hasSelectedDraft
                    ? "Patient Auto waits for the next Segment"
                    : "Patient Auto waiting for a transcript",
                detail: input.hasSelectedDraft
                    ? "Existing evidence is not sent retroactively. Hand off remains available."
                    : "It checks after a new selected transcript is saved.",
                systemImage: "waveform.badge.magnifyingglass",
                tone: .neutral
            )
        }

        return lifecyclePresentation(
            for: currentEvaluation,
            canAutomaticallyHandOff: input.canAutomaticallyHandOff
        )
    }

    private static func cancelledPresentation(
        reason: EndpointGraceCancellationReason?
    ) -> EndpointHandoffPresentation {
        switch reason {
        case .keptFloor:
            return EndpointHandoffPresentation(
                title: "Your floor is staying open",
                detail: "Patient Auto waits for a new completed Segment. Hand off remains available.",
                systemImage: "hand.raised.fill",
                tone: .advisory
            )
        case .boardActivity, .notesActivity:
            return EndpointHandoffPresentation(
                title: "Patient Auto cancelled after new work",
                detail: "A new Segment can start another check. Hand off remains available.",
                systemImage: "pencil.and.list.clipboard",
                tone: .advisory
            )
        case .interrupted:
            return EndpointHandoffPresentation(
                title: "Automatic Hand off was interrupted",
                detail: "It was not replayed. Continue answering or choose Hand off explicitly.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                tone: .warning
            )
        case .resumedSpeech:
            return EndpointHandoffPresentation(
                title: "Patient Auto cancelled when speech resumed",
                detail: "Finish the new Segment before Patient Auto checks again.",
                systemImage: "waveform",
                tone: .advisory
            )
        case .turnModeChanged, .manualHandOff, .sessionFinished, nil:
            return EndpointHandoffPresentation(
                title: "Automatic Hand off cancelled",
                detail: "The saved answer evidence is unchanged. Hand off remains available.",
                systemImage: "xmark.circle",
                tone: .neutral
            )
        }
    }

    private static func lifecyclePresentation(
        for evaluation: EndpointEvaluation,
        canAutomaticallyHandOff: Bool
    ) -> EndpointHandoffPresentation {
        switch evaluation.lifecycle {
        case .authorized:
            return EndpointHandoffPresentation(
                title: "Patient Auto checking this answer",
                detail: "Authorization is saved before the semantic request.",
                systemImage: "hourglass",
                tone: .working
            )
        case .proposalStored:
            guard let proposal = evaluation.proposal else {
                return invalidStatus
            }
            return proposalPresentation(
                for: proposal,
                canAutomaticallyHandOff: canAutomaticallyHandOff
            )
        case .failed:
            guard let failure = evaluation.failure else {
                return invalidStatus
            }
            return failurePresentation(for: failure)
        }
    }

    private static func proposalPresentation(
        for proposal: SemanticEndpointProposal,
        canAutomaticallyHandOff: Bool
    ) -> EndpointHandoffPresentation {
        switch proposal.decision {
        case .likelyContinue:
            return EndpointHandoffPresentation(
                title: "Patient Auto: keep going",
                detail: "The answer may be unfinished. Your Candidate Floor stays active.",
                systemImage: "arrow.forward.circle",
                tone: .advisory
            )
        case .likelyEnd:
            guard canAutomaticallyHandOff else {
                return EndpointHandoffPresentation(
                    title: "Save the Board before automatic Hand off",
                    detail: "The completion signal is saved. Save this Board draft as a revision, or choose Hand off after saving.",
                    systemImage: "square.and.arrow.down",
                    tone: .warning
                )
            }
            return EndpointHandoffPresentation(
                title: "Preparing automatic Hand off",
                detail: "The completion signal is saved; grace starts only while evidence remains current.",
                systemImage: "checkmark.circle",
                tone: .advisory
            )
        case .ambiguous:
            return EndpointHandoffPresentation(
                title: "Patient Auto: unclear",
                detail: "Keep answering or Hand off when you decide the answer is complete.",
                systemImage: "questionmark.circle",
                tone: .neutral
            )
        }
    }

    private static func failurePresentation(
        for failure: EndpointEvaluationFailure
    ) -> EndpointHandoffPresentation {
        switch failure.reason {
        case .missingCredential:
            return EndpointHandoffPresentation(
                title: "Patient Auto needs a Groq key",
                detail: "The transcript is saved. Add a key before a later Segment check.",
                systemImage: "key.fill",
                tone: .warning
            )
        case .contextRejected:
            return EndpointHandoffPresentation(
                title: "Patient Auto skipped this answer",
                detail: "The complete draft exceeds its context limit. Hand off remains explicit.",
                systemImage: "doc.badge.ellipsis",
                tone: .warning
            )
        case .transportFailure:
            return EndpointHandoffPresentation(
                title: "Patient Auto unavailable",
                detail: "The transcript is saved. A later Segment can start a new check.",
                systemImage: "network.slash",
                tone: .warning
            )
        case .providerRejected:
            return EndpointHandoffPresentation(
                title: "Patient Auto request rejected",
                detail: "The transcript is saved. Check Groq access before the next Segment.",
                systemImage: "exclamationmark.shield.fill",
                tone: .warning
            )
        case .invalidResponse:
            return EndpointHandoffPresentation(
                title: "Patient Auto response unavailable",
                detail: "No advisory result was saved. Hand off remains explicit.",
                systemImage: "exclamationmark.bubble.fill",
                tone: .warning
            )
        case .interrupted:
            return EndpointHandoffPresentation(
                title: "Patient Auto check interrupted",
                detail: "It will not replay automatically. A later Segment can start a new check.",
                systemImage: "pause.circle.fill",
                tone: .warning
            )
        }
    }

    private static var invalidStatus: EndpointHandoffPresentation {
        EndpointHandoffPresentation(
            title: "Patient Auto status unavailable",
            detail: "The transcript is saved. Hand off remains explicit.",
            systemImage: "exclamationmark.circle.fill",
            tone: .warning
        )
    }
}
