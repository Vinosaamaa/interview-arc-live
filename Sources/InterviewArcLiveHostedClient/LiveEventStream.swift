import Foundation

public enum LiveEventStreamEvent: Equatable, Sendable {
    case connected
    case disconnected(retryAfterSeconds: Int)
    case invalidation(LiveInvalidation)
}

public actor LiveEventStream {
    private let origin: URL
    private let tokenReader: any LiveIntegrationTokenReading
    private let session: URLSession
    private var continuation: AsyncStream<LiveEventStreamEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var generation = 0

    public init(
        origin: URL = URLSessionLiveV1Transport.productionOrigin,
        tokenReader: any LiveIntegrationTokenReading
    ) throws {
        guard origin.scheme?.lowercased() == "https",
              origin.host != nil,
              origin.path.isEmpty || origin.path == "/" else {
            throw LiveV1ClientError.invalidConfiguration
        }
        self.origin = origin
        self.tokenReader = tokenReader
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        loopTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func events() -> AsyncStream<LiveEventStreamEvent> {
        generation += 1
        let ownerGeneration = generation
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation?.finish()
            self.continuation = continuation
            self.loopTask?.cancel()
            self.loopTask = Task { await self.run() }
            continuation.onTermination = { @Sendable _ in
                Task { await self.stop(generation: ownerGeneration) }
            }
        }
    }

    public func stop() {
        generation += 1
        stopOwnedStream()
    }

    private func stop(generation ownerGeneration: Int) {
        guard generation == ownerGeneration else { return }
        generation += 1
        stopOwnedStream()
    }

    private func stopOwnedStream() {
        loopTask?.cancel()
        loopTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        continuation?.finish()
        continuation = nil
    }

    public static func fallbackDelaySeconds(afterFailure attempt: Int) -> Int {
        let bounded = min(max(attempt, 0), 3)
        return 15 * (1 << bounded)
    }

    private func run() async {
        var failureAttempt = 0
        while !Task.isCancelled {
            do {
                try await connectAndReceive()
                failureAttempt = 0
            } catch is CancellationError {
                return
            } catch {
                let delay = Self.fallbackDelaySeconds(afterFailure: failureAttempt)
                failureAttempt = min(failureAttempt + 1, 3)
                continuation?.yield(.disconnected(retryAfterSeconds: delay))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func connectAndReceive() async throws {
        let token = try await tokenReader.readIntegrationToken()
        var components = URLComponents(
            url: origin,
            resolvingAgainstBaseURL: false
        )
        components?.path = "/events"
        guard let url = components?.url else {
            throw LiveV1ClientError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "interview-arc-live",
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        )
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        continuation?.yield(.connected)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if webSocket === task { webSocket = nil }
        }

        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: continue
            }
            guard let invalidation = try? JSONDecoder().decode(
                LiveInvalidation.self,
                from: data
            ), invalidation.isLivePracticeChange else {
                continue
            }
            continuation?.yield(.invalidation(invalidation))
        }
    }
}
