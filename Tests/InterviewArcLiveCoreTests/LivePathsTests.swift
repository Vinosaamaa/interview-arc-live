import Foundation
import XCTest
@testable import InterviewArcLiveCore

final class LivePathsTests: XCTestCase {
    func testDiagnosticRootAcceptsBothMacOSTemporaryDirectorySpellings() throws {
        let input = "/private/tmp/interview-arc-live-ui-smoke-path-test"
        let expected = URL(fileURLWithPath: input).resolvingSymlinksInPath().path
        XCTAssertEqual(try LivePaths.diagnosticRoot(for: input).path, expected)
        XCTAssertEqual(try LivePaths.diagnosticRoot(for:
            "/tmp/interview-arc-live-ui-smoke-path-test").path, expected)
    }

    func testDiagnosticRootRejectsSharedRootAndEscapes() {
        for path in ["/private/tmp", "/tmp", "/tmp/../var", "/var/tmp", "/"] {
            XCTAssertThrowsError(try LivePaths.diagnosticRoot(for: path)) { error in
                XCTAssertEqual(error as? LivePathError, .invalidDiagnosticStateRoot)
            }
        }
    }
}
