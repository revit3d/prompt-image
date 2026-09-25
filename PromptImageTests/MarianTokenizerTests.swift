import Foundation
import Testing
@testable import PromptImage

private final class MarianTokenizerTestBundle {}

struct MarianTokenizerTests {
    private struct Golden: Decodable {
        struct Encoding: Decodable { let text: String; let tokens: [Int32] }
        struct Decoding: Decodable { let text: String; let tokens: [Int32] }
        let cases: [Encoding]
        let decoderCases: [Decoding]
        private enum CodingKeys: String, CodingKey {
            case cases
            case decoderCases = "decoder_cases"
        }
    }

    @Test
    func matchesIndependentTransformersEncodingAndTargetDecoding() throws {
        let tokenizer = try makeTokenizer()
        let bundle = Bundle(for: MarianTokenizerTestBundle.self)
        let url = try #require(bundle.url(forResource: "tokenizer-golden", withExtension: "json"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        #expect(golden.cases.count >= 30)
        #expect(!golden.decoderCases.isEmpty)
        for example in golden.cases {
            #expect(try tokenizer.encode(example.text) == example.tokens)
        }
        for example in golden.decoderCases {
            #expect(try tokenizer.decode(example.tokens) == example.text)
        }
    }

    @Test
    func boundsSourceTokensWithoutSilentlyTruncatingTheDescription() throws {
        let tokenizer = try makeTokenizer()
        #expect(try tokenizer.encode("") == [0])
        let maximum = try tokenizer.encode(String(repeating: "a ", count: 63))
        #expect(maximum.count == 64)
        #expect(maximum.last == 0)
        #expect(throws: MarianTokenizerError.tooManyTokens) {
            try tokenizer.encode(String(repeating: "a ", count: 64))
        }
        #expect(throws: MarianTokenizerError.inputTooLong) {
            try tokenizer.encode(String(repeating: "я", count: 8193))
        }
    }

    @Test
    func rejectsMalformedDecoderIDsAndSkipsAllSpecialTokens() throws {
        let tokenizer = try makeTokenizer()
        #expect(try tokenizer.decode([]) == "")
        #expect(try tokenizer.decode([62517, 0, 1]) == "")
        let invalidSequences: [[Int32]] = [[-1], [62518], Array(repeating: 0, count: 513)]
        for invalid in invalidSequences {
            #expect(throws: MarianTokenizerError.decodingFailed) { try tokenizer.decode(invalid) }
        }
    }

    @Test
    func rejectsAnIncompleteMarianVocabulary() throws {
        let resources = try TranslationModelResources()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = directory.appending(path: "vocab.json")
        try Data(#"{"</s>":0,"<unk>":1,"<pad>":62517}"#.utf8).write(to: vocabulary)
        #expect(throws: MarianTokenizerError.invalidResources) {
            try MarianTokenizer(sourceModelURL: resources.sourceTokenizerURL,
                                targetModelURL: resources.targetTokenizerURL,
                                vocabularyURL: vocabulary)
        }
    }

    private func makeTokenizer() throws -> MarianTokenizer {
        let resources = try TranslationModelResources()
        return try MarianTokenizer(sourceModelURL: resources.sourceTokenizerURL,
                                   targetModelURL: resources.targetTokenizerURL,
                                   vocabularyURL: resources.vocabularyURL)
    }
}
