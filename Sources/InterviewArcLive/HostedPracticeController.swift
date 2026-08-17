import Foundation
import InterviewArcLiveHostedClient

@MainActor
final class HostedPracticeController: ObservableObject {
    @Published private(set) var snapshot = HostedPracticeSnapshot(
        connection: .signedOut
    )
    @Published private(set) var tokenReadiness: LiveIntegrationTokenReadiness = .missing
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published var isConnectionSetupPresented = false

    private let tokenStore: LiveIntegrationTokenStore
    private let session: HostedPracticeSession
    private let eventStream: LiveEventStream
    private let tokenValidator: @Sendable (String) async throws -> Void
    private var eventTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var fallbackRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    static func makeDefault() throws -> HostedPracticeController {
        let tokenStore = LiveIntegrationTokenStore()
        let transport = try URLSessionLiveV1Transport()
        let client = LiveV1Client(
            tokenReader: tokenStore,
            transport: transport
        )
        return try HostedPracticeController(
            tokenStore: tokenStore,
            session: HostedPracticeSession(
                client: client,
                tokenReader: tokenStore,
                identityStore: PrivateLiveIdentityStore(),
                outbox: PrivateLiveOutboxStore(),
                clipStore: PrivateLiveClipStore()
            ),
            eventStream: LiveEventStream(tokenReader: tokenStore),
            tokenValidator: { token in
                let transport = try URLSessionLiveV1Transport()
                let reader = FixedLiveIntegrationTokenReader(token: token)
                let validator = LiveV1Client(
                    tokenReader: reader,
                    transport: transport
                )
                _ = try await validator.today()
            }
        )
    }

    init(
        tokenStore: LiveIntegrationTokenStore,
        session: HostedPracticeSession,
        eventStream: LiveEventStream,
        tokenValidator: @escaping @Sendable (String) async throws -> Void
    ) {
        self.tokenStore = tokenStore
        self.session = session
        self.eventStream = eventStream
        self.tokenValidator = tokenValidator
    }

    deinit {
        eventTask?.cancel()
        renewalTask?.cancel()
        fallbackRefreshTask?.cancel()
        refreshTask?.cancel()
        let eventStream = eventStream
        Task { await eventStream.stop() }
    }

    var canWrite: Bool { snapshot.connection == .writable }
    var hasHostedActivity: Bool { snapshot.activity != nil }

