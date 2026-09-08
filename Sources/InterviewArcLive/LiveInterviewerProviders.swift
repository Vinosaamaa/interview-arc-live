import Foundation
import InterviewArcLiveCore
import InterviewArcLiveCodexAdapter

/// The application composition point for the selected interviewer adapter.
/// Room/session logic and speech providers do not choose a model vendor.
enum LiveInterviewerProviders {
    static func makeDefault(
        fileManager: FileManager = .default
    ) -> any InterviewerProvider {
        do {
            let root = try LivePaths.applicationSupportRoot(fileManager: fileManager)
            let workingDirectory = root.appendingPathComponent(
                "CodexRuntime",
                isDirectory: true
            )
            for directory in [root, workingDirectory] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
            return CodexAppServerInterviewerRuntime(
                workingDirectoryURL: workingDirectory,
                model: CodexAppServerInterviewerRuntime.defaultInterviewerModel
            )
        } catch {
            return UnavailableInterviewerProvider(providerName: "Codex")
        }
    }
}

private struct UnavailableInterviewerProvider: InterviewerProvider {
    let providerName: String

    func preflight() async -> InterviewerReadiness { .transportFailure }

    func respond(to request: InterviewerRequest) async throws -> CanonicalInterviewerResponse {
        throw InterviewerRuntimeError.transportFailure
    }
}
