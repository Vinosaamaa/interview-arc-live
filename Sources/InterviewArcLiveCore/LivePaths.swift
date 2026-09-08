import Foundation

public enum LivePathError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
    case invalidDiagnosticStateRoot
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
            return try diagnosticRoot(for: diagnosticPath)
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

    // Standardizing a file URL collapses /private/tmp to /tmp on macOS.
    // Resolve both paths identically, including symlinks, for confinement.
    static func diagnosticRoot(for path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath()
        guard root.path.hasPrefix(temporary.path + "/") else {
            throw LivePathError.invalidDiagnosticStateRoot
        }
        return root
    }

    public static func sessionManifestsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("SessionManifests", isDirectory: true)
    }
}
