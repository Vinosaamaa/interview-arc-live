import Foundation

public enum CodingHarnessCommandClass: String, Sendable, Equatable {
    case quickRun = "Quick run"
    case fullRun = "Full run"
}

public enum CodingHarnessOutcome: Sendable, Equatable {
    case running
    case locallyVerified(passed: Int, total: Int)
    case failed(passed: Int, total: Int)
    case notReady(String)
    case failedToRun(String)

    public var label: String {
        switch self {
        case .running:
            "Running"
        case .locallyVerified:
            "Locally verified"
        case .failed:
            "Local verification failed"
        case .notReady:
            "Local harness is not ready"
        case .failedToRun:
            "Local run failed"
        }
    }

    public var isSuccess: Bool {
        if case .locallyVerified = self { return true }
        return false
    }
}

public struct CodingHarnessReceipt: Sendable, Equatable {
    public let identity: String
    public let commandClass: CodingHarnessCommandClass
    public let exitCode: Int32
    public let outcome: CodingHarnessOutcome
    public let diagnostics: String

    public init(
        identity: String,
        commandClass: CodingHarnessCommandClass,
        exitCode: Int32,
        outcome: CodingHarnessOutcome,
        diagnostics: String
    ) {
        self.identity = identity
        self.commandClass = commandClass
        self.exitCode = exitCode
        self.outcome = outcome
        self.diagnostics = Self.conciseDiagnostics(diagnostics)
    }

    public var summaryLine: String {
        switch outcome {
        case .running:
            "Running"
        case .locallyVerified(let passed, let total):
            "\(outcome.label) · \(passed) / \(total)"
        case .failed(let passed, let total):
            "\(outcome.label) · \(passed) / \(total)"
        case .notReady, .failedToRun:
            outcome.label
        }
    }

    public static func parse(
        identity: String,
        commandClass: CodingHarnessCommandClass,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> CodingHarnessReceipt {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let outcome = outcome(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
        return CodingHarnessReceipt(
            identity: identity,
            commandClass: commandClass,
            exitCode: exitCode,
            outcome: outcome,
            diagnostics: combined
        )
    }

    public static func running(
        identity: String,
        commandClass: CodingHarnessCommandClass
    ) -> CodingHarnessReceipt {
        CodingHarnessReceipt(
            identity: identity,
            commandClass: commandClass,
            exitCode: -1,
            outcome: .running,
            diagnostics: "Running…"
        )
    }

    public static func notReady(
        identity: String,
        commandClass: CodingHarnessCommandClass,
        reason: String = "The repository-owned Java harness is not published for this activity."
    ) -> CodingHarnessReceipt {
        CodingHarnessReceipt(
            identity: identity,
            commandClass: commandClass,
            exitCode: 75,
            outcome: .notReady(reason),
            diagnostics: reason
        )
    }

    static func outcome(
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> CodingHarnessOutcome {
        let combined = stdout + "\n" + stderr
        let lowered = combined.lowercased()
        if lowered.contains("still preparing")
            || lowered.contains("cannot run from status")
            || lowered.contains("harness is not ready")
            || lowered.contains("missing required --generation")
            || lowered.contains("no published harness") {
            return .notReady(firstLine(of: combined) ?? "The local harness is not ready.")
        }
        if let counts = passedTotal(in: combined) {
            if exitCode == 0, lowered.contains("locally verified") {
                return .locallyVerified(passed: counts.passed, total: counts.total)
            }
            return .failed(passed: counts.passed, total: counts.total)
        }
        if exitCode == 0, lowered.contains("locally verified") {
            return .locallyVerified(passed: 0, total: 0)
        }
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failedToRun("The harness produced no output.")
        }
        return .failedToRun(firstLine(of: combined) ?? "The harness did not finish.")
    }

    private static func passedTotal(
        in text: String
    ) -> (passed: Int, total: Int)? {
        let pattern = /passed\s+(\d+)\s*\/\s*(\d+)/
        if let match = text.firstMatch(of: pattern) {
            return (Int(match.1) ?? 0, Int(match.2) ?? 0)
        }
        return nil
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static func conciseDiagnostics(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let kept = Array(lines.prefix(24))
        return kept.joined(separator: "\n")
    }
}
