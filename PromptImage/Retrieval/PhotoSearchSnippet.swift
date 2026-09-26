import Foundation

/// A small, presentation-only excerpt of an OCR result, never a second search engine.
/// Matches complete letter/number tokens from the original query; it does not stem,
/// translate, or interpret operators. SQLite remains authoritative for retrieval.
nonisolated struct PhotoSearchSnippet: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let text: String
        let isMatch: Bool
    }

    static let maximumCharacters = 200

    let text: String
    let segments: [Segment]

    /// Shows the first matching token and nearby context. Other query terms may be
    /// outside the excerpt. Call once per accepted result, rather than per render.
    static func make(recognizedText: String, query: String) -> Self? {
        guard (try? PhotoIndexTextQuery.literal(query)) != nil else { return nil }
        let terms = Set(query.split { !$0.isLetter && !$0.isNumber }.map { folded($0) })
        guard !terms.isEmpty else { return nil }

        var cursor = recognizedText.startIndex
        var firstMatch: Range<String.Index>?
        while let token = nextToken(in: recognizedText, cursor: &cursor) {
            if terms.contains(folded(recognizedText[token])) {
                firstMatch = token
                break
            }
        }
        guard let firstMatch else { return nil }

        var start = recognizedText.index(firstMatch.lowerBound, offsetBy: -24,
                                         limitedBy: recognizedText.startIndex)
            ?? recognizedText.startIndex
        // Avoid a chopped context word at the beginning.
        while start > recognizedText.startIndex, start < firstMatch.lowerBound,
              isToken(recognizedText[start]),
              isToken(recognizedText[recognizedText.index(before: start)]) {
            recognizedText.formIndex(after: &start)
        }
        // Reserve room for both omission markers, including their separating spaces.
        var end = recognizedText.index(start, offsetBy: maximumCharacters - 4,
                                       limitedBy: recognizedText.endIndex)
            ?? recognizedText.endIndex
        if firstMatch.upperBound <= end {
            while end < recognizedText.endIndex, end > firstMatch.upperBound,
                  isToken(recognizedText[end]),
                  isToken(recognizedText[recognizedText.index(before: end)]) {
                recognizedText.formIndex(before: &end)
            }
        }

        var pieces: [(Substring, Bool)] = []
        var position = start
        cursor = firstMatch.lowerBound
        while cursor < end, let token = nextToken(in: recognizedText, cursor: &cursor),
              token.lowerBound < end {
            let tokenEnd = min(token.upperBound, end)
            if terms.contains(folded(recognizedText[token])) {
                if position < token.lowerBound {
                    pieces.append((recognizedText[position..<token.lowerBound], false))
                }
                pieces.append((recognizedText[token.lowerBound..<tokenEnd], true))
                position = tokenEnd
            }
        }
        if position < end { pieces.append((recognizedText[position..<end], false)) }

        var segments: [Segment] = []
        var pendingSpace = false
        func append(_ character: Character, isMatch: Bool) {
            if character.isWhitespace {
                pendingSpace = !segments.isEmpty
                return
            }
            if pendingSpace {
                add(" ", isMatch: false)
                pendingSpace = false
            }
            add(String(character), isMatch: isMatch)
        }
        func add(_ text: String, isMatch: Bool) {
            if let last = segments.last, last.isMatch == isMatch {
                segments[segments.count - 1] = Segment(text: last.text + text, isMatch: isMatch)
            } else {
                segments.append(Segment(text: text, isMatch: isMatch))
            }
        }
        if start > recognizedText.startIndex {
            append("…", isMatch: false)
            append(" ", isMatch: false)
        }
        for (piece, isMatch) in pieces {
            for character in piece { append(character, isMatch: isMatch) }
        }
        if end < recognizedText.endIndex {
            append(" ", isMatch: false)
            append("…", isMatch: false)
        }
        return Self(text: segments.map(\.text).joined(), segments: segments)
    }

    private static func isToken(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func nextToken(in text: String, cursor: inout String.Index)
        -> Range<String.Index>? {
        while cursor < text.endIndex, !isToken(text[cursor]) { text.formIndex(after: &cursor) }
        guard cursor < text.endIndex else { return nil }
        let start = cursor
        while cursor < text.endIndex, isToken(text[cursor]) { text.formIndex(after: &cursor) }
        return start..<cursor
    }

    private static func folded(_ token: Substring) -> String {
        // unicode61 removes common Latin accents, but keeps Cyrillic е/ё distinct.
        // Do not use global .diacriticInsensitive, which would conflate those letters.
        // This is intentionally conservative for uncommon Unicode forms: Foundation
        // and SQLite's Unicode 6.1 tables are not identical. A missing excerpt must
        // never remove a result that SQLite returned.
        let lowercase = token.lowercased()
        // Most OCR tokens need only case folding. Avoid allocating a decomposed
        // string per character while scanning a long Latin/Cyrillic document.
        guard lowercase.unicodeScalars.contains(where: {
            (0x00C0...0x024F).contains($0.value)
                || (0x0300...0x036F).contains($0.value)
                || (0x1E00...0x1EFF).contains($0.value)
        }) else { return lowercase }
        var result = ""
        for character in lowercase {
            let decomposed = String(character).decomposedStringWithCanonicalMapping
            let scalars = decomposed.unicodeScalars
            if let first = scalars.first,
               (97...122).contains(first.value), scalars.count == 2,
               scalars.dropFirst().allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) {
                result.unicodeScalars.append(first)
            } else {
                result.append(character)
            }
        }
        return result
    }
}
