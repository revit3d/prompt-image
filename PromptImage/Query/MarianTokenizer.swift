import Foundation
import SentencePieceRuntime

nonisolated enum MarianTokenizerError: Error, Equatable {
    case invalidResources
    case inputTooLong
    case tooManyTokens
    case encodingFailed
    case decodingFailed
}

/// Actor-owned wrapper around official SentencePiece 0.2.1. It deliberately maps
/// piece strings through Marian's shared vocabulary: SentencePiece's own IDs are
/// different from the model IDs. No sampling, logging, or query cache is enabled.
nonisolated final class MarianTokenizer {
    static let endToken: Int32 = 0
    static let unknownToken: Int32 = 1
    static let paddingToken: Int32 = 62_517
    static let maximumSourceTokens = 64

    private let source: OpaquePointer
    private let target: OpaquePointer
    private let vocabulary: [String: Int32]
    private let inverseVocabulary: [String]
    private let specialTokens: Set<Int32> = [endToken, unknownToken, paddingToken]
    private static let specials = try! NSRegularExpression(pattern: #"</s>|<unk>|<pad>"#)
    // Python's default dot excludes only LF, while ICU's dot excludes additional
    // Unicode line separators. Spell out LF to match the pinned Python regex.
    private static let languageCode = try! NSRegularExpression(pattern: #">>[^\n]+<<"#)

    init(sourceModelURL: URL, targetModelURL: URL, vocabularyURL: URL) throws {
        // Artifact preparation verifies checksums; also reject malformed vocabularies
        // rather than indexing model output into an incomplete/reordered mapping.
        for url in [sourceModelURL, targetModelURL, vocabularyURL] {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...16_777_216).contains(size) else { throw MarianTokenizerError.invalidResources }
        }
        let vocabulary = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabularyURL))
        guard vocabulary.count == 62_518,
              vocabulary["</s>"] == Self.endToken,
              vocabulary["<unk>"] == Self.unknownToken,
              vocabulary["<pad>"] == Self.paddingToken,
              Set(vocabulary.values) == Set(Int32(0)...Self.paddingToken) else {
            throw MarianTokenizerError.invalidResources
        }
        var inverse = Array(repeating: "", count: vocabulary.count)
        for (piece, id) in vocabulary { inverse[Int(id)] = piece }
        self.vocabulary = vocabulary
        inverseVocabulary = inverse
        source = try Self.load(sourceModelURL)
        do {
            target = try Self.load(targetModelURL)
        } catch {
            sp_runtime_destroy(source)
            throw error
        }
    }

    deinit {
        sp_runtime_destroy(source)
        sp_runtime_destroy(target)
    }

    /// Matches Transformers 4.51.3 MarianTokenizer(text), including literal special
    /// tokens and its language-code handling. Its optional normalize() method is
    /// NOT invoked by tokenizer(text); applying Moses punctuation rules here would
    /// change the reference IDs. SentencePiece performs its embedded normalization.
    func encode(_ text: String) throws -> [Int32] {
        try Task.checkCancellation()
        guard text.utf8.prefix(16_385).count <= 16_384 else { throw MarianTokenizerError.inputTooLong }
        let input = text as NSString
        var result: [Int32] = []
        var cursor = 0
        let matches = Self.specials.matches(in: text, range: NSRange(location: 0, length: input.length))
        for match in matches {
            if cursor < match.range.location {
                result += try encodeOrdinaryText(input.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            guard let id = vocabulary[input.substring(with: match.range)] else {
                throw MarianTokenizerError.invalidResources
            }
            result.append(id)
            guard result.count < Self.maximumSourceTokens else { throw MarianTokenizerError.tooManyTokens }
            cursor = NSMaxRange(match.range)
        }
        if cursor < input.length {
            result += try encodeOrdinaryText(input.substring(from: cursor))
        }
        guard result.count < Self.maximumSourceTokens else { throw MarianTokenizerError.tooManyTokens }
        result.append(Self.endToken)
        try Task.checkCancellation()
        return result
    }

    /// Matches target-tokenizer decoding with skip_special_tokens=true and
    /// clean_up_tokenization_spaces=false; unknown, PAD, and EOS IDs are omitted.
    func decode(_ ids: [Int32]) throws -> String {
        try Task.checkCancellation()
        guard ids.count <= 512, ids.allSatisfy({ (0...Self.paddingToken).contains($0) }) else {
            throw MarianTokenizerError.decodingFailed
        }
        guard let pieces = sp_runtime_pieces_create() else { throw MarianTokenizerError.decodingFailed }
        defer { sp_runtime_pieces_destroy(pieces) }
        for id in ids where !specialTokens.contains(id) {
            let bytes = Array(inverseVocabulary[Int(id)].utf8)
            let success = bytes.withUnsafeBufferPointer {
                sp_runtime_pieces_append(pieces, $0.baseAddress, $0.count)
            }
            guard success == 1 else { throw MarianTokenizerError.decodingFailed }
        }
        var length = 0
        var error: UnsafeMutablePointer<CChar>?
        let decoded = sp_runtime_decode(target, pieces, &length, &error)
        defer { sp_runtime_free(error); sp_runtime_free(decoded) }
        guard let decoded else { throw MarianTokenizerError.decodingFailed }
        let text = String(decoding: UnsafeBufferPointer(start: decoded, count: length), as: UTF8.self)
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return text
    }

    private func encodeOrdinaryText(_ text: String) throws -> [Int32] {
        try Task.checkCancellation()
        let range = NSRange(text.startIndex..., in: text)
        // Python re.match adds one initial greedy language-code token, whereas
        // re.sub removes every match. Preserve that unusual upstream behavior.
        let first = Self.languageCode.firstMatch(in: text, range: range)
        let prefix = first.flatMap { $0.range.location == 0 ? (text as NSString).substring(with: $0.range) : nil }
        let stripped = Self.languageCode.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let bytes = Array(stripped.utf8)
        var error: UnsafeMutablePointer<CChar>?
        let encoded = bytes.withUnsafeBufferPointer {
            sp_runtime_encode(source, $0.baseAddress, $0.count, &error)
        }
        defer { sp_runtime_free(error) }
        guard let encoded else { throw MarianTokenizerError.encodingFailed }
        defer { sp_runtime_pieces_destroy(encoded) }
        var ids: [Int32] = prefix.map { [vocabulary[$0] ?? Self.unknownToken] } ?? []
        let count = sp_runtime_piece_count(encoded)
        guard count + ids.count < Self.maximumSourceTokens else { throw MarianTokenizerError.tooManyTokens }
        for index in 0..<count {
            var length = 0
            guard let pointer = sp_runtime_piece(encoded, index, &length) else { throw MarianTokenizerError.encodingFailed }
            let piece = String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
            ids.append(vocabulary[piece] ?? Self.unknownToken)
        }
        return ids
    }

    private static func load(_ url: URL) throws -> OpaquePointer {
        var error: UnsafeMutablePointer<CChar>?
        let result = url.path.withCString { sp_runtime_create($0, &error) }
        defer { sp_runtime_free(error) }
        guard let result else { throw MarianTokenizerError.invalidResources }
        return result
    }
}
