import CoreML
import Darwin
import Foundation
import ImageIO
import Testing
@testable import PromptImage

private final class CLIPFixtureBundleToken {}

nonisolated private struct ValidationFixtures: Decodable {
    let images: [ImageCase]
    let texts: [TextCase]

    struct ImageCase: Decodable {
        let name: String
        let image_file: String
        let tensor_file: String
        let embedding_file: String
        let raw_size: [Int]
        let decoded_rgb_file: String?
    }

    struct TextCase: Decodable {
        let name: String
        let text: String
        let tokens: [Int32]
        let embedding_file: String
    }
}

@Suite(.serialized)
struct CLIPInferenceTests {
    private func fixtures() throws -> (URL, ValidationFixtures) {
        let bundle = Bundle(for: CLIPFixtureBundleToken.self)
        let directory = try #require(bundle.url(forResource: "CLIPValidation", withExtension: nil))
        let cases = try JSONDecoder().decode(
            ValidationFixtures.self,
            from: Data(contentsOf: directory.appendingPathComponent("validation-manifest.json"))
        )
        return (directory, cases)
    }

    private func floats(_ url: URL) throws -> [Float] {
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count.isMultiple(of: 4))
        return bytes.withUnsafeBytes { buffer in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }

    @Test
    func preprocessingAndInferenceMatchIndependentPythonReferences() async throws {
        let (directory, cases) = try fixtures()
        #expect(Set(cases.images.map(\.name)).isSuperset(of: ["cmyk-resize", "cmyk-no-resize"]),
                "Validation fixtures must include CMYK resize-order and decode-inversion coverage")
        let resources = try CLIPModelResources()
        let tokenizer = try CLIPTokenizer(contentsOf: resources.tokenizerURL)
        let engine = CLIPEmbeddingEngine(resources: resources, computeUnits: .cpuOnly)
        var imagePairs: [(CLIPEmbedding, CLIPEmbedding)] = []
        var textPairs: [(CLIPEmbedding, CLIPEmbedding)] = []

