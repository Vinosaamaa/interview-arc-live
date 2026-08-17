import XCTest

import InterviewArcLiveCore

final class LiveDebugTraceTests: XCTestCase {
    func testTokenKeepsShortPublicCodes() {
        XCTAssertEqual(LiveDebugTrace.token("receipt_not_found"), "receipt_not_found")
        XCTAssertEqual(LiveDebugTrace.token("lease.renew"), "lease.renew")
        XCTAssertEqual(LiveDebugTrace.token("foreign_holder_session"), "foreign_holder_session")
    }

    func testTokenRedactsSecretsPathsAndLongValues() {
        XCTAssertEqual(LiveDebugTrace.token("sk-example"), "redacted")
        XCTAssertEqual(LiveDebugTrace.token("gsk_example"), "redacted")
        XCTAssertEqual(LiveDebugTrace.token("/Users/example/Library"), "redacted")
        XCTAssertEqual(LiveDebugTrace.token("owner@example.com"), "redacted")
        XCTAssertEqual(LiveDebugTrace.token(String(repeating: "a", count: 65)), "redacted")
        XCTAssertEqual(LiveDebugTrace.token("hello world"), "redacted")
    }
}
