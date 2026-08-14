import XCTest
@testable import InterviewArcLiveCore

final class CueOnlyHandoffPolicyTests: XCTestCase {
    func testRecognizesConservativeTerminalCueFamilies() {
        let fixtures: [(String, CueOnlyHandoffReason)] = [
            ("The write path is durable. That’s my answer.", .explicitCompletion),
            ("I would monitor queue age — I’m done!", .explicitCompletion),
            ("Can you clarify the question?", .interviewerQuestion),
            ("I covered the storage tradeoff. Could you repeat the question?", .interviewerQuestion),
            ("How many daily users should I design for?", .interviewerQuestion),
            ("Could you give me a hint?", .hintRequest),
            ("I am stuck on partitioning; what should I consider next?", .hintRequest),
        ]

        for (transcript, reason) in fixtures {
            XCTAssertEqual(
                CueOnlyHandoffPolicy.reason(in: transcript),
                reason,
                transcript
            )
        }
    }

    func testRejectsNonterminalAmbiguousAndQuotedLanguage() {
        let fixtures = [
            "I’m done with the cache layer, and next I will cover the database.",
            "I am deciding whether the queue should be durable.",
            "A candidate might say “I’m done.”",
            "For example, hand off.",
            "The phrase your turn is useful in a protocol.",
            "I am still thinking through the tradeoff.",
            "",
        ]

        for transcript in fixtures {
            XCTAssertNil(CueOnlyHandoffPolicy.reason(in: transcript), transcript)
        }
    }
}
