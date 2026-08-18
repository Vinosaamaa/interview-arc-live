import Foundation
import os

/// Public-safe runtime traces for Live. Values are allow-listed and sanitized
/// so unified logs never carry secrets, transcripts, audio, private IDs, or
/// paths. Emitting a trace must not change control flow.
public enum LiveDebugTrace: Sendable {
    public static let subsystem = "app.interviewarc.live"

    private static let logger = Logger(subsystem: subsystem, category: "trace")

    private static let allowedKeys: Set<String> = [
        "code",
        "connection",
        "count",
        "ok",
        "operation",
        "phase",
        "reason",
    ]

    public static func event(_ name: String, _ fields: [String: String] = [:]) {
        var parts = ["event=\(token(name))"]
        for key in fields.keys.sorted() where allowedKeys.contains(key) {
            parts.append("\(key)=\(token(fields[key] ?? ""))")
        }
        let line = parts.joined(separator: " ")
        logger.debug("\(line, privacy: .public)")
    }

    public static func token(_ value: String) -> String {
        if value.isEmpty { return "empty" }
        if value.count > 64 { return "redacted" }
        if value.contains("/") || value.contains("\\") { return "redacted" }
        if value.hasPrefix("sk-") || value.hasPrefix("gsk_") { return "redacted" }
        if value.contains("@") { return "redacted" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "redacted"
        }
        return value
    }
}
