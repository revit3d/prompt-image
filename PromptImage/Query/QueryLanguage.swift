import Foundation
import NaturalLanguage

nonisolated enum QueryLanguageChoice: String, CaseIterable, Sendable {
    case automatic
    case russian
    case english
}

nonisolated enum QueryLanguage: String, Sendable, Equatable {
    case russian = "ru"
    case english = "en"
}

nonisolated struct QueryRoute: Sendable, Equatable {
    /// Preserve the exact query for a future OCR search, including its original language.
    let originalText: String
    let text: String
    let language: QueryLanguage
}

nonisolated enum QueryInputError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case ambiguousLanguage
    case unsupportedLanguage
}

/// Local language identification without language hints, query retention, or logging.
/// Explicit choices are assertions by the user and bypass automatic identification.
nonisolated struct QueryLanguageRouter: Sendable {
    static let maximumUTF8Bytes = 16_384

    private let detect: @Sendable (String) -> [NLLanguage: Double]

    init() {
        detect = { Self.languageHypotheses($0) }
    }

    /// Injection keeps confidence and unsupported-language tests independent of OS models.
    init(detector: @escaping @Sendable (String) -> [NLLanguage: Double]) {
        detect = detector
    }

    func route(_ text: String, choice: QueryLanguageChoice = .automatic) throws -> QueryRoute {
        // Bound work before trimming, and count bytes rather than graphemes, like CLIPTokenizer.
        guard text.utf8.prefix(Self.maximumUTF8Bytes + 1).count <= Self.maximumUTF8Bytes else {
            throw QueryInputError.tooLong
        }
        let prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.isEmpty else { throw QueryInputError.empty }

        let language: QueryLanguage
        switch choice {
        case .russian:
            language = .russian
        case .english:
            language = .english
        case .automatic:
            language = try identify(prepared)
        }
        return QueryRoute(originalText: text, text: prepared, language: language)
    }

    private func identify(_ text: String) throws -> QueryLanguage {
        let letters = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                return true
            default:
                // Ignore punctuation and combining marks for script identification;
                // decomposed accents must not change the routing decision.
                return false
            }
        }))
        // Very short words, numbers, and emoji do not provide dependable language evidence.
        guard letters.unicodeScalars.count >= 4 else { throw QueryInputError.ambiguousLanguage }

        let isLatin = letters.range(of: #"^\p{Latin}+$"#, options: .regularExpression) != nil
        let isCyrillic = letters.range(of: #"^\p{Cyrillic}+$"#, options: .regularExpression) != nil
        if !isLatin && !isCyrillic {
            let isMixed = letters.range(of: #"^[\p{Latin}\p{Cyrillic}]+$"#, options: .regularExpression) != nil
            // Mixed RU/EN descriptions need an explicit choice. A dominant script alone
            // cannot tell whether untranslated words are a product name or important text.
            throw isMixed ? QueryInputError.ambiguousLanguage : QueryInputError.unsupportedLanguage
        }

        let candidates = detect(text).filter { $0.value.isFinite && (0...1).contains($0.value) }
            .sorted { $0.value > $1.value }
        guard let best = candidates.first,
              best.value >= 0.8,
              best.value - (candidates.dropFirst().first?.value ?? 0) >= 0.2 else {
            throw QueryInputError.ambiguousLanguage
        }

        switch best.key {
        case .russian where isCyrillic:
            return .russian
        case .english where isLatin:
            return .english
        case .undetermined:
            throw QueryInputError.ambiguousLanguage
        case .russian, .english:
            // Do not accept an implausible recognizer result for the other script.
            throw QueryInputError.ambiguousLanguage
        default:
            // Cyrillic also includes Ukrainian/Bulgarian/etc.; Latin includes many
            // languages besides English. Neither script is itself a language choice.
            throw QueryInputError.unsupportedLanguage
        }
    }

    private static func languageHypotheses(_ text: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 5)
    }
}
