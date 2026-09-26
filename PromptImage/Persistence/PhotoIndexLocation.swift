import Darwin
import Foundation

/// The derived index is private, protected while locked, and never part of an iCloud backup.
nonisolated enum PhotoIndexLocation {
    static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            throw PhotoIndexError.fileProtection
        }
        return support.appendingPathComponent("PhotoIndex", isDirectory: true)
    }

    static func prepare(directory: URL) throws -> URL {
        try validateURL(directory)
        do {
            if let type = try itemType(at: directory) {
                guard type == S_IFDIR else { throw PhotoIndexError.fileProtection }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
            }
            try protectFiles(in: directory)
            return directory.appendingPathComponent("index.sqlite", isDirectory: false)
        } catch {
            throw PhotoIndexError.fileProtection
        }
    }

    static func protectFiles(in directory: URL) throws {
        try validateURL(directory)
        do {
            guard try itemType(at: directory) == S_IFDIR else { throw PhotoIndexError.fileProtection }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700],
                ofItemAtPath: directory.path)
            var excludedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedDirectory.setResourceValues(values)
            try protectDatabase(at: directory.appendingPathComponent("index.sqlite"))
        } catch {
            throw PhotoIndexError.fileProtection
        }
    }

    /// Check before SQLite opens any existing files; do not follow a linked database or sidecar.
    static func validateDatabase(at database: URL) throws {
        try validateURL(database)
        for file in databaseFiles(at: database) {
            if let type = try itemType(at: file), type != S_IFREG {
                throw PhotoIndexError.fileProtection
            }
        }
    }

    static func protectDatabase(at database: URL) throws {
        try validateDatabase(at: database)
        do {
            for file in databaseFiles(at: database) where try itemType(at: file) != nil {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600],
                    ofItemAtPath: file.path)
            }
        } catch {
            throw PhotoIndexError.fileProtection
        }
    }

    private static func databaseFiles(at database: URL) -> [URL] {
        [database] + ["-journal", "-wal", "-shm"].map {
            URL(fileURLWithPath: database.path + $0)
        }
    }

    private static func validateURL(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw PhotoIndexError.invalidInput }
    }

    /// lstat inspects the link itself, including dangling links that fileExists would miss.
    private static func itemType(at url: URL) throws -> mode_t? {
        var metadata = stat()
        let result = url.path.withCString { lstat($0, &metadata) }
        if result == 0 { return metadata.st_mode & S_IFMT }
        if errno == ENOENT { return nil }
        throw PhotoIndexError.fileProtection
    }
}