    func open(
        selecting type: LiveActivityType = .systemDesign
    ) async -> HostedPracticeSnapshot {
        let specialty: LiveActivityType = type == .leetcode ? .leetcode : .systemDesign
        tokenReadiness = await tokenStore.readiness()
        guard tokenReadiness == .ready || tokenReadiness == .readyUntilQuit else {
            isConnectionSetupPresented = true
            snapshot = HostedPracticeSnapshot(
                connection: .signedOut,
                boundSpecialty: specialty
            )
            return snapshot
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        snapshot = await session.open(selecting: specialty)
        applyConnectionState()
        if snapshot.activity != nil { startBackgroundRecovery() }
        return snapshot
    }

    func openPreferred() async -> HostedPracticeSnapshot {
        tokenReadiness = await tokenStore.readiness()
        guard tokenReadiness == .ready || tokenReadiness == .readyUntilQuit else {
            isConnectionSetupPresented = true
            snapshot = HostedPracticeSnapshot(connection: .signedOut)
            return snapshot
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        snapshot = await session.openPreferred()
        applyConnectionState()
        if snapshot.activity != nil { startBackgroundRecovery() }
        return snapshot
    }

    func saveToken(_ value: String, untilQuit: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await tokenValidator(value)
            if untilQuit { try await tokenStore.useUntilQuit(value) }
            else { try await tokenStore.saveAndVerify(value) }
            tokenReadiness = await tokenStore.readiness()
            snapshot = await session.open(selecting: snapshot.boundSpecialty)
            applyConnectionState()
            if snapshot.activity != nil { startBackgroundRecovery() }
            if snapshot.connection != .signedOut {
                isConnectionSetupPresented = false
            }
        } catch {
            if (error as? LiveV1ClientError)?.code == "unauthorized" {
                errorMessage = "Interview Arc rejected that personal integration token. Create a new token and try again."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() async {
        if snapshot.lease != nil {
            do {
                try await session.releaseLease()
                snapshot = await session.snapshot()
            } catch {
                snapshot = await session.snapshot()
                errorMessage = "The writer lease could not be released. The token was kept so Disconnect can be retried."
                startBackgroundRecovery()
                return
            }
        }
        stopBackgroundRecovery()
        do {
            try await tokenStore.remove()
            tokenReadiness = await tokenStore.readiness()
            snapshot = HostedPracticeSnapshot(connection: .signedOut)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard !isWorking else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        do {
            snapshot = try await session.refresh()
            errorMessage = nil
            if snapshot.activity != nil { startBackgroundRecovery() }
        } catch {
            snapshot = await session.snapshot()
            errorMessage = error.localizedDescription
            applyConnectionState()
        }
    }

    func startTimer() async throws {
        try await mutate { try await session.start() }
    }

    func pauseTimer() async throws {
        try await mutate { try await session.pause() }
    }

    func setResult(_ result: LiveResult) async throws {
        try await mutate { try await session.setResult(result) }
    }

    func clearResult() async throws {
        try await mutate { try await session.clearResult() }
    }

    func commitPair(
        pairID: String,
        candidate: LiveCandidatePairInput,
        interviewer: LiveInterviewerPairInput,
        clipID: String? = nil
    ) async throws {
        try await mutate {
            try await session.commitPair(
                pairID: pairID,
                candidate: candidate,
                interviewer: interviewer,
                clipID: clipID
            )
        }
    }

    func confirmCandidateEvidence(pairID: String) async throws {
        try await mutate {
            try await session.confirmCandidateEvidence(pairID: pairID)
        }
    }

    func finish() async throws {
        try await mutate { try await session.finish() }
    }

    func finishNext(nextActivityID: String) async throws {
        try await mutate {
            try await session.finishNext(nextActivityID: nextActivityID)
        }
    }

    func prepareForTermination() async -> Bool {
        if snapshot.pendingOperationCount > 0 {
            await session.recoverPendingOperations()
            snapshot = await session.snapshot()
            guard snapshot.pendingOperationCount == 0 else { return false }
        }
        if snapshot.connection == .writable {
            do {
                try await session.releaseLease()
                snapshot = await session.snapshot()
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        stopBackgroundRecovery()
        return true
    }

    private func applyConnectionState() {
        switch snapshot.connection {
        case .signedOut:
            isConnectionSetupPresented = true
            errorMessage = nil
        case .offline:
            errorMessage = "Interview Arc is offline. Local recovery data is retained."
        case .recoveryRequired(let code):
            errorMessage = "Hosted recovery is required before recording (\(code))."
        case .noOpenSystemDesignActivity:
            errorMessage = snapshot.boundSpecialty == .leetcode
                ? "Add a LeetCode activity to Today in Interview Arc."
                : "Add a System Design activity to Today in Interview Arc."
        case .loading, .readOnly, .writable:
            errorMessage = nil
        }
    }

    private func mutate(
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            snapshot = await session.snapshot()
            applyConnectionState()
        } catch {
            snapshot = await session.snapshot()
            applyConnectionState()
            throw error
        }
    }

    private func startBackgroundRecovery() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            let events = await eventStream.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .connected:
                    fallbackRefreshTask?.cancel()
                    await refresh()
                case .disconnected(let retryAfterSeconds):
                    scheduleFallbackRefresh(after: retryAfterSeconds)
                case .invalidation(let invalidation):
                    await session.receive(invalidation)
                    snapshot = await session.snapshot()
                    applyConnectionState()
                }
            }
        }
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard let self else { return }
                await session.tick()
                snapshot = await session.snapshot()
                applyConnectionState()
            }
        }
    }

    private func scheduleFallbackRefresh(after seconds: Int) {
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            await self?.refresh()
        }
    }

    private func stopBackgroundRecovery() {
        eventTask?.cancel()
        eventTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        fallbackRefreshTask?.cancel()
        fallbackRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        Task { await eventStream.stop() }
    }
}

private struct FixedLiveIntegrationTokenReader: LiveIntegrationTokenReading {
    let token: String

    func readIntegrationToken() async throws -> String { token }
    func credentialFingerprint() async throws -> String {
        String(repeating: "0", count: 64)
    }
}