        for item in cases.images {
            let data = try Data(contentsOf: directory.appendingPathComponent(item.image_file))
            let tensor = try CLIPImagePreprocessor().prepare(data: data)
            let expected = try floats(directory.appendingPathComponent(item.tensor_file))
            try #require(expected.count == tensor.count)
            let differences = expected.enumerated().map { abs($0.element - tensor[$0.offset].floatValue) }
            let meanError = differences.reduce(0, +) / Float(differences.count)
            let maxError = differences.max() ?? 0
            let byteScales = [0.26862954, 0.26130258, 0.27577711].map { $0 * 255 }
            var byteErrorTotal = 0.0
            for (index, difference) in differences.enumerated() {
                byteErrorTotal += Double(difference) * byteScales[index / (224 * 224)]
            }
            let meanByteError = byteErrorTotal / Double(differences.count)
            let actual = try await engine.imageEmbedding(data: data)
            let reference = try CLIPEmbedding(
                rawValues: floats(directory.appendingPathComponent(item.embedding_file)),
                modelID: resources.manifest.modelID
            )
            let cosine = try actual.cosineSimilarity(to: reference)
            print("CLIP_IMAGE_PARITY \(item.name) mean=\(meanError) max=\(maxError) mean_byte=\(meanByteError) cosine=\(cosine)")
            let isJPEG = ["jpg", "jpeg"].contains(URL(fileURLWithPath: item.image_file).pathExtension.lowercased())
            // ImageIO and Pillow use different JPEG decoders; PNG should match exactly.
            #if targetEnvironment(simulator)
            #expect(meanError <= (isJPEG ? 0.004 : 0.00001), "\(item.name): preprocessing mean error")
            #else
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let sourceColorModel = properties?[kCGImagePropertyColorModel] as? String
            if isJPEG && sourceColorModel == kCGImagePropertyColorModelRGB as String {
                // Physical ImageIO's RGB JPEG decoding differs by about half a byte
                // on the fixed 4:4:4 fixture. Bound this in 8-bit channel units, while
                // retaining maximum-error, embedding, and similarity-drift checks.
                #expect(meanByteError <= 1, "\(item.name): mean error must stay within one RGB code value")
            } else {
                #expect(meanError <= (isJPEG ? 0.004 : 0.00001), "\(item.name): preprocessing mean error")
            }
            #endif
            #expect(maxError <= (isJPEG ? 0.06 : 0.00001), "\(item.name): preprocessing maximum error")
            #expect(cosine >= 0.999, "\(item.name): image embedding agreement")
            imagePairs.append((actual, reference))
        }
        for item in cases.texts {
            #expect(try tokenizer.encode(item.text) == item.tokens, "\(item.name): exact token IDs")
            let actual = try await engine.textEmbedding(item.text)
            let reference = try CLIPEmbedding(
                rawValues: floats(directory.appendingPathComponent(item.embedding_file)),
                modelID: resources.manifest.modelID
            )
            #expect(try actual.cosineSimilarity(to: reference) >= 0.999, "\(item.name): text embedding agreement")
            textPairs.append((actual, reference))
        }
        var maximumDrift: Float = 0
        for (actualImage, referenceImage) in imagePairs {
            for (actualText, referenceText) in textPairs {
                let drift = abs(try actualImage.cosineSimilarity(to: actualText) - referenceImage.cosineSimilarity(to: referenceText))
                maximumDrift = max(maximumDrift, drift)
            }
        }
        print("CLIP_SIMILARITY_DRIFT \(maximumDrift)")
        #expect(maximumDrift <= 0.01)
        await engine.unload()
    }

    @Test
    func imageIODecodedRGBStaysWithinOneByteOfPillow() throws {
        let (directory, cases) = try fixtures()
        let item = try #require(cases.images.first { $0.name == "orientation-1" })
        let referenceFile = try #require(item.decoded_rgb_file)
        let expected = try Data(contentsOf: directory.appendingPathComponent(referenceFile))
        let encoded = try Data(contentsOf: directory.appendingPathComponent(item.image_file))
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(image.bitsPerComponent == 8 && image.colorSpace?.model == .rgb)
        try #require(item.raw_size == [image.width, image.height])
        try #require(expected.count == image.width * image.height * 3)
        let bytes = try #require(image.dataProvider?.data) as Data
        let pixelBytes = image.bitsPerPixel / 8
        let start: Int
        switch image.alphaInfo {
        case .none:
            try #require(pixelBytes == 3)
            start = 0
        case .noneSkipLast, .last, .premultipliedLast:
            try #require(pixelBytes == 4)
            start = 0
        case .noneSkipFirst, .first, .premultipliedFirst:
            try #require(pixelBytes == 4)
            start = 1
        default:
            throw CLIPImagePreprocessingError.unsupportedPixelFormat
        }
        let reversed = pixelBytes == 4 && image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        var totals = [Double](repeating: 0, count: 3)
        var maxima = [Int](repeating: 0, count: 3)
        for y in 0..<image.height {
            for x in 0..<image.width {
                for channel in 0..<3 {
                    let storageIndex = reversed ? pixelBytes - 1 - start - channel : start + channel
                    let actual = Int(bytes[y * image.bytesPerRow + x * pixelBytes + storageIndex])
                    let reference = Int(expected[(y * image.width + x) * 3 + channel])
                    let difference = abs(actual - reference)
                    totals[channel] += Double(difference)
                    maxima[channel] = max(maxima[channel], difference)
                }
            }
        }
        let means = totals.map { $0 / Double(image.width * image.height) }
        let mean = means.reduce(0, +) / 3
        print("CLIP_JPEG_DECODE_PARITY mean_byte=\(mean) channel_means=\(means) channel_maxima=\(maxima)")
        #expect(mean <= 1, "Native RGB JPEG decode must average at most one 8-bit code value from Pillow")
    }

    @Test
    func queuedCancellationAndUnloadingPreserveEngineUsability() async throws {
        let engine = CLIPEmbeddingEngine(resources: try CLIPModelResources(), computeUnits: .cpuOnly)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.textEmbedding("a photo of a cat")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let before = try await engine.textEmbedding("a photo of a cat")
        await engine.unload()
        let after = try await engine.textEmbedding("a photo of a cat")
        #expect(try before.cosineSimilarity(to: after) > 0.99999)
        await engine.unload()
    }

    /// Run this test alone in Release on the phone for useful hardware measurements.
    #if !targetEnvironment(simulator)
    @Test
    func measuresColdAndWarmInferenceOnCurrentHardware() async throws {
        let (directory, cases) = try fixtures()
        let fixture = try #require(cases.images.first { $0.name == "high-resolution" })
        let textFixture = try #require(cases.texts.first { $0.name == "text-cat" })
        let data = try Data(contentsOf: directory.appendingPathComponent(fixture.image_file))
        let resources = try CLIPModelResources()
        let imageReference = try CLIPEmbedding(rawValues: floats(directory.appendingPathComponent(fixture.embedding_file)), modelID: resources.manifest.modelID)
        let textReference = try CLIPEmbedding(rawValues: floats(directory.appendingPathComponent(textFixture.embedding_file)), modelID: resources.manifest.modelID)
        let engine = CLIPEmbeddingEngine(resources: resources, computeUnits: .all)
        let baseline = Self.residentBytes()
        let sampler = Task.detached(priority: .utility) {
            var peak = Self.residentBytes()
            while !Task.isCancelled {
                peak = max(peak, Self.residentBytes())
                try? await Task.sleep(for: .milliseconds(10))
            }
            return peak
        }
        defer { sampler.cancel() }
        var imageTimes: [Double] = []
        var textTimes: [Double] = []
        for _ in 0..<6 {
            var start = ContinuousClock.now
            let image = try await engine.imageEmbedding(data: data)
            imageTimes.append(Self.milliseconds(start.duration(to: .now)))
            start = .now
            let text = try await engine.textEmbedding(textFixture.text)
            textTimes.append(Self.milliseconds(start.duration(to: .now)))
            #expect(image.values.count == 512 && text.values.count == 512)
            #expect(image.values.allSatisfy { $0.isFinite } && text.values.allSatisfy { $0.isFinite })
            #expect(try image.cosineSimilarity(to: imageReference) >= 0.999)
            #expect(try text.cosineSimilarity(to: textReference) >= 0.999)
            #expect(abs(try image.cosineSimilarity(to: text) - imageReference.cosineSimilarity(to: textReference)) <= 0.01)
        }
        sampler.cancel()
        let peak = await sampler.value
        await engine.unload()
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "physical-device"
        #endif
        let report: [String: Any] = [
            "environment": environment, "compute_units": "all", "fixture": fixture.name,
            "image_cold_ms": imageTimes[0], "image_warm_ms": Array(imageTimes.dropFirst()),
            "text_cold_ms": textTimes[0], "text_warm_ms": Array(textTimes.dropFirst()),
            "baseline_resident_bytes": baseline, "sampled_peak_resident_bytes": peak,
            "after_unload_resident_bytes": Self.residentBytes(),
            "memory_sample_interval_ms": 10,
            "note": "Whole test process RSS; sampled peak, not guaranteed transient peak. Time includes preprocessing/loading/normalization. First call may use OS caches.",
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CLIP_BENCHMARK \(String(decoding: json, as: UTF8.self))")
    }
    #endif

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
