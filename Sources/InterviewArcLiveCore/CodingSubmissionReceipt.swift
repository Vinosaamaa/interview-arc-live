import Foundation

public enum CodingSubmissionCommand: String, Sendable, Equatable {
    case submit
    case retry
    case receipt
}

public enum CodingSubmissionOutcome: Sendable, Equatable {
    case submitting
    case waitingForLeetCode
    case accepted
    case rejected(verdict: String)
    case failed(code: String?, message: String)
    case ambiguous(String)

    public var label: String {
        switch self {
        case .submitting:
            "Submitting"
        case .waitingForLeetCode:
            "Submitting · waiting for LeetCode"
        case .accepted:
            "Accepted"
        case .rejected(let verdict):
            verdict
        case .failed:
            "Submit failed"
        case .ambiguous:
            "Submit result is ambiguous"
        }
    }

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

public struct CodingSubmissionReceipt: Sendable, Equatable {
    public let invocationID: String
    public let command: CodingSubmissionCommand
    public let outcome: CodingSubmissionOutcome
    public let diagnostics: String

    public init(
        invocationID: String,
        command: CodingSubmissionCommand,
        outcome: CodingSubmissionOutcome,
        diagnostics: String
    ) {
        self.invocationID = invocationID
        self.command = command
        self.outcome = outcome
        self.diagnostics = diagnostics
    }

    public var summaryLine: String {
        outcome.label
    }

    public static func submitting(
        invocationID: String,
        command: CodingSubmissionCommand
    ) -> CodingSubmissionReceipt {
        CodingSubmissionReceipt(
            invocationID: invocationID,
            command: command,
            outcome: .waitingForLeetCode,
            diagnostics: "Submitting · waiting for LeetCode"
        )
    }

    public static func parse(
        invocationID: String,
        command: CodingSubmissionCommand,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) -> CodingSubmissionReceipt {
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let envelope = JSONEnvelope.parse(from: stdout) ?? JSONEnvelope.parse(from: stderr) else {
            let reason = combined.isEmpty
                ? "The controller produced no structured envelope."
                : firstLine(of: combined) ?? combined
            return CodingSubmissionReceipt(
                invocationID: invocationID,
                command: command,
                outcome: .ambiguous(reason),
                diagnostics: combined.isEmpty ? reason : combined
            )
        }
        return fromEnvelope(
            envelope,
            fallbackInvocationID: invocationID,
            command: command,
            combinedDiagnostics: combined
        )
    }

    public static func fromEnvelope(
        _ envelope: JSONEnvelope,
        fallbackInvocationID: String,
        command: CodingSubmissionCommand,
        combinedDiagnostics: String
    ) -> CodingSubmissionReceipt {
        let invocationID = envelope.invocationId ?? fallbackInvocationID
        if envelope.ok {
            let verdict = envelope.resultVerdict?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outcome: CodingSubmissionOutcome
            if verdict == "Accepted" {
                outcome = .accepted
            } else if !verdict.isEmpty {
                outcome = .rejected(verdict: verdict)
            } else {
                outcome = .ambiguous("The controller returned success without a verdict.")
            }
            return CodingSubmissionReceipt(
                invocationID: invocationID,
                command: command,
                outcome: outcome,
                diagnostics: combinedDiagnostics
            )
        }
        if envelope.errorCode == "controller_receipt_pending" {
            return CodingSubmissionReceipt(
                invocationID: invocationID,
                command: command,
                outcome: .ambiguous(
                    envelope.errorMessage
                        ?? "The invocation was reserved but no terminal receipt is available."
                ),
                diagnostics: combinedDiagnostics
            )
        }
        return CodingSubmissionReceipt(
            invocationID: invocationID,
            command: command,
            outcome: .failed(code: envelope.errorCode, message: envelope.errorMessage ?? "Submit failed"),
            diagnostics: combinedDiagnostics
        )
    }

    public struct JSONEnvelope: Equatable, Sendable {
        public var ok: Bool
        public var invocationId: String?
        public var resultVerdict: String?
        public var errorCode: String?
        public var errorMessage: String?

        public static func parse(from text: String) -> JSONEnvelope? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = extractJSONObject(from: trimmed),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = object["ok"] as? Bool else {
                return nil
            }
            let result = object["result"] as? [String: Any]
            let error = object["error"] as? [String: Any]
            return JSONEnvelope(
                ok: ok,
                invocationId: object["invocationId"] as? String,
                resultVerdict: result?["verdict"] as? String,
                errorCode: error?["code"] as? String,
                errorMessage: error?["message"] as? String
            )
        }

        private static func extractJSONObject(from text: String) -> Data? {
            if let data = text.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
                return data
            }
            guard let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}"),
                  start < end else {
                return nil
            }
            let slice = String(text[start...end])
            return slice.data(using: .utf8)
        }
    }

    private static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
