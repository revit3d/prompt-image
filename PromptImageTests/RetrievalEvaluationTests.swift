import Darwin
import Foundation
import Testing
@testable import PromptImage

/// Opt in by copying the prepared public corpus into Documents/RetrievalDemo.
/// Nothing is read from Photos or the held-out query set. Run this test alone.
@Suite(.serialized)
struct RetrievalEvaluationTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        RetrievalDemoCorpus.defaultDirectory.appendingPathComponent("demo-manifest.json").path)))
    func evaluatesDevelopmentRetrievalOnCurrentHardware() async throws {
        let corpus = try RetrievalDemoCorpus(directory: RetrievalDemoCorpus.defaultDirectory)
        try #require(corpus.images.count == 400)
        try #require(corpus.queries.count == 28)
        let engine = RetrievalDemoEngine()
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
        let indexingStart = ContinuousClock.now
        try await engine.prepare { completed, total in
            if completed.isMultiple(of: 50) { print("RETRIEVAL_INDEX_PROGRESS \(completed)/\(total)") }
        }
        let indexingMilliseconds = Self.milliseconds(indexingStart.duration(to: .now))
        var rows: [[String: Any]] = []
        for query in corpus.queries {
            let start = ContinuousClock.now
            do {
                let result = try await engine.search(query.text, language: query.language == .russian ? .russian : .english)
                let elapsed = Self.milliseconds(start.duration(to: .now))
                #expect(result.originalText == query.text)
                #expect(result.matches.count == 10)
                #expect(Set(result.matches.map(\.id)).count == result.matches.count)
                #expect(result.matches.allSatisfy { $0.score.isFinite })
                let expected = Set(query.expectedImageIDs)
                let firstRank = result.matches.firstIndex { expected.contains($0.id) }.map { $0 + 1 }
                rows.append([
                    "query_id": query.id, "ranked_ids": result.matches.map(\.id),
                    "english_text": result.englishText, "search_ms": elapsed,
                    "first_relevant_rank": firstRank as Any? ?? NSNull(),
                ])
                print("RETRIEVAL_QUERY id=\(query.id) success_at_5=\(firstRank.map { $0 <= 5 } ?? false)")
            } catch {
                rows.append(["query_id": query.id, "ranked_ids": [String](),
                             "search_ms": Self.milliseconds(start.duration(to: .now)),
                             "error": String(describing: error)])
                Issue.record("Development query failed: \(query.id), \(error)")
            }
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
            "schema_version": 1, "model_id": RetrievalDemoCorpus.modelID,
            "translation_model_id": "helsinki-opus-mt-ru-en-fp16-v1",
            "corpus_fingerprint": corpus.fingerprint, "ranking_limit": 10,
            "environment": environment, "compute_units": "all", "cases": rows,
            "image_count": corpus.images.count, "indexing_ms": indexingMilliseconds,
            "embedding_bytes": corpus.images.count * 512 * MemoryLayout<Float>.size,
            "baseline_resident_bytes": baseline, "sampled_peak_resident_bytes": peak,
            "after_unload_resident_bytes": Self.residentBytes(), "memory_sample_interval_ms": 10,
            "note": "Development visual queries only. First query includes lazy translation/text model loading. Later queries reuse models. Whole-process RSS is sampled; this is not a battery test, held-out evaluation, or OCR test.",
        ]
        // Explicit evaluation output, containing only prepared public examples.
        // Normal UI searches never write or log query text/results.
        let reportURL = URL.documentsDirectory.appendingPathComponent("retrieval-evaluation.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: [.atomic])
        var excluded = reportURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        print("RETRIEVAL_EVALUATION_COMPLETE images=\(corpus.images.count) queries=\(rows.count) indexing_ms=\(indexingMilliseconds) peak_bytes=\(peak)")
    }

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
