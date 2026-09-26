import Foundation
import SQLite3
import Testing
@testable import PromptImage

struct SQLiteConnectionTests {
    @Test
    func bindingsPreserveUnicodeNULAndEmptyBlobAcrossReopen() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PhotoIndexLocation.prepare(directory: directory)
        let connection = try SQLiteConnection(url: url)
        try connection.execute("CREATE TABLE sample (a, b, c, d, e, f)")
        let values: [SQLiteValue] = [.text("Рецепт\0pancakes 👩🏽‍🍳"), .blob(Data()), .null,
                                     .integer(Int64.max), .real(0.125), .blob(Data([0, 255, 0]))]
        try connection.execute("INSERT INTO sample VALUES (?, ?, ?, ?, ?, ?)", values)
        try connection.close()
        let reopened = try SQLiteConnection(url: url)
        #expect(try reopened.query("SELECT * FROM sample") == [values])
        try reopened.close()
    }

    @Test
    func failingTransactionRollsBackAndConnectionRemainsUsable() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try SQLiteConnection(url: PhotoIndexLocation.prepare(directory: directory))
        defer { try? connection.close() }
        try connection.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)")
        #expect(throws: PhotoIndexError.self) {
            try connection.transaction {
                try connection.execute("INSERT INTO sample VALUES (?)", [.integer(7)])
                try connection.execute("INSERT INTO sample VALUES (?)", [.integer(7)])
            }
        }
        #expect(try connection.query("SELECT count(*) FROM sample") == [[.integer(0)]])
        try connection.transaction { try connection.execute("INSERT INTO sample VALUES (8)") }
        #expect(try connection.query("SELECT id FROM sample") == [[.integer(8)]])
    }

    @Test
    func cancellationBeforeCommitRollsBackEvenInCancelledTask() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PhotoIndexLocation.prepare(directory: directory)
        let task = Task.detached {
            let connection = try SQLiteConnection(url: url)
            defer { try? connection.close() }
            try connection.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY)")
            try connection.transaction {
                try connection.execute("INSERT INTO sample VALUES (1)")
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await task.value
            Issue.record("A cancelled transaction unexpectedly committed")
        } catch is CancellationError {
            // Check through another connection because the task above remains cancelled.
        }
        let reopened = try SQLiteConnection(url: url)
        defer { try? reopened.close() }
        #expect(try reopened.query("SELECT count(*) FROM sample") == [[.integer(0)]])
    }

    @Test
    func rejectsTrailingSQLAndWrongBindingCountsWithoutWriting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try SQLiteConnection(url: PhotoIndexLocation.prepare(directory: directory))
        try connection.execute("CREATE TABLE sample (value TEXT)")
        #expect(throws: PhotoIndexError.invalidInput) {
            try connection.execute("INSERT INTO sample VALUES ('first'); DELETE FROM sample")
        }
        #expect(throws: PhotoIndexError.invalidInput) {
            try connection.execute("INSERT INTO sample VALUES (?)")
        }
        #expect(try connection.query("SELECT count(*) FROM sample") == [[.integer(0)]])
        try connection.close()
        #expect(throws: PhotoIndexError.closed) { try connection.query("SELECT 1") }
    }

    @Test
    func locationIsExcludedFromBackupAndRefusesLinks() throws {
        let directory = temporaryDirectory()
        let linkedDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: linkedDirectory)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try PhotoIndexLocation.prepare(directory: directory)
        let connection = try SQLiteConnection(url: url)
        try connection.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        #expect(throws: PhotoIndexError.fileProtection) {
            try PhotoIndexLocation.prepare(directory: linkedDirectory)
        }
        let sidecar = URL(fileURLWithPath: url.path + "-wal")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: url)
        #expect(throws: PhotoIndexError.fileProtection) {
            try SQLiteConnection(url: url)
        }
    }

    @Test(.enabled(if: Self.isPhysicalDevice, "The simulator does not report iOS file-protection classes"))
    func completeProtectionAppliesToDirectoryDatabaseAndActiveJournal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PhotoIndexLocation.prepare(directory: directory)
        let connection = try SQLiteConnection(url: url)
        defer { try? connection.close() }
        try connection.execute("CREATE TABLE sample (value INTEGER)")
        try connection.transaction {
            try connection.execute("INSERT INTO sample VALUES (1)")
            for file in [directory, url, URL(fileURLWithPath: url.path + "-journal")] {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                // Foundation reports the NSString raw value, not its Swift typed wrapper.
                #expect(attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue)
            }
        }
    }

    private static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteConnectionTests-\(UUID().uuidString)")
    }
}
