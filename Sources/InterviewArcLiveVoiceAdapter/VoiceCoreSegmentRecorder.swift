import Foundation
import InterviewArcLiveCore
import InterviewArcVoiceCore

public enum VoiceCoreSegmentRecorderError: Error, Equatable, Sendable {
    case captureAlreadyActive
    case noActiveCapture
    case reservedDestinationAlreadyExists
    case authoritativeCaptureOutsideSessionRoot
    case invalidAuthoritativeAudioIdentity
    case sourceAudioUnavailable
}

@MainActor
public final class VoiceCoreSegmentRecorder: SegmentRecording {
    private struct ActiveCapture {
        let request: SegmentCaptureRequest
        let requestedURL: URL
        var startedAt: Date?
    }

    private struct RecoveryCandidate {
        let url: URL
        let identity: SegmentAudioIdentity
        let evidence: RecordingIntegrityEvidence
        let isRecoveredFile: Bool
        let modifiedAt: Date
    }

    private let driver: any VoiceCoreRecordingDriving
    private let paths: LiveVoicePaths
    private let fileManager: FileManager
    private let now: @MainActor () -> Date
    private let inspect: (RecordedCapture) throws -> RecordingIntegrityEvidence

    private var activeCapture: ActiveCapture?
    private var unexpectedTerminationHandler: (@MainActor @Sendable () -> Void)?
    private var didReportUnexpectedTermination = false

    public var onMetering: (@MainActor (VoiceCoreRecordingMetering) -> Void)? {
        get { driver.onMetering }
        set { driver.onMetering = newValue }
    }

    public convenience init() {
        self.init(
            driver: AnswerRecorderDriver(),
            paths: LiveVoicePaths(),
            fileManager: .default,
            now: Date.init,
            inspect: RecordingFileInspector.inspect
        )
    }

    public convenience init(acousticSegmenter: VoiceCoreAcousticSegmenter) {
        self.init(
            driver: acousticSegmenter,
            paths: LiveVoicePaths(),
            fileManager: .default,
            now: Date.init,
            inspect: RecordingFileInspector.inspect
        )
    }

    init(
        driver: any VoiceCoreRecordingDriving,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping @MainActor () -> Date = Date.init,
        inspect: @escaping (RecordedCapture) throws -> RecordingIntegrityEvidence
    ) {
        self.driver = driver
        paths = LiveVoicePaths(applicationSupportRoot: applicationSupportRoot)
        self.fileManager = fileManager
        self.now = now
        self.inspect = inspect
        installDriverTerminationBridge()
    }

    private init(
        driver: any VoiceCoreRecordingDriving,
        paths: LiveVoicePaths,
        fileManager: FileManager,
        now: @escaping @MainActor () -> Date,
        inspect: @escaping (RecordedCapture) throws -> RecordingIntegrityEvidence
    ) {
        self.driver = driver
        self.paths = paths
        self.fileManager = fileManager
        self.now = now
        self.inspect = inspect
        installDriverTerminationBridge()
    }

