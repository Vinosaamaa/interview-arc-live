import Foundation

public struct CodingWorkspaceLink: Codable, Equatable, Sendable {
    public var interviewArcRepositoryRoot: String

    public init(interviewArcRepositoryRoot: String) {
        self.interviewArcRepositoryRoot = interviewArcRepositoryRoot
    }
}

public struct CodingSourceIdentity: Equatable, Sendable {
    public let activityID: String
    public let questionID: String?
    public let title: String
    public let fileName: String
}

public enum CodingSourceStoreError: Error, Equatable, Sendable {
    case emptyActivityID
    case missingFileName
}

/// Resolves the one evolving Java file for a coding activity.
///
/// Linked Interview Arc checkouts are read from Live Application Support
/// `WorkspaceLink.json` at runtime. Personal paths never enter source or tests.
public enum CodingSourceStore {
    public static func fileName(
        questionID: String?,
        title: String
    ) -> String {
        let slug = canonicalSlug(fromQuestionID: questionID, title: title)
        if let number = problemNumber(fromQuestionID: questionID) {
            return "\(paddedProblemNumber(number))-\(slug).java"
        }
        return "\(slug).java"
    }

    public static func identity(
        activityID: String,
        questionID: String?,
        title: String
    ) throws -> CodingSourceIdentity {
        let trimmedActivity = activityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedActivity.isEmpty else {
            throw CodingSourceStoreError.emptyActivityID
        }
        let name = fileName(questionID: questionID, title: title)
        guard !name.isEmpty else {
            throw CodingSourceStoreError.missingFileName
        }
        return CodingSourceIdentity(
            activityID: trimmedActivity,
            questionID: questionID,
            title: title,
            fileName: name
        )
    }

    public static func resolveURL(
        identity: CodingSourceIdentity,
        applicationSupportRoot: URL,
        interviewArcRepositoryRoot: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let repositoryRoot = interviewArcRepositoryRoot {
            let solutions = repositoryRoot
                .appendingPathComponent("practice", isDirectory: true)
                .appendingPathComponent("leetcode", isDirectory: true)
                .appendingPathComponent("solutions", isDirectory: true)
            if let existing = existingSolution(
                named: identity.fileName,
                slug: (identity.fileName as NSString).deletingPathExtension,
                in: solutions,
                fileManager: fileManager
            ) {
                return existing
            }
            try fileManager.createDirectory(
                at: solutions,
                withIntermediateDirectories: true
            )
            return solutions.appendingPathComponent(identity.fileName)
        }

        let directory = applicationSupportRoot
            .appendingPathComponent("CodingSources", isDirectory: true)
            .appendingPathComponent(identity.activityID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(identity.fileName)
    }

    public static func loadWorkspaceLink(
        from fileURL: URL,
        fileManager: FileManager = .default
    ) -> CodingWorkspaceLink? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CodingWorkspaceLink.self, from: data)
    }

    public static func leetCodeProblemURL(
        questionID: String?,
        title: String
    ) -> URL? {
        let slug = canonicalSlug(fromQuestionID: questionID, title: title)
        guard !slug.isEmpty, slug != "problem" || questionID != nil else {
            return nil
        }
        return URL(string: "https://leetcode.com/problems/\(slug)/")
    }

    public static func defaultJavaSource(
        title: String,
        problemURL: URL?
    ) -> String {
        var lines = ["/*", " * \(title)"]
        if let problemURL {
            lines.append(" * \(problemURL.absoluteString)")
        }
        lines.append(contentsOf: [
            " *",
            " * Restate the public statement, constraints, and examples here.",
            " * Do not paste Editorial prose into this file.",
            " */",
            "",
            "public class Solution {",
            "}",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    public static func atomicWrite(
        _ text: String,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: [.atomic])
    }

    static func canonicalSlug(fromQuestionID questionID: String?, title: String) -> String {
        if let questionID, let slug = slugFromQuestionID(questionID) {
            return slug
        }
        let fromTitle = slugify(title)
        return fromTitle.isEmpty ? "problem" : fromTitle
    }

    static func problemNumber(fromQuestionID questionID: String?) -> Int? {
        guard let questionID else { return nil }
        let trimmed = questionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.wholeMatch(
            of: /^(\d{1,4})(?:-[a-z0-9-]+)?$/
        ) {
            return Int(match.1)
        }
        return nil
    }

    static func paddedProblemNumber(_ number: Int) -> String {
        String(format: "%04d", number)
    }

    private static func slugFromQuestionID(_ questionID: String) -> String? {
        let trimmed = questionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.wholeMatch(of: /^\d{1,4}-([a-z0-9-]+)$/) {
            return String(match.1)
        }
        if trimmed.wholeMatch(of: /^[a-z0-9]+(?:-[a-z0-9]+)+$/) != nil {
            return trimmed
        }
        return nil
    }

    private static func slugify(_ title: String) -> String {
        let scalars = title.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    private static func existingSolution(
        named fileName: String,
        slug: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
        let exact = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: exact.path) {
            return exact
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let suffix = "-\(slug).java"
        return contents.first { url in
            url.lastPathComponent.hasSuffix(suffix)
        }
    }
}
