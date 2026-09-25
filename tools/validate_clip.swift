// Build with the app's Models/*.swift files; runs the same Swift pipeline on Mac.
import CoreML
import Foundation

private struct Fixtures: Decodable {
    struct ImageCase: Decodable {
        let name: String
        let image_file: String
        let tensor_file: String
        let embedding_file: String
    }
    struct TextCase: Decodable {
        let name: String
        let text: String
        let tokens: [Int32]
        let embedding_file: String
    }
    let images: [ImageCase]
    let texts: [TextCase]
}

@main
struct ValidateCLIP {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw ValidationError.message("Usage: validate-clip MODEL_DIRECTORY FIXTURE_DIRECTORY REPORT_FILE")
        }
        let models = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let manager = FileManager.default
        let working = reportURL.deletingLastPathComponent().appendingPathComponent("clip-validation-\(UUID().uuidString)")
        try manager.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: working) }
        for name in ["CLIPImageEncoder", "CLIPTextEncoder"] {
            let compiled = try await MLModel.compileModel(at: models.appendingPathComponent("\(name).mlpackage"))
            try manager.copyItem(at: compiled, to: working.appendingPathComponent("\(name).mlmodelc"))
            try manager.removeItem(at: compiled)
        }
        for name in ["tokenizer.json", "model-manifest.json", "LICENSE.txt"] {
            try manager.copyItem(at: models.appendingPathComponent(name), to: working.appendingPathComponent(name))
        }
        let resources = try CLIPModelResources(directory: working)
        let engine = CLIPEmbeddingEngine(resources: resources, computeUnits: .cpuOnly)
        let tokenizer = try CLIPTokenizer(contentsOf: resources.tokenizerURL)
        let cases = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtures.appendingPathComponent("validation-manifest.json")))
        var imageResults: [[String: Any]] = []
        var textResults: [[String: Any]] = []
        var imagePairs: [(CLIPEmbedding, CLIPEmbedding)] = []
        var textPairs: [(CLIPEmbedding, CLIPEmbedding)] = []
        var passed = true

        for item in cases.images {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(item.image_file))
            let tensor = try CLIPImagePreprocessor().prepare(data: data)
            let expected = try floats(fixtures.appendingPathComponent(item.tensor_file))
            guard expected.count == tensor.count else { throw ValidationError.message("Invalid reference tensor") }
            let differences = expected.enumerated().map { abs($0.element - tensor[$0.offset].floatValue) }
            let mean = differences.reduce(0, +) / Float(differences.count)
            let maximum = differences.max() ?? 0
            let actual = try await engine.imageEmbedding(data: data)
            let reference = try CLIPEmbedding(rawValues: floats(fixtures.appendingPathComponent(item.embedding_file)), modelID: resources.manifest.modelID)
            let cosine = try actual.cosineSimilarity(to: reference)
            let isJPEG = ["jpg", "jpeg"].contains(URL(fileURLWithPath: item.image_file).pathExtension.lowercased())
            let itemPassed = mean <= (isJPEG ? 0.004 : 0.00001) && maximum <= (isJPEG ? 0.06 : 0.00001) && cosine >= 0.999
            passed = passed && itemPassed
            imageResults.append(["name": item.name, "mean_tensor_error": mean, "max_tensor_error": maximum, "embedding_cosine": cosine, "passed": itemPassed])
            imagePairs.append((actual, reference))
            print("\(item.name): tensor mean \(mean), max \(maximum), cosine \(cosine)")
        }
        for item in cases.texts {
            let tokensMatch = try tokenizer.encode(item.text) == item.tokens
            let actual = try await engine.textEmbedding(item.text)
            let reference = try CLIPEmbedding(rawValues: floats(fixtures.appendingPathComponent(item.embedding_file)), modelID: resources.manifest.modelID)
            let cosine = try actual.cosineSimilarity(to: reference)
            let itemPassed = tokensMatch && cosine >= 0.999
            passed = passed && itemPassed
            textResults.append(["name": item.name, "tokens_match": tokensMatch, "embedding_cosine": cosine, "passed": itemPassed])
            textPairs.append((actual, reference))
        }
        var maximumDrift: Float = 0
        for (image, referenceImage) in imagePairs {
            for (text, referenceText) in textPairs {
                maximumDrift = max(maximumDrift, abs(try image.cosineSimilarity(to: text) - referenceImage.cosineSimilarity(to: referenceText)))
            }
        }
        passed = passed && maximumDrift <= 0.01
        await engine.unload()
        let report: [String: Any] = [
            "passed": passed, "model_id": resources.manifest.modelID, "compute_units": "cpuOnly",
            "images": imageResults, "texts": textResults, "maximum_similarity_drift": maximumDrift,
            "thresholds": ["jpeg_mean_tensor_error": 0.004, "jpeg_max_tensor_error": 0.06, "png_tensor_error": 0.00001, "embedding_cosine": 0.999, "maximum_similarity_drift": 0.01],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        guard passed else { throw ValidationError.message("Swift/Python parity failed; see \(reportURL.path)") }
        print("Swift/Python parity passed; report: \(reportURL.path)")
    }

    private static func floats(_ url: URL) throws -> [Float] {
        let bytes = try Data(contentsOf: url)
        guard bytes.count.isMultiple(of: 4) else { throw ValidationError.message("Invalid Float32 fixture") }
        return bytes.withUnsafeBytes { buffer in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }
}

private enum ValidationError: Error { case message(String) }
