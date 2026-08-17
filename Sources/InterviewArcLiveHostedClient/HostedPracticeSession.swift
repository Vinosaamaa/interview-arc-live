import Foundation

public protocol LiveClock: Sendable {
    func epochMilliseconds() -> LiveEpochMilliseconds
}

public struct SystemLiveClock: LiveClock {
    public init() {}

    public func epochMilliseconds() -> LiveEpochMilliseconds {
        LiveEpochMilliseconds((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

public enum HostedPracticeConnection: Equatable, Sendable {
    case signedOut
    case loading
    case noOpenSystemDesignActivity
    case readOnly(reason: String)
    case writable
    case offline
    case recoveryRequired(code: String)
}

public struct HostedPracticeSnapshot: Equatable, Sendable {
    public let connection: HostedPracticeConnection
    public let today: LiveTodayProjection?
    public let activity: LiveActivityProjection?
    public let lease: LiveLeaseGrant?
    public let pendingOperationCount: Int
    public let hasQuarantinedOperations: Bool
    public let lastLiveInvalidationRevision: Int
    public let localToServerOffsetMilliseconds: LiveEpochMilliseconds
    public let boundSpecialty: LiveActivityType

    public init(
        connection: HostedPracticeConnection,
        today: LiveTodayProjection? = nil,
        activity: LiveActivityProjection? = nil,
        lease: LiveLeaseGrant? = nil,
        pendingOperationCount: Int = 0,
        hasQuarantinedOperations: Bool = false,
        lastLiveInvalidationRevision: Int = 0,
        localToServerOffsetMilliseconds: LiveEpochMilliseconds = 0,
        boundSpecialty: LiveActivityType = .systemDesign
    ) {
        self.connection = connection
        self.today = today
        self.activity = activity
        self.lease = lease
        self.pendingOperationCount = pendingOperationCount
        self.hasQuarantinedOperations = hasQuarantinedOperations
        self.lastLiveInvalidationRevision = lastLiveInvalidationRevision
        self.localToServerOffsetMilliseconds = localToServerOffsetMilliseconds
        self.boundSpecialty = boundSpecialty
    }

    public var question: String? {
        activity?.activity.prompt ?? activity?.activity.title
    }

    public var activityID: String? { activity?.activity.id }

    public func elapsedSeconds(
        localNow: LiveEpochMilliseconds
    ) -> Double? {
        guard let timer = activity?.activity.timer else { return nil }
        guard !timer.completed, let runningSince = timer.runningSince else {
            return timer.accumulatedSeconds
        }
        let serverNow = localNow + localToServerOffsetMilliseconds
        return timer.accumulatedSeconds
            + Double(max(0, serverNow - runningSince)) / 1_000
    }
}

public enum HostedPracticeSessionError: Error, Equatable, LocalizedError, Sendable {
    case noOpenSystemDesignActivity
    case leaseUnavailable
    case leaseExpired
    case operationAlreadyPending
    case recoveryRequired(String)
    case invalidClip

    public var errorDescription: String? {
        switch self {
        case .noOpenSystemDesignActivity:
            "No open System Design activity is available in Interview Arc Today."
        case .leaseUnavailable:
            "This room is read-only until its hosted writer lease is available."
        case .leaseExpired:
            "The hosted writer lease expired. Refresh before continuing."
        case .operationAlreadyPending:
            "A hosted operation is already awaiting recovery."
        case .recoveryRequired(let code):
            "Hosted recovery is required before continuing (\(code))."
        case .invalidClip:
            "The private clip does not match its declared size or checksum."
        }
    }
}

public actor HostedPracticeSession {
    private let client: LiveV1Client
    private let tokenReader: any LiveIntegrationTokenReading
    private let identityStore: PrivateLiveIdentityStore
    private let outbox: PrivateLiveOutboxStore
    private let clipStore: PrivateLiveClipStore
    private let clock: any LiveClock
    private let holderSessionID: String

    private var installation: LiveInstallationIdentity?
    private var fingerprint: String?
    private var lastRenewedAt: LiveEpochMilliseconds?
    private var boundSpecialty: LiveActivityType = .systemDesign
    private var state = HostedPracticeSnapshot(connection: .signedOut)

    public init(
        client: LiveV1Client,
        tokenReader: any LiveIntegrationTokenReading,
        identityStore: PrivateLiveIdentityStore,
        outbox: PrivateLiveOutboxStore,
        clipStore: PrivateLiveClipStore,
        clock: any LiveClock = SystemLiveClock(),
        holderSessionID: String = UUID().uuidString.lowercased()
    ) {
        self.client = client
        self.tokenReader = tokenReader
        self.identityStore = identityStore
        self.outbox = outbox
        self.clipStore = clipStore
        self.clock = clock
        self.holderSessionID = holderSessionID
    }

    public func snapshot() -> HostedPracticeSnapshot { state }

    public func readToday() async throws -> LiveTodayProjection {
        try await client.today()
    }

    @discardableResult
    public func openPreferred(
        acquireWriterLease: Bool = true
    ) async -> HostedPracticeSnapshot {
        do {
            let today = try await client.today()
            boundSpecialty = Self.liveRoomSpecialty(
                today.selectedLiveWorkSurface ?? .systemDesign
            )
        } catch LiveIntegrationTokenStoreError.missingToken {
            boundSpecialty = .systemDesign
        } catch {
            boundSpecialty = .systemDesign
        }
        return await open(
            acquireWriterLease: acquireWriterLease,
            selecting: boundSpecialty
        )
    }

    @discardableResult
    public func open(
        acquireWriterLease: Bool = true,
        selecting type: LiveActivityType = .systemDesign
    ) async -> HostedPracticeSnapshot {
        boundSpecialty = Self.liveRoomSpecialty(type)
        state = copy(connection: .loading)
        do {
            let fingerprint = try await tokenReader.credentialFingerprint()
            let installation = try await identityStore.loadOrCreate()
            self.fingerprint = fingerprint
            self.installation = installation

            let pending = try await outbox.records(
                credentialFingerprint: fingerprint
            )
            let quarantined = try await outbox.hasQuarantinedPartitions(
                excluding: fingerprint
            )
            var authority = try await readAuthority()
            state = HostedPracticeSnapshot(
                connection: .loading,
                today: authority.today,
                activity: authority.activity,
                pendingOperationCount: pending.count,
                hasQuarantinedOperations: quarantined,
                localToServerOffsetMilliseconds: authority.serverTime
                    - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )

            guard !quarantined else {
                state = copy(
                    connection: .recoveryRequired(code: "credential_changed")
                )
                return state
            }
            if !pending.isEmpty {
                state = copy(
                    connection: .recoveryRequired(code: "pending_operation"),
                    pendingOperationCount: pending.count
                )
                await recoverPendingOperations()
                if case .recoveryRequired = state.connection { return state }
                authority = try await readAuthority()
            }

            guard let activity = authority.activity else {
                state = HostedPracticeSnapshot(
                    connection: .noOpenSystemDesignActivity,
                    today: authority.today,
                    pendingOperationCount: 0,
                    hasQuarantinedOperations: quarantined,
                    localToServerOffsetMilliseconds:
                        authority.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
                return state
            }
            state = HostedPracticeSnapshot(
                connection: .readOnly(reason: "Acquiring writer lease"),
                today: authority.today,
                activity: activity,
                pendingOperationCount: 0,
                hasQuarantinedOperations: quarantined,
                localToServerOffsetMilliseconds:
                    activity.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
            if acquireWriterLease && (
                activity.activity.lifecycle == .planned
                    || activity.activity.lifecycle == .running
            ) {
                try await acquireLease()
            }
        } catch LiveIntegrationTokenStoreError.missingToken {
            state = copy(connection: .signedOut)
        } catch let error as LiveV1ClientError {
            apply(error)
        } catch {
            state = copy(connection: .offline)
        }
        return state
    }

    @discardableResult
    public func refresh() async throws -> HostedPracticeSnapshot {
        let previousActivityID = state.activityID
        var authority = try await readAuthority()
        guard !state.hasQuarantinedOperations else {
            state = HostedPracticeSnapshot(
                connection: .recoveryRequired(code: "credential_changed"),
                today: authority.today,
                activity: authority.activity,
                pendingOperationCount: try await pendingCount(),
                hasQuarantinedOperations: true,
                lastLiveInvalidationRevision: state.lastLiveInvalidationRevision,
                localToServerOffsetMilliseconds:
                    authority.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
            throw HostedPracticeSessionError.recoveryRequired(
                "credential_changed"
            )
        }
        if try await recoverPendingOperationsAfterAuthorityRead() {
            authority = try await readAuthority()
        }

        guard let selectedID = authority.today.selectedOpenActivity(
            of: boundSpecialty
        )?.id,
              let activity = authority.activity else {
            if state.lease != nil { try await releaseLease() }
            state = HostedPracticeSnapshot(
                connection: .noOpenSystemDesignActivity,
                today: authority.today,
                hasQuarantinedOperations: state.hasQuarantinedOperations,
                localToServerOffsetMilliseconds:
                    authority.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
            return state
        }

        let selectionChanged = previousActivityID != selectedID
        if selectionChanged, state.lease != nil {
            try await releaseLease()
        }

        if selectionChanged {
            state = HostedPracticeSnapshot(
                connection: .readOnly(reason: "Acquiring selected activity writer lease"),
                today: authority.today,
                activity: activity,
                pendingOperationCount: try await pendingCount(),
                hasQuarantinedOperations: state.hasQuarantinedOperations,
                lastLiveInvalidationRevision: state.lastLiveInvalidationRevision,
                localToServerOffsetMilliseconds:
                    activity.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
            if activity.activity.lifecycle == .planned
                || activity.activity.lifecycle == .running {
                try await acquireLease()
            }
            return state
        }

        let writable = leaseIsCurrent(in: activity)
        state = HostedPracticeSnapshot(
            connection: writable
                ? .writable
                : .readOnly(reason: "Writer lease required"),
            today: authority.today,
            activity: activity,
            lease: writable ? state.lease : nil,
            pendingOperationCount: try await pendingCount(),
            hasQuarantinedOperations: state.hasQuarantinedOperations,
            lastLiveInvalidationRevision: state.lastLiveInvalidationRevision,
            localToServerOffsetMilliseconds:
                activity.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
        return state
    }

    public func receive(_ invalidation: LiveInvalidation) async {
        guard invalidation.isLivePracticeChange,
              invalidation.revision > state.lastLiveInvalidationRevision else {
            return
        }
        state = copy(lastLiveInvalidationRevision: invalidation.revision)
        do { _ = try await refresh() }
        catch let error as LiveV1ClientError { apply(error) }
        catch { state = copy(connection: .offline) }
    }

    public func tick() async {
        guard case .writable = state.connection,
              let lease = state.lease else { return }
        let now = clock.epochMilliseconds()
        if now >= lease.expiresAt {
            state = copy(
                connection: .recoveryRequired(code: "lease_expired"),
                clearLease: true
            )
            return
        }
        if lastRenewedAt.map({ now - $0 >= 30_000 }) ?? true {
            do { try await renewLease() }
            catch { /* state is updated by perform */ }
        }
    }

    public func acquireLease() async throws {
        guard let installation,
              let activity = state.activity,
              let fingerprint else {
            throw HostedPracticeSessionError.noOpenSystemDesignActivity
        }
        let body = AcquireLeaseBody(
            operationId: operationID("lease-acquire"),
            holderId: installation.holderId,
            holderSessionId: holderSessionID
        )
        let response = try await perform(
            operation: "lease.acquire",
            pathSuffix: "lease/acquire",
            activity: activity,
            fencingToken: nil,
            body: body,
            fingerprint: fingerprint
        )
        guard let lease = response.lease else {
            throw LiveV1ClientError.malformedResponse
        }
        lastRenewedAt = clock.epochMilliseconds()
        state = HostedPracticeSnapshot(
            connection: .writable,
            today: state.today,
            activity: response.activity,
            lease: lease,
            pendingOperationCount: try await pendingCount(),
            hasQuarantinedOperations: state.hasQuarantinedOperations,
            lastLiveInvalidationRevision: state.lastLiveInvalidationRevision,
            localToServerOffsetMilliseconds:
                response.activity.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
    }

    public func renewLease() async throws {
        let response = try await fencedMutation(
            operation: "lease.renew",
            pathSuffix: "lease/renew"
        ) { operationID, holderID, sessionID, fence in
            FencedLeaseBody(
                operationId: operationID,
                holderId: holderID,
                holderSessionId: sessionID,
                fencingToken: fence
            )
        }
        guard let lease = response.lease else {
            throw LiveV1ClientError.malformedResponse
        }
        lastRenewedAt = clock.epochMilliseconds()
        state = copy(
            connection: .writable,
            activity: response.activity,
            lease: lease
        )
    }

    public func releaseLease() async throws {
        let pending = try await pendingCount()
        guard pending == 0 else {
            state = copy(
                connection: .recoveryRequired(code: "pending_operation"),
                pendingOperationCount: pending
            )
            throw HostedPracticeSessionError.operationAlreadyPending
        }
        _ = try await fencedMutation(
            operation: "lease.release",
            pathSuffix: "lease/release"
        ) { operationID, holderID, sessionID, fence in
            FencedLeaseBody(
                operationId: operationID,
                holderId: holderID,
                holderSessionId: sessionID,
                fencingToken: fence
            )
        }
        state = copy(
            connection: .readOnly(reason: "Writer lease released"),
            clearLease: true
        )
    }

    public func commitPair(
        pairID: String,
        candidate: LiveCandidatePairInput,
        interviewer: LiveInterviewerPairInput,
        clipID: String? = nil
    ) async throws {
        let response = try await fencedMutation(
            operation: "turn_pair.commit",
            pathSuffix: "turn-pairs"
        ) { operationID, holderID, sessionID, fence in
            CommitPairBody(
                operationId: operationID,
                holderId: holderID,
                holderSessionId: sessionID,
                fencingToken: fence,
                pairId: pairID,
                candidate: candidate,
                interviewer: interviewer,
                clipId: clipID
            )
        }
        apply(response)
    }

    public func stageClip(
        clipID: String,
        candidateTurnID: String,
        mimeType: String,
        byteSize: Int,
        sha256: String
    ) async throws {
        let response = try await fencedMutation(
            operation: "clip.stage",
            pathSuffix: "clips/stage"
        ) { operationID, holderID, sessionID, fence in
            StageClipBody(
                operationId: operationID,
                holderId: holderID,
                holderSessionId: sessionID,
                fencingToken: fence,
                clipId: clipID,
                candidateTurnId: candidateTurnID,
                mimeType: mimeType,
                byteSize: byteSize,
                sha256: sha256
            )
        }
        apply(response)
    }

    public func stageAndUploadClip(
        clipID: String,
        candidateTurnID: String,
        mimeType: String,
        data: Data
    ) async throws {
        let intent = try await clipStore.persist(
            clipID: clipID,
            candidateTurnID: candidateTurnID,
            mimeType: mimeType,
            data: data
        )
        try await stageClip(
            clipID: clipID,
            candidateTurnID: candidateTurnID,
            mimeType: mimeType,
            byteSize: intent.byteSize,
            sha256: intent.sha256
        )
        try await uploadClip(intent, content: data)
    }

    public func start() async throws { _ = try await command(.start) }
    public func pause() async throws { _ = try await command(.pause) }
    public func clearResult() async throws { _ = try await command(.clearResult) }
    public func finish() async throws { _ = try await command(.finish) }

    public func setResult(_ result: LiveResult) async throws {
        _ = try await command(.setResult, result: result)
    }

    public func confirmCandidateEvidence(pairID: String) async throws {
        _ = try await command(.confirmCandidateEvidence, pairID: pairID)
    }

    public func finishNext(nextActivityID: String) async throws {
        let response = try await command(
            .finishNext,
            nextActivityID: nextActivityID
        )
        guard let selectedNextActivityID = response.selectedNextActivityId else {
            throw LiveV1ClientError.malformedResponse
        }

        // Finish-next is one atomic server command, but the client must then
        // re-read the selected activity and acquire its own fresh writer
        // fence. Never carry the completed activity's lease forward.
        let today = try await client.today()
        let activity = try await client.activity(selectedNextActivityID)
        state = HostedPracticeSnapshot(
            connection: .readOnly(reason: "Acquiring next activity writer lease"),
            today: today,
            activity: activity,
            pendingOperationCount: try await pendingCount(),
            hasQuarantinedOperations: state.hasQuarantinedOperations,
            lastLiveInvalidationRevision: state.lastLiveInvalidationRevision,
            localToServerOffsetMilliseconds:
                activity.serverTime - clock.epochMilliseconds(),
                    boundSpecialty: boundSpecialty
                )
        try await acquireLease()
    }

    public func recoverPendingOperations() async {
        guard let fingerprint else { return }
        do {
            let records = try await outbox.records(
                credentialFingerprint: fingerprint
            )
            for record in records {
                guard try await recover(
                    record,
                    credentialFingerprint: fingerprint
                ) else { return }
            }
            state = copy(
                connection: .loading,
                pendingOperationCount: 0
            )
        } catch {
            state = copy(connection: .recoveryRequired(code: "outbox_unavailable"))
        }
    }

    private func recoverPendingOperationsAfterAuthorityRead() async throws -> Bool {
        let pending = try await pendingCount()
        guard pending > 0 else { return false }

        state = copy(
            connection: .recoveryRequired(code: "pending_operation"),
            pendingOperationCount: pending
        )
        await recoverPendingOperations()

        let remaining = try await pendingCount()
        guard remaining == 0 else {
            throw HostedPracticeSessionError.operationAlreadyPending
        }
        return true
    }

    private func readAuthority() async throws -> HostedAuthorityRead {
        let today = try await client.today()
        guard let selectedID = today.selectedOpenActivity(of: boundSpecialty)?.id else {
            return HostedAuthorityRead(today: today, activity: nil)
        }
        return HostedAuthorityRead(
            today: today,
            activity: try await client.activity(selectedID)
        )
    }

    private static func liveRoomSpecialty(
        _ type: LiveActivityType
    ) -> LiveActivityType {
        type == .leetcode ? .leetcode : .systemDesign
    }

    private func recover(
        _ record: LiveOutboxRecord,
        credentialFingerprint: String
    ) async throws -> Bool {
        do {
            _ = try await client.receipt(
                activityID: record.activityId,
                operationID: record.operationId
            )
            try await outbox.mark(
                operationID: record.operationId,
                credentialFingerprint: credentialFingerprint,
                phase: .receiptConfirmed
            )
            try await outbox.remove(
                operationID: record.operationId,
                credentialFingerprint: credentialFingerprint
            )
            applyRecoveredReceipt(record)
            return true
        } catch let error as LiveV1ClientError {
            guard error.code == "receipt_not_found" else {
                if error.code == "unauthorized" {
                    state = copy(connection: .signedOut)
                } else {
                    try await markRecovery(record, error: error)
                }
                return false
            }
        }

        guard record.holderSessionId == holderSessionID else {
            try await markRecovery(
                record,
                error: LiveV1ClientError.server(
                    statusCode: 404,
                    code: "receipt_not_found",
                    retryable: false
                )
            )
            return false
        }
        do {
            if record.method == .put {
                try await replayClipUpload(record)
            } else {
                let response = try await client.mutation(
                    activityID: record.activityId,
                    suffix: record.pathSuffix,
                    canonicalBody: record.canonicalBody
                )
                apply(response)
                applyRecoveredReceipt(record)
            }
            try await outbox.remove(
                operationID: record.operationId,
                credentialFingerprint: credentialFingerprint
            )
            return true
        } catch {
            try await markRecovery(record, error: error)
            return false
        }
    }

    private func command(
        _ command: LiveCommand,
        result: LiveResult? = nil,
        pairID: String? = nil,
        nextActivityID: String? = nil
    ) async throws -> LiveMutationResponse {
        guard let activity = state.activity else {
            throw HostedPracticeSessionError.noOpenSystemDesignActivity
        }
        let response = try await fencedMutation(
            operation: "command.\(command.rawValue)",
            pathSuffix: "commands"
        ) { operationID, holderID, sessionID, fence in
            CommandBody(
                operationId: operationID,
                holderId: holderID,
                holderSessionId: sessionID,
                fencingToken: fence,
                command: command,
                expectedWorkbenchRevision: activity.workbench.revision,
                expectedTimerRevision: Self.timerRevision(for: command, activity: activity),
                expectedResultRevision: Self.resultRevision(for: command, activity: activity),
                result: result,
                pairId: pairID,
                nextActivityId: nextActivityID,
                expectedNextTimerRevision: Self.nextTimerRevision(
                    command: command,
                    nextActivityID: nextActivityID,
                    today: state.today
                )
            )
        }
        apply(response)
        if command == .finish || command == .finishNext {
            state = copy(
                connection: .readOnly(reason: "Hosted activity finished"),
                clearLease: true
            )
        }
        return response
    }

    private func uploadClip(
        _ intent: PrivateLiveClipIntent,
        content suppliedContent: Data? = nil
    ) async throws {
        guard let activity = state.activity,
              let installation,
              let fingerprint,
              let lease = state.lease,
              lease.expiresAt > estimatedServerNow else {
            throw HostedPracticeSessionError.leaseUnavailable
        }
        let content: Data
        if let suppliedContent {
            content = try await clipStore.verify(intent, content: suppliedContent)
        } else {
            content = try await clipStore.verify(intent)
        }
        let operationID = operationID("clips-upload")
        let headers = [
            "Content-Type": intent.mimeType,
            "Content-Length": String(intent.byteSize),
            "X-Content-SHA256": intent.sha256,
            "X-Live-Operation-Id": operationID,
            "X-Live-Holder-Id": installation.holderId,
            "X-Live-Holder-Session-Id": holderSessionID,
            "X-Live-Fencing-Token": String(lease.fencingToken),
        ]
        let metadata = ClipUploadOutboxBody(
            operationId: operationID,
            clipId: intent.clipId,
            candidateTurnId: intent.candidateTurnId,
            byteSize: intent.byteSize,
            sha256: intent.sha256,
            mimeType: intent.mimeType,
            holderId: installation.holderId,
            holderSessionId: holderSessionID,
            fencingToken: lease.fencingToken
        )
        let canonicalBody = try client.canonicalData(metadata)
        let record = LiveOutboxRecord(
            operationId: operationID,
            operation: "clip.upload",
            method: .put,
            pathSuffix: "clips/\(intent.clipId)/content",
            activityId: activity.activity.id,
            workbenchId: activity.workbench.id,
            holderId: installation.holderId,
            holderSessionId: holderSessionID,
            fencingToken: lease.fencingToken,
            dependencyOperationId: try await outboxSummary().latestOperationID,
            canonicalBody: canonicalBody,
            localContentReference: intent.contentReference,
            uploadHeaders: headers,
            credentialFingerprint: fingerprint,
            createdAt: clock.epochMilliseconds()
        )
        try await outbox.prepare(record)
        state = copy(pendingOperationCount: try await pendingCount())
        do {
            let response = try await client.uploadClip(
                activityID: activity.activity.id,
                clipID: intent.clipId,
                body: content,
                headers: headers
            )
            try await outbox.remove(
                operationID: operationID,
                credentialFingerprint: fingerprint
            )
            if response.clip?.status == .available
                || response.activity.clips.contains(where: {
                    $0.clipId == intent.clipId && $0.status == .available
                }) {
                try await clipStore.remove(intent)
            }
            apply(response)
        } catch let error as LiveV1ClientError {
            let phase: LiveOutboxPhase = error == .transportUnavailable
                ? .ambiguous
                : .recoveryRequired
            try await outbox.mark(
                operationID: operationID,
                credentialFingerprint: fingerprint,
                phase: phase,
                lastSafeErrorCode: error.code ?? "transport_unavailable"
            )
            if error.code == "unauthorized" {
                state = copy(connection: .signedOut)
            } else if error == .transportUnavailable {
                state = copy(connection: .offline)
            } else if Self.isDefinitiveNoMutation(error) {
                try await outbox.remove(
                    operationID: operationID,
                    credentialFingerprint: fingerprint
                )
                state = copy(
                    connection: error.code == "lease_held"
                        ? .readOnly(reason: "Another writer holds this activity")
                        : state.connection,
                    pendingOperationCount: try await pendingCount()
                )
            } else {
                state = copy(
                    connection: .recoveryRequired(
                        code: error.code ?? "clip_upload"
                    )
                )
            }
            throw error
        }
    }

    private func replayClipUpload(_ record: LiveOutboxRecord) async throws {
        guard let reference = record.localContentReference,
              let headers = record.uploadHeaders,
              record.pathSuffix.hasPrefix("clips/"),
              record.pathSuffix.hasSuffix("/content") else {
            throw HostedPracticeSessionError.recoveryRequired(
                "clip_recovery_metadata"
            )
        }
        let clipID = String(
            record.pathSuffix
                .dropFirst("clips/".count)
                .dropLast("/content".count)
        )
        let content = try await clipStore.loadContent(reference: reference)
        let response = try await client.uploadClip(
            activityID: record.activityId,
            clipID: clipID,
            body: content,
            headers: headers
        )
        if response.clip?.status == .available,
           let intent = try await clipStore.loadIntent(clipID: clipID) {
            try await clipStore.remove(intent)
        }
        apply(response)
    }

    private func fencedMutation<Body: Encodable & Sendable>(
        operation: String,
        pathSuffix: String,
        makeBody: (
            _ operationID: String,
            _ holderID: String,
            _ holderSessionID: String,
            _ fencingToken: Int
        ) -> Body
    ) async throws -> LiveMutationResponse {
        guard let activity = state.activity,
              let installation,
              let fingerprint,
              let lease = state.lease else {
            throw HostedPracticeSessionError.leaseUnavailable
        }
        guard lease.expiresAt > estimatedServerNow else {
            state = copy(
                connection: .recoveryRequired(code: "lease_expired"),
                clearLease: true
            )
            throw HostedPracticeSessionError.leaseExpired
        }
        let body = makeBody(
            operationID(operation),
            installation.holderId,
            holderSessionID,
            lease.fencingToken
        )
        return try await perform(
            operation: operation,
            pathSuffix: pathSuffix,
            activity: activity,
            fencingToken: lease.fencingToken,
            body: body,
            fingerprint: fingerprint
        )
    }

    private func perform<Body: Encodable & Sendable>(
        operation: String,
        pathSuffix: String,
        activity: LiveActivityProjection,
        fencingToken: Int?,
        body: Body,
        fingerprint: String
    ) async throws -> LiveMutationResponse {
        let canonicalBody = try client.canonicalData(body)
        let operationID = try Self.operationID(in: canonicalBody)
        let record = LiveOutboxRecord(
            operationId: operationID,
            operation: operation,
            pathSuffix: pathSuffix,
            activityId: activity.activity.id,
            workbenchId: activity.workbench.id,
            holderId: installation?.holderId ?? "",
            holderSessionId: holderSessionID,
            fencingToken: fencingToken,
            dependencyOperationId: try await outboxSummary().latestOperationID,
            canonicalBody: canonicalBody,
            credentialFingerprint: fingerprint,
            createdAt: clock.epochMilliseconds()
        )
        try await outbox.prepare(record)
        state = copy(pendingOperationCount: try await pendingCount())

        do {
            let response = try await client.mutation(
                activityID: activity.activity.id,
                suffix: pathSuffix,
                canonicalBody: canonicalBody
            )
            guard response.receipt.operationId == operationID,
                  response.receipt.operation == operation else {
                throw LiveV1ClientError.malformedResponse
            }
            try await outbox.mark(
                operationID: operationID,
                credentialFingerprint: fingerprint,
                phase: .receiptConfirmed
            )
            try await outbox.remove(
                operationID: operationID,
                credentialFingerprint: fingerprint
            )
            state = copy(pendingOperationCount: try await pendingCount())
            return response
        } catch let error as LiveV1ClientError {
            if error == .transportUnavailable {
                try await outbox.mark(
                    operationID: operationID,
                    credentialFingerprint: fingerprint,
                    phase: .ambiguous,
                    lastSafeErrorCode: "transport_unavailable"
                )
                state = copy(
                    connection: .offline,
                    pendingOperationCount: try await pendingCount()
                )
            } else if error.code == "unauthorized" {
                try await outbox.mark(
                    operationID: operationID,
                    credentialFingerprint: fingerprint,
                    phase: .ambiguous,
                    lastSafeErrorCode: "unauthorized"
                )
                state = copy(connection: .signedOut)
            } else if Self.isDefinitiveNoMutation(error) {
                try await outbox.remove(
                    operationID: operationID,
                    credentialFingerprint: fingerprint
                )
                state = copy(
                    connection: error.code == "lease_held"
                        ? .readOnly(reason: "Another writer holds this activity")
                        : state.connection,
                    clearLease: error.code == "lease_held",
                    pendingOperationCount: try await pendingCount()
                )
            } else {
                try await outbox.mark(
                    operationID: operationID,
                    credentialFingerprint: fingerprint,
                    phase: .recoveryRequired,
                    lastSafeErrorCode: error.code
                )
                state = copy(
                    connection: .recoveryRequired(
                        code: error.code ?? "hosted_rejection"
                    ),
                    pendingOperationCount: try await pendingCount()
                )
            }
            throw error
        }
    }

    private func apply(_ response: LiveMutationResponse) {
        state = copy(
            connection: state.lease == nil
                ? .readOnly(reason: "Writer lease required")
                : .writable,
            today: response.today,
            activity: response.activity,
            localToServerOffsetMilliseconds:
                response.activity.serverTime - clock.epochMilliseconds()
        )
    }

    private func apply(_ error: LiveV1ClientError) {
        if error.code == "unauthorized" {
            state = copy(connection: .signedOut)
        } else if error == .transportUnavailable {
            state = copy(connection: .offline)
        } else if error.code == "lease_held" {
            state = copy(
                connection: .readOnly(reason: "Another writer holds this activity"),
                clearLease: true
            )
        } else {
            state = copy(
                connection: .recoveryRequired(
                    code: error.code ?? "hosted_response"
                )
            )
        }
    }

    /// These server gates are explicit, non-retryable rejections: the server
    /// promises no mutation and therefore there is no ambiguous receipt to
    /// recover. Conflict/fence errors deliberately remain in recovery.
    private static func isDefinitiveNoMutation(_ error: LiveV1ClientError) -> Bool {
        guard !error.retryable, let code = error.code else { return false }
        return [
            "lease_held",
            "candidate_evidence_required",
            "result_required",
            "no_next_activity",
            "next_activity_unavailable",
            "timer_completed",
            "timer_not_running",
            "timer_not_finishable",
            "session_completed",
            "voice_delivery_blocked",
        ].contains(code)
    }

    private func markRecovery(
        _ record: LiveOutboxRecord,
        error: Error
    ) async throws {
        let code = (error as? LiveV1ClientError)?.code ?? "ambiguous_operation"
        guard let fingerprint else { return }
        try await outbox.mark(
            operationID: record.operationId,
            credentialFingerprint: fingerprint,
            phase: .recoveryRequired,
            lastSafeErrorCode: code
        )
        state = copy(
            connection: .recoveryRequired(code: code),
            pendingOperationCount: try await pendingCount()
        )
    }

    private var estimatedServerNow: LiveEpochMilliseconds {
        clock.epochMilliseconds() + state.localToServerOffsetMilliseconds
    }

    private func leaseIsCurrent(in activity: LiveActivityProjection) -> Bool {
        guard let lease = state.lease else { return false }
        return lease.holderSessionId == holderSessionID
            && lease.expiresAt > activity.serverTime
            && activity.lease.active
            && activity.lease.holderPresent
            && activity.lease.expiresAt == lease.expiresAt
    }

    private func applyRecoveredReceipt(_ record: LiveOutboxRecord) {
        guard record.operation == "lease.release"
                || record.operation == "command.finish"
                || record.operation == "command.finish-next" else { return }
        state = copy(
            connection: .readOnly(reason: "Hosted activity finished or released"),
            clearLease: true
        )
    }

    private func operationID(_ prefix: String) -> String {
        "live-\(prefix)-\(UUID().uuidString.lowercased())"
    }

    private static func operationID(in body: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let operationID = object["operationId"] as? String else {
            throw LiveV1ClientError.invalidConfiguration
        }
        return operationID
    }

    private func pendingCount() async throws -> Int {
        try await outboxSummary().count
    }

    private func outboxSummary() async throws -> LiveOutboxSummary {
        guard let fingerprint else {
            return LiveOutboxSummary(count: 0, latestOperationID: nil)
        }
        return try await outbox.summary(
            credentialFingerprint: fingerprint
        )
    }

    private static func timerRevision(
        for command: LiveCommand,
        activity: LiveActivityProjection
    ) -> Int? {
        switch command {
        case .start, .pause, .finish, .finishNext:
            activity.activity.timer?.revision ?? 0
        default:
            nil
        }
    }

    private static func resultRevision(
        for command: LiveCommand,
        activity: LiveActivityProjection
    ) -> Int? {
        switch command {
        case .setResult, .clearResult, .finish, .finishNext:
            activity.activity.result.revision
        default:
            nil
        }
    }

    private static func nextTimerRevision(
        command: LiveCommand,
        nextActivityID: String?,
        today: LiveTodayProjection?
    ) -> Int? {
        guard command == .finishNext,
              let nextActivityID else { return nil }
        return today?.activities.first(where: { $0.id == nextActivityID })?
            .timer?.revision ?? 0
    }

    private func copy(
        connection: HostedPracticeConnection? = nil,
        today: LiveTodayProjection? = nil,
        activity: LiveActivityProjection? = nil,
        lease: LiveLeaseGrant? = nil,
        clearLease: Bool = false,
        pendingOperationCount: Int? = nil,
        hasQuarantinedOperations: Bool? = nil,
        lastLiveInvalidationRevision: Int? = nil,
        localToServerOffsetMilliseconds: LiveEpochMilliseconds? = nil
    ) -> HostedPracticeSnapshot {
        HostedPracticeSnapshot(
            connection: connection ?? state.connection,
            today: today ?? state.today,
            activity: activity ?? state.activity,
            lease: clearLease ? nil : (lease ?? state.lease),
            pendingOperationCount: pendingOperationCount
                ?? state.pendingOperationCount,
            hasQuarantinedOperations: hasQuarantinedOperations
                ?? state.hasQuarantinedOperations,
            lastLiveInvalidationRevision: lastLiveInvalidationRevision
                ?? state.lastLiveInvalidationRevision,
            localToServerOffsetMilliseconds: localToServerOffsetMilliseconds
                ?? state.localToServerOffsetMilliseconds,
                    boundSpecialty: boundSpecialty
                )
    }
}

private struct HostedAuthorityRead {
    let today: LiveTodayProjection
    let activity: LiveActivityProjection?

    var serverTime: LiveEpochMilliseconds {
        activity?.serverTime ?? today.serverTime
    }
}

private struct AcquireLeaseBody: Codable, Sendable {
    let operationId: String
    let holderId: String
    let holderSessionId: String
}

private struct FencedLeaseBody: Codable, Sendable {
    let operationId: String
    let holderId: String
    let holderSessionId: String
    let fencingToken: Int
}

private struct CommitPairBody: Codable, Sendable {
    let operationId: String
    let holderId: String
    let holderSessionId: String
    let fencingToken: Int
    let pairId: String
    let candidate: LiveCandidatePairInput
    let interviewer: LiveInterviewerPairInput
    let clipId: String?
}

private struct StageClipBody: Codable, Sendable {
    let operationId: String
    let holderId: String
    let holderSessionId: String
    let fencingToken: Int
    let clipId: String
    let candidateTurnId: String
    let mimeType: String
    let byteSize: Int
    let sha256: String
}

private struct CommandBody: Codable, Sendable {
    let operationId: String
    let holderId: String
    let holderSessionId: String
    let fencingToken: Int
    let command: LiveCommand
    let expectedWorkbenchRevision: Int
    let expectedTimerRevision: Int?
    let expectedResultRevision: Int?
    let result: LiveResult?
    let pairId: String?
    let nextActivityId: String?
    let expectedNextTimerRevision: Int?
}

private struct ClipUploadOutboxBody: Codable, Sendable {
    let operationId: String
    let clipId: String
    let candidateTurnId: String
    let byteSize: Int
    let sha256: String
    let mimeType: String
    let holderId: String
    let holderSessionId: String
    let fencingToken: Int
}
