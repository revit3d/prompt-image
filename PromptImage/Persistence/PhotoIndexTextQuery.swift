import Foundation

/// Shared bounds and literal whole-word AND parsing for persisted OCR search.
nonisolated enum PhotoIndexTextQuery {
    static let maximumUTF8Bytes = 4_096
    static let maximumTerms = 32

    static func literal(_ query: String) throws -> String? {
        guard query.utf8.prefix(maximumUTF8Bytes + 1).count <= maximumUTF8Bytes else {
            throw PhotoIndexError.invalidInput
        }
        let terms = query.split { !$0.isLetter && !$0.isNumber }
        guard terms.count <= maximumTerms else { throw PhotoIndexError.invalidInput }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " AND ")
    }
}
