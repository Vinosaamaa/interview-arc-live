import Foundation
import Darwin

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

    // Resolve the existing ancestor with POSIX realpath before adding an
    // absent tail. Foundation normalizes /private/tmp differently depending
    // on whether the final directory exists and on the macOS SDK version.
    static func diagnosticRoot(for path: String) throws -> URL {
        guard path.hasPrefix("/"), let temporary = realpath("/private/tmp", nil) else {
            throw LivePathError.invalidDiagnosticStateRoot
        }
        defer { free(temporary) }
        let temporaryPath = String(cString: temporary)
        var ancestor = path
        var missingComponents: [String] = []
        while true {
            if let resolved = realpath(ancestor, nil) {
                defer { free(resolved) }
                let rootPath = ([String(cString: resolved)] + missingComponents.reversed())
                    .joined(separator: "/")
                let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
                // URL standardization may spell /private/tmp as /tmp; compare
                // physical ancestry before returning a URL, not that spelling.
                guard rootPath.hasPrefix(temporaryPath + "/"),
                      !missingComponents.contains("..") else {
                    throw LivePathError.invalidDiagnosticStateRoot
                }
                return root
            }
            var metadata = stat()
            guard ancestor != "/", lstat(ancestor, &metadata) != 0, errno == ENOENT else {
                // An existing but unresolvable entry (including a dangling
                // symlink) is not evidence of confinement below temporary.
                throw LivePathError.invalidDiagnosticStateRoot
            }
            let component = (ancestor as NSString).lastPathComponent
            guard !component.isEmpty, component != ".", component != ".." else {
                throw LivePathError.invalidDiagnosticStateRoot
            }
            missingComponents.append(component)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    public static func sessionManifestsDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("SessionManifests", isDirectory: true)
    }
}
