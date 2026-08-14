import Foundation

/// Time Seam for the visible Patient Auto grace period. Production continuous
/// time and deterministic test time are both real Adapters; neither owns any
/// Session transition or evidence decision.
public protocol EndpointGraceScheduling: Sendable {
    func waitForGrace() async throws
}

public struct ContinuousEndpointGraceScheduler: EndpointGraceScheduling {
    public init() {}

    public func waitForGrace() async throws {
        try await Task.sleep(
            for: .milliseconds(EndpointGrace.durationMilliseconds)
        )
    }
}