    public func setUnexpectedTerminationHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        unexpectedTerminationHandler = handler
    }

    public func beginCapture(_ request: SegmentCaptureRequest) async throws {
        guard activeCapture == nil else {
            throw VoiceCoreSegmentRecorderError.captureAlreadyActive
        }

        let destinationURL = try paths.audioURL(
            sessionID: request.sessionID,
            identity: request.reservedAudioIdentity,
            createParentDirectory: true,
            fileManager: fileManager
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw VoiceCoreSegmentRecorderError.reservedDestinationAlreadyExists
        }

        activeCapture = ActiveCapture(
            request: request,
            requestedURL: destinationURL,
            startedAt: nil
        )
        didReportUnexpectedTermination = false
        do {
            try await driver.start(at: destinationURL) { [weak self] in
                guard let self else { return }
                self.activeCapture?.startedAt = self.now()
            }
            if activeCapture?.startedAt == nil {
                activeCapture?.startedAt = now()
            }
        } catch {
            activeCapture = nil
            throw error
        }
    }

    public func finishCapture() async throws -> CapturedAudioSegment {
        guard let activeCapture else {
            throw VoiceCoreSegmentRecorderError.noActiveCapture
        }

        let recorded = try driver.stop()
        let endedAt = now()
        // Once VoiceCore has finalized, this Adapter must never call stop on
        // that capture again. Any later adoption/inspection error is surfaced
        // while the source file remains privately preserved, and a fresh
        // reservation can start another capture.
        self.activeCapture = nil
        didReportUnexpectedTermination = false
        do {
            try paths.validateAuthoritativeCapture(
                at: recorded.url,
                for: activeCapture.request.sessionID,
                fileManager: fileManager
            )
        } catch LiveVoicePathError.authoritativeCaptureOutsideSessionRoot {
            throw VoiceCoreSegmentRecorderError.authoritativeCaptureOutsideSessionRoot
        } catch {
            throw VoiceCoreSegmentRecorderError.sourceAudioUnavailable
        }

        let authoritativeIdentity = try adoptIdentity(
            for: recorded.url,
            sessionID: activeCapture.request.sessionID
        )
        let authoritativeURL = try paths.audioURL(
            sessionID: activeCapture.request.sessionID,
            identity: authoritativeIdentity,
            createParentDirectory: false,
            fileManager: fileManager
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: authoritativeURL.path
        )

        let evidence = inspectedEvidence(for: recorded, at: authoritativeURL)
        let integrity = RecordingIntegrityEvaluator.evaluate(evidence)
        let isPlayable = evidence.fileSizeBytes >= 512
            && evidence.decodedFrameCount > 0
            && evidence.decodedDurationSeconds > 0
        let audioStartedAt = endedAt.addingTimeInterval(-max(0, recorded.duration))
        let startedAt = min(activeCapture.startedAt ?? audioStartedAt, audioStartedAt)

        return CapturedAudioSegment(
            audioIdentity: authoritativeIdentity,
            startedAtMilliseconds: Self.milliseconds(since1970: startedAt),
            endedAtMilliseconds: Self.milliseconds(since1970: endedAt),
            durationMilliseconds: Self.milliseconds(recorded.duration),
            decodedDurationMilliseconds: Self.milliseconds(
                evidence.decodedDurationSeconds
            ),
            byteCount: Int64(max(0, evidence.fileSizeBytes)),
            isPlayable: isPlayable,
            isPartial: !integrity.isComplete,
            integrityReasons: integrity.reasons.map {
                SegmentIntegrityReason($0.rawValue)
            }
        )
    }

    public func playbackURL(
        sessionID: SessionID,
        audioIdentity: SegmentAudioIdentity
    ) async throws -> URL {
        let url = try paths.audioURL(
            sessionID: sessionID,
            identity: audioIdentity,
            createParentDirectory: false,
            fileManager: fileManager
        )
        do {
            try paths.validateSourceAudio(at: url, fileManager: fileManager)
        } catch {
            throw VoiceCoreSegmentRecorderError.sourceAudioUnavailable
        }
        return url
    }

    public func recoverCapture(
        _ request: SegmentCaptureRequest
    ) async throws -> CapturedAudioSegment? {
        guard activeCapture == nil else {
            throw VoiceCoreSegmentRecorderError.captureAlreadyActive
        }
        let directory = try paths.sessionAudioDirectory(
            sessionID: request.sessionID,
            create: false,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: directory.path) else {
            return nil
        }

        let reservedName = request.reservedAudioIdentity.fileName
        let reservedStem = URL(fileURLWithPath: reservedName)
            .deletingPathExtension()
            .lastPathComponent
        let recoveredPrefix = "\(reservedStem)-recovered-"
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        let matchingURLs = entries.filter { url in
            let name = url.lastPathComponent
            return name == reservedName
                || (name.hasPrefix(recoveredPrefix)
                    && name.lowercased().hasSuffix(".m4a"))
        }

        let candidates = matchingURLs.compactMap { url -> RecoveryCandidate? in
            guard let identity = try? SegmentAudioIdentity(
                validating: url.lastPathComponent
            ),
            (try? paths.validateAuthoritativeCapture(
                at: url,
                for: request.sessionID,
                fileManager: fileManager
            )) != nil else {
                return nil
            }
            let recorded = RecordedCapture(
                url: url,
                duration: 0,
                writtenFrameCount: 0,
                writeErrorDescription: nil
            )
            guard let inspected = try? inspect(recorded) else { return nil }
            let evidence = RecordingIntegrityEvidence(
                wallDurationSeconds: inspected.decodedDurationSeconds,
                decodedDurationSeconds: inspected.decodedDurationSeconds,
                fileSizeBytes: inspected.fileSizeBytes,
                decodedFrameCount: inspected.decodedFrameCount,
                writeErrorDescription: inspected.writeErrorDescription,
                encodedAudioBytes: inspected.encodedAudioBytes,
                peakPowerDecibels: inspected.peakPowerDecibels
            )
            guard evidence.fileSizeBytes >= 512,
                  evidence.decodedFrameCount > 0,
                  evidence.decodedDurationSeconds > 0 else {
                return nil
            }
            let modifiedAt = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            return RecoveryCandidate(
                url: url,
                identity: identity,
                evidence: evidence,
                isRecoveredFile: url.lastPathComponent != reservedName,
                modifiedAt: modifiedAt
            )
        }
        guard let selected = candidates.sorted(by: Self.preferredRecovery).first else {
            return nil
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: selected.url.path
        )
        let integrity = RecordingIntegrityEvaluator.evaluate(selected.evidence)
        let endedAt = selected.modifiedAt
        let startedAt = endedAt.addingTimeInterval(
            -selected.evidence.decodedDurationSeconds
        )
        return CapturedAudioSegment(
            audioIdentity: selected.identity,
            startedAtMilliseconds: Self.milliseconds(since1970: startedAt),
            endedAtMilliseconds: Self.milliseconds(since1970: endedAt),
            durationMilliseconds: Self.milliseconds(
                selected.evidence.decodedDurationSeconds
            ),
            decodedDurationMilliseconds: Self.milliseconds(
                selected.evidence.decodedDurationSeconds
            ),
            byteCount: Int64(max(0, selected.evidence.fileSizeBytes)),
            isPlayable: true,
            isPartial: true,
            integrityReasons: integrity.reasons.map {
                SegmentIntegrityReason($0.rawValue)
            }
        )
    }

    private func installDriverTerminationBridge() {
        driver.onUnexpectedTermination = { [weak self] in
            guard let self,
                  self.activeCapture != nil,
                  !self.didReportUnexpectedTermination else {
                return
            }
            self.didReportUnexpectedTermination = true
            self.unexpectedTerminationHandler?()
        }
    }

    private func adoptIdentity(
        for authoritativeURL: URL,
        sessionID: SessionID
    ) throws -> SegmentAudioIdentity {
        if let identity = try? SegmentAudioIdentity(
            validating: authoritativeURL.lastPathComponent
        ) {
            return identity
        }

        let identity: SegmentAudioIdentity
        do {
            identity = try SegmentAudioIdentity(
                validating: "capture-\(UUID().uuidString.lowercased()).m4a"
            )
        } catch {
            throw VoiceCoreSegmentRecorderError.invalidAuthoritativeAudioIdentity
        }
        let adoptedURL = try paths.audioURL(
            sessionID: sessionID,
            identity: identity,
            createParentDirectory: false,
            fileManager: fileManager
        )
        do {
            try fileManager.moveItem(at: authoritativeURL, to: adoptedURL)
        } catch {
            throw VoiceCoreSegmentRecorderError.sourceAudioUnavailable
        }
        return identity
    }

    private func inspectedEvidence(
        for recorded: RecordedCapture,
        at authoritativeURL: URL
    ) -> RecordingIntegrityEvidence {
        let authoritativeCapture = RecordedCapture(
            url: authoritativeURL,
            duration: recorded.duration,
            writtenFrameCount: recorded.writtenFrameCount,
            writeErrorDescription: recorded.writeErrorDescription,
            peakPowerDecibels: recorded.peakPowerDecibels
        )
        if let evidence = try? inspect(authoritativeCapture) {
            return evidence
        }
        let byteCount = (try? authoritativeURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        return RecordingIntegrityEvidence(
            wallDurationSeconds: recorded.duration,
            decodedDurationSeconds: 0,
            fileSizeBytes: byteCount,
            decodedFrameCount: 0,
            writeErrorDescription: recorded.writeErrorDescription
                ?? "integrity_inspection_failed",
            peakPowerDecibels: recorded.peakPowerDecibels
        )
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((max(0, seconds) * 1_000).rounded())
    }

    private static func preferredRecovery(
        _ lhs: RecoveryCandidate,
        _ rhs: RecoveryCandidate
    ) -> Bool {
        if lhs.isRecoveredFile != rhs.isRecoveredFile {
            return lhs.isRecoveredFile
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        if lhs.evidence.decodedDurationSeconds
            != rhs.evidence.decodedDurationSeconds {
            return lhs.evidence.decodedDurationSeconds
                > rhs.evidence.decodedDurationSeconds
        }
        return lhs.identity.fileName < rhs.identity.fileName
    }
}
