import InterviewArcLiveCore

/// Pure presentation policy for the observational endpointing slice. The app
/// model supplies canonical evidence identities; this Module decides whether
/// the latest durable Evaluation is current and maps only bounded state to UI
/// copy.
struct EndpointShadowPresentation: Equatable {
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

    static func make(
        turnMode: TurnMode,
        phase: InterviewRoomPhase?,
        currentEvaluation: EndpointEvaluation?,
        hasSelectedDraft: Bool,
        hasUnresolvedDraft: Bool,
        hasStaleEvaluation: Bool
    ) -> EndpointShadowPresentation {
        if turnMode == .cueOnly {
            return EndpointShadowPresentation(
                title: "Cue Only turn-taking",
                detail: "A terminal finish, direct question, or hint cue triggers Hand off after its transcript is saved. The Hand off control remains available.",
                systemImage: "quote.bubble.fill",
                tone: .neutral
            )
        }
        guard turnMode == .patientAuto else {
            return EndpointShadowPresentation(
                title: "Manual turn-taking",
                detail: "Semantic endpoint calls are off. Hand off remains explicit.",
                systemImage: "hand.raised.fill",
                tone: .neutral
            )
        }
        guard phase == .candidateFloor else {
            return EndpointShadowPresentation(
                title: "Shadow waits for your floor",
                detail: "It observes completed Segments only. Hand off remains explicit.",
                systemImage: "eye",
                tone: .neutral
            )
        }
        if hasUnresolvedDraft {
            return EndpointShadowPresentation(
                title: "Shadow waiting for complete transcripts",
                detail: "Resolve or exclude every draft Segment before another advisory check.",
                systemImage: "ellipsis.bubble",
                tone: .neutral
            )
        }
        if hasStaleEvaluation {
            return EndpointShadowPresentation(
                title: "Evidence changed · Shadow waiting",
                detail: "The prior result is no longer current. A new Segment can start another check.",
                systemImage: "arrow.triangle.2.circlepath",
                tone: .neutral
            )
        }
        guard let currentEvaluation else {
            return EndpointShadowPresentation(
                title: hasSelectedDraft
                    ? "Shadow waits for the next Segment"
                    : "Shadow waiting for a transcript",
                detail: hasSelectedDraft
                    ? "Existing evidence is not sent retroactively. Hand off remains explicit."
                    : "It checks only after a new selected transcript is saved.",
                systemImage: "eye",
                tone: .neutral
            )
        }

        return lifecyclePresentation(for: currentEvaluation)
    }

    private static func lifecyclePresentation(
        for evaluation: EndpointEvaluation
    ) -> EndpointShadowPresentation {
        switch evaluation.lifecycle {
        case .authorized:
            return EndpointShadowPresentation(
                title: "Shadow checking this answer",
                detail: "Authorization is saved. This check cannot Hand off your answer.",
                systemImage: "hourglass",
                tone: .working
            )
        case .proposalStored:
            guard let proposal = evaluation.proposal else {
                return invalidStatus
            }
            return proposalPresentation(for: proposal)
        case .failed:
            guard let failure = evaluation.failure else {
                return invalidStatus
            }
            return failurePresentation(for: failure)
        }
    }

    private static func proposalPresentation(
        for proposal: SemanticEndpointProposal
    ) -> EndpointShadowPresentation {
        switch proposal.decision {
        case .likelyContinue:
            return EndpointShadowPresentation(
                title: "Shadow: keep going",
                detail: "The answer may be unfinished. Advisory only; Hand off remains explicit.",
                systemImage: "arrow.forward.circle",
                tone: .advisory
            )
        case .likelyEnd:
            return EndpointShadowPresentation(
                title: "Shadow: likely complete",
                detail: "This is advisory only. Nothing happens until you choose Hand off.",
                systemImage: "checkmark.circle",
                tone: .advisory
            )
        case .ambiguous:
            return EndpointShadowPresentation(
                title: "Shadow: unclear",
                detail: "Keep answering or Hand off when you decide the answer is complete.",
                systemImage: "questionmark.circle",
                tone: .neutral
            )
        }
    }

    private static func failurePresentation(
        for failure: EndpointEvaluationFailure
    ) -> EndpointShadowPresentation {
        switch failure.reason {
        case .missingCredential:
            return EndpointShadowPresentation(
                title: "Shadow needs a Groq key",
                detail: "The transcript is saved. Add a key before a later Segment check.",
                systemImage: "key.fill",
                tone: .warning
            )
        case .contextRejected:
            return EndpointShadowPresentation(
                title: "Shadow skipped this answer",
                detail: "The complete draft exceeds its context limit. Hand off remains explicit.",
                systemImage: "doc.badge.ellipsis",
                tone: .warning
            )
        case .transportFailure:
            return EndpointShadowPresentation(
                title: "Shadow unavailable",
                detail: "The transcript is saved. A later Segment can start a new check.",
                systemImage: "network.slash",
                tone: .warning
            )
        case .providerRejected:
            return EndpointShadowPresentation(
                title: "Shadow request rejected",
                detail: "The transcript is saved. Check Groq access before the next Segment.",
                systemImage: "exclamationmark.shield.fill",
                tone: .warning
            )
        case .invalidResponse:
            return EndpointShadowPresentation(
                title: "Shadow response unavailable",
                detail: "No advisory result was saved. Hand off remains explicit.",
                systemImage: "exclamationmark.bubble.fill",
                tone: .warning
            )
        case .interrupted:
            return EndpointShadowPresentation(
                title: "Shadow check interrupted",
                detail: "It will not replay automatically. A later Segment can start a new check.",
                systemImage: "pause.circle.fill",
                tone: .warning
            )
        }
    }

    private static var invalidStatus: EndpointShadowPresentation {
        EndpointShadowPresentation(
            title: "Shadow status unavailable",
            detail: "The transcript is saved. Hand off remains explicit.",
            systemImage: "exclamationmark.circle.fill",
            tone: .warning
        )
    }
}
