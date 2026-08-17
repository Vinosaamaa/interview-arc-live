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

    public static func codingSourcesDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("CodingSources", isDirectory: true)
    }

    public static func workspaceLinkFile(
        fileManager: FileManager = .default
    ) throws -> URL {
        try applicationSupportRoot(fileManager: fileManager)
            .appendingPathComponent("WorkspaceLink.json", isDirectory: false)
    }
}
