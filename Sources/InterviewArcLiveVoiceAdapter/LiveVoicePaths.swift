import CryptoKit
import Foundation
import InterviewArcLiveCore

enum LiveVoicePathError: Error, Equatable, Sendable {
    case sourceAudioMissing
    case sourceAudioIsNotRegularFile
    case authoritativeCaptureOutsideSessionRoot
    case invalidAuthoritativeAudioIdentity
    case destinationAlreadyExists
}

struct ProviderScratchCleanupPolicy: Equatable, Sendable {
    let staleAge: TimeInterval
    let maximumSessionDirectories: Int
    let maximumAttemptDirectories: Int
    let maximumDeletions: Int

    static let production = ProviderScratchCleanupPolicy(
        staleAge: 24 * 60 * 60,
        maximumSessionDirectories: 64,
        maximumAttemptDirectories: 256,
        maximumDeletions: 64
    )
}

struct LiveVoicePaths: Sendable {
    private let configuredApplicationSupportRoot: URL?

    init(applicationSupportRoot: URL? = nil) {
        configuredApplicationSupportRoot = applicationSupportRoot
    }

    func audioURL(
        sessionID: SessionID,
        identity: SegmentAudioIdentity,
        createParentDirectory: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try sessionAudioDirectory(
            sessionID: sessionID,
            create: createParentDirectory,
            fileManager: fileManager
        )
        return directory.appendingPathComponent(
            identity.fileName,
            isDirectory: false
        )
    }

    func sessionAudioDirectory(
        sessionID: SessionID,
        create: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        let audioRoot = root.appendingPathComponent("Audio", isDirectory: true)
        let directory = audioRoot.appendingPathComponent(
            "session-\(Self.digest(sessionID.rawValue))",
            isDirectory: true
        )
        if create {
            try ensurePrivateDirectory(root, fileManager: fileManager)
            try ensurePrivateDirectory(audioRoot, fileManager: fileManager)
            try ensurePrivateDirectory(directory, fileManager: fileManager)
        }
        return directory.standardizedFileURL
    }

    func transcriptionScratchDirectory(
        sessionID: SessionID,
        attemptID: TranscriptionAttemptID,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try applicationSupportRoot(fileManager: fileManager)
        let scratchRoot = root.appendingPathComponent(
            "ProviderScratch",
            isDirectory: true
        )
        let sessionDirectory = scratchRoot.appendingPathComponent(
            "session-\(Self.digest(sessionID.rawValue))",
            isDirectory: true
        )
        let directory = sessionDirectory.appendingPathComponent(
            "attempt-\(Self.digest(attemptID.rawValue))-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try ensurePrivateDirectory(root, fileManager: fileManager)
        try ensurePrivateDirectory(scratchRoot, fileManager: fileManager)
        try ensurePrivateDirectory(sessionDirectory, fileManager: fileManager)
        try ensurePrivateDirectory(directory, fileManager: fileManager)
        return directory.standardizedFileURL
    }

    /// Removes only old, Live-shaped attempt directories beneath
    /// `ProviderScratch`. Enumeration and deletion are deliberately bounded,
    /// fresh directories are retained as potentially in-flight, and symlinks
    /// are never traversed or removed.
    @discardableResult
    func cleanupStaleTranscriptionScratch(
        now: Date,
        policy: ProviderScratchCleanupPolicy = .production,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard policy.maximumSessionDirectories > 0,
              policy.maximumAttemptDirectories > 0,
              policy.maximumDeletions > 0 else {
            return 0
        }

        let root = try applicationSupportRoot(fileManager: fileManager)
        let scratchRoot = root.appendingPathComponent(
            "ProviderScratch",
            isDirectory: true
        ).standardizedFileURL
        guard fileManager.fileExists(atPath: scratchRoot.path) else {
            return 0
        }
        let rootValues = try scratchRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            return 0
        }

        let resolvedScratchRoot = scratchRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let cutoff = now.addingTimeInterval(-max(0, policy.staleAge))
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: scratchRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var inspectedAttempts = 0
        var deletionCount = 0
        for sessionDirectory in sessionDirectories.prefix(
            policy.maximumSessionDirectories
        ) {
            guard Self.isSessionScratchDirectoryName(
                sessionDirectory.lastPathComponent
            ) else {
                continue
            }
            guard let sessionValues = try? sessionDirectory.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            ),
                  sessionValues.isDirectory == true,
                  sessionValues.isSymbolicLink != true,
                  Self.isStrictDescendant(
                      sessionDirectory.resolvingSymlinksInPath().standardizedFileURL,
                      of: resolvedScratchRoot
                  ) else {
                continue
            }

            guard let attempts = try? fileManager.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
                continue
            }
            for attempt in attempts {
                guard inspectedAttempts < policy.maximumAttemptDirectories,
                      deletionCount < policy.maximumDeletions else {
                    return deletionCount
                }
                inspectedAttempts += 1

                guard Self.isAttemptScratchDirectoryName(
                    attempt.lastPathComponent
                ) else {
                    continue
                }
                guard let values = try? attempt.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff,
                      Self.isStrictDescendant(
                          attempt.resolvingSymlinksInPath().standardizedFileURL,
                          of: resolvedScratchRoot
                      ) else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: attempt)
                    deletionCount += 1
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Another Live process won the same bounded cleanup race.
                } catch {
                    // One inaccessible stale directory must not prevent later
                    // root-confined candidates from being considered.
                }
            }
        }
        return deletionCount
    }

    func validateSourceAudio(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw LiveVoicePathError.sourceAudioMissing
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LiveVoicePathError.sourceAudioIsNotRegularFile
        }
    }

    func validateAuthoritativeCapture(
        at url: URL,
        for sessionID: SessionID,
        fileManager: FileManager = .default
    ) throws {
        let expectedDirectory = try sessionAudioDirectory(
            sessionID: sessionID,
            create: false,
            fileManager: fileManager
        ).resolvingSymlinksInPath().standardizedFileURL
        let actualURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard actualURL.deletingLastPathComponent() == expectedDirectory else {
            throw LiveVoicePathError.authoritativeCaptureOutsideSessionRoot
        }
        try validateSourceAudio(at: actualURL, fileManager: fileManager)
    }

    private func applicationSupportRoot(
        fileManager: FileManager
    ) throws -> URL {
        if let configuredApplicationSupportRoot {
            return configuredApplicationSupportRoot.standardizedFileURL
        }
        return try LivePaths.applicationSupportRoot(fileManager: fileManager)
    }

    private func ensurePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSessionScratchDirectoryName(_ name: String) -> Bool {
        hasSHA256Suffix(name, prefix: "session-")
    }

    private static func isAttemptScratchDirectoryName(_ name: String) -> Bool {
        let prefix = "attempt-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count == 64 + 1 + 36 else { return false }
        let digestEnd = suffix.index(suffix.startIndex, offsetBy: 64)
        let digest = suffix[..<digestEnd]
        guard digest.allSatisfy(\.isHexDigit), suffix[digestEnd] == "-" else {
            return false
        }
        let uuidStart = suffix.index(after: digestEnd)
        return UUID(uuidString: String(suffix[uuidStart...])) != nil
    }

    private static func hasSHA256Suffix(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 64 && suffix.allSatisfy(\.isHexDigit)
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
