import CoreML
import Foundation
import Testing
@testable import PromptImage

struct CLIPModelResourcesTests {
    @Test
    func modelBundleContainsMatchingManifestTokenizerAndLicense() throws {
        let resources = try CLIPModelResources()

        #expect(resources.manifest.schemaVersion == 1)
        #expect(resources.manifest.modelID == "openai-clip-vit-b32-fp16-v2")
        #expect(resources.manifest.embeddingDimension == 512)
        #expect(resources.manifest.contextLength == 77)
        #expect(resources.manifest.imageSize == 224)
        #expect(!resources.manifest.embeddingNormalized)
        let tokenizer = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: resources.tokenizerURL)) as? [String: Any]
        )
        #expect(tokenizer["schema_version"] as? Int == 1)
        #expect(tokenizer["model_id"] as? String == resources.manifest.modelID)
        #expect(tokenizer["context_length"] as? Int == 77)
        #expect(tokenizer["start_token"] as? Int == 49406)
        #expect(tokenizer["end_token"] as? Int == 49407)
        #expect(tokenizer["padding_token"] as? Int == 0)
        let vocabulary = try #require(tokenizer["vocabulary"] as? [String: Int])
        #expect(vocabulary.count == 49408)
        #expect(vocabulary["<|startoftext|>"] == 49406)
        #expect(vocabulary["<|endoftext|>"] == 49407)

        let golden = try #require(tokenizer["golden_tokens"] as? [[String: Any]])
        let expectedPrefixes: [(String, [Int])] = [
            ("", [49406, 49407]),
            ("a photo of a cat", [49406, 320, 1125, 539, 320, 2368, 49407]),
            ("a red car beside a tree", [49406, 320, 736, 1615, 13519, 320, 2677, 49407]),
            ("Recipe: eggs, milk &amp; flour!", [49406, 4614, 281, 7099, 267, 5205, 261, 18592, 256, 49407]),
            ("a cafe\u{301} by the sea — summer ☀️", [49406, 320, 15304, 638, 518, 2102, 2005, 1673, 8219, 49407]),
        ]
        #expect(golden.count == expectedPrefixes.count + 1)
        for (text, prefix) in expectedPrefixes {
            let example = try #require(golden.first { $0["text"] as? String == text })
            let tokens = try #require(example["tokens"] as? [Int])
            #expect(tokens.count == 77)
            #expect(tokens == prefix + Array(repeating: 0, count: 77 - prefix.count))
        }
        let longExample = try #require(golden.first { $0["text"] as? String == String(repeating: "a photo ", count: 100) })
        let longTokens = try #require(longExample["tokens"] as? [Int])
        let truncatedContent = (0..<75).map { $0.isMultiple(of: 2) ? 320 : 1125 }
        #expect(longTokens.count == 77)
        #expect(longTokens == [49406] + truncatedContent + [49407])
        let license = try String(contentsOf: resources.licenseURL, encoding: .utf8)
        #expect(license.contains("MIT License"))
        #expect(license.contains("OpenAI"))
    }

    @Test
    func compiledEncodersLoadOnCPUAndExposeTheExpectedTensorContract() throws {
        let resources = try CLIPModelResources()

        // Load one encoder at a time to avoid holding both sets of weights during this check.
        for encoder in CLIPEncoder.allCases {
            try autoreleasepool {
                let model = try resources.loadEncoder(encoder, computeUnits: .cpuOnly)
                let inputName = encoder == .image ? "image" : "tokens"
                let expectedShape = encoder == .image ? [1, 3, 224, 224] : [1, 77]
                let expectedType: MLMultiArrayDataType = encoder == .image ? .float32 : .int32

                #expect(Set(model.modelDescription.inputDescriptionsByName.keys) == [inputName])
                #expect(Set(model.modelDescription.outputDescriptionsByName.keys) == ["embedding"])
                let input = try #require(model.modelDescription.inputDescriptionsByName[inputName])
                let inputArray = try #require(input.multiArrayConstraint)
                #expect(inputArray.shape.map(\.intValue) == expectedShape)
                #expect(inputArray.dataType == expectedType)
                let output = try #require(model.modelDescription.outputDescriptionsByName["embedding"])
                let outputArray = try #require(output.multiArrayConstraint)
                #expect(outputArray.shape.map(\.intValue) == [1, 512])
                #expect(outputArray.dataType == .float32)
            }
        }
    }
}
