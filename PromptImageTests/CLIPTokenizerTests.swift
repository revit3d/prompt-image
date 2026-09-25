import Foundation
import Testing
@testable import PromptImage

struct CLIPTokenizerTests {
    @Test
    func tokenIDsMatchTheBundledPythonGoldenExamples() throws {
        let resources = try CLIPModelResources()
        let tokenizer = try CLIPTokenizer(contentsOf: resources.tokenizerURL)
        let artifact = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.tokenizerURL)) as? [String: Any]
        let golden = try #require(artifact?["golden_tokens"] as? [[String: Any]])
        for example in golden {
            let text = try #require(example["text"] as? String)
            let expected = try #require(example["tokens"] as? [Int])
            #expect(try tokenizer.encode(text) == expected.map(Int32.init))
        }
    }

    @Test
    func byteBPEAndCleanupMatchIndependentUnicodeAndHTMLReferences() throws {
        let tokenizer = try CLIPTokenizer(contentsOf: CLIPModelResources().tokenizerURL)
        // Generated independently with the pinned upstream SimpleTokenizer, ftfy
        // 6.3.1 and Python 3.11.16. Prefixes include BOS/EOS; zero padding follows.
        let examples: [(String, [Int32])] = [
            ("Привет, мир! Фото кота на диване", [49406, 26302, 16370, 29503, 110, 22176, 141, 480, 267, 38018, 16701, 141, 478, 256, 38981, 27152, 28599, 27080, 22705, 27080, 140, 112, 29503, 110, 16912, 22705, 140, 369, 49407]),
            ("I can't, you're, we've, she'll, he'd; 123 ٣²", [49406, 328, 753, 713, 267, 592, 982, 267, 649, 1200, 267, 1043, 1342, 267, 797, 1896, 282, 272, 273, 274, 149, 352, 41175, 49407]),
            ("👩🏽‍🍳 cooking 🇷🇺 🏖️", [49406, 18800, 8514, 4244, 37441, 6283, 37902, 1109, 28877, 49407]),
            ("q\u{0307} a\u{0323}\u{0301} क्", [49406, 336, 16384, 157, 118, 350, 136, 479, 22067, 19389, 49407]),
            ("&AMP; &EACUTE; &notit; &notin; &nbsp; &frac12;", [49406, 261, 4166, 126, 361, 585, 282, 17788, 487, 33613, 49407]),
            ("&COPYSR; &LTCC; &LTIMES; &AMPERSAND;", [49406, 5811, 5428, 282, 283, 2021, 282, 283, 47744, 282, 261, 4840, 537, 282, 49407]),
            ("&ZeroWidthSpace;", [49406, 9844, 49407]),
            ("\u{FEFF}\u{1B}[31mred\u{1B}[0m\u{00} car", [49406, 736, 1615, 49407]),
            ("&#169; &#x1F431; &#128;", [49406, 5811, 22979, 6309, 49407]),
            ("Ｕﾀｰﾝ ﬃ ŉ", [49406, 84, 34941, 18584, 367, 1021, 328, 262, 333, 49407]),
            ("<b>&EACUTE;</b> &amp;amp;amp;", [49406, 283, 321, 29, 261, 68, 19734, 26, 34308, 321, 285, 261, 6259, 282, 49407]),
            ("a &lt; b &amp;amp;amp;amp;", [49406, 320, 283, 321, 261, 49407]),
            ("Hello\n<b>&EACUTE;</b>", [49406, 3306, 283, 321, 29, 261, 68, 19734, 26, 34308, 321, 285, 49407]),
            ("<b>\n&EACUTE;", [49406, 283, 321, 285, 261, 68, 19734, 282, 49407]),
            ("\u{200E}שלום\u{200F}", [49406, 31001, 147, 102, 147, 250, 147, 243, 147, 507, 728, 493, 49407]),
            ("Straße İSTANBUL ς Σ", [49406, 1894, 127, 253, 324, 328, 16384, 11231, 139, 480, 139, 481, 49407]),
            ("cafe\u{0301}", [49406, 15304, 49407]),
        ]
        for (text, prefix) in examples {
            #expect(try tokenizer.encode(text) == prefix + Array(repeating: 0, count: 77 - prefix.count))
        }
    }

    @Test
    func truncationPreservesEndTokenAtEveryContextBoundary() throws {
        let tokenizer = try CLIPTokenizer(contentsOf: CLIPModelResources().tokenizerURL)
        for contentCount in [0, 1, 74, 75, 76, 100] {
            let expectedCount = min(contentCount, 75)
            let expected = [Int32(49406)] + Array(repeating: Int32(320), count: expectedCount)
                + [Int32(49407)] + Array(repeating: Int32(0), count: 75 - expectedCount)
            #expect(try tokenizer.encode(String(repeating: "a ", count: contentCount)) == expected)
        }
    }

    @Test
    func malformedEncodingAndOversizedQueriesFailExplicitly() throws {
        let tokenizer = try CLIPTokenizer(contentsOf: CLIPModelResources().tokenizerURL)
        for text in ["bad\u{FFFD}text", "cafÃ©", "â€™", "&#0;", "&#xD800;", "&#1114112;"] {
            #expect(throws: CLIPTokenizerError.unsupportedTextEncoding) {
                try tokenizer.encode(text)
            }
        }
        #expect(throws: CLIPTokenizerError.inputTooLong(maximumUTF8Bytes: 16_384)) {
            try tokenizer.encode(String(repeating: "a", count: 16_385))
        }
        // The limit is UTF-8 bytes, not grapheme count; large Unicode input is bounded too.
        #expect(throws: CLIPTokenizerError.inputTooLong(maximumUTF8Bytes: 16_384)) {
            try tokenizer.encode(String(repeating: "🐱", count: 4097))
        }
    }

    @Test
    func rejectsTokenizerArtifactsWithTheWrongContract() throws {
        let resources = try CLIPModelResources()
        let data = try Data(contentsOf: resources.tokenizerURL)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tokenizer.json")
        let changes: [(String, Any)] = [
            ("schema_version", 2), ("model_id", "different-model"),
            ("context_length", 76), ("start_token", 0), ("padding_token", 1),
            ("pattern", "[a-z]+"), ("merges", [[String]]()),
            ("byte_encoder", [String: String]()),
        ]
        for (key, value) in changes {
            var modified = original
            modified[key] = value
            try JSONSerialization.data(withJSONObject: modified).write(to: url)
            #expect(throws: CLIPTokenizerError.invalidTokenizer) {
                try CLIPTokenizer(contentsOf: url)
            }
        }
    }
}
