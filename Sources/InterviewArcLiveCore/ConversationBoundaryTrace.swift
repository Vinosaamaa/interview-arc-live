import Foundation
import os

/// Public-safe Module-boundary trace. Callers may record command, phase,
/// result code, and counts only. Audio, transcripts, credentials, private
/// IDs, provider bodies, and filesystem paths must never appear here.
public struct ConversationBoundaryEvent: Sendable, Equatable {
    public let command: String
    public let phase: InterviewRoomPhase
    public let resultCode: String
    public let counts: [String: Int]

    public init(
        command: String,
        phase: InterviewRoomPhase,
        resultCode: String,
        counts: [String: Int] = [:]
    ) {
        self.command = command
        self.phase = phase
        self.resultCode = resultCode
        self.counts = counts
    }
}

public protocol ConversationBoundaryTracing: AnyObject, Sendable {
    func record(_ event: ConversationBoundaryEvent)
}

/// Production tracer. The payload is only bounded enums and integer counts.
public final class OSLogConversationBoundaryTracer: ConversationBoundaryTracing, Sendable {
    private let logger = Logger(
        subsystem: "app.interviewarc.live",
        category: "conversation-boundary"
    )

    public init() {}

    public func record(_ event: ConversationBoundaryEvent) {
        let countSummary = event.counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        logger.info(
            "command=\(event.command, privacy: .public) phase=\(event.phase.rawValue, privacy: .public) result=\(event.resultCode, privacy: .public) counts=\(countSummary, privacy: .public)"
        )
    }
}

/// Reference-semantic tracer for tests.
public final class CapturingConversationBoundaryTracer:
    ConversationBoundaryTracing,
    @unchecked Sendable
{
    public private(set) var events: [ConversationBoundaryEvent] = []
    private let lock = NSLock()

    public init() {}

    public func record(_ event: ConversationBoundaryEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
