import Foundation

public enum CueOnlyHandoffReason: String, Sendable, Equatable {
    case explicitCompletion = "explicit_completion"
    case interviewerClarification = "interviewer_clarification"
    case hintRequest = "hint_request"
}

/// Conservative transcript-boundary policy for the Cue Only turn mode.
///
/// Matching is deliberately terminal and deterministic. The policy does not
/// infer semantic completeness, rewrite transcript evidence, or invoke a
/// provider. Broader endpoint decisions belong to Patient Auto.
public enum CueOnlyHandoffPolicy {
    public static func reason(in transcript: String) -> CueOnlyHandoffReason? {
        let words = canonicalWords(in: transcript)
        guard !words.isEmpty, !endsWithQuotedExample(transcript) else {
            return nil
        }

        if matchesTerminalPhrase(in: words, phrases: completionPhrases) {
            return .explicitCompletion
        }
        if matchesTerminalPhrase(in: words, phrases: clarificationPhrases) {
            return .interviewerClarification
        }
        if matchesTerminalPhrase(in: words, phrases: hintPhrases) {
            return .hintRequest
        }
        return nil
    }

    private static let completionPhrases = [
        ["i", "m", "done"],
        ["i", "am", "done"],
        ["that", "s", "my", "answer"],
        ["that", "is", "my", "answer"],
        ["that", "s", "it"],
        ["that", "is", "it"],
        ["hand", "off"],
        ["your", "turn"],
        ["i", "ll", "hand", "it", "back"],
        ["i", "will", "hand", "it", "back"],
        ["over", "to", "you"],
    ]

    private static let clarificationPhrases = [
        ["can", "you", "clarify", "the", "question"],
        ["could", "you", "clarify", "the", "question"],
        ["would", "you", "clarify", "the", "question"],
        ["can", "you", "repeat", "the", "question"],
        ["could", "you", "repeat", "the", "question"],
        ["would", "you", "repeat", "the", "question"],
        ["what", "do", "you", "mean", "by", "that"],
    ]

    private static let hintPhrases = [
        ["can", "you", "give", "me", "a", "hint"],
        ["could", "you", "give", "me", "a", "hint"],
        ["would", "you", "give", "me", "a", "hint"],
        ["may", "i", "have", "a", "hint"],
        ["can", "you", "help", "me"],
        ["could", "you", "help", "me"],
        ["what", "should", "i", "consider", "next"],
    ]

    private static let attributionWords: Set<String> = [
        "example", "phrase", "quote", "say", "says", "said",
    ]

    private static func matchesTerminalPhrase(
        in words: [String],
        phrases: [[String]]
    ) -> Bool {
        for phrase in phrases where words.count >= phrase.count {
            let start = words.count - phrase.count
            guard Array(words[start...]) == phrase else { continue }
            if start > 0, attributionWords.contains(words[start - 1]) {
                continue
            }
            if start >= 2,
               words[start - 2] == "for",
               words[start - 1] == "example" {
                continue
            }
            return true
        }
        return false
    }

    private static func canonicalWords(in transcript: String) -> [String] {
        let folded = transcript
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty {
            words.append(String(current))
        }
        return words
    }

    private static func endsWithQuotedExample(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ["\"", "”", "’", "»"].contains(last)
    }
}
