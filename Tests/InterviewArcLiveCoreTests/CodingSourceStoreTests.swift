import Foundation
import XCTest

@testable import InterviewArcLiveCore

final class CodingSourceStoreTests: XCTestCase {
    func testFileNameUsesPaddedNumberAndSlug() {
        XCTAssertEqual(
            CodingSourceStore.fileName(questionID: "1", title: "Two Sum"),
            "0001-two-sum.java"
        )
        XCTAssertEqual(
            CodingSourceStore.fileName(questionID: "0146-lru-cache", title: "LRU Cache"),
            "0146-lru-cache.java"
        )
        XCTAssertEqual(
            CodingSourceStore.fileName(questionID: "two-sum", title: "Two Sum"),
            "two-sum.java"
        )
    }

    func testResolveUsesLiveCopyWhenCheckoutIsUnlinked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "coding-source-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try CodingSourceStore.identity(
            activityID: "activity-code",
            questionID: "1",
            title: "Two Sum"
        )
        let url = try CodingSourceStore.resolveURL(
            identity: identity,
            applicationSupportRoot: root,
            interviewArcRepositoryRoot: nil
        )
        XCTAssertEqual(
            url.lastPathComponent,
            "0001-two-sum.java"
        )
        XCTAssertTrue(
            url.path.contains("CodingSources/activity-code")
        )
    }

    func testResolvePrefersExistingCheckoutSolutionMatchingSlug() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "coding-source-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let solutions = root
            .appendingPathComponent("practice", isDirectory: true)
            .appendingPathComponent("leetcode", isDirectory: true)
            .appendingPathComponent("solutions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: solutions,
            withIntermediateDirectories: true
        )
        let existing = solutions.appendingPathComponent("0001-two-sum.java")
        try Data("// fixture\n".utf8).write(to: existing)

        let identity = try CodingSourceStore.identity(
            activityID: "activity-code",
            questionID: "two-sum",
            title: "Two Sum"
        )
        let url = try CodingSourceStore.resolveURL(
            identity: identity,
            applicationSupportRoot: root.appendingPathComponent("support"),
            interviewArcRepositoryRoot: root
        )
        XCTAssertEqual(
            url.standardizedFileURL,
            existing.standardizedFileURL
        )
    }

    func testTitleAloneNeverInventsALeetCodeNumber() {
        XCTAssertEqual(
            CodingSourceStore.fileName(questionID: nil, title: "Two Sum"),
            "two-sum.java"
        )
        XCTAssertEqual(
            CodingSourceStore.fileName(questionID: "0001-two-sum", title: "Ignored"),
            "0001-two-sum.java"
        )
        XCTAssertNil(CodingSourceStore.problemNumber(fromQuestionID: "two-sum"))
        XCTAssertEqual(
            CodingSourceStore.leetCodeProblemURL(
                questionID: "two-sum",
                title: "Two Sum"
            )?.absoluteString,
            "https://leetcode.com/problems/two-sum/"
        )
    }

    func testWorkspaceLinkLoadsFromTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "coding-workspace-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkout = root.appendingPathComponent("interview-arc", isDirectory: true)
        let linkFile = root.appendingPathComponent("WorkspaceLink.json")
        try JSONEncoder().encode(
            CodingWorkspaceLink(interviewArcRepositoryRoot: checkout.path)
        ).write(to: linkFile)

        let link = try XCTUnwrap(
            CodingSourceStore.loadWorkspaceLink(from: linkFile)
        )
        XCTAssertEqual(link.interviewArcRepositoryRoot, checkout.path)
        XCTAssertTrue(link.interviewArcRepositoryRoot.hasSuffix("interview-arc"))
    }
}
