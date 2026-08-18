import Foundation

public struct FloorHoldID:
    RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum FloorHoldLifecycle: String, Codable, Sendable, Equatable {
    case active
    case released
}

public enum FloorHoldReleaseReason: String, Codable, Sendable, Equatable {
    case sendAnswer = "send_answer"
    case turnModeChanged = "turn_mode_changed"
    case sessionFinished = "session_finished"
}

/// Durable candidate intent that keeps the Candidate Floor across pauses and
/// completed Segments. Automatic Endpoint Grace and Hand off stay suppressed
/// until Send answer releases the hold through the canonical Hand-off path.
public struct FloorHold: Codable, Sendable, Equatable {
    public let id: FloorHoldID
    public let activationCommandID: CommandID
    public let lifecycle: FloorHoldLifecycle
    public let releaseReason: FloorHoldReleaseReason?
    public let releaseCommandID: CommandID?
    public let completedCandidateTurnID: TurnID?

    internal init(
        id: FloorHoldID,
        activationCommandID: CommandID,
        lifecycle: FloorHoldLifecycle,
        releaseReason: FloorHoldReleaseReason? = nil,
        releaseCommandID: CommandID? = nil,
        completedCandidateTurnID: TurnID? = nil
    ) {
        self.id = id
        self.activationCommandID = activationCommandID
        self.lifecycle = lifecycle
        self.releaseReason = releaseReason
        self.releaseCommandID = releaseCommandID
        self.completedCandidateTurnID = completedCandidateTurnID
    }

    public static func active(
        id: FloorHoldID,
        activationCommandID: CommandID
    ) -> FloorHold {
        FloorHold(
            id: id,
            activationCommandID: activationCommandID,
            lifecycle: .active
        )
    }

    public func releasing(
        commandID: CommandID,
        reason: FloorHoldReleaseReason,
        candidateTurnID: TurnID? = nil
    ) -> FloorHold {
        FloorHold(
            id: id,
            activationCommandID: activationCommandID,
            lifecycle: .released,
            releaseReason: reason,
            releaseCommandID: commandID,
            completedCandidateTurnID: candidateTurnID
        )
    }
}

extension Array where Element == FloorHold {
    public var activeHold: FloorHold? {
        last { $0.lifecycle == .active }
    }
}
