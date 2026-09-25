import Foundation

nonisolated struct LibraryPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
}
