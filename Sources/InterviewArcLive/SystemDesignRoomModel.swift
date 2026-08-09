import Foundation
import InterviewArcLiveCore

@MainActor
final class SystemDesignRoomModel: ObservableObject {
    @Published private(set) var snapshot: InterviewRoomSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Restoring local session…"

    let question = "Design a global notification system."

    private let sessionID = SessionID("local-system-design-tracer")
    private var session: InterviewRoomSession?

    var canAct: Bool {
        guard !isWorking, let phase = snapshot?.phase else { return false }
        return phase == .candidateFloor
            || phase == .interviewerProcessing
            || phase == .interviewerTurn
    }

    var actionTitle: String {
        switch snapshot?.phase {
        case .interviewerProcessing: "Retry interviewer"
        case .interviewerTurn: "Give me the floor"
        default: "Hand off"
        }
    }

    var actionIcon: String {
        snapshot?.phase == .interviewerProcessing
            ? "arrow.clockwise.circle.fill"
            : "arrowshape.right.circle.fill"
    }

    func open() async {
        guard session == nil, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let store = try FileSessionManifestStore()
            let runtime = DeterministicInterviewerRuntime(
                response: CanonicalInterviewerResponse(
                    displayMarkdown: "Good. How will clients observe delivery without coupling every channel to the request path?",
                    spokenText: "Good. How will clients observe delivery without coupling every channel to the request path?"
                )
            )

            let openedSession: InterviewRoomSession
            if try await store.load(sessionID: sessionID) == nil {
                openedSession = try await InterviewRoomSession.start(
                    sessionID: sessionID,
                    activityID: "local-system-design-tracer",
                    manifestStore: store,
                    interviewerRuntime: runtime
                )
            } else {
                openedSession = try await InterviewRoomSession.restore(
                    sessionID: sessionID,
                    manifestStore: store,
                    interviewerRuntime: runtime
                )
            }

            session = openedSession
            var restored = await openedSession.snapshot()
            if restored.phase == .ready {
                restored = try await openedSession.execute(
                    .giveCandidateFloor(commandID: CommandID("local-give-floor-0"))
                )
            }
            snapshot = restored
            statusMessage = status(for: restored)
        } catch {
            statusMessage = "Local session unavailable"
        }
    }

    func performPrimaryAction() async {
        guard let session, let snapshot, canAct else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let updated: InterviewRoomSnapshot
            switch snapshot.phase {
            case .candidateFloor:
                updated = try await session.execute(
                    .handOff(
                        commandID: CommandID("local-handoff-\(snapshot.revision)"),
                        transcript: CandidateTranscript(
                            body: "Transactional alerts need a durable path with explicit delivery state.",
                            quality: .verified
                        )
                    )
                )
            case .interviewerProcessing:
                updated = try await session.execute(
                    .retryInterviewerResponse(
                        commandID: CommandID(
                            "local-retry-interviewer-\(snapshot.revision)"
                        )
                    )
                )
            case .interviewerTurn:
                updated = try await session.execute(
                    .giveCandidateFloor(
                        commandID: CommandID("local-give-floor-\(snapshot.revision)")
                    )
                )
            default:
                return
            }

            self.snapshot = updated
            statusMessage = status(for: updated)
        } catch {
            let recovered = await session.snapshot()
            self.snapshot = recovered
            statusMessage = status(for: recovered)
        }
    }

    private func status(for snapshot: InterviewRoomSnapshot) -> String {
        if snapshot.phase == .interviewerProcessing {
            return "Answer saved · interviewer retry available"
        }
        return "Saved locally · revision \(snapshot.revision)"
    }
}
