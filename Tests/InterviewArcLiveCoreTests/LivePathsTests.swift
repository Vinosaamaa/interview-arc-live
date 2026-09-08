import Foundation
import XCTest
@testable import InterviewArcLiveCore

final class LivePathsTests: XCTestCase {
    func testDiagnosticRootAcceptsBothMacOSTemporaryDirectorySpellings() throws {
        let input = "/private/tmp/interview-arc-live-ui-smoke-path-test"
        let expected = URL(fileURLWithPath: input).standardizedFileURL.path
        XCTAssertEqual(try LivePaths.diagnosticRoot(for: input).path, expected)
        XCTAssertEqual(try LivePaths.diagnosticRoot(for:
            "/tmp/interview-arc-live-ui-smoke-path-test").path, expected)
    }

    func testDiagnosticRootRejectsSymlinksOutsideTemporaryAndResolvesExistingRoots() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("interview-arc-live-ui-smoke-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try LivePaths.diagnosticRoot(for: root.path).path, root.standardizedFileURL.path)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(atPath: outside.path, withDestinationPath: "/var")
        XCTAssertThrowsError(try LivePaths.diagnosticRoot(for: outside.appendingPathComponent("missing").path))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path,
            withDestinationPath: "/var/interview-arc-live-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try LivePaths.diagnosticRoot(for: dangling.appendingPathComponent("child").path))
    }

    func testDiagnosticRootRejectsSharedRootAndEscapes() {
        for path in ["/private/tmp", "/tmp", "/tmp/../var", "/var/tmp", "/"] {
            XCTAssertThrowsError(try LivePaths.diagnosticRoot(for: path)) { error in
                XCTAssertEqual(error as? LivePathError, .invalidDiagnosticStateRoot)
            }
        }
    }
}
