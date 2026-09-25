import CoreML
import Darwin
import Foundation
import Testing
@testable import PromptImage

private final class BundledTranslationFixtureToken {}

nonisolated private struct TranslationReferences: Decodable {
    let schema_version: Int
    let model_id: String
    let cases: [Example]

    struct Example: Decodable {
        let id: String
        let russian: String
        let manual_english: String
        let source_tokens: [Int32]
        let generated_tokens: [Int32]
        let translation: String
    }
}

/// These fixtures contain fixed public examples, never the user's photo library
/// or queries. Serialize inference checks to keep their memory use bounded.
@Suite(.serialized)
struct BundledTranslationTests {
    private func references() throws -> TranslationReferences {
        let bundle = Bundle(for: BundledTranslationFixtureToken.self)
        let url = try #require(bundle.url(forResource: "translation-reference", withExtension: "json"))
        let references = try JSONDecoder().decode(TranslationReferences.self, from: Data(contentsOf: url))
        try #require(references.schema_version == 1)
        try #require(references.cases.count == 10)
        try #require(Set(references.cases.map(\.id)).count == references.cases.count)
        return references
    }

    @Test
    func bundledResourcesDeclareMatchingLanguagePairAndGenerationContract() async throws {
        let references = try references()
        let resources = try TranslationModelResources()
        let manifest = resources.manifest
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.modelID == "helsinki-opus-mt-ru-en-fp16-v1")
        #expect(manifest.modelID == references.model_id)
        #expect(manifest.sourceLanguages == ["ru"])
        #expect(manifest.targetLanguage == "en")
        #expect(manifest.maximumSourceTokens == 64)
        #expect(manifest.maximumDecoderTokens == 64)
        #expect(manifest.vocabularySize == 62_518)
        #expect(manifest.hiddenSize == 512)
        #expect(manifest.eosTokenID == 0)
        #expect(manifest.padTokenID == 62_517)
        #expect(manifest.decoderStartTokenID == manifest.padTokenID)
        for url in [resources.encoderURL, resources.decoderURL] {
            #expect(url.pathExtension == "mlmodelc")
            let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
            #expect(!files.isEmpty)
        }
        let license = try String(contentsOf: resources.licenseURL, encoding: .utf8)
        #expect(license.contains("Creative Commons"))
        let engine = BundledTranslationEngine(resources: resources, computeUnits: .cpuOnly)
        #expect(await engine.availability() == .ready)
        await engine.unload()
    }

    @Test
    func cpuTranslationsMatchIndependentPythonReferences() async throws {
        let references = try references()
        let resources = try TranslationModelResources()
        let tokenizer = try MarianTokenizer(
            sourceModelURL: resources.sourceTokenizerURL,
            targetModelURL: resources.targetTokenizerURL,
            vocabularyURL: resources.vocabularyURL
        )
        let engine = BundledTranslationEngine(resources: resources, computeUnits: .cpuOnly)
        for example in references.cases {
            #expect(try tokenizer.encode(example.russian) == example.source_tokens, "\(example.id): source tokens")
            #expect(example.source_tokens.last == resources.manifest.eosTokenID)
            #expect(example.source_tokens.count <= resources.manifest.maximumSourceTokens)
            #expect(example.generated_tokens.last == resources.manifest.eosTokenID)
            #expect(example.generated_tokens.count < resources.manifest.maximumDecoderTokens)
            #expect(try tokenizer.decode(example.generated_tokens) == example.translation, "\(example.id): reference decode")
            let translated = try await engine.translate(example.russian, from: "ru", to: "en")
            #expect(translated == example.translation, "\(example.id): Core ML CPU versus Python greedy generation")
            print("BUNDLED_TRANSLATION_PARITY id=\(example.id) matches=\(translated == example.translation)")
        }
        await engine.unload()
    }

    @Test
    func invalidInputsUnsupportedPairsAndPreflightCancellationAreRejected() async throws {
        let engine = BundledTranslationEngine(resources: try TranslationModelResources(), computeUnits: .cpuOnly)
        for (source, target) in [("en", "ru"), ("uk", "en"), ("ru", "ru")] {
            await #expect(throws: QueryTranslationError.unsupportedLanguagePair) {
                try await engine.translate("кот на диване", from: source, to: target)
            }
        }
        for text in ["", " \n\t "] {
            await #expect(throws: QueryTranslationError.invalidTranslation) {
                try await engine.translate(text, from: "ru", to: "en")
            }
        }
        // The public reference maps "кот" to two content tokens. Repetition
        // exceeds the 63-token content budget while staying below the byte cap.
        await #expect(throws: QueryTranslationError.inputTooLong) {
            try await engine.translate(String(repeating: "кот ", count: 64), from: "ru", to: "en")
        }
        await #expect(throws: QueryTranslationError.inputTooLong) {
            try await engine.translate(String(repeating: "я", count: 8_193), from: "ru", to: "en")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.translate("кот на диване", from: "ru", to: "en")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await engine.unload()
    }

    @Test
    func unloadingAndReloadingPreserveTranslation() async throws {
        let example = try #require(try references().cases.first)
        let engine = BundledTranslationEngine(resources: try TranslationModelResources(), computeUnits: .cpuOnly)
        let before = try await engine.translate(example.russian, from: "ru", to: "en")
        await engine.unload()
        let after = try await engine.translate(example.russian, from: "ru", to: "en")
        #expect(before == example.translation)
        #expect(after == before)
        await engine.unload()
    }

    @MainActor
    @Test
    func russianQueryFlowsThroughRealTranslationAndNormalizedCLIPEmbedding() async throws {
        let example = try #require(try references().cases.first)
        let translator = BundledQueryTranslator(engine: BundledTranslationEngine(
            resources: try TranslationModelResources(), computeUnits: .cpuOnly
        ))
        let clip = CLIPEmbeddingEngine(resources: try CLIPModelResources(), computeUnits: .cpuOnly)
        let pipeline = QueryEmbeddingPipeline(translator: translator, encoder: clip)
        let original = " \n\(example.russian)\t "
        let russian = try await pipeline.prepare(original, language: .russian)
        let manual = try await pipeline.prepare(example.manual_english, language: .english)
        #expect(russian.originalText == original)
        #expect(russian.englishText == example.translation)
        #expect(russian.sourceLanguage == .russian)
        #expect(manual.originalText == example.manual_english)
        #expect(manual.sourceLanguage == .english)
        for result in [russian, manual] {
            #expect(result.embedding.values.count == 512)
            #expect(result.embedding.values.allSatisfy { $0.isFinite })
            let norm = result.embedding.values.reduce(0.0) { $0 + Double($1) * Double($1) }
            #expect(abs(norm - 1) < 0.00001)
        }
        let cosine = try russian.embedding.cosineSimilarity(to: manual.embedding)
        #expect(cosine.isFinite && (-1...1).contains(cosine))
        // Descriptive diagnostic only: no translation-quality or retrieval claim.
        print("BUNDLED_TRANSLATION_CLIP_DIAGNOSTIC id=\(example.id) cosine=\(cosine)")
        await pipeline.unload()
    }

    /// Run alone in Release on a physical phone. Includes translation model
    /// loading on the first call, then ten fixed public queries with warm models.
    #if !targetEnvironment(simulator)
    @Test
    func measuresBundledTranslationOnCurrentHardware() async throws {
        let references = try references()
        let first = try #require(references.cases.first)
        let resources = try TranslationModelResources()
        let clipResources = try CLIPModelResources()
        let engine = BundledTranslationEngine(resources: resources, computeUnits: .all)
        let clip = CLIPEmbeddingEngine(resources: clipResources, computeUnits: .all)
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
        let coldStart = ContinuousClock.now
        let coldTranslation = try await engine.translate(first.russian, from: "ru", to: "en")
        let coldMilliseconds = Self.milliseconds(coldStart.duration(to: .now))
        #expect(coldTranslation == first.translation, "\(first.id): first .all result must match the CPU reference")
        var warmMilliseconds: [Double] = []
        var rows: [[String: Any]] = []
        var matchingReferences = 0
        for example in references.cases {
            let start = ContinuousClock.now
            let translated = try await engine.translate(example.russian, from: "ru", to: "en")
            let milliseconds = Self.milliseconds(start.duration(to: .now))
            warmMilliseconds.append(milliseconds)
            let matches = translated == example.translation
            if matches { matchingReferences += 1 }
            #expect(matches, "\(example.id): .all versus CPU reference, actual translation: \(translated)")
            let translatedEmbedding = try await clip.textEmbedding(translated)
            let manualEmbedding = try await clip.textEmbedding(example.manual_english)
            let cosine = try translatedEmbedding.cosineSimilarity(to: manualEmbedding)
            #expect(cosine.isFinite && (-1...1).contains(cosine))
            rows.append([
                "id": example.id, "public_russian": example.russian,
                "manual_english": example.manual_english, "translation": translated,
                "reference_translation": example.translation, "matches_reference": matches,
                "translation_ms": milliseconds, "reference_generated_tokens": example.generated_tokens.count,
                "manual_english_clip_cosine": cosine,
            ])
        }
        sampler.cancel()
        let peak = await sampler.value
        await engine.unload()
        await clip.unload()
        let report: [String: Any] = [
            "environment": "physical-device", "compute_units": "all",
            "translation_model_id": resources.manifest.modelID, "clip_model_id": clipResources.manifest.modelID,
            "public_case_count": references.cases.count, "matching_references": matchingReferences,
            "translation_first_call_ms": coldMilliseconds,
            "translation_warm_median_ms": Self.median(warmMilliseconds),
            "translation_warm_ms": warmMilliseconds, "cases": rows,
            "baseline_resident_bytes": baseline, "sampled_peak_resident_bytes": peak,
            "after_unload_resident_bytes": Self.residentBytes(), "memory_sample_interval_ms": 10,
            "note": "Fixed public text only. Whole-process sampled RSS includes translation and CLIP. First call may reuse OS caches. Warm timings span different phrases. CLIP cosine is descriptive, not a translation or retrieval quality measurement.",
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("BUNDLED_TRANSLATION_BENCHMARK \(String(decoding: json, as: UTF8.self))")
    }
    #endif

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
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
