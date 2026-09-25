import Foundation

/// Durable derived data only; this actor neither reads PhotoKit nor starts inference.
/// The app must keep one store owner. Open once at startup, after protected data is available.
actor PhotoIndexStore {
    static let schemaVersion = 1
    private static let applicationID: Int64 = 0x5052494D
    private let database: SQLiteConnection

    init(directoryURL: URL) throws {
        let url = try PhotoIndexLocation.prepare(directory: directoryURL)
        let connection = try SQLiteConnection(url: url)
        do {
            try Self.prepareSchema(connection)
            try PhotoIndexLocation.protectFiles(in: directoryURL)
            // A previous process may have exited during inference. Its attempt must
            // never publish into the resumed index; successful work remains intact.
            try connection.transaction {
                try connection.execute("UPDATE stages SET status = 'pending', attempt = NULL WHERE status = 'processing'")
            }
        } catch {
            try? connection.close()
            throw error
        }
        database = connection
    }

    static func openDefault() throws -> PhotoIndexStore {
        try PhotoIndexStore(directoryURL: PhotoIndexLocation.defaultDirectory())
    }

    func close() throws { try database.close() }

    /// Refresh a permitted asset snapshot. This does not infer deletions from a partial list.
    @discardableResult
    func upsert(_ photo: LibraryPhoto, versions: PhotoIndexVersions) throws -> PhotoIndexRecord {
        try Self.validate(photo)
        try Self.validateIdentifier(versions.embedding)
        try Self.validateIdentifier(versions.ocr)
        return try database.transaction {
            try upsertInTransaction(photo, versions: versions)
        }
    }

    /// Reconcile the complete, currently permitted library snapshot in one transaction.
    /// Never pass a page or a fetch still in progress: absent assets and their derived
    /// data are removed. Duplicate identifiers are rejected before any mutation.
    func synchronize(_ photos: [LibraryPhoto], versions: PhotoIndexVersions) throws {
        try Self.validateIdentifier(versions.embedding)
        try Self.validateIdentifier(versions.ocr)
        var permittedIDs = Set<String>()
        for photo in photos {
            try Task.checkCancellation()
            try Self.validate(photo)
            guard permittedIDs.insert(photo.id).inserted else { throw PhotoIndexError.invalidInput }
        }
        try database.transaction {
            try retainOnlyInTransaction(assetIDs: permittedIDs)
            for photo in photos { _ = try upsertInTransaction(photo, versions: versions) }
        }
    }

    /// Remove derived data outside the permitted snapshot even if model resources
    /// are unavailable. An empty set clears the index; original photos are untouched.
    func retainOnly(assetIDs: Set<String>) throws {
        for id in assetIDs { try Self.validateIdentifier(id) }
        try database.transaction { try retainOnlyInTransaction(assetIDs: assetIDs) }
    }

    /// Explicit retry leaves successful and currently processing stages intact.
    func retryIncomplete() throws {
        try database.transaction {
            try database.execute("""
                UPDATE stages SET status = 'pending', failure = NULL
                WHERE status IN ('failed', 'requiresDownload')
                """)
        }
    }

    /// Call only after the preceding worker has drained. This also repairs a claim
    /// whose cancellation could not be saved while protected data was unavailable.
    /// Old tickets become stale; completed results are preserved.
    func recoverInterruptedWork() throws {
        try database.transaction {
            try database.execute("UPDATE stages SET status = 'pending', attempt = NULL WHERE status = 'processing'")
        }
    }

    func summary() throws -> PhotoIndexSummary {
        guard let row = try database.query("""
            SELECT COUNT(*),
                COALESCE(SUM(e.status = 'complete' AND o.status = 'complete'), 0),
                COALESCE(SUM(e.status = 'complete'), 0),
                COALESCE(SUM(o.status = 'complete'), 0),
                COALESCE(SUM(e.status IN ('pending', 'processing') OR o.status IN ('pending', 'processing')), 0),
                COALESCE(SUM(e.status = 'requiresDownload' OR o.status = 'requiresDownload'), 0),
                COALESCE(SUM(e.status = 'failed' OR o.status = 'failed'), 0)
            FROM photos p
            JOIN stages e ON e.photo_id = p.photo_id AND e.kind = 'embedding'
            JOIN stages o ON o.photo_id = p.photo_id AND o.kind = 'ocr'
            """).first else { throw PhotoIndexError.invalidStoredData }
        let counts = try row.map { Int(try Self.integer($0)) }
        return PhotoIndexSummary(totalCount: counts[0], completeCount: counts[1],
            embeddingCount: counts[2], ocrCount: counts[3], pendingCount: counts[4],
            downloadRequiredCount: counts[5], failedCount: counts[6])
    }

    /// Caller owns the transaction and has validated the snapshot and versions.
    private func upsertInTransaction(_ photo: LibraryPhoto, versions: PhotoIndexVersions) throws -> PhotoIndexRecord {
        let current = try record(for: photo.id)
        if let current, current.photo == photo,
           current.embedding.version == versions.embedding, current.ocr.version == versions.ocr {
            return current
        }
        if let current, current.photo != photo {
            // Cascade deletion clears both payloads and FTS, while the new generation
            // rejects a late result even if the old and new metadata later match again.
            try database.execute("DELETE FROM photos WHERE asset_id = ?", [.text(photo.id)])
        }
        if current == nil || current?.photo != photo {
            try database.execute("""
                INSERT INTO photos(asset_id, creation_date, modification_date, width, height, generation)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(photo.id), Self.dateValue(photo.creationDate), Self.dateValue(photo.modificationDate),
                      .integer(Int64(photo.pixelWidth)), .integer(Int64(photo.pixelHeight)), .text(UUID().uuidString)])
            let id = try photoID(photo.id)
            for (stage, version) in [(PhotoIndexStage.embedding, versions.embedding), (.ocr, versions.ocr)] {
                try database.execute("INSERT INTO stages(photo_id, kind, version, status) VALUES (?, ?, ?, 'pending')",
                                     [.integer(id), .text(stage.rawValue), .text(version)])
            }
        } else if let current {
            let id = try photoID(photo.id)
            for (stage, version) in [(PhotoIndexStage.embedding, versions.embedding), (.ocr, versions.ocr)] {
                let state = stage == .embedding ? current.embedding : current.ocr
                if state.version != version {
                    try database.execute("""
                        UPDATE stages SET version = ?, status = 'pending', attempt = NULL, payload = NULL, failure = NULL
                        WHERE photo_id = ? AND kind = ?
                        """, [.text(version), .integer(id), .text(stage.rawValue)])
                    if stage == .ocr { try deleteText(id) }
                }
            }
        }
        guard let record = try record(for: photo.id) else { throw PhotoIndexError.invalidStoredData }
        return record
    }

    private func retainOnlyInTransaction(assetIDs: Set<String>) throws {
        let existingIDs = try database.query("SELECT asset_id FROM photos").map { try Self.text($0[0]) }
        for id in existingIDs where !assetIDs.contains(id) {
            try database.execute("DELETE FROM photos WHERE asset_id = ?", [.text(id)])
        }
    }

    func record(for assetID: String) throws -> PhotoIndexRecord? {
        guard let row = try database.query("""
            SELECT photo_id, creation_date, modification_date, width, height, generation
            FROM photos WHERE asset_id = ?
            """, [.text(assetID)]).first else { return nil }
        let id = try Self.integer(row[0])
        guard let generation = UUID(uuidString: try Self.text(row[5])) else { throw PhotoIndexError.invalidStoredData }
        let photo = LibraryPhoto(id: assetID, creationDate: try Self.date(row[1]), modificationDate: try Self.date(row[2]),
                                 pixelWidth: Int(try Self.integer(row[3])), pixelHeight: Int(try Self.integer(row[4])))
        return try PhotoIndexRecord(photo: photo, generation: generation,
                                    embedding: stageState(id, stage: .embedding), ocr: stageState(id, stage: .ocr))
    }

    /// Claim pending work or explicitly retry a failed/cloud-only stage. Already running
    /// or completed stages must not be claimed again without cancellation/invalidation.
    func beginWork(for assetID: String, stage: PhotoIndexStage) throws -> PhotoIndexWork {
        try database.transaction {
            guard let current = try record(for: assetID) else { throw PhotoIndexError.invalidInput }
            let state = stage == .embedding ? current.embedding : current.ocr
            guard state.status != .processing, state.status != .complete else { throw PhotoIndexError.invalidTransition }
            let id = try photoID(assetID)
            let attempt = UUID()
            try database.execute("""
                UPDATE stages SET status = 'processing', attempt = ?, payload = NULL, failure = NULL
                WHERE photo_id = ? AND kind = ?
                """, [.text(attempt.uuidString), .integer(id), .text(stage.rawValue)])
            if stage == .ocr { try deleteText(id) }
            return PhotoIndexWork(assetID: assetID, assetGeneration: current.generation,
                                  stage: stage, version: state.version, attemptID: attempt)
        }
    }

    func saveEmbedding(_ embedding: CLIPEmbedding, for work: PhotoIndexWork) throws {
        guard work.stage == .embedding, embedding.modelID == work.version else { throw PhotoIndexError.invalidInput }
        let payload = try PhotoIndexCodec.encodeEmbedding(embedding)
        try database.transaction {
            let id = try requireCurrent(work)
            try complete(id, stage: .embedding, payload: payload)
        }
    }

    func saveOCR(_ result: PhotoOCRResult, for work: PhotoIndexWork) throws {
        guard work.stage == .ocr else { throw PhotoIndexError.invalidInput }
        let payload = try PhotoIndexCodec.encodeOCR(result)
        try database.transaction {
            let id = try requireCurrent(work)
            try complete(id, stage: .ocr, payload: payload)
            try database.execute("""
                INSERT INTO ocr_text(photo_id, text) VALUES (?, ?)
                ON CONFLICT(photo_id) DO UPDATE SET text = excluded.text
                """, [.integer(id), .text(result.text)])
        }
    }

    func fail(_ work: PhotoIndexWork, with failure: PhotoIndexFailure) throws {
        try finish(work, status: .failed, failure: failure)
    }

    func markRequiresDownload(_ work: PhotoIndexWork) throws {
        try finish(work, status: .requiresDownload)
    }

    /// Durable cleanup must also work from a scheduler task that was just cancelled.
    /// Only this small state transition gets a fresh cancellation context; result
    /// writes and other transactions continue to respect their caller's cancellation.
    func cancel(_ work: PhotoIndexWork) async throws {
        try await Task.detached { try await self.finish(work, status: .pending) }.value
    }

    /// Bounded, deterministic pages for a future foreground scheduler. Failed and
    /// cloud-only stages require an explicit retry, avoiding infinite automatic loops.
    func recordsNeedingWork(afterID: String? = nil, limit: Int = 100) throws -> [PhotoIndexRecord] {
        try Self.validateLimit(limit)
        let rows = try database.query("""
            SELECT asset_id FROM photos p WHERE (? IS NULL OR asset_id > ?)
            AND EXISTS(SELECT 1 FROM stages s WHERE s.photo_id = p.photo_id AND s.status = 'pending')
            ORDER BY asset_id COLLATE BINARY LIMIT ?
            """, [Self.optionalText(afterID), Self.optionalText(afterID), .integer(Int64(limit))])
        return try rows.map { row in
            guard let record = try record(for: Self.text(row[0])) else { throw PhotoIndexError.invalidStoredData }
            return record
        }
    }

    /// Only vectors from the requested model space are returned; no full-index allocation is required.
    func embeddings(modelID: String, afterID: String? = nil, limit: Int = 200) throws -> [SemanticIndexedImage] {
        try Self.validateIdentifier(modelID)
        try Self.validateLimit(limit)
        return try database.query("""
            SELECT p.asset_id, s.payload FROM stages s JOIN photos p ON p.photo_id = s.photo_id
            WHERE s.kind = 'embedding' AND s.status = 'complete' AND s.version = ?
            AND (? IS NULL OR p.asset_id > ?) ORDER BY p.asset_id COLLATE BINARY LIMIT ?
            """, [.text(modelID), Self.optionalText(afterID), Self.optionalText(afterID), .integer(Int64(limit))]).map {
                try SemanticIndexedImage(id: Self.text($0[0]),
                                         embedding: PhotoIndexCodec.decodeEmbedding(Self.blob($0[1]), modelID: modelID))
            }
    }

    func ocr(for assetID: String, version: String) throws -> PhotoOCRResult? {
        guard let row = try database.query("""
            SELECT s.payload FROM stages s JOIN photos p ON p.photo_id = s.photo_id
            WHERE p.asset_id = ? AND s.kind = 'ocr' AND s.status = 'complete' AND s.version = ?
            """, [.text(assetID), .text(version)]).first else { return nil }
        return try PhotoIndexCodec.decodeOCR(Self.blob(row[0]))
    }

    /// Literal whole-word AND search. FTS operators and punctuation from user input
    /// never become query syntax. This layer does not perform Russian stemming or fusion.
    func searchOCR(_ query: String, version: String, limit: Int = 50) throws -> [PhotoIndexTextMatch] {
        try Self.validateLimit(limit)
        try Self.validateIdentifier(version)
        guard query.utf8.count <= 4_096 else { throw PhotoIndexError.invalidInput }
        let terms = query.split { !$0.isLetter && !$0.isNumber }
        guard terms.count <= 32 else { throw PhotoIndexError.invalidInput }
        guard !terms.isEmpty else { return [] }
        let literal = terms.map { "\"\($0)\"" }.joined(separator: " AND ")
        return try database.query("""
            SELECT p.asset_id, t.text, bm25(ocr_fts) FROM ocr_fts
            JOIN ocr_text t ON t.photo_id = ocr_fts.rowid
            JOIN photos p ON p.photo_id = t.photo_id
            JOIN stages s ON s.photo_id = p.photo_id AND s.kind = 'ocr'
            WHERE ocr_fts MATCH ? AND s.version = ? AND s.status = 'complete'
            ORDER BY bm25(ocr_fts), p.asset_id COLLATE BINARY LIMIT ?
            """, [.text(literal), .text(version), .integer(Int64(limit))]).map {
                try PhotoIndexTextMatch(assetID: Self.text($0[0]), text: Self.text($0[1]), rank: Self.real($0[2]))
            }
    }

    func remove(assetIDs: [String]) throws {
        try database.transaction {
            for id in assetIDs { try database.execute("DELETE FROM photos WHERE asset_id = ?", [.text(id)]) }
        }
    }

    /// Clears derived data only. PhotoKit/source images are never touched.
    func clear() throws {
        try database.transaction { try database.execute("DELETE FROM photos") }
    }

    private func photoID(_ assetID: String) throws -> Int64 {
        guard let row = try database.query("SELECT photo_id FROM photos WHERE asset_id = ?", [.text(assetID)]).first else {
            throw PhotoIndexError.invalidInput
        }
        return try Self.integer(row[0])
    }

    private func stageState(_ id: Int64, stage: PhotoIndexStage) throws -> PhotoIndexStageState {
        guard let row = try database.query("SELECT version, status, failure FROM stages WHERE photo_id = ? AND kind = ?",
                                           [.integer(id), .text(stage.rawValue)]).first,
              let status = PhotoIndexStatus(rawValue: try Self.text(row[1])) else { throw PhotoIndexError.invalidStoredData }
        let failure: PhotoIndexFailure?
        if row[2] == .null { failure = nil }
        else {
            guard let value = PhotoIndexFailure(rawValue: try Self.text(row[2])) else { throw PhotoIndexError.invalidStoredData }
            failure = value
        }
        return try PhotoIndexStageState(version: Self.text(row[0]), status: status, failure: failure)
    }

    private func requireCurrent(_ work: PhotoIndexWork) throws -> Int64 {
        let rows = try database.query("""
            SELECT p.photo_id FROM photos p JOIN stages s ON s.photo_id = p.photo_id
            WHERE p.asset_id = ? AND p.generation = ? AND s.kind = ? AND s.version = ?
            AND s.status = 'processing' AND s.attempt = ?
            """, [.text(work.assetID), .text(work.assetGeneration.uuidString), .text(work.stage.rawValue),
                  .text(work.version), .text(work.attemptID.uuidString)])
        guard let row = rows.first else { throw PhotoIndexError.staleWork }
        return try Self.integer(row[0])
    }

    private func complete(_ id: Int64, stage: PhotoIndexStage, payload: Data) throws {
        try database.execute("""
            UPDATE stages SET status = 'complete', payload = ?, attempt = NULL, failure = NULL
            WHERE photo_id = ? AND kind = ?
            """, [.blob(payload), .integer(id), .text(stage.rawValue)])
    }

    private func finish(_ work: PhotoIndexWork, status: PhotoIndexStatus, failure: PhotoIndexFailure? = nil) throws {
        try database.transaction {
            let id = try requireCurrent(work)
            try database.execute("""
                UPDATE stages SET status = ?, failure = ?, attempt = NULL, payload = NULL
                WHERE photo_id = ? AND kind = ?
                """, [.text(status.rawValue), Self.optionalText(failure?.rawValue), .integer(id), .text(work.stage.rawValue)])
            if work.stage == .ocr { try deleteText(id) }
        }
    }

    private func deleteText(_ id: Int64) throws {
        try database.execute("DELETE FROM ocr_text WHERE photo_id = ?", [.integer(id)])
    }

    private static func prepareSchema(_ database: SQLiteConnection) throws {
        let version = Int(try integer(database.query("PRAGMA user_version")[0][0]))
        let appID = try integer(database.query("PRAGMA application_id")[0][0])
        guard version >= 0 else { throw PhotoIndexError.invalidDatabase }
        guard version <= schemaVersion else { throw PhotoIndexError.unsupportedSchema(version) }
        if version == 0 {
            guard appID == 0,
                  try database.query("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else {
                throw PhotoIndexError.invalidDatabase
            }
            try database.transaction {
                for statement in schema { try database.execute(statement) }
                try database.execute("PRAGMA application_id = \(applicationID)")
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        } else {
            guard appID == applicationID else { throw PhotoIndexError.invalidDatabase }
            guard try database.query("PRAGMA quick_check(1)") == [[.text("ok")]],
                  try database.query("PRAGMA foreign_key_check").isEmpty else { throw PhotoIndexError.invalidStoredData }
        }
        // Available since SQLite 3.42; older supported system builds still get core
        // secure_delete. Neither setting promises forensic erasure from flash storage.
        let components = try text(database.query("SELECT sqlite_version()")[0][0]).split(separator: ".").compactMap { Int($0) }
        if components.count >= 2 && (components[0] > 3 || (components[0] == 3 && components[1] >= 42)) {
            try database.execute("INSERT INTO ocr_fts(ocr_fts, rank) VALUES ('secure-delete', 1)")
        }
    }

    private static let schema = [
        """
        CREATE TABLE photos (
            photo_id INTEGER PRIMARY KEY, asset_id TEXT NOT NULL UNIQUE CHECK(length(asset_id) > 0),
            creation_date REAL, modification_date REAL, width INTEGER NOT NULL CHECK(width > 0),
            height INTEGER NOT NULL CHECK(height > 0), generation TEXT NOT NULL UNIQUE
        )
        """,
        """
        CREATE TABLE stages (
            photo_id INTEGER NOT NULL REFERENCES photos(photo_id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('embedding','ocr')), version TEXT NOT NULL CHECK(length(version) > 0),
            status TEXT NOT NULL CHECK(status IN ('pending','processing','complete','requiresDownload','failed')),
            attempt TEXT, payload BLOB, failure TEXT,
            PRIMARY KEY(photo_id, kind),
            CHECK((status = 'processing') = (attempt IS NOT NULL)),
            CHECK((status = 'complete') = (payload IS NOT NULL)),
            CHECK((status = 'failed') = (failure IS NOT NULL)),
            CHECK(kind != 'embedding' OR payload IS NULL OR length(payload) = 2048)
        )
        """,
        "CREATE INDEX stages_by_status ON stages(status, kind, photo_id)",
        """
        CREATE TABLE ocr_text (
            photo_id INTEGER PRIMARY KEY REFERENCES photos(photo_id) ON DELETE CASCADE, text TEXT NOT NULL
        )
        """,
        "CREATE VIRTUAL TABLE ocr_fts USING fts5(text, content='ocr_text', content_rowid='photo_id', tokenize='unicode61')",
        """
        CREATE TRIGGER ocr_insert AFTER INSERT ON ocr_text BEGIN
            INSERT INTO ocr_fts(rowid, text) VALUES (new.photo_id, new.text);
        END
        """,
        """
        CREATE TRIGGER ocr_delete AFTER DELETE ON ocr_text BEGIN
            INSERT INTO ocr_fts(ocr_fts, rowid, text) VALUES ('delete', old.photo_id, old.text);
        END
        """,
        """
        CREATE TRIGGER ocr_update AFTER UPDATE ON ocr_text BEGIN
            INSERT INTO ocr_fts(ocr_fts, rowid, text) VALUES ('delete', old.photo_id, old.text);
            INSERT INTO ocr_fts(rowid, text) VALUES (new.photo_id, new.text);
        END
        """,
    ]

    private static func validate(_ photo: LibraryPhoto) throws {
        try validateIdentifier(photo.id)
        guard photo.pixelWidth > 0, photo.pixelHeight > 0,
              photo.creationDate?.timeIntervalSinceReferenceDate.isFinite != false,
              photo.modificationDate?.timeIntervalSinceReferenceDate.isFinite != false else { throw PhotoIndexError.invalidInput }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.contains("\0") else { throw PhotoIndexError.invalidInput }
    }

    private static func validateLimit(_ limit: Int) throws {
        guard (1...1_000).contains(limit) else { throw PhotoIndexError.invalidInput }
    }

    // Preserve Date's native epoch to avoid rounding a fractional asset timestamp
    // through a larger Unix timestamp and falsely invalidating an unchanged photo.
    private static func dateValue(_ date: Date?) -> SQLiteValue { date.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null }
    private static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    private static func text(_ value: SQLiteValue) throws -> String {
        guard case .text(let text) = value else { throw PhotoIndexError.invalidStoredData }; return text
    }
    private static func integer(_ value: SQLiteValue) throws -> Int64 {
        guard case .integer(let number) = value else { throw PhotoIndexError.invalidStoredData }; return number
    }
    private static func real(_ value: SQLiteValue) throws -> Double {
        let number: Double
        switch value {
        case .real(let value): number = value
        case .integer(let value): number = Double(value)
        default: throw PhotoIndexError.invalidStoredData
        }
        guard number.isFinite else { throw PhotoIndexError.invalidStoredData }; return number
    }
    private static func blob(_ value: SQLiteValue) throws -> Data {
        guard case .blob(let data) = value else { throw PhotoIndexError.invalidStoredData }; return data
    }
    private static func date(_ value: SQLiteValue) throws -> Date? {
        if value == .null { return nil }; return try Date(timeIntervalSinceReferenceDate: real(value))
    }
}
