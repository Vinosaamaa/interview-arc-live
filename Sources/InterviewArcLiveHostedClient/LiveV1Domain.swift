import Foundation

public typealias LiveEpochMilliseconds = Int64

public enum LiveResult: String, Codable, CaseIterable, Sendable {
    case solved
    case solvedAfterReviewingApproach = "solved_after_reviewing_approach"
    case failed
    case unknown = "__unknown"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum LiveActivityType: String, Codable, Sendable {
    case leetcode
    case systemDesign = "system_design"
    case behavioral
    case unknown = "__unknown"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum LiveActivityLifecycle: String, Codable, Sendable {
    case planned
    case running
    case completed
    case unknown = "__unknown"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct LiveTimer: Codable, Equatable, Sendable {
    public let accumulatedSeconds: Double
    public let startedAt: LiveEpochMilliseconds?
    public let runningSince: LiveEpochMilliseconds?
    public let completed: Bool
    public let completedAt: LiveEpochMilliseconds?
    public let revision: Int

    public init(
        accumulatedSeconds: Double,
        startedAt: LiveEpochMilliseconds?,
        runningSince: LiveEpochMilliseconds?,
        completed: Bool,
        completedAt: LiveEpochMilliseconds?,
        revision: Int
    ) {
        self.accumulatedSeconds = accumulatedSeconds
        self.startedAt = startedAt
        self.runningSince = runningSince
        self.completed = completed
        self.completedAt = completedAt
        self.revision = revision
    }
}

public struct LiveWorkbench: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int
    public let openedPacificDate: String
    public let openedAt: LiveEpochMilliseconds
}

public struct LiveFocus: Codable, Equatable, Sendable {
    public let activityId: String?
    public let sessionId: String?
    public let focusedAt: LiveEpochMilliseconds?
}

public struct LiveSessionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let activityIds: [String]
    public let allocatedSeconds: Int?
    public let revision: Int
    public let timer: LiveTimer?
}

public struct LiveResultProjection: Codable, Equatable, Sendable {
    public let value: LiveResult?
    public let revision: Int
}

public struct LiveActivitySummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let questionId: String?
    public let date: String
    public let source: String?
    public let type: LiveActivityType
    public let title: String
    public let prompt: String?
    public let allocatedSeconds: Int
    public let sessionId: String?
    public let lifecycle: LiveActivityLifecycle
    public let revision: Int
    public let timer: LiveTimer?
    public let result: LiveResultProjection
}

public struct LiveTodayProjection: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serverTime: LiveEpochMilliseconds
    public let ownerRevision: Int
    public let workbench: LiveWorkbench?
    public let focus: LiveFocus
    public let sessions: [LiveSessionSummary]
    public let activities: [LiveActivitySummary]

    public var selectedSystemDesignActivity: LiveActivitySummary? {
        if let focused = focus.activityId,
           let activity = activities.first(where: {
               $0.id == focused
                   && $0.type == .systemDesign
                   && ($0.lifecycle == .planned || $0.lifecycle == .running)
           }) {
            return activity
        }
        return activities.first {
            $0.type == .systemDesign
                && ($0.lifecycle == .planned || $0.lifecycle == .running)
        }
    }
}

public enum LiveCandidateEvidenceStatus: String, Codable, Sendable {
    case verified
    case bestAvailable = "best_available"
    case possibleContamination = "possible_contamination"
    case unknown = "__unknown"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct LiveCandidateTurn: Codable, Equatable, Sendable {
    public let turnId: String
    public let text: String
    public let evidenceStatus: LiveCandidateEvidenceStatus
    public let evidenceConfirmedAt: LiveEpochMilliseconds?
    public let evidenceSatisfied: Bool
    public let occurredAt: LiveEpochMilliseconds
    public let sequence: Int
}

public struct LiveInterviewerTurn: Codable, Equatable, Sendable {
    public let turnId: String
    public let displayMarkdown: String
    public let spokenText: String
    public let occurredAt: LiveEpochMilliseconds
    public let sequence: Int
}

public struct LivePair: Codable, Equatable, Sendable, Identifiable {
    public let pairId: String
    public let candidate: LiveCandidateTurn
    public let interviewer: LiveInterviewerTurn
    public let clipId: String?
    public let committedAt: LiveEpochMilliseconds

