import Foundation

nonisolated enum CLIPTokenizerError: Error, Equatable {
    case invalidTokenizer
    case inputTooLong(maximumUTF8Bytes: Int)
    case unsupportedTextEncoding
}

/// OpenAI CLIP byte-level BPE, including the end token when a query is truncated.
/// Standard Unicode/HTML cleanup is supported; heuristic repair of corrupted text
/// encodings is deliberately not a port of Python's full ftfy implementation.
nonisolated struct CLIPTokenizer: Sendable {
    static let maximumInputUTF8Bytes = 16_384
    private static let contextLength = 77
    private static let startToken: Int32 = 49_406
    private static let endToken: Int32 = 49_407
    private static let expectedPattern = #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#

    private let vocabulary: [String: Int32]
    private let byteEncoder: [String]
    private let mergeRanks: [Pair: Int]
    private let pattern: NSRegularExpression

    init(contentsOf url: URL) throws {
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(contentsOf: url))
        guard artifact.schemaVersion == 1,
              artifact.modelID == "openai-clip-vit-b32-fp16-v2",
              artifact.contextLength == Self.contextLength,
              artifact.startToken == Self.startToken,
              artifact.endToken == Self.endToken,
              artifact.paddingToken == 0,
              artifact.pattern == Self.expectedPattern,
              artifact.vocabulary.count == 49_408,
              Set(artifact.vocabulary.values) == Set(Int32(0)..<49_408),
              artifact.vocabulary["<|startoftext|>"] == Self.startToken,
              artifact.vocabulary["<|endoftext|>"] == Self.endToken,
              artifact.byteEncoder.count == 256,
              artifact.merges.count == 48_894 else {
            throw CLIPTokenizerError.invalidTokenizer
        }

        var bytes = [String]()
        for byte in 0..<256 {
            guard let symbol = artifact.byteEncoder[String(byte)],
                  symbol.unicodeScalars.count == 1,
                  artifact.vocabulary[symbol] != nil,
                  artifact.vocabulary[symbol + "</w>"] != nil else {
                throw CLIPTokenizerError.invalidTokenizer
            }
            bytes.append(symbol)
        }
        guard Set(bytes).count == 256 else { throw CLIPTokenizerError.invalidTokenizer }

        var ranks = [Pair: Int]()
        for (rank, pair) in artifact.merges.enumerated() {
            guard pair.count == 2,
                  artifact.vocabulary[pair[0] + pair[1]] != nil,
                  ranks.updateValue(rank, forKey: Pair(first: pair[0], second: pair[1])) == nil else {
                throw CLIPTokenizerError.invalidTokenizer
            }
        }
        vocabulary = artifact.vocabulary
        byteEncoder = bytes
        mergeRanks = ranks
        pattern = try NSRegularExpression(pattern: artifact.pattern, options: .caseInsensitive)
    }

    func encode(_ text: String) throws -> [Int32] {
        guard text.utf8.count <= Self.maximumInputUTF8Bytes else {
            throw CLIPTokenizerError.inputTooLong(maximumUTF8Bytes: Self.maximumInputUTF8Bytes)
        }
        let cleaned = try CLIPTextCleaner.clean(text)
        var result: [Int32] = [Self.startToken]
        // Cache only within this call: no user text is retained between searches.
        var localCache = [String: [Int32]]()
        for match in pattern.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) {
            guard let range = Range(match.range, in: cleaned) else {
                throw CLIPTokenizerError.invalidTokenizer
            }
            let word = String(cleaned[range])
            let tokens: [Int32]
            if let cached = localCache[word] {
                tokens = cached
            } else {
                tokens = try encodeWord(word)
                localCache[word] = tokens
            }
            result.append(contentsOf: tokens.prefix(Self.contextLength - 1 - result.count))
            if result.count == Self.contextLength - 1 { break }
        }
        result.append(Self.endToken)
        result.append(contentsOf: repeatElement(0, count: Self.contextLength - result.count))
        return result
    }

    private func encodeWord(_ word: String) throws -> [Int32] {
        if word == "<|startoftext|>" { return [Self.startToken] }
        if word == "<|endoftext|>" { return [Self.endToken] }
        // These are individual byte symbols, not Swift extended grapheme clusters.
        var pieces = word.utf8.map { byteEncoder[Int($0)] }
        guard !pieces.isEmpty else { return [] }
        pieces[pieces.count - 1] += "</w>"

        while pieces.count > 1 {
            var bestPair: Pair?
            var bestRank = Int.max
            for index in 0..<(pieces.count - 1) {
                let pair = Pair(first: pieces[index], second: pieces[index + 1])
                if let rank = mergeRanks[pair], rank < bestRank {
                    bestPair = pair
                    bestRank = rank
                }
            }
            guard let pair = bestPair else { break }
            var merged = [String]()
            merged.reserveCapacity(pieces.count)
            var index = 0
            while index < pieces.count {
                if index + 1 < pieces.count,
                   pieces[index] == pair.first, pieces[index + 1] == pair.second {
                    merged.append(pair.first + pair.second)
                    index += 2
                } else {
                    merged.append(pieces[index])
                    index += 1
                }
            }
            pieces = merged
        }
        return try pieces.map {
            guard let token = vocabulary[$0] else { throw CLIPTokenizerError.invalidTokenizer }
            return token
        }
    }

    private struct Pair: Hashable, Sendable {
        let first: String
        let second: String
    }

    private struct Artifact: Decodable {
        let schemaVersion: Int
        let modelID: String
        let contextLength: Int
        let startToken: Int32
        let endToken: Int32
        let paddingToken: Int32
        let vocabulary: [String: Int32]
        let byteEncoder: [String: String]
        let merges: [[String]]
        let pattern: String

        enum CodingKeys: String, CodingKey {
            case vocabulary, merges, pattern
            case schemaVersion = "schema_version"
            case modelID = "model_id"
            case contextLength = "context_length"
            case startToken = "start_token"
            case endToken = "end_token"
            case paddingToken = "padding_token"
            case byteEncoder = "byte_encoder"
        }
    }
}

