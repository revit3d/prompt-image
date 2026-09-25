import Foundation
import Testing
@testable import PromptImage

struct RetrievalDemoCorpusTests {
    private struct Fixture {
        let directory: URL
        let imageBytes: Data
        let imageID: String
        let fingerprint: String
        var manifest: [String: Any]

        var imageURL: URL { directory.appendingPathComponent("images/sample.png") }

        func writeManifest() throws {
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("demo-manifest.json"))
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrieval-corpus-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"),
                                               withIntermediateDirectories: true)
        // A generated one-pixel PNG is enough to verify file provenance without private photos.
        let bytes = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let digest = RetrievalDemoCorpus.digest(bytes)
        let imageID = "img_" + digest.prefix(12)
        let source = ["benchmark_sha256": String(repeating: "a", count: 64),
                      "images_csv_sha256": String(repeating: "b", count: 64),
                      "development_queries_csv_sha256": String(repeating: "c", count: 64)]
        let sourceBytes = try JSONSerialization.data(withJSONObject: source,
                                                    options: [.sortedKeys, .withoutEscapingSlashes])
        let fingerprint = RetrievalDemoCorpus.digest(sourceBytes)
        let fixture = Fixture(directory: directory, imageBytes: bytes, imageID: imageID,
                              fingerprint: fingerprint, manifest: [
            "schema_version": 1,
            "model_id": RetrievalDemoCorpus.modelID,
            "source": source,
            "corpus_fingerprint": fingerprint,
            "images": [["id": imageID, "relative_path": "images/sample.png", "sha256": digest]],
            "queries": [["id": "query_ru", "group_id": "group_1", "language": "ru",
                         "text": "кошка у окна", "expected_image_ids": [imageID]]]
        ])
        try bytes.write(to: fixture.imageURL)
        try fixture.writeManifest()
        return fixture
    }

    @Test
    func readsValidatedCorpusAndPreservesDevelopmentQuery() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corpus = try RetrievalDemoCorpus(directory: fixture.directory)
        #expect(corpus.fingerprint == fixture.fingerprint)
        // Matches Python's canonical JSON fingerprint, not Foundation-specific whitespace.
        #expect(corpus.fingerprint == "2f01ddee2f7cd2b95db2de7ef83b9c99edb70b1b756f28f47a8f40cd37d17d58")
        #expect(corpus.summary.imageCount == 1)
        let image = try #require(corpus.images.first)
        #expect(image.id == fixture.imageID)
        #expect(try corpus.imageData(for: image) == fixture.imageBytes)
        #expect(try corpus.imageURL(for: image) == fixture.imageURL)
        let query = try #require(corpus.summary.queries.first)
        #expect(query.id == "query_ru")
        #expect(query.groupID == "group_1")
        #expect(query.language == .russian)
        #expect(query.text == "кошка у окна")
        #expect(query.expectedImageIDs == [fixture.imageID])
    }

    @Test
    func missingManifestHasDistinctSetupError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: RetrievalDemoError.corpusMissing) { try RetrievalDemoCorpus(directory: missing) }
    }

    @Test
    func changedImageIsDetectedWhenReadForInference() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corpus = try RetrievalDemoCorpus(directory: fixture.directory)
        let record = try #require(corpus.images.first)
        try (fixture.imageBytes + Data([0])).write(to: fixture.imageURL)
        #expect(throws: RetrievalDemoError.imageChanged) { try corpus.imageData(for: record) }
    }

    @Test
    func sourceHashesMustMatchFingerprint() throws {
        var fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var source = try #require(fixture.manifest["source"] as? [String: String])
        source["benchmark_sha256"] = String(repeating: "d", count: 64)
        fixture.manifest["source"] = source
        try fixture.writeManifest()
        #expect(throws: RetrievalDemoError.invalidCorpus) { try RetrievalDemoCorpus(directory: fixture.directory) }
    }

    @Test(arguments: ["../outside.png", "/images/sample.png", "images/../sample.png",
                      "images//sample.png", "images/./sample.png", "images\\sample.png", "images/"])
    func rejectsUnsafeRelativePaths(path: String) throws {
        var fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var records = try #require(fixture.manifest["images"] as? [[String: String]])
        records[0]["relative_path"] = path
        fixture.manifest["images"] = records
        try fixture.writeManifest()
        #expect(throws: RetrievalDemoError.invalidCorpus) { try RetrievalDemoCorpus(directory: fixture.directory) }
    }

    @Test
    func rejectsSymbolicImageLinksEvenWhenTargetIsInsideCorpus() throws {
        var fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let link = fixture.directory.appendingPathComponent("images/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.imageURL)
        var records = try #require(fixture.manifest["images"] as? [[String: String]])
        records[0]["relative_path"] = "images/link.png"
        fixture.manifest["images"] = records
        try fixture.writeManifest()
        #expect(throws: RetrievalDemoError.invalidCorpus) { try RetrievalDemoCorpus(directory: fixture.directory) }
    }

    @Test
    func rejectsIncompatibleModelAndUnknownExpectedImage() throws {
        var fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = fixture.manifest
        fixture.manifest["model_id"] = "different-clip-version"
        try fixture.writeManifest()
        #expect(throws: RetrievalDemoError.invalidCorpus) { try RetrievalDemoCorpus(directory: fixture.directory) }

        fixture.manifest = original
        var queries = try #require(fixture.manifest["queries"] as? [[String: Any]])
        queries[0]["expected_image_ids"] = ["img_unknown"]
        fixture.manifest["queries"] = queries
        try fixture.writeManifest()
        #expect(throws: RetrievalDemoError.invalidCorpus) { try RetrievalDemoCorpus(directory: fixture.directory) }
    }
}
