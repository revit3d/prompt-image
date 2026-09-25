import CryptoKit
import Foundation

nonisolated enum RetrievalDemoError: Error, LocalizedError, Equatable {
    case corpusMissing, invalidCorpus, imageChanged, indexNotReady, preparationInProgress

    var errorDescription: String? {
        switch self {
        case .corpusMissing: "Тестовая подборка ещё не перенесена на iPhone. Добавьте её по инструкции разработчика и повторите проверку."
        case .invalidCorpus: "Тестовая подборка повреждена или несовместима с моделью. Подготовьте и перенесите её заново."
        case .imageChanged: "Изображение из тестовой подборки изменилось. Подготовьте и перенесите подборку заново."
        case .indexNotReady: "Сначала подготовьте изображения для поиска."
        case .preparationInProgress: "Дождитесь завершения или отмены текущей подготовки."
        }
    }
}

nonisolated struct RetrievalDemoQuery: Identifiable, Sendable {
    let id: String
    let groupID: String
    let language: QueryLanguage
    let text: String
    let expectedImageIDs: [String]
}

nonisolated struct RetrievalDemoSummary: Sendable {
    let imageCount: Int
    let queries: [RetrievalDemoQuery]
}

nonisolated struct RetrievalDemoMatch: Identifiable, Sendable {
    let id: String
    let imageURL: URL
    let score: Float
}

nonisolated struct RetrievalDemoSearchResult: Sendable {
    let originalText: String
    let englishText: String
    let matches: [RetrievalDemoMatch]
}

/// Development sample copied to the app's data container, never bundled or
/// imported into Photos. The production photo-library index is a later stage.
nonisolated struct RetrievalDemoCorpus: Sendable {
    static let modelID = "openai-clip-vit-b32-fp16-v2"
    struct ImageRecord: Decodable, Sendable {
        let id: String
        let relativePath: String
        let sha256: String
        private enum CodingKeys: String, CodingKey {
            case id, relativePath = "relative_path", sha256
        }
    }
    private struct Manifest: Decodable {
        struct Query: Decodable {
            let id: String
            let groupID: String
            let language: String
            let text: String
            let expectedImageIDs: [String]
            private enum CodingKeys: String, CodingKey {
                case id, groupID = "group_id", language, text, expectedImageIDs = "expected_image_ids"
            }
        }
        let schemaVersion: Int
        let modelID: String
        let corpusFingerprint: String
        let source: [String: String]
        let images: [ImageRecord]
        let queries: [Query]
        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", modelID = "model_id"
            case corpusFingerprint = "corpus_fingerprint", source, images, queries
        }
    }

    let directory: URL
    let fingerprint: String
    let images: [ImageRecord]
    let queries: [RetrievalDemoQuery]
    var summary: RetrievalDemoSummary { .init(imageCount: images.count, queries: queries) }

    static var defaultDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("RetrievalDemo", isDirectory: true)
    }

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let manifestURL = directory.appendingPathComponent("demo-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw RetrievalDemoError.corpusMissing }
        do {
            let bytes = try Self.readFile(manifestURL, under: directory, maximumBytes: 1_048_576)
            let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
            guard manifest.schemaVersion == 1, manifest.modelID == Self.modelID,
                  (1...500).contains(manifest.images.count), manifest.queries.count <= 100,
                  Set(manifest.source.keys) == ["benchmark_sha256", "images_csv_sha256", "development_queries_csv_sha256"],
                  manifest.source.values.allSatisfy(Self.isDigest) else { throw RetrievalDemoError.invalidCorpus }
            let sourceBytes = try JSONSerialization.data(withJSONObject: manifest.source, options: [.sortedKeys, .withoutEscapingSlashes])
            guard Self.digest(sourceBytes) == manifest.corpusFingerprint else { throw RetrievalDemoError.invalidCorpus }
            var ids = Set<String>()
            var paths = Set<String>()
            for image in manifest.images {
                try Task.checkCancellation()
                guard image.id == "img_" + image.sha256.prefix(12), Self.isDigest(image.sha256),
                      ids.insert(image.id).inserted, paths.insert(image.relativePath).inserted else {
                    throw RetrievalDemoError.invalidCorpus
                }
                _ = try Self.imageURL(image.relativePath, under: directory)
            }
            var queryIDs = Set<String>()
            var prepared: [RetrievalDemoQuery] = []
            for query in manifest.queries {
                guard !query.id.isEmpty, queryIDs.insert(query.id).inserted,
                      !query.groupID.isEmpty, let language = QueryLanguage(rawValue: query.language),
                      !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      query.text.utf8.count <= QueryLanguageRouter.maximumUTF8Bytes,
                      !query.expectedImageIDs.isEmpty,
                      Set(query.expectedImageIDs).count == query.expectedImageIDs.count,
                      Set(query.expectedImageIDs).isSubset(of: ids) else { throw RetrievalDemoError.invalidCorpus }
                prepared.append(.init(id: query.id, groupID: query.groupID, language: language,
                                      text: query.text, expectedImageIDs: query.expectedImageIDs))
            }
            fingerprint = manifest.corpusFingerprint
            images = manifest.images
            queries = prepared
        } catch is CancellationError { throw CancellationError() }
        catch { throw RetrievalDemoError.invalidCorpus }
    }

    func imageURL(for image: ImageRecord) throws -> URL {
        try Self.imageURL(image.relativePath, under: directory)
    }

    func imageData(for image: ImageRecord) throws -> Data {
        try Task.checkCancellation()
        let bytes = try Self.readFile(imageURL(for: image), under: directory, maximumBytes: 5 * 1_024 * 1_024)
        guard Self.digest(bytes) == image.sha256 else { throw RetrievalDemoError.imageChanged }
        return bytes
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func imageURL(_ path: String, under directory: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "images", components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw RetrievalDemoError.invalidCorpus
        }
        let url = directory.appendingPathComponent(path)
        try validateFile(url, under: directory, maximumBytes: 5 * 1_024 * 1_024)
        return url
    }

    private static func readFile(_ url: URL, under directory: URL, maximumBytes: Int) throws -> Data {
        try validateFile(url, under: directory, maximumBytes: maximumBytes)
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw RetrievalDemoError.invalidCorpus }
        return bytes
    }

    private static func validateFile(_ url: URL, under directory: URL, maximumBytes: Int) throws {
        let root = directory.standardizedFileURL
        var current = url.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { throw RetrievalDemoError.invalidCorpus }
        while current.path.hasPrefix(root.path + "/") || current == root {
            guard try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
                throw RetrievalDemoError.invalidCorpus
            }
            if current == root { break }
            current.deleteLastPathComponent()
        }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize,
              (1...maximumBytes).contains(size) else { throw RetrievalDemoError.invalidCorpus }
    }
}
