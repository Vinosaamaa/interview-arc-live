import Darwin
import Foundation
import InterviewArcLiveCodexAdapter
import InterviewArcLiveCore

@main
struct InterviewArcLiveCodexSmoke {
    private static let optInEnvironmentKey =
        "INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE"

    static func main() async {
        guard ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1" else {
            fail(
                "Codex smoke is opt-in. Set \(optInEnvironmentKey)=1 to run it.",
                code: 64
            )
        }

        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        guard !isInsideRepository(workingDirectory) else {
            fail("Codex smoke requires a temporary non-repository working directory.", code: 65)
        }

        let runtime = CodexAppServerInterviewerRuntime(
            workingDirectoryURL: workingDirectory,
            model: CodexAppServerInterviewerRuntime.defaultInterviewerModel
        )
        switch await runtime.preflight() {
        case .ready:
            break
        case .missing:
            fail("Codex smoke failed: Codex is not installed.", code: 69)
        case .incompatible(_, let requiredVersion):
            fail("Codex smoke failed: this build requires \(requiredVersion).", code: 69)
        case .unauthenticated:
            fail("Codex smoke failed: sign in through ChatGPT or Codex first.", code: 69)
        case .transportFailure:
            fail("Codex smoke failed: the local readiness check did not complete.", code: 69)
        }

        do {
            let prompt = try ActivityPrompt(
                specialty: .systemDesign,
                stage: "Installed smoke",
                question: "Ask one concise system-design follow-up.",
                requestedParts: ["Probe queue backpressure and delivery reliability."]
            )
            let candidate = CandidateTurn(
                id: TurnID("installed-smoke-candidate"),
                commandID: CommandID("installed-smoke-command"),
                transcript: CandidateTranscript(
                    body: "I would absorb bursts in a durable queue and make delivery workers idempotent.",
                    quality: .verified
                )
            )
            let request = InterviewerRequest(
                sessionID: SessionID("installed-codex-smoke"),
                activityID: "installed-codex-smoke",
                activityPrompt: prompt,
                candidateTurn: candidate,
                priorVisibleTurns: [],
                responseTurnID: TurnID("installed-smoke-interviewer")
            )
            let response = try await runtime.respond(to: request)
            guard !response.displayMarkdown.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  !response.spokenText.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else {
                fail("Codex smoke failed: no canonical interviewer response.", code: 70)
            }
            print("Installed Codex interviewer smoke passed.")
        } catch let error as CodexAppServerRuntimeError {
            fail(safeFailureMessage(for: error), code: 70)
        } catch {
            fail("Codex smoke failed before a canonical response was accepted.", code: 70)
        }
    }

    private static func safeFailureMessage(
        for error: CodexAppServerRuntimeError
    ) -> String {
        switch error {
        case .missing:
            "Codex smoke failed: Codex is not installed."
        case .incompatible(_, let requiredVersion):
            "Codex smoke failed: this build requires \(requiredVersion)."
        case .unauthenticated:
            "Codex smoke failed: sign in through ChatGPT or Codex first."
        case .transportFailure:
            "Codex smoke failed: the local transport did not complete."
        case .protocolFailure:
            "Codex smoke failed: the tested local protocol did not complete."
        case .serverFailure:
            "Codex smoke failed: the local server rejected the request."
        case .malformedFinalResponse:
            "Codex smoke failed: the final response was malformed."
        case .cancelled:
            "Codex smoke failed: the request was cancelled."
        }
    }

    private static func isInsideRepository(_ directory: URL) -> Bool {
        var current = directory.resolvingSymlinksInPath().standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(
                atPath: current.appendingPathComponent(".git").path
            ) {
                return true
            }
            current.deleteLastPathComponent()
        }
        return false
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        if let data = "\(message)\n".data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        Darwin.exit(code)
    }
}
