import CryptoKit
import Darwin
import Foundation

enum PrivateInterviewerWaveStoreError: Error, Equatable, Sendable {
    case invalidFormat
    case emptyChunk
    case nonFiniteSample
    case durationLimitExceeded
    case writeAlreadyActive
    case writeNotActive
    case unsafeStorage
    case destinationAlreadyExists
    case invalidFinalFile
}

struct PrivateInterviewerWaveWriteToken: Hashable, Sendable {
    fileprivate let sessionDigest: String
    fileprivate let attemptDigest: String
    let partialFileName: String
    let finalFileName: String
}

struct PrivateInterviewerWaveDescriptor: Equatable, Sendable {
    let fileName: String
    let sampleRate: Int
    let channelCount: Int
    let frameCount: Int
    let durationMilliseconds: Int
    let byteCount: Int
    let sha256: String
}

/// Private, deterministic Float32 WAV persistence used below the Core speech
/// storage Interface. Tokens and descriptors carry only validated filenames;
/// absolute paths stay inside this Adapter.
actor PrivateInterviewerWaveStore {
    static let sampleRate = 24_000
    static let channelCount = 1
    static let bytesPerSample = MemoryLayout<Float>.size
    static let headerByteCount = 44
    /// `mara-v1` is bounded to 1,200 codec tokens (about 96 seconds). Keep a
    /// small framing margin without permitting an oversized provider effect.
    static let maximumDurationSeconds = 100
    static let maximumFrameCount = sampleRate * maximumDurationSeconds

    private struct ActiveWrite {
        let handle: FileHandle
        let partialURL: URL
        var frameCount: Int
    }

    private let configuredApplicationSupportRoot: URL?
    private let fileManager: FileManager
    private let maximumFrameCount: Int
    private var activeWrites: [PrivateInterviewerWaveWriteToken: ActiveWrite] = [:]

    init(
        applicationSupportRoot: URL? = nil,
        maximumFrameCount: Int = PrivateInterviewerWaveStore.maximumFrameCount,
        fileManager: FileManager = .default
    ) {
        configuredApplicationSupportRoot = applicationSupportRoot
        self.maximumFrameCount = max(1, maximumFrameCount)
        self.fileManager = fileManager
    }

    func begin(
        sessionIdentity: String,
        attemptIdentity: String,
        partialFileName: String,
        finalFileName: String
    ) throws -> PrivateInterviewerWaveWriteToken {
        let token = try validatedToken(
            sessionIdentity: sessionIdentity,
            attemptIdentity: attemptIdentity,
            partialFileName: partialFileName,
            finalFileName: finalFileName
        )
        guard activeWrites[token] == nil else {
            throw PrivateInterviewerWaveStoreError.writeAlreadyActive
        }

        let directory = try sessionDirectory(
            sessionDigest: token.sessionDigest,
            create: true
        )
        let partialURL = directory.appendingPathComponent(
            token.partialFileName,
            isDirectory: false
        )
        let finalURL = directory.appendingPathComponent(
            token.finalFileName,
            isDirectory: false
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw PrivateInterviewerWaveStoreError.destinationAlreadyExists
        }

        let descriptor = Darwin.open(
            partialURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw errno == EEXIST
                ? PrivateInterviewerWaveStoreError.destinationAlreadyExists
                : PrivateInterviewerWaveStoreError.unsafeStorage
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        do {
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw PrivateInterviewerWaveStoreError.unsafeStorage
            }
            try handle.write(contentsOf: Self.wavHeader(frameCount: 0))
            try enforcePrivateFilePermissions(partialURL)
            try handle.seekToEnd()
            activeWrites[token] = ActiveWrite(
                handle: handle,
                partialURL: partialURL,
                frameCount: 0
            )
            return token
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
    }

    func append(
        _ samples: [Float],
        sampleRate: Int,
        channelCount: Int,
        to token: PrivateInterviewerWaveWriteToken
    ) throws {
        guard sampleRate == Self.sampleRate,
              channelCount == Self.channelCount else {
            throw PrivateInterviewerWaveStoreError.invalidFormat
        }
        guard !samples.isEmpty else {
            throw PrivateInterviewerWaveStoreError.emptyChunk
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw PrivateInterviewerWaveStoreError.nonFiniteSample
        }
        guard var active = activeWrites[token] else {
            throw PrivateInterviewerWaveStoreError.writeNotActive
        }
        let (nextFrameCount, overflow) = active.frameCount.addingReportingOverflow(
            samples.count
        )
        guard !overflow, nextFrameCount <= maximumFrameCount else {
            throw PrivateInterviewerWaveStoreError.durationLimitExceeded
        }

        try active.handle.write(contentsOf: Self.float32LittleEndianData(samples))
        active.frameCount = nextFrameCount
        activeWrites[token] = active
    }

    func finalize(
        _ token: PrivateInterviewerWaveWriteToken
    ) throws -> PrivateInterviewerWaveDescriptor {
        guard let active = activeWrites.removeValue(forKey: token) else {
            throw PrivateInterviewerWaveStoreError.writeNotActive
        }
        guard active.frameCount > 0 else {
            try? active.handle.close()
            try? fileManager.removeItem(at: active.partialURL)
            throw PrivateInterviewerWaveStoreError.invalidFinalFile
        }

        do {
            try writeHeader(
                Self.wavHeader(frameCount: active.frameCount),
                to: active.handle
            )
            try active.handle.synchronize()
            try active.handle.close()
            try validatePrivateFile(active.partialURL)
            let descriptor = try inspectWave(
                at: active.partialURL,
                expectedFileName: token.partialFileName
            )
            let finalURL = active.partialURL.deletingLastPathComponent()
                .appendingPathComponent(token.finalFileName, isDirectory: false)
            try moveExclusively(from: active.partialURL, to: finalURL)
            try enforcePrivateFilePermissions(finalURL)
            try synchronizeDirectory(finalURL.deletingLastPathComponent())
            return PrivateInterviewerWaveDescriptor(
                fileName: token.finalFileName,
                sampleRate: descriptor.sampleRate,
                channelCount: descriptor.channelCount,
                frameCount: descriptor.frameCount,
                durationMilliseconds: descriptor.durationMilliseconds,
                byteCount: descriptor.byteCount,
                sha256: descriptor.sha256
            )
        } catch {
            try? active.handle.close()
            throw error
        }
    }

    func discard(_ token: PrivateInterviewerWaveWriteToken) {
        if let active = activeWrites.removeValue(forKey: token) {
            try? active.handle.close()
            try? fileManager.removeItem(at: active.partialURL)
            return
        }
        if let partialURL = try? waveURL(
            sessionDigest: token.sessionDigest,
            fileName: token.partialFileName,
            createParentDirectory: false
        ) {
            try? fileManager.removeItem(at: partialURL)
        }
    }

    func recover(
        sessionIdentity: String,
        attemptIdentity: String,
        partialFileName: String,
        finalFileName: String
    ) throws -> PrivateInterviewerWaveDescriptor? {
        let token = try validatedToken(
            sessionIdentity: sessionIdentity,
            attemptIdentity: attemptIdentity,
            partialFileName: partialFileName,
            finalFileName: finalFileName
        )
        let finalURL = try waveURL(
            sessionDigest: token.sessionDigest,
            fileName: token.finalFileName,
            createParentDirectory: false
        )
        if fileManager.fileExists(atPath: finalURL.path),
           let descriptor = try? inspectWave(
               at: finalURL,
               expectedFileName: token.finalFileName
           ) {
            return descriptor
        }
        let partialURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(token.partialFileName, isDirectory: false)
        if fileManager.fileExists(atPath: partialURL.path) {
            let values = try? partialURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            if values?.isRegularFile == true,
               values?.isSymbolicLink != true {
                try? fileManager.removeItem(at: partialURL)
            }
        }
        return nil
    }

    func inspectFinal(
        sessionIdentity: String,
        fileName: String
    ) throws -> PrivateInterviewerWaveDescriptor {
        guard Self.isFinalFileName(fileName) else {
            throw PrivateInterviewerWaveStoreError.invalidFinalFile
        }
        let url = try waveURL(
            sessionDigest: Self.digest(sessionIdentity),
            fileName: fileName,
            createParentDirectory: false
        )
        return try inspectWave(at: url, expectedFileName: fileName)
    }

    func playbackURL(
        sessionIdentity: String,
        fileName: String
    ) throws -> URL {
        _ = try inspectFinal(sessionIdentity: sessionIdentity, fileName: fileName)
        return try waveURL(
            sessionDigest: Self.digest(sessionIdentity),
            fileName: fileName,
            createParentDirectory: false
        )
    }

    private func writeHeader(_ header: Data, to handle: FileHandle) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.seekToEnd()
    }

    private func inspectWave(
        at url: URL,
        expectedFileName: String
    ) throws -> PrivateInterviewerWaveDescriptor {
        do {
            try validatePrivateFile(url)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count >= Self.headerByteCount,
                  data.prefix(4) == Data("RIFF".utf8),
                  data[8..<12] == Data("WAVE".utf8),
                  data[12..<16] == Data("fmt ".utf8),
                  Self.uint32(at: 16, in: data) == 16,
                  Self.uint16(at: 20, in: data) == 3,
                  Self.uint16(at: 22, in: data) == Self.channelCount,
                  Self.uint32(at: 24, in: data) == Self.sampleRate,
                  Self.uint32(at: 28, in: data)
                    == Self.sampleRate * Self.bytesPerSample,
                  Self.uint16(at: 32, in: data) == Self.bytesPerSample,
                  Self.uint16(at: 34, in: data) == 32,
                  data[36..<40] == Data("data".utf8) else {
                throw PrivateInterviewerWaveStoreError.invalidFinalFile
            }
            let dataByteCount = Int(Self.uint32(at: 40, in: data))
            guard dataByteCount > 0,
                  dataByteCount.isMultiple(of: Self.bytesPerSample),
                  data.count == Self.headerByteCount + dataByteCount,
                  Int(Self.uint32(at: 4, in: data)) == data.count - 8 else {
                throw PrivateInterviewerWaveStoreError.invalidFinalFile
            }
            let frameCount = dataByteCount / Self.bytesPerSample
            guard frameCount <= maximumFrameCount,
                  Self.allSamplesAreFinite(in: data) else {
                throw PrivateInterviewerWaveStoreError.invalidFinalFile
            }
            return PrivateInterviewerWaveDescriptor(
                fileName: expectedFileName,
                sampleRate: Self.sampleRate,
                channelCount: Self.channelCount,
                frameCount: frameCount,
                durationMilliseconds: Int(
                    (Double(frameCount) / Double(Self.sampleRate) * 1_000).rounded()
                ),
                byteCount: data.count,
                sha256: Self.digest(data)
            )
        } catch let error as PrivateInterviewerWaveStoreError {
            throw error
        } catch {
            throw PrivateInterviewerWaveStoreError.invalidFinalFile
        }
    }

    private func waveURL(
        sessionDigest: String,
        fileName: String,
        createParentDirectory: Bool
    ) throws -> URL {
        let directory = try sessionDirectory(
            sessionDigest: sessionDigest,
            create: createParentDirectory
        )
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func validatedToken(
        sessionIdentity: String,
        attemptIdentity: String,
        partialFileName: String,
        finalFileName: String
    ) throws -> PrivateInterviewerWaveWriteToken {
        let attemptDigest = Self.digest(attemptIdentity)
        guard finalFileName == "speech-\(attemptDigest).wav",
              partialFileName == "speech-\(attemptDigest).partial.wav",
              Self.isFinalFileName(finalFileName),
              Self.isPartialFileName(partialFileName) else {
            throw PrivateInterviewerWaveStoreError.invalidFinalFile
        }
        return PrivateInterviewerWaveWriteToken(
            sessionDigest: Self.digest(sessionIdentity),
            attemptDigest: attemptDigest,
            partialFileName: partialFileName,
            finalFileName: finalFileName
        )
    }

    private func sessionDirectory(
        sessionDigest: String,
        create: Bool
    ) throws -> URL {
        let root = try applicationSupportRoot()
        let speechRoot = root.appendingPathComponent(
            "InterviewerSpeech",
            isDirectory: true
        )
        let directory = speechRoot.appendingPathComponent(
            "session-\(sessionDigest)",
            isDirectory: true
        )
        if create {
            try ensurePrivateDirectory(root)
            try ensurePrivateDirectory(speechRoot)
            try ensurePrivateDirectory(directory)
        }
        return directory.standardizedFileURL
    }

    private func applicationSupportRoot() throws -> URL {
        if let configuredApplicationSupportRoot {
            return configuredApplicationSupportRoot.standardizedFileURL
        }
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
        return base.appendingPathComponent(
            "InterviewArcLive",
            isDirectory: true
        )
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Existing Live-owned directories are expected and validated below.
        }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func validatePrivateFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
    }

    private func enforcePrivateFilePermissions(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try validatePrivateFile(url)
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw PrivateInterviewerWaveStoreError.unsafeStorage
        }
    }

    private func moveExclusively(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw errno == EEXIST
                ? PrivateInterviewerWaveStoreError.destinationAlreadyExists
                : PrivateInterviewerWaveStoreError.unsafeStorage
        }
    }

    private static func wavHeader(frameCount: Int) -> Data {
        let dataByteCount = frameCount * bytesPerSample
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(3))
        data.appendLittleEndian(UInt16(channelCount))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample))
        data.appendLittleEndian(UInt16(32))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataByteCount))
        return data
    }

    private static func float32LittleEndianData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * bytesPerSample)
        for sample in samples {
            data.appendLittleEndian(sample.bitPattern)
        }
        return data
    }

    private static func allSamplesAreFinite(in data: Data) -> Bool {
        var offset = headerByteCount
        while offset < data.count {
            let sample = Float(bitPattern: uint32(at: offset, in: data))
            guard sample.isFinite else { return false }
            offset += bytesPerSample
        }
        return true
    }

    private static func uint16(at offset: Int, in data: Data) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func uint32(at offset: Int, in data: Data) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isFinalFileName(_ fileName: String) -> Bool {
        guard fileName.count <= 160,
              fileName.hasSuffix(".wav"),
              !fileName.hasSuffix(".partial.wav"),
              fileName != ".wav" else {
            return false
        }
        let stem = fileName.dropLast(4)
        return stem.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    private static func isPartialFileName(_ fileName: String) -> Bool {
        guard fileName.count <= 168,
              fileName.hasSuffix(".partial.wav") else {
            return false
        }
        let stem = fileName.dropLast(".partial.wav".count)
        return !stem.isEmpty && stem.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