/// The deterministic portion of CLIP's ftfy + HTML + whitespace cleanup.
/// Character mappings follow ftfy 6.3.1; attribution is in CLIPTextCleaningData.
private nonisolated enum CLIPTextCleaner {
    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    private static let terminalEscape = try! NSRegularExpression(pattern: #"\x1B\[(?:\d|;)*[a-zA-Z]"#)
    private static let strictEntity = try! NSRegularExpression(pattern: #"&#?[0-9A-Za-z]{1,24};"#)
    private static let htmlEntity = try! NSRegularExpression(pattern: #"&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)"#)

    static func clean(_ text: String) throws -> String {
        try rejectCorruptEncoding(text)
        var fixedLines = [String]()
        var decodeEntities = true
        // ftfy disables its automatic HTML decoding from the first line with '<'.
        for line in text.components(separatedBy: "\n") {
            if line.contains("<") { decodeEntities = false }
            var current = line
            while true {
                let previous = current
                if decodeEntities { current = unescape(current, strict: true) }
                try rejectCorruptEncoding(current)
                current = standardFixes(current)
                if current == previous { break }
            }
            fixedLines.append(current)
        }
        var cleaned = fixedLines.joined(separator: "\n")
        cleaned = unescape(unescape(cleaned, strict: false), strict: false)
        try rejectCorruptEncoding(cleaned)
        cleaned = whitespace.stringByReplacingMatches(
            in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: " "
        )
        // All Unicode whitespace has become ASCII spaces. Foundation's broader
        // whitespace CharacterSet would also strip U+200B, unlike Python CLIP.
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ")).lowercased()
    }

    private static func standardFixes(_ text: String) -> String {
        var fixed = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if let mapped = CLIPTextCleaningData.c1Controls[value] {
                fixed += mapped
            } else if let mapped = CLIPTextCleaningData.ligatures[value] {
                fixed += mapped
            } else if value == 0x3000 {
                fixed += " "
            } else if (0xFF01..<0xFFF0).contains(value) {
                fixed += String(scalar).precomposedStringWithCompatibilityMapping
            } else {
                fixed.unicodeScalars.append(scalar)
            }
        }
        var characters = ""
        for scalar in fixed.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x02BC, 0x2018...0x201B: characters += "'"
            case 0x201C...0x201F: characters += "\""
            case 0x0D, 0x0085, 0x2028, 0x2029: characters += "\n"
            default: characters.unicodeScalars.append(scalar)
            }
        }
        characters = terminalEscape.stringByReplacingMatches(
            in: characters, range: NSRange(characters.startIndex..., in: characters), withTemplate: ""
        )
        let kept = characters.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !(value <= 0x08 || value == 0x0B || (0x0E...0x1F).contains(value)
                || value == 0x7F || (0x206A...0x206F).contains(value) || value == 0xFEFF
                || (0xFFF9...0xFFFC).contains(value))
        }
        return String(String.UnicodeScalarView(kept)).precomposedStringWithCanonicalMapping
    }

    private static func unescape(_ text: String, strict: Bool) -> String {
        let expression = strict ? strictEntity : htmlEntity
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = source.substring(with: match.range)
            output += decodeEntity(entity, strict: strict)
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return output
    }

    private static func decodeEntity(_ entity: String, strict: Bool) -> String {
        let name = String(entity.dropFirst())
        if name.hasPrefix("#") {
            var digits = name.dropFirst()
            if digits.last == ";" { digits = digits.dropLast() }
            let radix = digits.first == "x" || digits.first == "X" ? 16 : 10
            if radix == 16 { digits = digits.dropFirst() }
            guard !digits.isEmpty,
                  digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  radix == 16 || digits.allSatisfy({ $0.isNumber }) else { return entity }
            guard let value = UInt32(digits, radix: radix) else { return "\u{FFFD}" }
            if value == 0 || (0xD800...0xDFFF).contains(value) || value > 0x10FFFF { return "\u{FFFD}" }
            if let mapped = CLIPTextCleaningData.c1Controls[value] { return mapped }
            if value <= 0x08 || value == 0x0B || (0x0E...0x1F).contains(value)
                || value == 0x7F || (0xFDD0...0xFDEF).contains(value)
                || value & 0xFFFF == 0xFFFE || value & 0xFFFF == 0xFFFF { return "" }
            guard let scalar = UnicodeScalar(value) else { return "\u{FFFD}" }
            return String(scalar)
        }
        if let replacement = CLIPTextCleaningData.htmlEntities[name] { return replacement }
        if strict {
            return CLIPTextCleaningData.uppercaseEntities[name] ?? entity
        }
        // HTML5 permits some missing semicolons and consumes the longest known prefix.
        for count in stride(from: name.count - 1, through: 2, by: -1) {
            let prefix = String(name.prefix(count))
            if let replacement = CLIPTextCleaningData.htmlEntities[prefix] {
                return replacement + name.dropFirst(count)
            }
        }
        return entity
    }

    private static func rejectCorruptEncoding(_ text: String) throws {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.contains(where: { $0.value == 0xFFFD }) else {
            throw CLIPTokenizerError.unsupportedTextEncoding
        }
        // Catch recognizable UTF-8 bytes decoded as Latin-1/Windows-1252. Full ftfy
        // also repairs other legacy encodings; those heuristics are not implemented.
        let bytes: [UInt8?] = scalars.map { scalar in
            if scalar.value <= 0xFF { return UInt8(scalar.value) }
            return CLIPTextCleaningData.reverseWindows1252[scalar.value]
        }
        for start in bytes.indices {
            guard let first = bytes[start], (0xC2...0xF4).contains(first) else { continue }
            let count = first < 0xE0 ? 2 : (first < 0xF0 ? 3 : 4)
            guard start + count <= bytes.count else { continue }
            let candidate = bytes[start..<(start + count)].compactMap { $0 }
            if candidate.count == count,
               let decoded = String(bytes: candidate, encoding: .utf8),
               decoded.unicodeScalars.count == 1 {
                throw CLIPTokenizerError.unsupportedTextEncoding
            }
        }
    }
}