    public var id: String { pairId }
}

public enum LiveClipStatus: String, Codable, Sendable {
    case staged
    case uploading
    case available
    case failed
    case abandoned
    case unknown = "__unknown"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct LiveClip: Codable, Equatable, Sendable, Identifiable {
    public let clipId: String
    public let candidateTurnId: String
    public let pairId: String?
    public let mimeType: String
    public let byteSize: Int
    public let sha256: String
    public let status: LiveClipStatus
    public let failureCode: String?
    public let createdAt: LiveEpochMilliseconds
    public let updatedAt: LiveEpochMilliseconds

    public var id: String { clipId }
}

public struct LiveLeaseSummary: Codable, Equatable, Sendable {
    public let active: Bool
    public let holderPresent: Bool
    public let expiresAt: LiveEpochMilliseconds?
}

public struct LiveActivityProjection: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serverTime: LiveEpochMilliseconds
    public let ownerRevision: Int
    public let workbench: LiveWorkbench
    public let focus: LiveFocus
    public let session: LiveSessionSummary?
    public let activity: LiveActivityDetail
    public let lease: LiveLeaseSummary
    public let pairs: [LivePair]
    public let clips: [LiveClip]
}

public struct LiveActivityDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let questionId: String?
    public let date: String
    public let source: String?
    public let type: LiveActivityType
    public let title: String
    public let prompt: String?
    public let allocatedSeconds: Int
    public let sessionId: String?
    public let lifecycle: LiveActivityLifecycle
    public let revision: Int
    public let timer: LiveTimer?
    public let result: LiveResultProjection
    public let textEvidenceSatisfied: Bool
}

public indirect enum LiveJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LiveJSONValue])
    case array([LiveJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LiveJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([LiveJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct LiveMutationReceipt: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operationId: String
    public let activityId: String
    public let operation: String
    public let committedAt: LiveEpochMilliseconds
    public let result: [String: LiveJSONValue]
}

public struct LiveLeaseGrant: Codable, Equatable, Sendable {
    public let fencingToken: Int
    public let expiresAt: LiveEpochMilliseconds
    public let holderSessionId: String
}

public struct LiveConfirmation: Codable, Equatable, Sendable {
    public let pairId: String
    public let confirmedAt: LiveEpochMilliseconds
}

public struct LiveMutationResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let duplicate: Bool
    public let receipt: LiveMutationReceipt
    public let activity: LiveActivityProjection
    public let lease: LiveLeaseGrant?
    public let selectedNextActivityId: String?
    public let confirmation: LiveConfirmation?
    public let today: LiveTodayProjection?
    public let clip: LiveClip?
}

public struct LiveReceiptResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let receipt: LiveMutationReceipt
}

public struct LiveErrorBody: Codable, Equatable, Sendable {
    public let error: String
    public let code: String
    public let retryable: Bool
    public let holderPresent: Bool?
    public let expiresAt: LiveEpochMilliseconds?
}

public struct LiveInvalidation: Codable, Equatable, Sendable {
    public let type: String
    public let revision: Int
    public let scope: String
    public let occurredAt: LiveEpochMilliseconds

    public var isLivePracticeChange: Bool {
        type == "practice_changed" && scope == "live" && revision > 0
    }
}

public struct LiveCandidatePairInput: Codable, Equatable, Sendable {
    public let turnId: String
    public let text: String
    public let evidenceStatus: LiveCandidateEvidenceStatus
    public let occurredAt: LiveEpochMilliseconds

    public init(
        turnId: String,
        text: String,
        evidenceStatus: LiveCandidateEvidenceStatus,
        occurredAt: LiveEpochMilliseconds
    ) {
        self.turnId = turnId
        self.text = text
        self.evidenceStatus = evidenceStatus
        self.occurredAt = occurredAt
    }
}

public struct LiveInterviewerPairInput: Codable, Equatable, Sendable {
    public let turnId: String
    public let displayMarkdown: String
    public let spokenText: String
    public let occurredAt: LiveEpochMilliseconds

    public init(
        turnId: String,
        displayMarkdown: String,
        spokenText: String,
        occurredAt: LiveEpochMilliseconds
    ) {
        self.turnId = turnId
        self.displayMarkdown = displayMarkdown
        self.spokenText = spokenText
        self.occurredAt = occurredAt
    }
}

public enum LiveCommand: String, Codable, Sendable {
    case start
    case pause
    case finish
    case setResult = "set_result"
    case clearResult = "clear_result"
    case confirmCandidateEvidence = "confirm_candidate_evidence"
    case finishNext = "finish-next"
}
