import Foundation

public enum LivePathError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
}

/// Live-owned runtime paths, derived at runtime so no personal path enters
/// source or durable manifests.
public enum LivePaths {
    public static let applicationSupportDirectoryName = "InterviewArcLive"

    public static func applicationSupportRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
#if INTERVIEW_ARC_LIVE_DIAGNOSTIC_STATE_ROOT
        if let diagnosticPath = ProcessInfo.processInfo.environment[
            "INTERVIEW_ARC_LIVE_DIAGNOSTIC_STATE_ROOT"
        ], !diagnosticPath.isEmpty {
            let root = URL(fileURLWithPath: diagnosticPath, isDirectory: true)
                .standardizedFileURL
            if root.path == "/private/tmp" || root.path.hasPrefix("/private/tmp/") {
                return root
            }
        }
#endif

        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LivePathError.applicationSupportDirectoryUnavailable
        }

        return base.appendingPathComponent(
            applicationSupportDirectoryName,
            isDirectory: true
        )
    }

    public static func sessionManifestsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("SessionManifests", isDirectory: true)
    }
}
