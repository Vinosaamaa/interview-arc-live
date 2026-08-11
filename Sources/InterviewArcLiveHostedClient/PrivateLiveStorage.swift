import Darwin
import Foundation
import InterviewArcLiveCore

enum PrivateLiveStorageError: Error, Equatable, Sendable {
    case unsafePath
    case invalidPermissions
    case openFailed(Int32)
    case writeFailed(Int32)
    case syncFailed(Int32)
    case renameFailed(Int32)
}

struct PrivateLiveJSONStore: Sendable {
    let directoryHierarchy: [URL]
    let fileURL: URL

    init(directoryHierarchy: [URL], fileURL: URL) {
        self.directoryHierarchy = directoryHierarchy
        self.fileURL = fileURL
    }

    func load<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard let data = try loadData() else { return nil }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try saveData(encoder.encode(value))
    }

    func loadData() throws -> Data? {
        try prepareDirectories()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        try rejectSymbolicLink(fileURL)
        try enforceMode(fileURL, mode: 0o600)
        return try Data(contentsOf: fileURL)
    }

    func saveData(_ data: Data) throws {
        try prepareDirectories()
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).prepared"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw PrivateLiveStorageError.openFailed(errno) }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var remaining = buffer.count
                var cursor = base
                while remaining > 0 {
                    let count = Darwin.write(descriptor, cursor, remaining)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw PrivateLiveStorageError.writeFailed(errno)
                    }
                    remaining -= count
                    cursor = cursor.advanced(by: count)
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw PrivateLiveStorageError.syncFailed(errno)
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw PrivateLiveStorageError.invalidPermissions
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw PrivateLiveStorageError.syncFailed(errno)
        }

        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw PrivateLiveStorageError.renameFailed(errno)
        }
        try enforceMode(fileURL, mode: 0o600)
        let directoryDescriptor = Darwin.open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw PrivateLiveStorageError.openFailed(errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw PrivateLiveStorageError.syncFailed(errno)
        }
    }

    private func prepareDirectories() throws {
        for directory in directoryHierarchy {
            if FileManager.default.fileExists(atPath: directory.path) {
                try rejectSymbolicLink(directory)
            } else {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try enforceMode(directory, mode: 0o700)
        }
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw PrivateLiveStorageError.unsafePath
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw PrivateLiveStorageError.unsafePath
        }
    }

    private func enforceMode(_ url: URL, mode: Int) throws {
        guard Darwin.chmod(url.path, mode_t(mode)) == 0 else {
            throw PrivateLiveStorageError.invalidPermissions
        }
    }

    static func hostedHierarchy(
        leaf: String,
        fileManager: FileManager = .default
    ) throws -> ([URL], URL) {
        let root = try LivePaths.applicationSupportRoot(fileManager: fileManager)
        let hosted = root.appendingPathComponent("Hosted", isDirectory: true)
        let v1 = hosted.appendingPathComponent("v1", isDirectory: true)
        let destination = v1.appendingPathComponent(leaf, isDirectory: false)
        return ([root, hosted, v1], destination)
    }
}
